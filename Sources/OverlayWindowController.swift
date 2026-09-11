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
    private var lastRawAngle: Double?
    private var motionDirection: MotionDirection = .idle
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        
        // Connect intelligent hardware pre-arming.
        LidSensor.shared.onPreArmCapture = { [weak self] in
            self?.captureScreenAsync()
        }
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
    
    private func handleSleep() {
        metalView?.isPaused = true
        window?.alphaValue = 0.0
        overlayLatched = false
        lastRawAngle = nil
        motionDirection = .idle
        AppSettings.shared.isScreenCaptureDormant = true
    }
    
    private func handleWake() {
        // Keep the overlay hidden until the first real angle sample arrives. If the lid
        // is still inside the effect range, update(turn:angle:) will latch it immediately
        // and play the opening motion from the physical sensor position.
        overlayLatched = false
        lastRawAngle = nil
        motionDirection = .idle
        
        if let win = self.window, AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        if AppSettings.shared.imageSourceMode == .liveCapture {
            captureScreenAsync()
        }
    }
    
    private func setupWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        
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
        
        // One-time initial image load in background during app launch.
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
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }
        
        let settings = AppSettings.shared
        updateMotionDirection(with: angle)
        
        // The upstream app maps the entire physical close into 0...1. Duo motion is
        // intentionally front-loaded: the spatial fold reaches full depth around 60°,
        // while the remaining travel is reserved for the dark horizon / final blackout.
        let startAngle = settings.startTiltAngle
        let endAngle = min(settings.endTiltAngle, startAngle - 16.0)
        let preferredFullEffectAngle = 60.0
        let fullEffectAngle = min(startAngle - 8.0, max(endAngle + 8.0, preferredFullEffectAngle))
        
        let effectProgress: Double
        let closureProgress: Double
        
        if settings.isTestModeActive {
            // Keep the preview slider useful even though the live hardware path is now
            // split into spatial-effect and final-closure phases.
            effectProgress = min(1.0, max(0.0, turn / 0.58))
            closureProgress = min(1.0, max(0.0, (turn - 0.58) / 0.42))
        } else {
            // turn is already exponentially smoothed by LidSensor. Reconstructing an
            // effective angle from it gives the shader a stable, low-jitter physical input.
            let effectiveAngle = startAngle - turn * (startAngle - endAngle)
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
        
        // Latch the overlay once the fold begins. On the way back up, keep it alive
        // slightly beyond the trigger angle so a hand hovering around ~90° cannot make
        // the overlay flicker on/off. The last few degrees are a sharp 1:1 snapshot,
        // making the handoff back to the real desktop visually invisible.
        if hasVisibleEffect {
            overlayLatched = true
        }
        
        if motionDirection == .opening && angle >= releaseAngle {
            overlayLatched = false
        } else if !hasVisibleEffect && angle >= releaseAngle {
            overlayLatched = false
        }
        
        if overlayLatched {
            let wasHidden = win.alphaValue < 0.5
            if wasHidden {
                win.alphaValue = 1.0
                win.orderFrontRegardless()
                if settings.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                
                // Pre-arm normally gives us the frame already. This is a fallback for a
                // fast close, wake/unfold, or a user who disabled/re-enabled the effect.
                if settings.imageSourceMode == .liveCapture {
                    captureScreenAsync()
                }
            }
            mv.isPaused = false
        } else {
            win.alphaValue = 0.0
            mv.isPaused = true
            mv.currentTurn = 0.0
            mv.closureProgress = 0.0
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
        overlayLatched = false
        lastRawAngle = nil
        motionDirection = .idle
        window?.alphaValue = 0.0
        metalView?.isPaused = true
        metalView?.currentTurn = 0.0
        metalView?.closureProgress = 0.0
        metalView?.motionDirection = MotionDirection.idle.rawValue
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
