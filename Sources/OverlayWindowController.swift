import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private enum MotionDirection: Float {
        case opening = -1.0
        case idle = 0.0
        case closing = 1.0
    }
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
    private var isCapturing = false
    private var overlayLatched = false
    private var preArmCapturedThisMotion = false
    private var lastRawAngle: Double?
    private var motionDirection: MotionDirection = .idle
    private var lastPermissionProbe: TimeInterval = 0
    private var suppressForClamshell = false
    private var displayReconfigurationObserver: NSObjectProtocol?
    private var stillSince: TimeInterval = 0
    private var stillLow: Double = 0
    private var stillHigh: Double = 0
    private var isReleasing = false
    private var isReleased = false
    private var releaseStartTime: TimeInterval = 0
    private var releaseFromTurn: Double = 0
    private var releasedAtTarget: Double = 0
    private var releasedFloor: Double = 0
    private var reengageStartTime: TimeInterval = 0
    private static let motionBand = 0.03
    private static let autoReleaseDelay: TimeInterval = 1.0
    private static let releaseDuration: TimeInterval = 0.45
    private static let reengageDuration: TimeInterval = 0.18
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        
        // Keep the upstream pre-arm hook as a compatible fallback. This controller also
        // pre-arms directly from the raw angle so capture can happen before the visual trigger.
        LidSensor.shared.onPreArmCapture = { [weak self] in
            self?.captureScreenAsync()
        }

        refreshSuppression()
        displayReconfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayReconfiguration()
        }
    }

    deinit {
        if let displayReconfigurationObserver {
            NotificationCenter.default.removeObserver(displayReconfigurationObserver)
        }
    }

    /// Permission can change in System Settings while DuoMo remains active.
    private func capturePermissionIsGranted() -> Bool {
        let settings = AppSettings.shared
        if settings.hasScreenRecordingPermission { return true }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPermissionProbe >= 1.0 else { return false }
        lastPermissionProbe = now
        let granted = ScreenCapture.shared.hasPermission()
        if granted { settings.hasScreenRecordingPermission = true }
        return granted
    }
    
    private func setupSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
    }

    private static func foldScreen() -> NSScreen? {
        DisplayTopology.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshSuppression() {
        suppressForClamshell = DisplayTopology.isClamshellDesktop
    }

    private func handleDisplayReconfiguration() {
        refreshSuppression()
        ScreenCapture.shared.invalidateCaches()
        if suppressForClamshell {
            stopOverlay()
            return
        }
        if let screen = DisplayTopology.builtInScreen() {
            window?.setFrame(screen.frame, display: false)
        }
    }

    /// A transparent top-level window still participates in WindowServer
    /// composition. Ordering it out is the only truthful idle state.
    private func hideOverlay(resetProgress: Bool = true) {
        window?.alphaValue = 0.0
        window?.orderOut(nil)
        metalView?.isPaused = true
        if resetProgress {
            metalView?.currentTurn = 0.0
            metalView?.closureProgress = 0.0
            metalView?.motionDirection = MotionDirection.idle.rawValue
        }
    }
    
    private func handleSleep() {
        hideOverlay()
        resetAutoRelease()
        overlayLatched = false
        preArmCapturedThisMotion = false
        lastRawAngle = nil
        motionDirection = .idle
        AppSettings.shared.isScreenCaptureDormant = true
    }
    
    private func handleWake() {
        // Keep the overlay hidden until the first real angle sample arrives. If the lid
        // is still inside the effect range, update(turn:angle:) will latch it immediately
        // and play the opening motion from the physical sensor position.
        overlayLatched = false
        preArmCapturedThisMotion = false
        lastRawAngle = nil
        motionDirection = .idle
        resetAutoRelease()
        refreshSuppression()
        guard !suppressForClamshell else {
            hideOverlay()
            AppSettings.shared.isScreenCaptureDormant = true
            return
        }
        
        if let win = self.window, AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        if AppSettings.shared.imageSourceMode == .liveCapture {
            captureScreenAsync()
        }
    }
    
    private func setupWindow() {
        guard let screen = Self.foldScreen() else { return }
        
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.canBecomeVisibleWithoutLogin = true
        if AppSettings.shared.enableLockScreenPriority {
            win.level = .init(rawValue: Int(Int32.max - 2))
        } else {
            win.level = .screenSaver
        }
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.alphaValue = 0.0
        
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView
        
        Task {
            if let img = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(img)
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }

    private func resetAutoRelease() {
        stillSince = 0
        stillLow = 0
        stillHigh = 0
        isReleasing = false
        isReleased = false
        releaseStartTime = 0
        releaseFromTurn = 0
        releasedAtTarget = 0
        releasedFloor = 0
        reengageStartTime = 0
    }

    private func resolveAutoRelease(
        sensorTurn: Double,
        sensorTarget: Double,
        angle: Double
    ) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let settings = AppSettings.shared

        if sensorTarget <= 0.0005 {
            resetAutoRelease()
            return sensorTurn
        }

        if isReleasing {
            if abs(sensorTarget - releasedAtTarget) > Self.motionBand {
                isReleasing = false
                stillSince = 0
                stillLow = sensorTarget
                stillHigh = sensorTarget
                return sensorTurn
            }
            let t = min(1.0, (now - releaseStartTime) / Self.releaseDuration)
            let eased = 1.0 - pow(1.0 - t, 3.0)
            let value = releaseFromTurn * (1.0 - eased)
            if t >= 1.0 {
                isReleasing = false
                isReleased = true
                releasedFloor = sensorTarget
                stillSince = 0
                return 0
            }
            return value
        }

        if isReleased {
            if sensorTarget < releasedFloor - Self.motionBand {
                releasedFloor = sensorTarget
            }
            guard sensorTarget > releasedFloor + Self.motionBand else { return 0 }
            isReleased = false
            reengageStartTime = now
            stillSince = 0
            stillLow = sensorTarget
            stillHigh = sensorTarget
        }

        guard settings.isHardwareSensor,
              !settings.isTestModeActive,
              angle > settings.endTiltAngle + 5.0 else {
            stillSince = 0
            stillLow = sensorTarget
            stillHigh = sensorTarget
            return sensorTurn
        }

        if sensorTarget < stillLow { stillLow = sensorTarget }
        if sensorTarget > stillHigh { stillHigh = sensorTarget }
        if stillHigh - stillLow > Self.motionBand {
            stillLow = sensorTarget
            stillHigh = sensorTarget
            stillSince = now
        } else if stillSince == 0 {
            stillSince = now
        }

        if stillSince > 0, now - stillSince >= Self.autoReleaseDelay {
            isReleasing = true
            releaseStartTime = now
            releaseFromTurn = sensorTurn
            releasedAtTarget = sensorTarget
        }

        if reengageStartTime > 0 {
            let t = min(1.0, (now - reengageStartTime) / Self.reengageDuration)
            if t >= 1.0 { reengageStartTime = 0 }
            let eased = 1.0 - pow(1.0 - t, 3.0)
            return sensorTurn * eased
        }
        return sensorTurn
    }
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }
        
        let settings = AppSettings.shared
        guard capturePermissionIsGranted() else {
            stopOverlay()
            return
        }
        if !overlayLatched && turn > 0.0001 {
            refreshSuppression()
        }
        guard !suppressForClamshell else {
            stopOverlay()
            return
        }
        updateMotionDirection(with: angle)
        let resolvedTurn = resolveAutoRelease(
            sensorTurn: turn,
            sensorTarget: settings.normalizedTurn(for: angle),
            angle: angle
        )
        
        let startAngle = settings.startTiltAngle
        let endAngle = min(settings.endTiltAngle, startAngle - 16.0)
        let preferredFullEffectAngle = 60.0
        let fullEffectAngle = min(startAngle - 8.0, max(endAngle + 8.0, preferredFullEffectAngle))
        
        // Pre-arm the screenshot before any overlay is visible. This avoids one-frame
        // flashes of an old texture when the user closes the lid quickly.
        let preArmAngle = min(135.0, startAngle + 15.0)
        if motionDirection == .closing,
           angle <= preArmAngle,
           angle > startAngle,
           !preArmCapturedThisMotion,
           settings.imageSourceMode == .liveCapture {
            preArmCapturedThisMotion = true
            captureScreenAsync()
        }
        if motionDirection == .opening && angle >= preArmAngle {
            preArmCapturedThisMotion = false
        }
        
        let effectProgress: Double
        let closureProgress: Double
        
        if settings.isTestModeActive {
            effectProgress = min(1.0, max(0.0, resolvedTurn / 0.58))
            closureProgress = min(1.0, max(0.0, (resolvedTurn - 0.58) / 0.42))
        } else {
            // turn is already exponentially smoothed by LidSensor. Reconstructing an
            // effective angle from it gives the shader a stable, low-jitter physical input.
            let effectiveAngle = startAngle - resolvedTurn * (startAngle - endAngle)
            let effectRange = max(1.0, startAngle - fullEffectAngle)
            let closeRange = max(1.0, fullEffectAngle - endAngle)
            effectProgress = min(1.0, max(0.0, (startAngle - effectiveAngle) / effectRange))
            closureProgress = min(1.0, max(0.0, (fullEffectAngle - effectiveAngle) / closeRange))
        }
        
        mv.currentTurn = Float(effectProgress)
        mv.closureProgress = Float(closureProgress)
        mv.motionDirection = motionDirection.rawValue
        mv.blurStrength = Float(settings.blurStrength)
        mv.reflectionIntensity = Float(settings.reflectionIntensity)
        
        let releaseAngle = min(135.0, startAngle + 8.0)
        let hasVisibleEffect = effectProgress > 0.0001 || closureProgress > 0.0001
        
        if hasVisibleEffect {
            overlayLatched = true
        }
        if isReleased && resolvedTurn <= 0.0005 {
            overlayLatched = false
        }
        
        if motionDirection == .opening && angle >= releaseAngle {
            overlayLatched = false
        } else if !hasVisibleEffect && angle >= releaseAngle {
            overlayLatched = false
        }
        
        if overlayLatched {
            let wasHidden = win.alphaValue < 0.5
            if wasHidden {
                if let builtIn = DisplayTopology.builtInScreen(), win.frame != builtIn.frame {
                    win.setFrame(builtIn.frame, display: false)
                }
                win.alphaValue = 1.0
                win.orderFrontRegardless()
                if settings.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                
                // Fallback for an exceptionally fast close that jumped over the pre-arm zone.
                if settings.imageSourceMode == .liveCapture && !preArmCapturedThisMotion {
                    preArmCapturedThisMotion = true
                    captureScreenAsync()
                }
            }
            mv.isPaused = false
        } else {
            hideOverlay()
            if angle >= preArmAngle {
                preArmCapturedThisMotion = false
            }
        }
    }
    
    private func updateMotionDirection(with angle: Double) {
        defer { lastRawAngle = angle }
        guard let previous = lastRawAngle else { return }
        
        let delta = angle - previous
        // Direction is intentionally sticky while the lid is stationary. If the user
        // pauses midway through an opening, the opening optical curve should not suddenly
        // snap back to the closing curve just because velocity reached zero.
        if delta < -0.35 {
            motionDirection = .closing
        } else if delta > 0.45 {
            motionDirection = .opening
        }
    }
    
    public func stopOverlay() {
        resetAutoRelease()
        overlayLatched = false
        preArmCapturedThisMotion = false
        lastRawAngle = nil
        motionDirection = .idle
        hideOverlay()
    }
    
    public func updateWindowLevel() {
        guard let win = self.window else { return }
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        } else {
            win.level = .screenSaver
        }
    }
    
    public func captureScreenAsync() {
        refreshSuppression()
        guard !suppressForClamshell else {
            AppSettings.shared.isScreenCaptureDormant = true
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        AppSettings.shared.isScreenCaptureDormant = false
        
        Task {
            if let image = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(image)
                    self.isCapturing = false
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            } else {
                await MainActor.run {
                    self.isCapturing = false
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }
}
