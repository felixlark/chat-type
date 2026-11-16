import CoreGraphics

struct TopOverlayLayout {
    static func hud(size: CGSize, visible: CGRect, safeTop: CGFloat, inset: CGFloat = 16) -> CGRect {
        let fitted = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        return CGRect(x: visible.midX - fitted.width / 2,
                      y: max(visible.minY, min(visible.maxY, safeTop) - inset - fitted.height),
                      width: fitted.width, height: fitted.height)
    }
    static func caption(hud: CGRect, visible: CGRect, lines: Int) -> CGRect {
        let width = min(600, max(1, visible.width - 32))
        let height = CGFloat(max(2, lines)) * 30 + 24
        return CGRect(x: visible.midX - width / 2, y: hud.minY - 12 - height, width: width, height: height)
    }
}
