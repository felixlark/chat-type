import Foundation
import Security

struct DoubaoOrganizationFailure: LocalizedError, Sendable {
    let partialText: String
    let detail: String
    var errorDescription: String? { "豆包整理未完整结束，部分输出已保留。\(detail)" }
}

enum DoubaoHTTP {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PolishRedirectPolicy(), delegateQueue: nil)
    }()

    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    static func organize(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DoubaoError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard http.mimeType == "text/event-stream" else { throw DoubaoError.unexpectedContent }
        var stream = DoubaoOrganizationStream()
        let originalText = request.httpBody.flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["query"] as? String
        }
        var line = Data()
        var body = Data()
        // Parse bytes ourselves: some AsyncLineSequence implementations omit blank
        // lines, which would destroy SSE event-block boundaries.
        do { for try await byte in bytes {
            try Task.checkCancellation()
            body.append(byte)
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                try stream.consume(line: String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
                if stream.done { _ = try stream.result(originalText: originalText); return (body, response) }
            } else { line.append(byte) }
        }
        throw DoubaoError.incomplete("文字整理")
        } catch {
            try Task.checkCancellation()
            if let partial = stream.partialText {
                throw DoubaoOrganizationFailure(partialText: partial, detail: error.localizedDescription)
            }
            throw error
        }
    }
}

protocol DoubaoKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ value: String) throws
}

struct DoubaoKeychain: DoubaoKeyStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "me.longbiaochen.chattype.doubao",
         kSecAttrAccount as String: "asr-configuration"]
    }
    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DoubaoError.credentials }
        return String(data: data, encoding: .utf8)
    }
    func save(_ value: String) throws {
        let data = Data(value.utf8)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                throw DoubaoError.credentials
            }
        } else if status != errSecSuccess { throw DoubaoError.credentials }
    }
}

actor DoubaoCredentials {
    static let shared = DoubaoCredentials()
    let store: any DoubaoKeyStoring
    let loader: DoubaoHTTP.Loader
    init(store: any DoubaoKeyStoring = DoubaoKeychain(), loader: @escaping DoubaoHTTP.Loader = DoubaoHTTP.load) {
        self.store = store; self.loader = loader
    }

    func key(refresh: Bool = false) async throws -> String {
        if !refresh, let cached = try store.load(), !cached.isEmpty { return cached }
        // Compatible Mac candidate identity observed in controlled replay; no
        // device registration, existing device ID or account session is used.
        let url = URL(string: "https://is.snssdk.com/service/settings/v3/?aid=685343&device_platform=mac&app_name=oime&version_name=1.1.0&version_code=1010005&channel=release")!
        var request = URLRequest(url: url)
        request.setValue("ChatType/macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DoubaoError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let settings = data["settings"] as? [String: Any],
              let asr = settings["asr_config"] as? [String: Any],
              let key = asr["app_key"] as? String, !key.isEmpty else { throw DoubaoError.credentials }
        try Task.checkCancellation()
        try store.save(key)
        return key
    }
}

struct DoubaoTextOrganizer: TextPolishing {
    var loader: DoubaoHTTP.Loader = DoubaoHTTP.organize

    static func request(text: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://ime.doubao.com/api/v2/ai/text_organization")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("ChatType/macOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": text, "scene": 6, "stream": true,
            "space_at_cn_en_nb": 0, "space_at_newline": 0
        ])
        return request
    }

    func polish(text: String, terminologyEntries: [TerminologyEntry], hintTerms: [String]) async throws -> TextPolishResult {
        try Task.checkCancellation()
        let (data, response) = try await loader(Self.request(text: text))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DoubaoError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var stream = DoubaoOrganizationStream()
        do { for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            try stream.consume(line: line.hasSuffix("\r") ? String(line.dropLast()) : line)
        }
        let result = try stream.result(originalText: text)
        if DoubaoPolishSafety.hasDetachedNegatedPredicate(original: text, rewritten: result) {
            return TextPolishResult(text: text, provider: .doubaoIME, applied: false,
                estimatedInputTokens: 0, estimatedOutputTokens: 0, providerText: result,
                protectionReason: "豆包整理拆开了否定动作与后文，已保留识别原文。")
        }
        return TextPolishResult(text: result, provider: .doubaoIME, applied: result != text,
                                estimatedInputTokens: 0, estimatedOutputTokens: 0)
        } catch {
            if let partial = stream.partialText {
                throw DoubaoOrganizationFailure(partialText: partial, detail: error.localizedDescription)
            }
            throw error
        }
    }
}
