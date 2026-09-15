import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject, NSWindowDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var angleMenuItem: NSMenuItem?
    private var lastRenderedConnectedState: Bool?
    private var lastRenderedHardwareState: Bool?
    private var lastRenderedClosingState: Bool?
    
    public override init() {
        super.init()
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "DuoMo")
            button.imagePosition = .imageLeading
            button.title = ""
        }
        
        let menu = NSMenu()
        
        let header = NSMenuItem(title: "DuoMo", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        let angleItem = NSMenuItem(title: "Sensor: Connecting...", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openSettings = NSMenuItem(title: "Open Settings...", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)

        let captureItem = NSMenuItem(title: "Capture Current Screen", action: #selector(recaptureScreen), keyEquivalent: "r")
        captureItem.target = self
        menu.addItem(captureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit DuoMo", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
        
        refreshMenuBarTitle()
    }
    
    public func updateAngleDisplay(angle _: Double, isConnected: Bool) {
        let isHardwareSensor = AppSettings.shared.isHardwareSensor
        let isClosing = AppSettings.shared.isClosing
        guard isConnected != lastRenderedConnectedState ||
                isHardwareSensor != lastRenderedHardwareState ||
                isClosing != lastRenderedClosingState else {
            return
        }

        lastRenderedConnectedState = isConnected
        lastRenderedHardwareState = isHardwareSensor
        lastRenderedClosingState = isClosing

        statusItem?.button?.title = ""
        
        if let angleItem = self.angleMenuItem {
            if isConnected {
                if isHardwareSensor {
                    angleItem.title = isClosing ? "Sensor: Folding" : "Sensor: Ready"
                } else {
                    angleItem.title = "Mode: Clamshell Auto-Animation"
                }
            } else {
                angleItem.title = "Lid Sensor: Disconnected"
            }
        }
    }
    
    public func refreshMenuBarTitle() {
        statusItem?.button?.title = ""
    }
    
    @objc public func openControlPanel() {
        if let existing = controlPanelWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? LiquidGlassControlPanel.preferredHeight
        let panelHeight = min(
            LiquidGlassControlPanel.preferredHeight,
            max(360, visibleHeight - 36)
        )

        let win = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 460,
                height: panelHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentViewController = NSHostingController(
            rootView: LiquidGlassControlPanel(panelHeight: panelHeight)
        )
        win.isReleasedWhenClosed = false
        
        self.controlPanelWindow = win
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate
    
    public func windowWillClose(_ notification: Notification) {
        // When the control panel is dismissed, always clear test mode so the
        // fold overlay doesn't stay frozen on screen.
        if AppSettings.shared.isTestModeActive {
            AppSettings.shared.isTestModeActive = false
            AppSettings.shared.testTurnValue = 0.0
        }
    }
    
    @objc private func recaptureScreen() {
        OverlayWindowController.shared.captureScreenAsync()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
