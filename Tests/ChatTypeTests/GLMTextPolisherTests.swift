import Foundation
import Testing
@testable import ChatType

private final class MemoryGLMKeys: GLMKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private(set) var loads = 0
    init(_ key: String? = "synthetic-glm-key") { self.key = key }
    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return key
    }
    func save(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.key = key
    }
    func contains() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return key != nil
    }
}

private func glmConfig() -> TextPolishConfig {
    var config = TextPolishConfig()
    config.provider = .glmFlash
    return config
}

private func glmEvent(_ content: String = "", reason: String? = nil) throws -> String {
    var choice: [String: Any] = ["delta": ["content": content, "reasoning_content": "private reasoning"]]
    if let reason { choice["finish_reason"] = reason }
    let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
}

@Test func glmConfigRoundTripAndLegacyDefaults() throws {
    let old = try JSONDecoder().decode(TextPolishConfig.self, from: Data(#"{"allowChatGPTAuthFallback":false}"#.utf8))
    #expect(old.provider == .chatGPTAuth)
    #expect(!old.chatGPTAuthEnabled)
    let data = try JSONEncoder().encode(glmConfig())
    #expect(try JSONDecoder().decode(TextPolishConfig.self, from: data).provider == .glmFlash)
    #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-glm-key"))
    var config = glmConfig()
    config.chatGPTAuthEnabled = false
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: false, glmKeyAvailable: true)?.id == .glmFlash)
    config.mode = .disabled
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: true, glmKeyAvailable: true) == nil)
}

