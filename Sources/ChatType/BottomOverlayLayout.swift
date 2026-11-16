import AppKit
import ApplicationServices

struct BottomOverlayLayout {
    struct Placement {
        let frame: CGRect
        let needsAdjustment: Bool
    }
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
    static func place(size: CGSize, visible: CGRect, protected: [CGRect], preferred: CGPoint? = nil, manual: Bool = false) -> Placement {
        let fitted = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        if manual, let preferred {
            let fallback = clamp(CGRect(origin: preferred, size: fitted), to: visible)
            var xs = [preferred.x, visible.minX, visible.maxX - fitted.width]
            var ys = [preferred.y, visible.minY, visible.maxY - fitted.height]
            for area in protected {
                xs += [area.minX - fitted.width - 12, area.maxX + 12]
                ys += [area.minY - fitted.height - 12, area.maxY + 12]
            }
            var nearest: CGRect?
            var distance = CGFloat.infinity
            for x in xs {
                for y in ys {
                    let frame = clamp(CGRect(origin: CGPoint(x: x, y: y), size: fitted), to: visible)
                    guard !protected.contains(where: { $0.intersects(frame) }) else { continue }
                    let squared = pow(frame.minX - preferred.x, 2) + pow(frame.minY - preferred.y, 2)
                    if squared < distance { nearest = frame; distance = squared }
                }
            }
            return Placement(frame: nearest ?? fallback, needsAdjustment: nearest == nil)
        }
        let bottom = visible.minY + 24
        let center = visible.midX - fitted.width / 2
        var origins: [CGPoint] = []
        if let preferred { origins.append(preferred) }
        origins.append(CGPoint(x: center, y: bottom))
        origins += protected.map { CGPoint(x: center, y: $0.maxY + 12) }
        origins += [CGPoint(x: visible.minX + 16, y: bottom), CGPoint(x: visible.maxX - fitted.width - 16, y: bottom)]
        for origin in origins {
            let frame = clamp(CGRect(origin: origin, size: fitted), to: visible)
            if !protected.contains(where: { $0.intersects(frame) }) {
                return Placement(frame: frame, needsAdjustment: false)
            }
        }
        return Placement(frame: clamp(CGRect(x: center, y: bottom, width: fitted.width, height: fitted.height), to: visible), needsAdjustment: true)
    }
}

/// Geometry only: no text, credentials or AX permission requests are read here.
@MainActor
struct OverlayFocusGeometry {
    let protected: [CGRect]
    let hasEditableGeometry: Bool
    static func read(visible: CGRect) -> Self {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let primary = NSScreen.screens.first else { return Self(protected: [], hasEditableGeometry: false) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, key as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func rect(_ source: AXUIElement) -> CGRect? {
            var p: CFTypeRef?; var s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(source, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero; var size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
            return OverlayPlacementSession.appKitFrame(fromAccessibility: CGRect(origin: point, size: size), primaryScreenTop: primary.frame.maxY)
        }
        guard let focus = element(root, kAXFocusedUIElementAttribute as String) else { return Self(protected: [], hasEditableGeometry: false) }
        var role: CFTypeRef?; var range: CFTypeRef?
        AXUIElementCopyAttributeValue(focus, kAXRoleAttribute as CFString, &role)
        let hasRange = AXUIElementCopyAttributeValue(focus, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        guard hasRange || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? ""), let edit = rect(focus) else {
            return Self(protected: [], hasEditableGeometry: false)
        }
        let window = element(root, kAXFocusedWindowAttribute as String).flatMap { rect($0) } ?? edit
        if edit.height < visible.height * 0.3 {
            return Self(protected: [CGRect(x: window.minX, y: edit.minY - 12, width: window.width, height: edit.height + 24)], hasEditableGeometry: true)
        }
        var areas = [CGRect(x: window.minX, y: window.minY, width: window.width, height: 48)]
        if let range {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focus, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
               let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var caret = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &caret) {
                    areas.append(OverlayPlacementSession.appKitFrame(fromAccessibility: caret, primaryScreenTop: primary.frame.maxY).insetBy(dx: -24, dy: -24))
                }
            }
        }
        return Self(protected: areas, hasEditableGeometry: true)
    }
}
