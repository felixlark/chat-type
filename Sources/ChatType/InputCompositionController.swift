import AppKit

struct InputCompositionAnchor {
    let caret: CGRect
    let input: CGRect
    let font: NSFont
    let foreground: NSColor
    let background: NSColor
}

@MainActor
protocol InputCompositionPresenting: AnyObject {
    func show(_ text: String, anchor: @escaping @MainActor () async -> InputCompositionAnchor?)
    func hide()
}

/// A provisional composition at the input, separate from the state HUD.
@MainActor
final class InputCompositionController: InputCompositionPresenting {
    private var panel: NSPanel?
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let surface = NSView()
    private var value = ""
    private var anchorProvider: (@MainActor () async -> InputCompositionAnchor?)?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    func show(_ text: String, anchor: @escaping @MainActor () async -> InputCompositionAnchor?) {
        value = text
        anchorProvider = anchor
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func hide() {
        generation += 1
        timer?.invalidate(); timer = nil
        refreshTask?.cancel(); refreshTask = nil
        anchorProvider = nil
        panel?.orderOut(nil)
    }

    private func refresh() {
        guard refreshTask == nil, let anchorProvider else { return }
        let current = generation
        refreshTask = Task { [weak self] in
            let anchor = await anchorProvider()
            guard let self, self.generation == current, !Task.isCancelled else { return }
            defer { self.refreshTask = nil }
            guard let anchor else { self.panel?.orderOut(nil); return }
            self.render(anchor)
        }
    }

    private func render(_ anchor: InputCompositionAnchor) {
        guard !value.isEmpty else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            surface.wantsLayer = true
            surface.layer?.cornerRadius = 6
            surface.layer?.borderWidth = 1
            textView.isEditable = false; textView.isSelectable = false
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.documentView = textView
            scroll.autoresizingMask = [.width, .height]
            surface.addSubview(scroll)
            panel.contentView = surface
            panel.setAccessibilityLabel("ChatType 原位初稿")
            self.panel = panel
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: anchor.font, .foregroundColor: anchor.foreground,
            .paragraphStyle: paragraph,
            .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
            .underlineColor: anchor.foreground.withAlphaComponent(0.4),
        ]
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.caret) }?.visibleFrame ?? anchor.input
        let available = screen.insetBy(dx: 8, dy: 8)
        guard !available.isNull, available.width > 0, available.height > 0 else { panel?.orderOut(nil); return }
        let natural = (value as NSString).size(withAttributes: attributes)
        let width = min(available.width, InputCompositionLayout.preferredWidth,
                        max(anchor.font.pointSize * 4, natural.width + 12))
        let measured = (value as NSString).boundingRect(with: CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let height = min(available.height, max(anchor.font.boundingRectForFont.height, ceil(measured.height)) + 12)
        panel?.setFrame(InputCompositionLayout.frame(caret: anchor.caret, size: CGSize(width: width, height: height),
                                                    available: available), display: false)
        surface.layer?.backgroundColor = anchor.background.withAlphaComponent(0.88).cgColor
        surface.layer?.borderColor = anchor.foreground.withAlphaComponent(0.26).cgColor
        scroll.frame = CGRect(x: 6, y: 6, width: max(1, width - 12), height: max(1, height - 12))
        textView.textContainer?.containerSize = CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: attributes))
        textView.setFrameSize(CGSize(width: max(1, width - 12), height: max(scroll.frame.height, ceil(measured.height))))
        textView.scrollToEndOfDocument(nil)
        panel?.orderFrontRegardless()
    }
}

enum InputCompositionLayout {
    // Presentation width requested by the owner: moderate wrapping independent
    // of the source input's width. This does not truncate the draft.
    static let preferredWidth: CGFloat = 360

    static func frame(caret: CGRect, size: CGSize, available: CGRect) -> CGRect {
        let x = min(max(available.minX, caret.maxX + 6), available.maxX - size.width)
        let top = min(available.maxY, max(available.minY + size.height, caret.minY - 6))
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}
