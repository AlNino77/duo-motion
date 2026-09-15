import AppKit
import CoreGraphics
import IOKit

/// Hardware-backed display decisions for the fold overlay.
enum DisplayTopology {
    static let isPortableHardware: Bool = {
        let root = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(
            root,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() != nil
    }()

    static func builtInScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID else {
                continue
            }
            if CGDisplayIsBuiltin(displayID) != 0 { return screen }
        }
        return nil
    }

    static func isBuiltInPanelAsleepOrGone() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return false }
        for index in 0..<Int(count) {
            if CGDisplayIsBuiltin(displays[index]) != 0 {
                return CGDisplayIsAsleep(displays[index]) != 0
            }
        }
        return true
    }

    static func hasBuiltInPanelOnline() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return false }
        for index in 0..<Int(count) where CGDisplayIsBuiltin(displays[index]) != 0 {
            return true
        }
        return false
    }

    static var isClamshellDesktop: Bool {
        (isPortableHardware || hasBuiltInPanelOnline()) && isBuiltInPanelAsleepOrGone()
    }

    static func builtInBackingScale() -> CGFloat {
        (builtInScreen() ?? NSScreen.main)?.backingScaleFactor ?? 2.0
    }
}
