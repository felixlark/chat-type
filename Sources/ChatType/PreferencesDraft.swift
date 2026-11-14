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

    init(config: AppConfig) { self.config = config; applied = config }
    var hasChanges: Bool { config != applied }

    func apply(using save: (AppConfig) -> Result<Void, any Error>) -> Result<Void, any Error> {
        let result: Result<Void, any Error> = hasChanges ? save(config) : .success(())
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
