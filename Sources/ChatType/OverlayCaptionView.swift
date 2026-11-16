import AppKit

/// Four rows are a subtitle viewport, not a limit on recognition or saved text.
@MainActor
struct OverlayCaptionText {
    static let font = NSFont.systemFont(ofSize: 22, weight: .medium)
    static func attributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 30; paragraph.maximumLineHeight = 30
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }
    static func lines(_ text: String, width: CGFloat) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Keep the current sentence, including a just-finished sentence, rather
        // than continually growing the subtitle with the whole recording.
        let stops = CharacterSet(charactersIn: "。！？!?\n")
        var segment = trimmed[...]
        let trailing = CharacterSet(charactersIn: "。！？!?\n\"'”’」』）)]")
        var contentEnd = trimmed.endIndex
        while contentEnd > trimmed.startIndex {
            let previous = trimmed.index(before: contentEnd)
            guard trimmed[previous].unicodeScalars.allSatisfy(trailing.contains) else { break }
            contentEnd = previous
        }
        if let boundary = trimmed[..<contentEnd].lastIndex(where: { $0.unicodeScalars.contains(where: stops.contains) }) {
            let next = trimmed.index(after: boundary)
            if next < trimmed.endIndex { segment = trimmed[next...] }
        }
        let value = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
        let storage = NSTextStorage(string: value, attributes: attributes())
        let manager = NSLayoutManager(); let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var result: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _,_,_,glyphs,_ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            result.append((value as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Array(result.suffix(4))
    }
}

/// A result is a fresh presentation even when its words match the live tail.
/// Only its own draw receipt starts reading time, after synchronous injection.
struct CaptionPresentationState {
    private(set) var generation = 0
    private(set) var awaitsFinalDraw = false
    mutating func change(final: Bool) -> Int { generation += 1; awaitsFinalDraw = final; return generation }
    mutating func didDraw(_ value: Int) -> Bool {
        guard value == generation, awaitsFinalDraw else { return false }
        awaitsFinalDraw = false; return true
    }
    mutating func reset() { generation += 1; awaitsFinalDraw = false }
}

@MainActor
final class OverlayCaptionPanel {
    private var panel: NSPanel?
    private let view = CaptionDrawingView()
    private let presentsPanel: Bool
    private var text = ""
    private var laidOutText = ""
    private var laidOutWidth: CGFloat = 0
    private(set) var displayedLines: [String] = []
    private(set) var frame = CGRect.zero
    private var state = CaptionPresentationState()
    var onFinalDraw: (() -> Void)?
    init(presentsPanel: Bool) {
        self.presentsPanel = presentsPanel
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.onDraw = { [weak self] generation in
            guard let self, self.state.didDraw(generation) else { return }
            self.onFinalDraw?()
        }
    }
    func update(_ value: String, final: Bool = false, hud: CGRect, visible: CGRect) {
        guard !value.isEmpty else { return }
        let changed = value != text
        guard changed || final else { return }
        text = value
        if changed || final { view.generation = state.change(final: final) }
        position(hud: hud, visible: visible)
        guard presentsPanel else { return }
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isFloatingPanel = true; p.hidesOnDeactivate = false
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.setAccessibilityLabel("ChatType 实时字幕")
            p.contentView = view; panel = p
        }
        panel?.setFrame(frame, display: false)
        view.needsDisplay = true
        panel?.orderFrontRegardless()
        panel?.displayIfNeeded()
    }
    func position(hud: CGRect, visible: CGRect) {
        guard !text.isEmpty else { return }
        let width = min(600, max(1, visible.width - 32))
        if text != laidOutText || width != laidOutWidth {
            displayedLines = OverlayCaptionText.lines(text, width: width - 32)
            laidOutText = text; laidOutWidth = width
            view.lines = displayedLines
            view.setAccessibilityValue(displayedLines.joined(separator: "\n"))
        }
        frame = TopOverlayLayout.caption(hud: hud, visible: visible, lines: displayedLines.count)
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
    }
    func reset() {
        state.reset(); text = ""; laidOutText = ""; displayedLines = []; view.lines = []
        panel?.orderOut(nil)
    }
    // Headless state tests acknowledge rendering without presenting a window.
    func debugAcknowledgeFinalDraw() {
        if state.didDraw(state.generation) { onFinalDraw?() }
    }
}

@MainActor
private final class CaptionDrawingView: NSView {
    var lines: [String] = []
    var generation = 0
    var onDraw: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.90).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let text = lines.joined(separator: "\n")
        (text as NSString).draw(in: bounds.insetBy(dx: 16, dy: 12), withAttributes: OverlayCaptionText.attributes())
        if window?.isVisible == true { onDraw?(generation) }
    }
}
