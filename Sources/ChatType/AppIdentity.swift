import Foundation

/// Exact app-owned service names from the signed package. Accounts and product
/// data directories remain owned by their existing implementations.
struct AppIdentity: Equatable, Sendable {
    static let defaultBundleID = "io.github.felixlark.ChatType"
    static let serviceFields = ["ChatTypeChatGPTSessionService", "ChatTypeDoubaoService",
                                "ChatTypeGLMService", "ChatTypeQwenService", "ChatTypeMarkpipeService"]
    static let current: AppIdentity = {
        do { return try AppIdentity(info: Bundle.main.infoDictionary ?? [:]) }
        catch { fatalError("ChatType package identity metadata is incomplete.") }
    }()
    static var loggingSubsystem: String { Bundle.main.bundleIdentifier ?? defaultBundleID }

    let chatGPTSessionService: String
    let doubaoService: String
    let glmService: String
    let qwenService: String
    let markpipeService: String

    enum IdentityError: Error { case incompleteServices }

    init(info: [String: Any]) throws {
        let fields = Self.serviceFields
        let values: [String]
        if fields.allSatisfy({ info[$0] == nil }) {
            // SwiftPM/unpackaged development uses the same public defaults as
            // the packager; an explicit partial package never mixes identities.
            values = ["chatgpt-session", "doubao", "glm", "qwen", "markpipe"].map { Self.defaultBundleID + "." + $0 }
        } else {
            values = try fields.map { field in
                guard let value = info[field] as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw IdentityError.incompleteServices
                }
                return value
            }
        }
        chatGPTSessionService = values[0]
        doubaoService = values[1]
        glmService = values[2]
        qwenService = values[3]
        markpipeService = values[4]
    }
}