@Test func glmRequestUsesIndependentKeyFixedDestinationAndSharedPrompt() async throws {
    let auth = FakeChatGPTAuthManager()
    let stream = try glmEvent("保留 ChatType v0.5。") + glmEvent(reason: "stop")
    let result = try await OpenAICompatibleTextPolisher(
        config: glmConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
        glmKeyStore: MemoryGLMKeys(), dataLoader: { request in
            #expect(request.url?.absoluteString == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-glm-key")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["model"] as? String == "glm-4.7-flash")
            #expect(body["stream"] as? Bool == true)
            #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(body["temperature"] as? Double == 0.2)
            #expect(body["max_tokens"] as? Int == 1200)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages[0]["content"]?.contains("ChatType aliases: 聊天类型") == true)
            #expect(messages[1]["content"] == "保留聊天类型 v0.5。")
            return (Data(stream.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ).polish(text: "保留聊天类型 v0.5。", terminologyEntries: [TerminologyEntry(canonical: "ChatType", aliases: ["聊天类型"])], hintTerms: [])
    #expect(result.text == "保留 ChatType v0.5。")
    #expect(result.provider == .glmFlash)
    #expect(auth.bestCallCount == 0)
    #expect(auth.refreshCallCount == 0)
}

@Test func glmMissingKeyStopsBeforeNetworkOrOAuth() async {
    let auth = FakeChatGPTAuthManager()
    await #expect(throws: TextPolishError.self) {
        try await OpenAICompatibleTextPolisher(
            config: glmConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
            glmKeyStore: MemoryGLMKeys(nil), dataLoader: { _ in
                Issue.record("Missing key reached network")
                throw TextPolishError.invalidResponse
            }
        ).polish(text: "测试", terminologyEntries: [], hintTerms: [])
    }
    #expect(auth.bestCallCount == 0)
}

@Test func glmRejectsIncompleteInvalidAndNonStopStreams() async throws {
    let streams = try [
        glmEvent("partial"),
        glmEvent("partial", reason: "length"),
        glmEvent("partial", reason: "content_filter"),
        glmEvent(reason: "stop"),
        "data: [DONE]\n\n",
        "data: bad-json\n\n",
        "data: {\"error\":{\"message\":\"synthetic-secret-body\"}}\n\n",
    ]
    for stream in streams {
        await #expect(throws: TextPolishError.self) {
            try await OpenAICompatibleTextPolisher(
                config: glmConfig(), chatGPTAuthAvailable: false, glmKeyStore: MemoryGLMKeys(),
                dataLoader: { request in
                    (Data(stream.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            ).polish(text: "测试", terminologyEntries: [], hintTerms: [])
        }
    }
}

@Test func glmStopsAtSemanticCompletionAndIgnoresReasoning() throws {
    var stream = ChatCompletionPolishStream()
    #expect(try !stream.consume("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden\"}}]}"))
    #expect(stream.text.isEmpty)
    #expect(try !stream.consume(glmEvent("visible").trimmingCharacters(in: .newlines)))
    #expect(try stream.consume(glmEvent(reason: "stop").trimmingCharacters(in: .newlines)))
    #expect(stream.text == "visible")
}

@Test func glmRateLimitIsSafeAndCancellationPropagates() async throws {
    let auth = FakeChatGPTAuthManager()
    do {
        _ = try await OpenAICompatibleTextPolisher(
            config: glmConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true, glmKeyStore: MemoryGLMKeys(),
            dataLoader: { request in
                (Data("synthetic-secret-body".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
            }
        ).polish(text: "测试", terminologyEntries: [], hintTerms: [])
        Issue.record("429 succeeded")
    } catch {
        #expect(error.localizedDescription.contains("429"))
        #expect(!error.localizedDescription.contains("synthetic-secret-body"))
    }
    #expect(auth.refreshCallCount == 0)
    let (entered, continuation) = AsyncStream<Void>.makeStream()
    let polisher = OpenAICompatibleTextPolisher(
        config: glmConfig(), chatGPTAuthAvailable: false, glmKeyStore: MemoryGLMKeys(),
        dataLoader: { _ in
            continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            throw TextPolishError.invalidResponse
        }
    )
    let task = Task { try await polisher.polish(text: "测试", terminologyEntries: [], hintTerms: []) }
    var iterator = entered.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func chatGPTValidatesDestinationBeforeLoadingOAuthAndNeverReadsGLMKey() async {
    for endpoint in ["https://example.com/responses", "http://chatgpt.com/responses", "https://chatgpt.com:444/responses", "https://chatgpt.com.evil.example/responses"] {
        var config = TextPolishConfig()
        config.chatGPTResponseURL = endpoint
        let auth = FakeChatGPTAuthManager()
        let keys = MemoryGLMKeys()
        await #expect(throws: TextPolishError.self) {
            try await OpenAICompatibleTextPolisher(
                config: config, chatGPTAuthProvider: auth, chatGPTAuthAvailable: true, glmKeyStore: keys,
                dataLoader: { _ in Issue.record("Unaudited destination reached network"); throw TextPolishError.invalidResponse }
            ).polish(text: "test", terminologyEntries: [], hintTerms: [])
        }
        #expect(auth.bestCallCount == 0)
        #expect(keys.loads == 0)
    }
}

@Test func fixedPolishEndpointsRejectEveryRedirect() {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
    let task = session.dataTask(with: original)
    let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
    for destination in ["https://example.com/", "https://open.bigmodel.cn/next", "https://open.bigmodel.cn:444/", "http://open.bigmodel.cn/"] {
        PolishRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)) { redirected in
            #expect(redirected == nil)
        }
    }
}

@Test func chatGPTSuccessLeavesGLMCredentialsUntouched() async throws {
    let keys = MemoryGLMKeys()
    let auth = FakeChatGPTAuthManager(bestTokens: [.success("synthetic-oauth")])
    let result = try await OpenAICompatibleTextPolisher(
        config: TextPolishConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
        glmKeyStore: keys, dataLoader: { request in
            #expect(request.url?.host == "chatgpt.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-oauth")
            return (Data(#"{"status":"completed","output_text":"complete"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ).polish(text: "test", terminologyEntries: [], hintTerms: [])
    #expect(result.provider == .chatGPTAuth)
    #expect(keys.loads == 0)
}
