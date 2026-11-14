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

    var errorDescription: String? {
        switch self {
        case .clipboardUnavailable:
            return "无法写入剪贴板。"
        case .keyEventFailed:
            return "生成 Cmd+V 事件失败。"
        }
    }
}

enum ClipboardFallbackReason: Sendable, Equatable {
    case userSelected
    case accessibilityPermissionRequired
    case noEditableTarget

    var statusDetail: String {
        switch self {
        case .userSelected: return "Copied to clipboard as selected"
        case .accessibilityPermissionRequired:
            return "Copied to clipboard. Grant Accessibility access for auto-paste."
        case .noEditableTarget:
            return "Copied to clipboard"
        }
    }

    var overlaySubtitle: String {
        switch self {
        case .userSelected: return "已按设置复制到剪贴板。"
        case .accessibilityPermissionRequired:
            return "Accessibility permission is off, so ChatType left the text in the clipboard."
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
protocol TextInjecting: AnyObject {
    func copyToClipboard(text: String) throws -> InjectionOutcome
    func inject(
        text: String,
        preserveClipboard: Bool,
        restoreDelayMilliseconds: UInt64,
        launchAppContext: LaunchAppContext?
    ) throws -> InjectionOutcome
}

extension TextInjecting {
    func copyToClipboard(text: String) throws -> InjectionOutcome { throw InjectionError.clipboardUnavailable }
}

@MainActor
final class TextInjector: TextInjecting {
    func copyToClipboard(text: String) throws -> InjectionOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw InjectionError.clipboardUnavailable }
        return .copiedToClipboard(reason: .userSelected)
    }
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.longbiaochen.chattype",
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
        let pasteboard = NSPasteboard.general
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

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw InjectionError.keyEventFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let snapshot {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: restoreDelayMilliseconds * 1_000_000)
                snapshot.restore(to: pasteboard)
            }
        }

        return .pasted
    }

    private func waitForPasteTarget(launchAppContext: LaunchAppContext?) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if isPasteTargetReady(launchAppContext: launchAppContext) {
                return true
            }
            restoreLaunchAppIfNeeded(launchAppContext)
            usleep(25_000)
        }

        return isPasteTargetReady(launchAppContext: launchAppContext)
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
        let pasteboard = NSPasteboard.general
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
