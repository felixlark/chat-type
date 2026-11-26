import Combine
import Foundation

/// One draft survives section/window changes. Explicit recording/reprocess
/// actions apply it once; typing never writes the full vocabulary to disk.
@MainActor
final class PreferencesDraft: ObservableObject {
    @Published var config: AppConfig
    @Published var message = "选择完成后可直接按激活快捷键；正在处理的录音保持原路线。"
    @Published var isError = false
    @Published private(set) var isRecordingShortcut = false
    var onBeginShortcutCapture: () throws -> Void = {}
    var onEndShortcutCapture: () throws -> Void = {}
    private var applied: AppConfig
    private let hasPolishCredential: @MainActor (TextPolishProviderID) -> Bool

    init(config: AppConfig, hasPolishCredential: (@MainActor (TextPolishProviderID) -> Bool)? = nil) {
        self.config = config; applied = config; self.hasPolishCredential = hasPolishCredential ?? Self.keyIsPresent
    }

    private static func keyIsPresent(_ provider: TextPolishProviderID) -> Bool {
        switch provider {
        case .qwenFlash: return KeychainQwenKeyStore().contains()
        case .glmFlash: return KeychainGLMKeyStore().contains()
        case .deepSeekFlash: return KeychainMarkpipeKeyStore().contains()
        default: return true
        }
    }
    var hasChanges: Bool { config != applied }
    var activeShortcut: ActivationShortcut { ActivationShortcut(applied.transcription) }
    var shortcutHasChanges: Bool { ActivationShortcut(config.transcription) != activeShortcut }

    func beginShortcutCapture() {
        do {
            try onBeginShortcutCapture()
            isRecordingShortcut = true
        } catch { message = error.localizedDescription; isError = true }
    }

    func endShortcutCapture(_ shortcut: ActivationShortcut? = nil) {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        if let shortcut {
            config.transcription.hotkeyKeyCode = shortcut.keyCode
            config.transcription.hotkeyModifiers = shortcut.modifiers
            config.transcription.hotkeyIsCustomized = true
        }
        do { try onEndShortcutCapture() }
        catch { message = error.localizedDescription; isError = true }
    }

    func apply(includeShortcut: Bool = true, using save: (AppConfig) -> Result<Void, any Error>) -> Result<Void, any Error> {
        var candidate = config
        if !includeShortcut {
            candidate.transcription.hotkeyKeyCode = applied.transcription.hotkeyKeyCode
            candidate.transcription.hotkeyModifiers = applied.transcription.hotkeyModifiers
            candidate.transcription.hotkeyIsCustomized = applied.transcription.hotkeyIsCustomized
        }
        let polish = config.transcription.textPolish
        let result: Result<Void, any Error>
        if config.transcription.provider == .deepSeek, !hasPolishCredential(.deepSeekFlash) {
            result = .failure(MarkpipeASRKeyRequired())
        } else if polish.isEnabled, [.qwenFlash, .glmFlash, .deepSeekFlash].contains(polish.provider),
                  !hasPolishCredential(polish.provider) {
            result = .failure(PolishCredentialRequired(provider: polish.provider))
        } else {
            result = candidate != applied ? save(candidate) : .success(())
        }
        switch result {
        case .success:
            applied = candidate
            message = shortcutHasChanges ? "流程已应用；快捷键待保存。" : "已应用 · 用于新录音和“按当前流程重跑”。"
            isError = false
        case .failure(let error):
            message = error.localizedDescription; isError = true
        }
        return result
    }
}


private struct PolishCredentialRequired: LocalizedError {
    let provider: TextPolishProviderID
    var errorDescription: String? {
        if provider == .deepSeekFlash {
            return "请先在 Account 保存 DeepSeek API Key，或关闭润色；当前选择尚未应用。"
        }
        return "请先在 Account 保存 \(provider.title) API Key，或关闭润色；当前选择尚未应用。"
    }
}

private struct MarkpipeASRKeyRequired: LocalizedError {
    var errorDescription: String? {
        "请先在 Account 保存 DeepSeek API Key；DeepSeek API 全流程当前尚未应用。"
    }
}
