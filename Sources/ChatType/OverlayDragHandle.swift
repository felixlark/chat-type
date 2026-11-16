import AppKit

@MainActor
final class OverlayDragHandle: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onChange: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBegin?(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        onChange?(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        onEnd?(window.convertPoint(toScreen: event.locationInWindow))
    }
}
