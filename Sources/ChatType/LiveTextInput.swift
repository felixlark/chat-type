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
    var anchor: InputCompositionAnchor? { get }
    func write(_ value: String, caret: Int) -> LiveTextWriteResult
}

@MainActor
protocol LiveTextInputControlling: AnyObject {
    func begin(context: LaunchAppContext?, enabled: Bool)
    func prepare() async
    func update(_ text: String)
    func finish(_ text: String, injector: any TextInjecting) async throws -> InjectionOutcome?
    func endRecording()
    func suspend()
    func reset()
}
extension LiveTextInputControlling { func prepare() async {} }

@MainActor
final class LiveTextInput: LiveTextInputControlling {
    typealias EditorFactory = @MainActor (LaunchAppContext?) -> (any PinnedEditorSession)?
    private let capture: @MainActor (LaunchAppContext?) -> (any LiveTextTarget)?
    private let composition: any InputCompositionPresenting
    private let editorFactory: EditorFactory
    private var target: (any LiveTextTarget)?
    private var span: LiveTextSpan?
    private var editor: (any PinnedEditorSession)?
    private var editorReady = false
    private var editorWindow: InputWindowAnchor?
    private var text = ""
    private var generation = 0
    private(set) var hasSession = false

    init(capture: @escaping @MainActor (LaunchAppContext?) -> (any LiveTextTarget)? = AXLiveTextTarget.capture,
         composition: (any InputCompositionPresenting)? = nil,
         editorFactory: @escaping EditorFactory = { context in
             context?.bundleIdentifier == "com.sublimetext.4" ? SublimeEditorSession() : nil
         }) {
        self.capture = capture; self.composition = composition ?? InputCompositionController(); self.editorFactory = editorFactory
    }

    func begin(context: LaunchAppContext?, enabled: Bool) {
        reset()
        guard enabled else { return }
        hasSession = true
        editor = editorFactory(context)
        if editor != nil { editorWindow = InputWindowAnchor.capture(context); return }
        target = capture(context)
        if let value = target?.value, let selection = target?.selection { span = LiveTextSpan(value: value, selection: selection) }
    }

    func prepare() async {
        guard let editor else { return }
        let current = generation
        let ready = (try? await editor.prepare()) != nil
        if generation == current { editorReady = ready }
    }

    func update(_ text: String) {
        guard hasSession, !text.isEmpty else { return }
        self.text = text
        let current = generation
        composition.show(text) { [weak self] in
            guard let self, self.generation == current else { return nil }
            if let editor = self.editor {
                guard self.editorReady, let window = self.editorWindow,
                      let response = try? await editor.geometry(), response.visible == true,
                      self.generation == current else { return nil }
                return window.compositionAnchor(response)
            }
            guard self.target?.value == self.span?.original else { return nil }
            return self.target?.anchor
        }
    }

