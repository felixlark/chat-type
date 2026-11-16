import AppKit
import ApplicationServices

struct LiveTextSpan: Equatable {
    let original: String
    let selection: NSRange
    init?(value: String, selection: NSRange) {
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        original = value; self.selection = selection
    }
    func replacing(with text: String, current: String) -> String? {
        guard current == original else { return nil }
        return (original as NSString).replacingCharacters(in: selection, with: text)
    }
}

enum LiveTextWriteResult { case rejected, applied(observedValue: String?) }

@MainActor
protocol LiveTextTarget: AnyObject {
    var value: String? { get }
    var selection: NSRange? { get }
    var nativePasteTarget: (any PinnedPasteTarget)? { get }
    func write(_ value: String, caret: Int) -> LiveTextWriteResult
}
extension LiveTextTarget { var nativePasteTarget: (any PinnedPasteTarget)? { nil } }

@MainActor
protocol LiveTextInputControlling: AnyObject {
    func begin(context: LaunchAppContext?, enabled: Bool)
    func prepare() async
    func finish(_ text: String, injector: any TextInjecting, configuration: InjectionConfig) async throws -> InjectionOutcome?
    func suspend()
    func reset()
}
extension LiveTextInputControlling {
    func prepare() async {}
    func finish(_ text: String, injector: any TextInjecting) async throws -> InjectionOutcome? {
        try await finish(text, injector: injector, configuration: InjectionConfig())
    }
}

@MainActor
final class LiveTextInput: LiveTextInputControlling {
    typealias EditorFactory = @MainActor (LaunchAppContext?) -> (any PinnedEditorSession)?
    private let capture: @MainActor (LaunchAppContext?) -> (any LiveTextTarget)?
    private let editorFactory: EditorFactory
    private var target: (any LiveTextTarget)?
    private var span: LiveTextSpan?
    private var editor: (any PinnedEditorSession)?
    private var editorReady = false
    private var generation = 0
    private(set) var hasSession = false

    init(capture: @escaping @MainActor (LaunchAppContext?) -> (any LiveTextTarget)? = AXLiveTextTarget.capture,
         editorFactory: @escaping EditorFactory = { context in
             context?.bundleIdentifier == "com.sublimetext.4" ? SublimeEditorSession() : nil
         }) {
        self.capture = capture; self.editorFactory = editorFactory
    }

    func begin(context: LaunchAppContext?, enabled: Bool) {
        reset()
        guard enabled else { return }
        hasSession = true
        editor = editorFactory(context)
        if editor != nil { return }
        target = capture(context)
        if let value = target?.value, let selection = target?.selection { span = LiveTextSpan(value: value, selection: selection) }
    }

    func prepare() async {
        guard let editor else { return }
        let current = generation
        let ready = (try? await editor.prepare()) != nil
        if generation == current { editorReady = ready }
    }

