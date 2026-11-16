import AppKit
import Carbon
import SwiftUI

enum ShortcutCaptureError: LocalizedError {
    case busy
    var errorDescription: String? { "请先停止当前录音或处理，再录入快捷键。" }
}

struct ActivationShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(_ config: TranscriptionConfig) {
        keyCode = config.hotkeyKeyCode
        modifiers = config.hotkeyModifiers
    }

    init(keyCode: UInt32, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var title: String {
        var parts: [String] = []
        for (mask, name) in [(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")] {
            if modifiers & UInt32(mask) != 0 { parts.append(name) }
        }
        parts.append(Self.keyNames[keyCode] ?? "Key \(keyCode)")
        return parts.joined(separator: " + ")
    }

    // Physical virtual-key codes, matching Carbon registration rather than a
    // character produced by the active input method.
    private static let keyNames: [UInt32: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
        12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
        22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O",
        32:"U", 33:"[", 34:"I", 35:"P", 36:"Return", 37:"L", 38:"J", 39:"'", 40:"K", 41:";",
        42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 50:"`", 51:"Delete",
        64:"F17", 79:"F18", 80:"F19", 90:"F20", 96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8",
        101:"F9", 103:"F11", 105:"F13", 106:"F16", 107:"F14", 109:"F10", 111:"F12", 113:"F15",
        114:"Help", 115:"Home", 116:"Page Up", 117:"Forward Delete", 118:"F4", 119:"End", 120:"F2",
        121:"Page Down", 122:"F1", 123:"Left", 124:"Right", 125:"Down", 126:"Up"
    ]
}

/// Owns runtime registration. A failed registration or disk write keeps the
/// old handle alive; unchanged saves never collide with their own hotkey.
@MainActor
final class ActivationShortcutRegistration {
    typealias Register = (ActivationShortcut) throws -> AnyObject
    private let register: Register
    private var handle: AnyObject?
    private(set) var shortcut: ActivationShortcut?

    init(register: @escaping Register) { self.register = register }

    func replace(with candidate: ActivationShortcut, persist: () throws -> Void) throws {
        let replacement = candidate != shortcut || handle == nil ? try register(candidate) : handle
        try persist()
        handle = replacement
        shortcut = candidate
    }

    func suspend() { handle = nil }

    func resume() throws {
        if handle == nil, let shortcut { handle = try register(shortcut) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (ActivationShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) {}
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }

    final class CaptureView: NSView {
        var onCapture: ((ActivationShortcut) -> Void)?
        var onCancel: (() -> Void)?
        private var observer: NSObjectProtocol?
        private var completed = false
        override var acceptsFirstResponder: Bool { true }

        override func resignFirstResponder() -> Bool {
            stop()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { stop(); return }
            window.makeFirstResponder(self)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }

        override func keyDown(with event: NSEvent) {
            guard !completed, !event.isARepeat else { return }
            if event.keyCode == 53 { stop(); return }
            completed = true
            onCapture?(ActivationShortcut(keyCode: UInt32(event.keyCode), modifiers: ActivationShortcut.carbonModifiers(event.modifierFlags)))
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard !completed else { return }
            completed = true
            onCancel?()
        }
    }
}
