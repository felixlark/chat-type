import Foundation
import Security

enum JWTClaimDecoder {
    static func payload(from token: String?) -> [String: Any]? {
        guard let token else {
            return nil
        }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else {
            return nil
        }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding != 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: base64)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

struct ChatGPTSession: Codable, Sendable, Equatable {
    var accessToken: String
    var accessTokenExpiresAt: Date?
    var refreshToken: String?
    var idToken: String?
    var userEmail: String?
    var updatedAt: Date

    init(
        accessToken: String,
        accessTokenExpiresAt: Date?,
        refreshToken: String? = nil,
        idToken: String? = nil,
        userEmail: String?,
        updatedAt: Date
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.userEmail = userEmail
        self.updatedAt = updatedAt
    }

    func tokenIsUsable(now: Date) -> Bool {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard let accessTokenExpiresAt else {
            return true
        }

        return accessTokenExpiresAt > now
    }

    var chatGPTAccountID: String? {
        for token in [idToken, accessToken] {
            guard let payload = JWTClaimDecoder.payload(from: token) else {
                continue
            }
            if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
               let accountID = auth["chatgpt_account_id"] as? String,
               accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return accountID
            }
            if let accountID = payload["https://api.openai.com/auth.chatgpt_account_id"] as? String,
               accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return accountID
            }
        }
        return nil
    }
}

protocol ChatGPTSessionPersisting: Sendable {
    func load() throws -> ChatGPTSession?
    func save(_ session: ChatGPTSession) throws
    func delete() throws
}

enum ChatGPTSessionStoreError: LocalizedError {
    case unexpectedData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "ChatType 保存的 ChatGPT 会话无法解析。"
        case .unhandledStatus(let status):
            return "ChatType 无法访问本地 ChatGPT 会话存储（OSStatus \(status)）。"
        }
    }
}

struct KeychainChatGPTSessionStore: ChatGPTSessionPersisting {
    let service: String
    let account: String
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init(
        service: String = "me.longbiaochen.ChatType.ChatGPTSession",
        account: String = "default",
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.service = service
        self.account = account
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() throws -> ChatGPTSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw ChatGPTSessionStoreError.unexpectedData
            }
            return try decoder.decode(ChatGPTSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw ChatGPTSessionStoreError.unhandledStatus(status)
        }
    }

    func save(_ session: ChatGPTSession) throws {
        let data = try encoder.encode(session)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateQuery = baseQuery()
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw ChatGPTSessionStoreError.unhandledStatus(updateStatus)
            }
        default:
            throw ChatGPTSessionStoreError.unhandledStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatGPTSessionStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class InMemoryChatGPTSessionStore: ChatGPTSessionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ChatGPTSession?

    init(session: ChatGPTSession? = nil) {
        self.session = session
    }

    func load() throws -> ChatGPTSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: ChatGPTSession) throws {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        session = nil
        lock.unlock()
    }
}