    func finish(_ text: String, injector: any TextInjecting, configuration: InjectionConfig) async throws -> InjectionOutcome? {
        guard hasSession else { return nil }
        let current = generation
        if let editor {
            if editorReady {
                let applied = try await editor.commit(text)
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                if applied { reset(); return .pasted }
            }
        } else if let target, let span, let value = target.value,
                  let final = span.replacing(with: text, current: value) {
            if let pinned = target.nativePasteTarget {
                let outcome = try injector.injectPinned(text: text, span: span, target: pinned, configuration: configuration)
                reset(); return outcome
            }
            if final == value { reset(); return .pasted }
            switch target.write(final, caret: span.selection.location + text.utf16.count) {
            case .rejected: break
            case .applied(let observed):
                guard observed == final else { throw EditorDeliveryError.outputUnknown }
                reset(); return .pasted
            }
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let result = try injector.copyToClipboard(text: text)
        reset()
        if case .copiedToClipboard = result { return .copiedToClipboard(reason: .originalTargetUnavailable) }
        return result
    }

    func suspend() { editor?.cancelPending() }
    func reset() {
        generation += 1
        editor?.close()
        target = nil; span = nil; editor = nil; editorReady = false; hasSession = false
    }
}

@MainActor
final class InputWindowAnchor {
    let window: AXUIElement
    let pid: pid_t
    init(window: AXUIElement, pid: pid_t) { self.window = window; self.pid = pid }
    static func capture(_ context: LaunchAppContext?) -> InputWindowAnchor? {
        guard let context, AXIsProcessTrusted(),
              let window = axElement(AXUIElementCreateApplication(context.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
        return InputWindowAnchor(window: window, pid: context.processIdentifier)
    }
    var visible: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              (axAttribute(window, kAXMinimizedAttribute) as? Bool) != true,
              let focused = axElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return false }
        return CFEqual(focused, window)
    }
}

@MainActor
private final class AXLiveTextTarget: LiveTextTarget, PinnedPasteTarget {
    let element: AXUIElement
    let window: InputWindowAnchor?
    let selected: NSRange?
    let processIdentifier: pid_t
    private let isWebEditable: Bool
    init(_ element: AXUIElement, window: InputWindowAnchor?, pid: pid_t) {
        self.element = element; self.window = window; self.processIdentifier = pid
        var ancestor: AXUIElement? = element
        var seen: [AXUIElement] = []
        var web = false
        while let node = ancestor, !seen.contains(where: { CFEqual($0, node) }) {
            if axAttribute(node, kAXRoleAttribute) as? String == "AXWebArea" { web = true; break }
            seen.append(node); ancestor = axElement(node, kAXParentAttribute)
        }
        isWebEditable = web
        if let raw = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            var r = CFRange()
            selected = AXValueGetValue(raw as! AXValue, .cfRange, &r) ? NSRange(location: r.location, length: r.length) : nil
        } else { selected = nil }
    }
    static func capture(_ context: LaunchAppContext?) -> (any LiveTextTarget)? {
        guard let context, AXIsProcessTrusted(),
              let element = axElement(AXUIElementCreateApplication(context.processIdentifier), kAXFocusedUIElementAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(axAttribute(element, kAXRoleAttribute) as? String ?? ""),
              axAttribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String,
              (axAttribute(element, kAXEnabledAttribute) as? Bool) != false else { return nil }
        return AXLiveTextTarget(element, window: InputWindowAnchor.capture(context), pid: context.processIdentifier)
    }
    var value: String? { axAttribute(element, kAXValueAttribute) as? String }
    var selection: NSRange? { selected }
    var nativePasteTarget: (any PinnedPasteTarget)? { isWebEditable ? self : nil }
    var placeholderLabel: String? {
        (axAttribute(element, kAXPlaceholderValueAttribute) as? String) ?? (axAttribute(element, kAXTitleAttribute) as? String)
    }
    private var currentSelection: NSRange? {
        guard let raw = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    func requestPasteFocus(selection: NSRange) {
        guard let window else { return }
        let app = AXUIElementCreateApplication(processIdentifier)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
            NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
        }
        if axElement(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window.window) }) != true {
            AXUIElementPerformAction(window.window, kAXRaiseAction as CFString)
        }
        if axElement(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, element) }) != true {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        if currentSelection != selection {
            var range = CFRange(location: selection.location, length: selection.length)
            if let raw = AXValueCreate(.cfRange, &range) { AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, raw) }
        }
    }
    func hasPasteFocus(selection: NSRange) -> Bool {
        guard window?.visible == true, currentSelection == selection,
              let focused = axElement(AXUIElementCreateApplication(processIdentifier), kAXFocusedUIElementAttribute),
              (axAttribute(element, kAXEnabledAttribute) as? Bool) != false else { return false }
        return CFEqual(focused, element)
    }
    func write(_ value: String, caret: Int) -> LiveTextWriteResult {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue, AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else { return .rejected }
        let observed = self.value
        if observed == value {
            var range = CFRange(location: caret, length: 0)
            if let raw = AXValueCreate(.cfRange, &range) { AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, raw) }
        }
        return .applied(observedValue: observed)
    }
}

@MainActor private func axAttribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
@MainActor private func axElement(_ element: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = axAttribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
@MainActor private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), let s = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