    func finish(_ text: String, injector: any TextInjecting) async throws -> InjectionOutcome? {
        guard hasSession else { return nil }
        let current = generation
        composition.hide()
        if let editor {
            if editorReady {
                let applied = try await editor.commit(text)
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                if applied { reset(); return .pasted }
            }
        } else if let target, let span, let value = target.value,
                  let final = span.replacing(with: text, current: value) {
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

    func endRecording() { /* The original composition stays provisional through polish. */ }
    func suspend() { composition.hide(); editor?.cancelPending(); text = "" }
    func reset() {
        generation += 1
        composition.hide(); editor?.close()
        target = nil; span = nil; editor = nil; editorWindow = nil; editorReady = false; text = ""; hasSession = false
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
    func compositionAnchor(_ r: EditorBridgeResponse) -> InputCompositionAnchor? {
        guard visible, let frame = axRect(window), let x = r.caretX, let y = r.caretY,
              let vx = r.viewportX, let vy = r.viewportY, let width = r.width, let height = r.height else { return nil }
        let caret = appKitRect(CGRect(x: frame.minX + x, y: frame.minY + y, width: 1, height: r.lineHeight ?? 20))
        let input = appKitRect(CGRect(x: frame.minX + vx, y: frame.minY + vy, width: width, height: height))
        return InputCompositionAnchor(caret: caret, input: input,
            font: NSFont(name: r.fontName ?? "Menlo", size: r.fontSize ?? 13) ?? .systemFont(ofSize: r.fontSize ?? 13),
            foreground: color(r.foreground) ?? .labelColor, background: color(r.background) ?? .textBackgroundColor)
    }
    private func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

@MainActor
private final class AXLiveTextTarget: LiveTextTarget {
    let element: AXUIElement
    let window: InputWindowAnchor?
    let selected: NSRange?
    init(_ element: AXUIElement, window: InputWindowAnchor?) {
        self.element = element; self.window = window
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
        return AXLiveTextTarget(element, window: InputWindowAnchor.capture(context))
    }
    var value: String? { axAttribute(element, kAXValueAttribute) as? String }
    var selection: NSRange? { selected }
    var anchor: InputCompositionAnchor? {
        guard window?.visible == true, let input = axRect(element), let selected else { return nil }
        var range = CFRange(location: selected.location, length: 0)
        guard let raw = AXValueCreate(.cfRange, &range) else { return nil }
        var bounds: CFTypeRef?
        var caret = CGRect(x: input.minX + 6, y: input.minY + 6, width: 1, height: 20)
        if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, raw, &bounds) == .success,
           let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() { _ = AXValueGetValue(bounds as! AXValue, .cgRect, &caret) }
        var attributed: CFTypeRef?
        if let styleRange = InputCompositionTextStyle.adjacentRange(in: value ?? "", caret: selected.location) {
            var range = CFRange(location: styleRange.location, length: styleRange.length)
            if let styleValue = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, styleValue, &attributed)
            }
        }
        let string = attributed as? NSAttributedString
        let attributes = (string?.length ?? 0) > 0 ? string!.attributes(at: 0, effectiveRange: nil) : [:]
        let font = InputCompositionTextStyle.font(attributes, fallbackSize: max(1, caret.height * 0.75))
        return InputCompositionAnchor(caret: appKitRect(caret), input: appKitRect(input), font: font,
            foreground: InputCompositionTextStyle.color(attributes, cocoa: .foregroundColor, ax: "AXForegroundColor") ?? .labelColor,
            background: InputCompositionTextStyle.color(attributes, cocoa: .backgroundColor, ax: "AXBackgroundColor") ?? .textBackgroundColor)
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
@MainActor private func appKitRect(_ rect: CGRect) -> CGRect {
    OverlayPlacementSession.appKitFrame(fromAccessibility: rect, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
}

@MainActor
enum InputCompositionTextStyle {
    static func adjacentRange(in value: String, caret: Int) -> NSRange? {
        let string = value as NSString
        guard string.length > 0, caret >= 0, caret <= string.length else { return nil }
        return string.rangeOfComposedCharacterSequence(at: min(caret, string.length - 1))
    }
    // Public AXTextAttributedString.h keys; use their verified string values
    // because this SDK imports the CFString globals as mutable Unmanaged vars.
    static func font(_ attributes: [NSAttributedString.Key: Any], fallbackSize: CGFloat) -> NSFont {
        if let font = attributes[.font] as? NSFont { return font }
        if let info = attributes[NSAttributedString.Key("AXFont")] as? [String: Any],
           let name = info["AXFontName"] as? String,
           let size = info["AXFontSize"] as? NSNumber,
           let font = NSFont(name: name, size: CGFloat(size.doubleValue)) { return font }
        return .systemFont(ofSize: fallbackSize)
    }
    static func color(_ attributes: [NSAttributedString.Key: Any], cocoa: NSAttributedString.Key, ax: String) -> NSColor? {
        if let color = attributes[cocoa] as? NSColor { return color }
        if let raw = attributes[NSAttributedString.Key(ax)] {
            let value = raw as CFTypeRef
            if CFGetTypeID(value) == CGColor.typeID { return NSColor(cgColor: value as! CGColor) }
        }
        return nil
    }
}
