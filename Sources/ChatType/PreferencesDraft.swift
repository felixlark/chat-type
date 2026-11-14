import Combine
import Foundation

/// One draft survives section/window changes. Explicit recording/reprocess
/// actions apply it once; typing never writes the full vocabulary to disk.
@MainActor
final class PreferencesDraft: ObservableObject {
    @Published var config: AppConfig
    @Published var message = "选择完成后可直接按 F5；正在处理的录音保持原路线。"
    @Published var isError = false
    private var applied: AppConfig
    private let hasPolishCredential: @MainActor (TextPolishProviderID) -> Bool

    init(config: AppConfig, hasPolishCredential: (@MainActor (TextPolishProviderID) -> Bool)? = nil) {
        self.config = config; applied = config; self.hasPolishCredential = hasPolishCredential ?? Self.keyIsPresent
    }

    private static func keyIsPresent(_ provider: TextPolishProviderID) -> Bool {
        switch provider {
        case .qwenFlash: return KeychainQwenKeyStore().contains()
        case .glmFlash: return KeychainGLMKeyStore().contains()
        default: return true
        }
    }
    var hasChanges: Bool { config != applied }

    func apply(using save: (AppConfig) -> Result<Void, any Error>) -> Result<Void, any Error> {
        let polish = config.transcription.textPolish
        let result: Result<Void, any Error>
        if polish.isEnabled, [.qwenFlash, .glmFlash].contains(polish.provider), !hasPolishCredential(polish.provider) {
            result = .failure(PolishCredentialRequired(provider: polish.provider))
        } else {
            result = hasChanges ? save(config) : .success(())
        }
        switch result {
        case .success:
            applied = config
            message = "已应用 · 用于新录音和“按当前流程重跑”。"
            isError = false
        case .failure(let error):
            message = error.localizedDescription; isError = true
        }
        return result
    }
}


private struct PolishCredentialRequired: LocalizedError {
    let provider: TextPolishProviderID
    var errorDescription: String? { "请先在 Dictation 的 Polish 阶段保存 \(provider.title) API Key，或关闭润色；当前选择尚未应用。" }
}
