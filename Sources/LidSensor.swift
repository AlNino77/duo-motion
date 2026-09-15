import Foundation
import AppKit
import IOKit
import IOKit.hid
import QuartzCore

public final class LidSensor {
    public static let shared = LidSensor()
    
    public typealias TurnCallback = (_ turn: Double, _ angle: Double) -> Void
    public var onTurnUpdate: TurnCallback?
    public var onPreArmCapture: (() -> Void)?
    
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var isDeviceOpen = false
    private let hidQueue = DispatchQueue(label: "com.lqsky7.duomo.hid", qos: .userInitiated)
    private let hidStateLock = NSLock()
    private var hidTimer: DispatchSourceTimer?
    private var lastHIDReopenAttempt: CFTimeInterval = 0
    private var readFailureCount = 0
    private var latestRawAngle: Double = 120.0
    private var latestSampleTime: CFTimeInterval = 0
    private var latestReadSucceeded = false
    private var timer: Timer?
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    
    // Physics and motion tracking
    private var lastTime: CFTimeInterval?
    public private(set) var displayTurn: Double = 0.0
    public private(set) var targetTurn: Double = 0.0
    public private(set) var currentRawAngle: Double = 120.0
    private var previousRawAngle: Double = 120.0
    private var previousSampleTime: CFTimeInterval = 0
    private var smoothedAngularVelocity: Double = 0
    private var predictorAngle: Double = 120.0
    private var predictorVelocity: Double = 0
    private var predictorSampleTime: CFTimeInterval = 0
    private var isActivelyClosing: Bool = false
    private var hasPreArmedInThisMotion: Bool = false
    private var lastPreArmTime: CFTimeInterval = 0
    private var lastUIStatePublishTime: CFTimeInterval = 0
    private var stationaryFrames: Int = 0
    
    // Clamshell mode animation state (MacBook Neo, M1, etc.)
    private var isSimulating: Bool = false
    private var simulationStartTime: CFTimeInterval = 0
    private var simulationDuration: CFTimeInterval = 0.55
    private var simulationStartTurn: Double = 0.0
    private var simulationTargetTurn: Double = 0.0
    private var simulationStartAngle: Double = 120.0
    private var simulationTargetAngle: Double = 35.0
    private var lastKnownClamshellClosed: Bool = false
    
    private init() {
        setupManager()
        setupWakeAndSleepObservers()
    }
    
    deinit {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(center.removeObserver)
    }
    
