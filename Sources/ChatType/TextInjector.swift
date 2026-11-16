import AppKit
import ApplicationServices
import Foundation
import OSLog

struct EditableTextSnapshot: Sendable, Equatable {
    let value: String
    let selectedRange: CFRange

    static func == (lhs: EditableTextSnapshot, rhs: EditableTextSnapshot) -> Bool {
        lhs.value == rhs.value &&
            lhs.selectedRange.location == rhs.selectedRange.location &&
            lhs.selectedRange.length == rhs.selectedRange.length
    }
}

enum TextInsertionPlan: Sendable, Equatable {
    case keyPressPaste
    case clipboardFallback(reason: ClipboardFallbackReason)
}

struct LaunchAppContext: Sendable, Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
    let processIdentifier: pid_t

    @MainActor
    static func current() -> LaunchAppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return LaunchAppContext(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }
}

enum InjectionError: LocalizedError {
    case keyEventFailed
    case clipboardUnavailable
    case clipboardChanged

    var errorDescription: String? {
        switch self {
        case .clipboardUnavailable:
            return "无法写入剪贴板。"
        case .clipboardChanged:
            return "输出前剪贴板已变化，未自动粘贴；终稿仍保留在 History。"
        case .keyEventFailed:
            return "生成 Cmd+V 事件失败。"
        }
    }
}

enum ClipboardFallbackReason: Sendable, Equatable {
    case userSelected
    case accessibilityPermissionRequired
    case noEditableTarget
    case originalTargetUnavailable

    var statusDetail: String {
        switch self {
        case .userSelected: return "Copied to clipboard as selected"
        case .accessibilityPermissionRequired:
            return "Copied to clipboard. Grant Accessibility access for auto-paste."
        case .originalTargetUnavailable:
            return "原输入框已变化或不可写；终稿已复制，请核对框内临时文字。"
        case .noEditableTarget:
            return "Copied to clipboard"
        }
    }

    var overlaySubtitle: String {
        switch self {
        case .userSelected: return "已按设置复制到剪贴板。"
        case .accessibilityPermissionRequired:
            return "Accessibility permission is off, so ChatType left the text in the clipboard."
        case .originalTargetUnavailable:
            return "原输入框已变化或不可写；终稿已复制，请核对框内临时文字。"
        case .noEditableTarget:
            return "No editable cursor was found. Paste manually."
        }
    }
}

enum InjectionOutcome: Sendable, Equatable {
    case pasted
    case copiedToClipboard(reason: ClipboardFallbackReason)
}

@MainActor
protocol PinnedPasteTarget: AnyObject {
    var value: String? { get }
    var processIdentifier: pid_t { get }
    var placeholderLabel: String? { get }
    func requestPasteFocus(selection: NSRange)
    func hasPasteFocus(selection: NSRange) -> Bool
}

enum PinnedPasteReceipt {
    static func matches(observed: String?, span: LiveTextSpan, inserted: String, placeholder: String?) -> Bool {
        if observed == span.replacing(with: inserted, current: span.original) { return true }
        // Chromium exposes the empty ProseMirror placeholder as AXValue plus
        // its paragraph separator. A real paste removes the placeholder.
        guard let placeholder, !placeholder.isEmpty,
              span.selection == NSRange(location: 0, length: 0),
              span.original == placeholder + "\n" else { return false }
        // Chromium omits the empty paragraph separator once actual content
        // is inserted; other web editors retain it in their AXValue.
        return observed == inserted || observed == inserted + "\n"
    }
}

@MainActor
protocol TextInjecting: AnyObject {
    func copyToClipboard(text: String) throws -> InjectionOutcome
    func injectPinned(text: String, span: LiveTextSpan, target: any PinnedPasteTarget,
                      configuration: InjectionConfig) throws -> InjectionOutcome
    func inject(
        text: String,
        preserveClipboard: Bool,
        restoreDelayMilliseconds: UInt64,
        launchAppContext: LaunchAppContext?
    ) throws -> InjectionOutcome
}

extension TextInjecting {
    func copyToClipboard(text: String) throws -> InjectionOutcome { throw InjectionError.clipboardUnavailable }
    func injectPinned(text: String, span: LiveTextSpan, target: any PinnedPasteTarget,
                      configuration: InjectionConfig) throws -> InjectionOutcome { throw InjectionError.keyEventFailed }
}

@MainActor
final class TextInjector: TextInjecting {
    private static let targetUIResponseBudgetNanoseconds: UInt64 = 1_000_000_000
    private let pasteboard: NSPasteboard
    private let sendPaste: @MainActor (pid_t?) throws -> Void
    private let settleAfterPaste: @MainActor () -> Void

