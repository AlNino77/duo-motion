import Foundation
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit DuoMo",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory app with menu bar item, but allow control panel window activation
        NSApp.setActivationPolicy(.accessory)
        setupApplicationMenu()
        
        // Initialize subsystems
        _ = MenuBarController.shared
        _ = OverlayWindowController.shared
        
        let sensor = LidSensor.shared
        sensor.onTurnUpdate = { turn, angle in
            OverlayWindowController.shared.update(turn: turn, angle: angle)
        }
        sensor.start()
        
        // Open the single control panel. Permission guidance lives inline there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MenuBarController.shared.openControlPanel()
        }
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        LidSensor.shared.stop()
    }
}