    private func setupWakeAndSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObserverTokens.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObserverTokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
        workspaceObserverTokens.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
    }
    
    public func handleWake() {
        if AppSettings.shared.isHardwareSensor {
            resetPredictor(to: currentRawAngle)
            hidQueue.async { [weak self] in
                guard let self else { return }
                self.stopHIDPollingOnQueue(closeDevice: true)
                self.startHIDPollingOnQueue()
            }
        } else {
            // Clamshell mode: on wake / opening from sleep, animate unfold
            animateUnfold()
        }
    }
    
    public func handleWillSleep() {
        if !AppSettings.shared.isHardwareSensor {
            // Clamshell mode: animate fold on sleep
            animateFold()
        }
    }

    /// Check for the dedicated lid-angle sensor without opening HID devices.
    /// Nil means the registry query itself was inconclusive.
    private static func lidAngleSensorPresenceInIORegistry() -> Bool? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDDevice"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }

        var sawHIDDevice = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            sawHIDDevice = true
            defer { IOObjectRelease(service) }

            let product = (property(service, kIOHIDProductKey) as? String) ?? ""
            if product.lowercased() == "las" { return true }

            let pid = (property(service, kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let page = (property(service, kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue ?? 0
            let usage = (property(service, kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue ?? 0
            if pid == 0x8104, page == 0x0020, usage == 0x008A { return true }
        }
        return sawHIDDevice ? false : nil
    }
    
    private func setupManager() {
        if Self.lidAngleSensorPresenceInIORegistry() == false {
            activateClamshellMode(reason: "No continuous lid angle sensor found")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        
        // Multi-Strategy Hardware Sensor Probing:
        // STRICTLY match only sensor hardware (UsagePage 0x20, PID 0x8104, "las").
        // NEVER match keyboards or general input to prevent macOS from asking for "Keystroke Receiving" permission.
        let matchingCriteria: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104
            ],
            [
                kIOHIDPrimaryUsagePageKey as String: 0x0020,
                kIOHIDPrimaryUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            activateClamshellMode(reason: "Lid sensor HID access unavailable")
            return
        }
        self.hidManager = manager
        
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            activateClamshellMode(reason: "No sensor HID devices found")
            return
        }
        
        var foundDevice: IOHIDDevice?
        var detectedPid: Int = 0
        var detectedProd: String = ""
        
        for dev in devices {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            
            // Hard safety guard: Skip any keyboard, mouse, or pointer devices
            if page == 1 { continue }
            
            let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            
            let isCandidate = prod.lowercased() == "las" ||
                              prod.lowercased().contains("lid") ||
                              prod.lowercased().contains("angle") ||
                              (page == 32 && usage == 138)
            
            if isCandidate {
                if IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess {
                    var testReport = [UInt8](repeating: 0, count: 8)
                    var len: CFIndex = testReport.count
                    let res = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &testReport, &len)
                    IOHIDDeviceClose(dev, Self.noOptions)
                    
                    if res == kIOReturnSuccess && len >= 3 {
                        foundDevice = dev
                        detectedPid = pid
                        detectedProd = prod.isEmpty ? "las" : prod
                        break
                    }
                }
            }
        }
        
        if let dev = foundDevice {
            self.hidDevice = dev
            AppSettings.shared.isHardwareSensor = true
            AppSettings.shared.isClamshellMode = false
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Hardware Lid Angle Sensor connected (PID: 0x\(String(format: "%04X", detectedPid)) - \(detectedProd))."
        } else {
            // Hardware sensor not present on this machine (e.g. MacBook Neo, M1 Air, M1 Pro 13", iMac)
            activateClamshellMode(reason: "MacBook Neo / M1 without continuous LAS hardware")
        }
    }
    
    private func activateClamshellMode(reason: String) {
        self.hidDevice = nil
        AppSettings.shared.isHardwareSensor = false
        AppSettings.shared.isClamshellMode = true
        AppSettings.shared.isSensorConnected = true
        AppSettings.shared.sensorStatusMessage = "Clamshell Mode Active (MacBook Neo / M1 — Auto Sleep & Wake Animation Enabled)"
        lastKnownClamshellClosed = isLidClosedViaIORegistry()
    }
    
    private func isLidClosedViaIORegistry() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        
        if let prop = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return prop.boolValue
        }
        return false
    }
    
    // MARK: - Clamshell Mode Simulations (MacBook Neo & M1)
    
    public func animateUnfold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.55
        simulationStartTurn = max(0.85, displayTurn)
        simulationTargetTurn = 0.0
        simulationStartAngle = 35.0
        simulationTargetAngle = 120.0
        AppSettings.shared.isClosing = false
    }
    
    public func animateFold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.45
        simulationStartTurn = displayTurn
        simulationTargetTurn = 0.85
        simulationStartAngle = 120.0
        simulationTargetAngle = 35.0
        AppSettings.shared.isClosing = true
    }
    
    public func triggerPreviewAnimation() {
        animateFold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.animateUnfold()
        }
    }
    
    // The feature-report call can occasionally block while the Mac wakes.
    // Keep it away from the main run loop and publish only a small snapshot.
    private func startHIDPollingOnQueue() {
        guard hidTimer == nil else { return }
        _ = openHIDDeviceIfNeeded(force: true)

        let source = DispatchSource.makeTimerSource(queue: hidQueue)
        source.schedule(
            deadline: .now(),
            repeating: .nanoseconds(16_666_667),
            leeway: .milliseconds(2)
        )
        source.setEventHandler { [weak self] in
            self?.pollHIDOnce()
        }
        hidTimer = source
        source.resume()
    }

    private func stopHIDPollingOnQueue(closeDevice: Bool) {
        hidTimer?.setEventHandler {}
        hidTimer?.cancel()
        hidTimer = nil
        if closeDevice, isDeviceOpen, let device = hidDevice {
            IOHIDDeviceClose(device, Self.noOptions)
            isDeviceOpen = false
        }
        publishHIDReadFailure()
    }

    private func openHIDDeviceIfNeeded(force: Bool = false) -> Bool {
        if isDeviceOpen { return true }
        guard let device = hidDevice else { return false }

        let now = CACurrentMediaTime()
        if !force, now - lastHIDReopenAttempt < 1.0 { return false }
        lastHIDReopenAttempt = now
        if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
            isDeviceOpen = true
            readFailureCount = 0
            return true
        }
        return false
    }

    private func pollHIDOnce() {
        guard openHIDDeviceIfNeeded(), let device = hidDevice else {
            publishHIDReadFailure()
            return
        }

        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &report,
            &length
        )

        guard result == kIOReturnSuccess, length >= 3 else {
            readFailureCount += 1
            publishHIDReadFailure()
            if readFailureCount >= 3 {
                IOHIDDeviceClose(device, Self.noOptions)
                isDeviceOpen = false
            }
            return
        }

        readFailureCount = 0
        let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
        hidStateLock.lock()
        latestRawAngle = Double(rawValue)
        latestSampleTime = CACurrentMediaTime()
        latestReadSucceeded = true
        hidStateLock.unlock()
    }

    private func publishHIDReadFailure() {
        hidStateLock.lock()
        latestReadSucceeded = false
        hidStateLock.unlock()
    }

    private func latestHIDSample() -> (angle: Double, time: CFTimeInterval, succeeded: Bool) {
        hidStateLock.lock()
        defer { hidStateLock.unlock() }
        return (latestRawAngle, latestSampleTime, latestReadSucceeded)
    }

    private func resetPredictor(to angle: Double) {
        predictorAngle = angle
        predictorVelocity = 0
        predictorSampleTime = 0
        previousRawAngle = angle
        previousSampleTime = 0
        smoothedAngularVelocity = 0
    }

    private func updatePredictor(measured angle: Double, sampleTime: CFTimeInterval) {
        let dt = sampleTime - predictorSampleTime
        guard predictorSampleTime > 0, dt > 0, dt <= 0.25 else {
            predictorAngle = angle
            predictorVelocity = 0
            predictorSampleTime = sampleTime
            return
        }

        let measuredVelocity = (angle - previousRawAngle) / dt
        guard abs(measuredVelocity) <= 1_200 else {
            predictorAngle = angle
            predictorVelocity = 0
            predictorSampleTime = sampleTime
            return
        }

        let projectedAngle = predictorAngle + predictorVelocity * dt
        let correction = angle - projectedAngle
        predictorAngle = projectedAngle + correction * 0.35
        predictorVelocity += correction / dt * 0.08
        predictorVelocity = min(720, max(-720, predictorVelocity))
        predictorSampleTime = sampleTime
    }

    private func predictedAngle(measured angle: Double, sampleAge: CFTimeInterval) -> Double {
        guard isActivelyClosing, smoothedAngularVelocity < -3 else { return angle }
        let horizon = min(0.08, max(0, sampleAge) + 0.045)
        let estimate = predictorAngle + predictorVelocity * horizon
        let lead = min(8.0, max(-8.0, estimate - angle))
        return min(180, max(0, angle + lead))
    }

    public func start() {
        guard timer == nil else { return }
        
        if AppSettings.shared.isHardwareSensor {
            hidQueue.async { [weak self] in
                self?.startHIDPollingOnQueue()
            }
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    public func stop() {
        timer?.invalidate()
        timer = nil
        hidQueue.async { [weak self] in
            self?.stopHIDPollingOnQueue(closeDevice: true)
        }
    }
    
    private func tick() {
        let settings = AppSettings.shared
        
        if settings.isHardwareSensor {
            let nowTime = CACurrentMediaTime()
            let sample = latestHIDSample()
            let sampleAge = nowTime - sample.time

            if sample.succeeded, sample.time > previousSampleTime, sampleAge <= 0.25 {
                let angle = sample.angle
                let sampleInterval = sample.time - previousSampleTime

                if previousSampleTime > 0, sampleInterval > 0 {
                    let instantVelocity = (angle - previousRawAngle) / sampleInterval
                    smoothedAngularVelocity = smoothedAngularVelocity * 0.65 + instantVelocity * 0.35
                    updatePredictor(measured: angle, sampleTime: sample.time)

                    let isMovingDownward = smoothedAngularVelocity < -18
                    let isMovingUpward = smoothedAngularVelocity > 24
                    if isMovingDownward {
                        isActivelyClosing = true
                        stationaryFrames = 0
                    } else if isMovingUpward {
                        isActivelyClosing = false
                        hasPreArmedInThisMotion = false
                        stationaryFrames = 0
                    } else {
                        stationaryFrames += 1
                        if stationaryFrames > 12 { // ~200ms of no downward movement
                            isActivelyClosing = false
                        }
                    }
                } else {
                    resetPredictor(to: angle)
                    predictorSampleTime = sample.time
                }

                // If lid is safely open, reset pre-arm latch and mark capture engine dormant
                if angle >= settings.startTiltAngle || (!isActivelyClosing && angle >= settings.startTiltAngle - 10.0) {
                    hasPreArmedInThisMotion = false
                    if !settings.isScreenCaptureDormant {
                        settings.isScreenCaptureDormant = true
                    }
                }

                // Wake capture shortly before the configured fold range.
                let preArmThreshold = min(135.0, settings.startTiltAngle + 15.0)
                if angle <= preArmThreshold && angle < settings.startTiltAngle {
                    if !hasPreArmedInThisMotion && nowTime - lastPreArmTime > 2.0 {
                        hasPreArmedInThisMotion = true
                        lastPreArmTime = nowTime
                        settings.isScreenCaptureDormant = false
                        onPreArmCapture?()
                    }
                }

                previousRawAngle = angle
                previousSampleTime = sample.time
                currentRawAngle = angle
                if nowTime - lastUIStatePublishTime >= 1.0 / 15.0 {
                    lastUIStatePublishTime = nowTime
                    settings.currentLidAngle = angle
                }
                if settings.isClosing != isActivelyClosing {
                    settings.isClosing = isActivelyClosing
                }
                if !settings.isSensorConnected {
                    settings.isSensorConnected = true
                }
            } else if sample.time > 0, sampleAge > 0.5, settings.isSensorConnected {
                settings.isSensorConnected = false
                settings.sensorStatusMessage = "Waiting for the lid angle sensor to resume."
            }

            // The tile keeps the measured angle. Only the animation receives this
            // bounded prediction while the lid is actively closing.
            let renderAngle = predictedAngle(
                measured: currentRawAngle,
                sampleAge: sample.time > 0 ? sampleAge : 0
            )
            targetTurn = settings.normalizedTurn(for: renderAngle)

            // Follow easing physics
            let now = nowTime
            let dt: Double
            if let last = lastTime {
                dt = min(now - last, 0.1)
            } else {
                dt = 1.0 / 60.0
            }
            lastTime = now
            
            let follow = settings.followSpeed
            let factor = 1.0 - exp(-dt * follow)
            displayTurn += (targetTurn - displayTurn) * factor
            if abs(targetTurn - displayTurn) < 0.0005 {
                displayTurn = targetTurn
            }
        } else {
            // Clamshell Mode (MacBook Neo, M1, etc.)
            let currentClosed = isLidClosedViaIORegistry()
            if currentClosed != lastKnownClamshellClosed {
                lastKnownClamshellClosed = currentClosed
                if currentClosed {
                    animateFold()
                } else {
                    animateUnfold()
                }
            }
            
            if isSimulating {
                let elapsed = CACurrentMediaTime() - simulationStartTime
                let t = min(1.0, elapsed / simulationDuration)
                // Smooth cubic ease out
                let ease = 1.0 - pow(1.0 - t, 3.0)
                displayTurn = simulationStartTurn + (simulationTargetTurn - simulationStartTurn) * ease
                currentRawAngle = simulationStartAngle + (simulationTargetAngle - simulationStartAngle) * ease
                settings.currentLidAngle = currentRawAngle
                
                if t >= 1.0 {
                    isSimulating = false
                    displayTurn = simulationTargetTurn
                    currentRawAngle = simulationTargetAngle
                    settings.currentLidAngle = currentRawAngle
                }
            } else if settings.isTestModeActive {
                displayTurn = settings.normalizedTurn(for: 120.0)
                currentRawAngle = 120.0 - displayTurn * 85.0
                settings.currentLidAngle = currentRawAngle
            } else {
                displayTurn = 0.0
                currentRawAngle = 120.0
                settings.currentLidAngle = 120.0
            }
        }
        
        onTurnUpdate?(displayTurn, currentRawAngle)
    }
}
