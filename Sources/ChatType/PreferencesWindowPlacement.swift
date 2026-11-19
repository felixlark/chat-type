import AppKit
import CoreGraphics

struct PreferencesScreenGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let isBuiltIn: Bool
}

enum PreferencesWindowPlacement {
    static func maximizedFrame(in screens: [PreferencesScreenGeometry]) -> CGRect? {
        (screens.first(where: \.isBuiltIn) ?? screens.first)?.visibleFrame
    }

    static func screens() -> [PreferencesScreenGeometry] {
        NSScreen.screens.map { screen in
            PreferencesScreenGeometry(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isBuiltIn: isBuiltIn(screen)
            )
        }
    }

    static func isBuiltIn(_ screen: NSScreen?) -> Bool {
        guard let screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
