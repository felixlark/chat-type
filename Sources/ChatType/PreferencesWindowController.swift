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
        onLoadHistoryIndex: @escaping @Sendable () throws -> RecoveryHistoryIndex,
        onLoadHistoryRecord: @escaping @Sendable (UUID) throws -> RecoveryRecord?,
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord, UUID?) -> Void,
        onReprocessRecoveryRecord: @escaping (RecoveryRecord, UUID?) -> Void,
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
            onLoadHistoryIndex: onLoadHistoryIndex,
            onLoadHistoryRecord: onLoadHistoryRecord,
            recoveryDirectoryURL: recoveryDirectoryURL,
            onRetryRecoveryRecord: onRetryRecoveryRecord,
            onReprocessRecoveryRecord: onReprocessRecoveryRecord,
            onOpenConfigFolder: onOpenConfigFolder,
            focusRecoveryHistory: focusRecoveryHistory
        )
        let hostingController = NSHostingController(rootView: view)

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 1200, height: 720)
        window.title = "ChatType Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = hostingController

        super.init(window: window)
        window.delegate = self
        applyDefaultPlacement(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if let window,
           !window.isVisible || !PreferencesWindowPlacement.isBuiltIn(window.screen) {
            applyDefaultPlacement(to: window)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyDefaultPlacement(to window: NSWindow) {
        guard let frame = PreferencesWindowPlacement.maximizedFrame(
            in: PreferencesWindowPlacement.screens()
        ) else {
            window.center()
            return
        }
        window.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? ShortcutRecorder.CaptureView {
            recorder.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
