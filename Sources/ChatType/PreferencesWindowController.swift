import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        config: AppConfig,
        draft: PreferencesDraft? = nil,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Result<Void, any Error>,
        onImportAppleContactRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onImportWeixinRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onLoadRecentHistory: @escaping @Sendable () throws -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping @Sendable () throws -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onReprocessRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false,
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        let view = PreferencesView(
            initialConfig: config,
            draft: draft,
            authManager: authManager,
            onSave: onSave,
            onImportAppleContactRemarks: onImportAppleContactRemarks,
            onImportWeixinRemarks: onImportWeixinRemarks,
            onLoadRecentHistory: onLoadRecentHistory,
            onLoadRecoveryHistory: onLoadRecoveryHistory,
            recoveryDirectoryURL: recoveryDirectoryURL,
            onRetryRecoveryRecord: onRetryRecoveryRecord,
            onReprocessRecoveryRecord: onReprocessRecoveryRecord,
            onOpenConfigFolder: onOpenConfigFolder,
            focusRecoveryHistory: focusRecoveryHistory
        )
        let hostingController = NSHostingController(rootView: view)

        let window = CommandClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            onQuit: { NSApp.terminate(nil) }
        )
        window.minSize = NSSize(width: 940, height: 680)
        window.title = "ChatType Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentViewController = hostingController

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class CommandClosingWindow: NSWindow {
    private let onQuit: () -> Void

    init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
        onQuit: @escaping () -> Void
    ) {
        self.onQuit = onQuit
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? ShortcutRecorder.CaptureView {
            recorder.keyDown(with: event)
            return true
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let isCommandOnly = modifiers == .command
        let key = event.charactersIgnoringModifiers?.lowercased()

        if event.type == .keyDown, isCommandOnly, key == "q" {
            onQuit()
            return true
        }

        if event.type == .keyDown, isCommandOnly, key == "w" {
            close()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
