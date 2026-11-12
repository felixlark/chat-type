import AppKit

@MainActor
final class OverlayTranscriptView: NSScrollView {
    private let text = NSTextView()
    private var changingProgrammatically = false
    private var renderedWidth: CGFloat?
    private var renderedCompact: Bool?
    private(set) var followsLatest = true
    var onFollowingChanged: ((Bool) -> Void)?
    private(set) var desiredHeight: CGFloat = 40
    var fullText: String { text.string }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        documentView = text
        setAccessibilityLabel("实时转写全文")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ value: String, width: CGFloat, compact: Bool) {
        guard value != text.string || renderedWidth != width || renderedCompact != compact else { return }
        renderedWidth = width; renderedCompact = compact
        changingProgrammatically = true
        defer { changingProgrammatically = false }
        let previous = contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        paragraph.lineBreakMode = .byWordWrapping
        if text.string != value {
            text.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: ChatTypePalette.mist,
                .paragraphStyle: paragraph]))
        }
        text.textContainer?.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let height = ceil(text.layoutManager?.usedRect(for: text.textContainer!).height ?? 40)
        desiredHeight = min(compact ? 40 : 80, max(40, height))
        text.setFrameSize(NSSize(width: max(1, width - 16), height: max(height, desiredHeight)))
        if followsLatest { scrollToLatest() }
        else { contentView.scroll(to: previous); reflectScrolledClipView(contentView) }
    }
    func scrollToLatest() {
        let previous = changingProgrammatically
        changingProgrammatically = true
        defer { changingProgrammatically = previous }
        contentView.scroll(to: CGPoint(x: 0, y: max(0, text.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
    func resumeFollowing() {
        followsLatest = true
        scrollToLatest()
        onFollowingChanged?(true)
    }
    func reset() {
        followsLatest = true
        text.string = ""
        renderedWidth = nil; renderedCompact = nil
        onFollowingChanged?(true)
    }
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        guard !changingProgrammatically, let event = NSApp.currentEvent,
              [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
        userDidScroll()
    }
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        userDidScroll()
    }
    func userDidScroll() {
        followsLatest = contentView.bounds.maxY >= text.bounds.maxY - 2
        onFollowingChanged?(followsLatest)
    }
}

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
