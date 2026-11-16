import AppKit
import ApplicationServices

/// Own only the selected span. UTF-16 offsets match the Accessibility contract.
struct LiveTextSpan: Equatable {
    let original: String
    let selection: NSRange
    private(set) var expected: String

    init?(value: String, selection: NSRange) {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        self.original = value
        self.selection = selection
        self.expected = value
    }

    func replacing(with text: String, current: String) -> String? {
        guard current == expected else { return nil }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }

    mutating func accept(_ value: String) { expected = value }
}

@MainActor
protocol LiveTextTarget: AnyObject {
    var value: String? { get }
    var selection: NSRange? { get }
    var frame: CGRect? { get }
    func write(_ value: String, caret: Int) -> Bool
}

@MainActor
protocol LiveTextPresenting: AnyObject {
    func show(_ text: String, frame: CGRect)
    func hide()
}

@MainActor
protocol LiveTextInputControlling: AnyObject {
    func begin(context: LaunchAppContext?, enabled: Bool)
    func update(_ text: String)
    func finish(_ text: String, injector: any TextInjecting) throws -> InjectionOutcome?
    func endRecording()
    func suspend()
    func reset()
}

/// The captured element remains the destination even if another field/app gains focus.
@MainActor
final class LiveTextInput: LiveTextInputControlling {
    private let capture: @MainActor (LaunchAppContext?) -> (any LiveTextTarget)?
    private let preview: any LiveTextPresenting
    private var target: (any LiveTextTarget)?
    private var span: LiveTextSpan?
    private var text = ""
    private var direct = true
    private(set) var hasSession = false

    init(capture: @escaping @MainActor (LaunchAppContext?) -> (any LiveTextTarget)? = AXLiveTextTarget.capture,
         preview: (any LiveTextPresenting)? = nil) {
        self.capture = capture
        self.preview = preview ?? InputPreviewPanel()
    }

    func begin(context: LaunchAppContext?, enabled: Bool) {
        reset()
        guard enabled else { return }
        hasSession = true
        target = capture(context)
        if let value = target?.value, let selection = target?.selection {
            span = LiveTextSpan(value: value, selection: selection)
        }
    }

    func update(_ text: String) {
        guard hasSession, !text.isEmpty else { return }
        if text != self.text {
            self.text = text
            if direct, replace(text) { preview.hide(); return }
            direct = false
        }
        if !direct, let frame = target?.frame {
            preview.show(text, frame: frame)
        } else if !direct { preview.hide() }
    }

    /// Call only after the final result is durably sealed. nil means live input was disabled.
    func finish(_ text: String, injector: any TextInjecting) throws -> InjectionOutcome? {
        guard hasSession else { return nil }
        preview.hide()
        if replace(text) { resetWithoutRollback(); return .pasted }
        rollback()
        let result = try injector.copyToClipboard(text: text)
        resetWithoutRollback()
        if case .copiedToClipboard = result { return .copiedToClipboard(reason: .originalTargetUnavailable) }
        return result
    }

    func endRecording() { preview.hide() }

    /// Errors/cancellation remove only our unchanged draft. Retain the pin for manual Retry.
    func suspend() {
        rollback()
        preview.hide()
        text = ""
    }

    func reset() { suspend(); resetWithoutRollback() }

    private func resetWithoutRollback() {
        preview.hide()
        target = nil; span = nil; text = ""; direct = true; hasSession = false
    }

    private func replace(_ text: String) -> Bool {
        guard let target, var span, let current = target.value,
              let next = span.replacing(with: text, current: current) else { return false }
        if next == current { return true }
        guard target.write(next, caret: span.selection.location + text.utf16.count) else { return false }
        span.accept(next); self.span = span
        return true
    }

    private func rollback() {
        guard let target, var span, span.expected != span.original,
              target.value == span.expected,
              target.write(span.original, caret: span.selection.location + span.selection.length) else { return }
        span.accept(span.original); self.span = span
    }
}

@MainActor
private final class AXLiveTextTarget: LiveTextTarget {
    private let element: AXUIElement
    private let pid: pid_t
    init(_ element: AXUIElement, pid: pid_t) { self.element = element; self.pid = pid }

    static func capture(_ context: LaunchAppContext?) -> (any LiveTextTarget)? {
        guard AXIsProcessTrusted(), let context, context.processIdentifier > 0 else { return nil }
        let app = AXUIElementCreateApplication(context.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let target = AXLiveTextTarget(raw as! AXUIElement, pid: context.processIdentifier)
        let role = target.attribute(kAXRoleAttribute) as? String
        let subrole = target.attribute(kAXSubroleAttribute) as? String
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? ""),
              subrole != kAXSecureTextFieldSubrole as String,
              (target.attribute(kAXEnabledAttribute) as? Bool) != false else { return nil }
        return target
    }

    private func attribute(_ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    var value: String? { attribute(kAXValueAttribute) as? String }
    var selection: NSRange? {
        guard let raw = attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    var frame: CGRect? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        guard let p = attribute(kAXPositionAttribute), let s = attribute(kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              let primary = NSScreen.screens.first else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return OverlayPlacementSession.appKitFrame(fromAccessibility: CGRect(origin: point, size: size), primaryScreenTop: primary.frame.maxY)
    }
    func write(_ value: String, caret: Int) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success,
              self.value == value else { return false }
        var range = CFRange(location: caret, length: 0)
        if let raw = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, raw)
        }
        return true
    }
}

/// Separate from the status HUD, covering exactly the captured input's rectangle.
@MainActor
private final class InputPreviewPanel: LiveTextPresenting {
    private var panel: NSPanel?
    private let scroll = NSScrollView()
    private let textView = NSTextView()

    func show(_ text: String, frame: CGRect) {
        if panel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            textView.isEditable = false; textView.isSelectable = false
            textView.font = .systemFont(ofSize: 14)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            scroll.documentView = textView; scroll.hasVerticalScroller = false
            panel.contentView = scroll
            panel.setAccessibilityLabel("输入框实时预览")
            self.panel = panel
        }
        panel?.setFrame(frame, display: false)
        textView.setFrameSize(NSSize(width: frame.width, height: frame.height))
        textView.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        if textView.string != text { textView.string = text; textView.scrollToEndOfDocument(nil) }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
}