    init(pasteboard: NSPasteboard = .general,
         sendPaste: @escaping @MainActor (pid_t?) throws -> Void = TextInjector.postPaste,
         settleAfterPaste: @escaping @MainActor () -> Void = { usleep(150_000) }) {
        self.pasteboard = pasteboard; self.sendPaste = sendPaste; self.settleAfterPaste = settleAfterPaste
    }

    func copyToClipboard(text: String) throws -> InjectionOutcome {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw InjectionError.clipboardUnavailable }
        return .copiedToClipboard(reason: .userSelected)
    }

    func injectPinned(text: String, span: LiveTextSpan, target: any PinnedPasteTarget,
                      configuration: InjectionConfig) throws -> InjectionOutcome {
        target.requestPasteFocus(selection: span.selection)
        guard waitForPasteTarget(launchAppContext: nil, pinned: target, selection: span.selection),
              target.value == span.original else {
            _ = try copyToClipboard(text: text)
            return .copiedToClipboard(reason: .originalTargetUnavailable)
        }
        let snapshot = configuration.preserveClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil
        let placeholder = target.placeholderLabel
        _ = try copyToClipboard(text: text)
        let ownedChangeCount = pasteboard.changeCount
        // The existing pre-paste settle also applies to the pinned path.
        usleep(60_000)
        let targetReady = target.hasPasteFocus(selection: span.selection) && target.value == span.original
        guard pasteboard.changeCount == ownedChangeCount else { throw InjectionError.clipboardChanged }
        guard targetReady else {
            return .copiedToClipboard(reason: .originalTargetUnavailable)
        }
        // Keep post -> receipt synchronous on MainActor. Cancellation cannot
        // interleave a cancelled journal between the event and its receipt.
        let receiptDeadline = DispatchTime.now().uptimeNanoseconds + Self.targetUIResponseBudgetNanoseconds
        try sendPaste(target.processIdentifier)
        settleAfterPaste()
        var observed = target.value
        func matches() -> Bool {
            PinnedPasteReceipt.matches(observed: observed, span: span, inserted: text, placeholder: placeholder)
        }
        // Reuse the existing target-UI response budget for this separate
        // receipt phase. An AX IPC call can itself outlast the polling window.
        while !matches(), DispatchTime.now().uptimeNanoseconds < receiptDeadline {
            usleep(25_000)
            observed = target.value
        }
        guard matches() else {
            let observedLength = observed?.utf16.count ?? -1
            let breaks = observed?.filter { $0 == "\n" }.count ?? -1
            logger.error("Pinned paste receipt unavailable: originalUTF16=\(span.original.utf16.count, privacy: .public), insertedUTF16=\(text.utf16.count, privacy: .public), observedUTF16=\(observedLength, privacy: .public), observedParagraphBreaks=\(breaks, privacy: .public)")
            throw EditorDeliveryError.outputUnknown
        }
        if let snapshot {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: configuration.restoreDelayMilliseconds * 1_000_000)
                guard self.pasteboard.changeCount == ownedChangeCount else { return }
                snapshot.restore(to: self.pasteboard)
            }
        }
        return .pasted
    }
    private let logger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "TextInjector"
    )

    nonisolated static func injectionOutcome(
        hasEditableTextFocus: Bool,
        accessibilityTrusted: Bool
    ) -> InjectionOutcome {
        guard accessibilityTrusted else {
            return .copiedToClipboard(reason: .accessibilityPermissionRequired)
        }
        guard hasEditableTextFocus else {
            return .copiedToClipboard(reason: .noEditableTarget)
        }
        return .pasted
    }

    nonisolated static func injectionPlan(
        text _: String,
        accessibilityTrusted: Bool,
        editableTextSnapshot _: EditableTextSnapshot?,
        fallbackEditableTextSnapshot _: EditableTextSnapshot?,
        hasEditableTextFocus: Bool,
        hasFallbackEditableTextFocus: Bool
    ) -> TextInsertionPlan {
        guard accessibilityTrusted else {
            return .clipboardFallback(reason: .accessibilityPermissionRequired)
        }

        guard hasEditableTextFocus || hasFallbackEditableTextFocus else {
            return .clipboardFallback(reason: .noEditableTarget)
        }

        return .keyPressPaste
    }

    func inject(
        text: String,
        preserveClipboard: Bool,
        restoreDelayMilliseconds: UInt64,
        launchAppContext: LaunchAppContext?
    ) throws -> InjectionOutcome {
        let accessibilityTrusted = AccessibilityPermission.isTrusted()
        if !accessibilityTrusted {
            AccessibilityPermission.requestTrustIfNeeded()
        }

        let hasEditableTextFocus = accessibilityTrusted && FocusedElementInspector.hasEditableTextFocus()
        let hasFallbackEditableTextFocus = accessibilityTrusted &&
            FocusedElementInspector.hasEditableTextFocus(in: launchAppContext)
        let plan = Self.injectionPlan(
            text: text,
            accessibilityTrusted: accessibilityTrusted,
            editableTextSnapshot: nil,
            fallbackEditableTextSnapshot: nil,
            hasEditableTextFocus: hasEditableTextFocus,
            hasFallbackEditableTextFocus: hasFallbackEditableTextFocus
        )

        logger.info(
            "Injection plan resolved to \(String(describing: plan), privacy: .public); currentEditableFocus=\(hasEditableTextFocus, privacy: .public); fallbackEditableFocus=\(hasFallbackEditableTextFocus, privacy: .public); hasLaunchAppContext=\(launchAppContext != nil, privacy: .public)"
        )

        switch plan {
        case .clipboardFallback(let reason):
            copyToPasteboard(text)
            return .copiedToClipboard(reason: reason)
        case .keyPressPaste:
            return try pasteUsingClipboard(
                text: text,
                preserveClipboard: preserveClipboard,
                restoreDelayMilliseconds: restoreDelayMilliseconds,
                launchAppContext: launchAppContext
            )
        }
    }

    private func pasteUsingClipboard(
        text: String,
        preserveClipboard: Bool,
        restoreDelayMilliseconds: UInt64,
        launchAppContext: LaunchAppContext?
    ) throws -> InjectionOutcome {
        let snapshot = preserveClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil

        restoreLaunchAppIfNeeded(launchAppContext)
        guard waitForPasteTarget(launchAppContext: launchAppContext) else {
            logger.error("Paste target did not become frontmost before timeout; leaving transcript in clipboard")
            copyToPasteboard(text)
            return .copiedToClipboard(reason: .noEditableTarget)
        }

        copyToPasteboard(text)
        usleep(60_000)

        guard isPasteTargetReady(launchAppContext: launchAppContext) else {
            return .copiedToClipboard(reason: .noEditableTarget)
        }

        try sendPaste(nil)
        let ownedChangeCount = pasteboard.changeCount
        if let snapshot {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: restoreDelayMilliseconds * 1_000_000)
                guard self.pasteboard.changeCount == ownedChangeCount else { return }
                snapshot.restore(to: self.pasteboard)
            }
        }

        return .pasted
    }

    private static func postPaste(to processIdentifier: pid_t?) throws {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw InjectionError.keyEventFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let processIdentifier {
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func waitForPasteTarget(launchAppContext: LaunchAppContext?, pinned: (any PinnedPasteTarget)? = nil,
                                    selection: NSRange = NSRange(location: 0, length: 0)) -> Bool {
        func ready() -> Bool { pinned?.hasPasteFocus(selection: selection) ?? isPasteTargetReady(launchAppContext: launchAppContext) }
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.targetUIResponseBudgetNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if ready() {
                return true
            }
            if let pinned { pinned.requestPasteFocus(selection: selection) }
            else { restoreLaunchAppIfNeeded(launchAppContext) }
            usleep(25_000)
        }

        return ready()
    }

    private func isPasteTargetReady(launchAppContext: LaunchAppContext?) -> Bool {
        Self.isPasteTargetReady(
            launchAppProcessIdentifier: launchAppContext?.processIdentifier,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            hasEditableTextFocus: FocusedElementInspector.hasEditableTextFocus()
        )
    }

    nonisolated static func isPasteTargetReady(
        launchAppProcessIdentifier: pid_t?,
        frontmostProcessIdentifier: pid_t?,
        hasEditableTextFocus: Bool
    ) -> Bool {
        guard hasEditableTextFocus else { return false }
        guard let launchAppProcessIdentifier else { return true }
        return frontmostProcessIdentifier == launchAppProcessIdentifier
    }

    private func restoreLaunchAppIfNeeded(_ launchAppContext: LaunchAppContext?) {
        guard
            let launchAppContext,
            let currentFrontmostApp = NSWorkspace.shared.frontmostApplication,
            currentFrontmostApp.processIdentifier != launchAppContext.processIdentifier,
            let app = NSRunningApplication(processIdentifier: launchAppContext.processIdentifier)
        else {
            return
        }

        let bundleIdentifier = launchAppContext.bundleIdentifier ?? "unknown"
        logger.info(
            "Reactivating launch app before paste: pid=\(launchAppContext.processIdentifier, privacy: .public) bundleID=\(bundleIdentifier, privacy: .public)"
        )
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(120_000)
    }

    private func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let snapshot = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        return PasteboardSnapshot(items: snapshot)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for item in items {
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item {
                pasteboardItem.setData(data, forType: type)
            }
            pasteboard.writeObjects([pasteboardItem])
        }
    }
}
