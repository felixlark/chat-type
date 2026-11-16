import Foundation
import Security

protocol QwenKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func contains() -> Bool
}

struct KeychainQwenKeyStore: QwenKeyStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppIdentity.current.qwenService,
         kSecAttrAccount as String: "default"]
    }

    func contains() -> Bool {
        // Metadata lookup: settings never retrieves the stored secret.
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    var credentialReadQuery: [String: Any] {
        var lookup = query
        lookup[kSecReturnData as String] = true
        return lookup
    }
    func load() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(credentialReadQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw QwenKeyStoreError.status(status)
        }
        return key
    }

    func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw QwenKeyStoreError.emptyKey }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw QwenKeyStoreError.status(status) }
    }
}

private enum QwenKeyStoreError: LocalizedError {
    case emptyKey
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey: return "Enter a Qwen API Key first."
        case .status(let code): return "Qwen Keychain operation failed (\(code))."
        }
    }
}
