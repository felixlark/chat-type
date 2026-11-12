import Foundation
import Testing
@testable import ChatType

private final class MemoryQwenKeys: QwenKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private(set) var loads = 0
    init(_ key: String? = "synthetic-qwen-key") { self.key = key }
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

private func qwenConfig() -> TextPolishConfig {
    var config = TextPolishConfig()
    config.provider = .qwenFlash
    return config
}

private func qwenEvent(_ content: String = "", reason: String? = nil) throws -> String {
    var choice: [String: Any] = ["delta": ["content": content, "reasoning_content": "private reasoning"]]
    if let reason { choice["finish_reason"] = reason }
    let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
}

@Test func qwenConfigRoundTripAndLegacyDefaults() throws {
    let old = try JSONDecoder().decode(TextPolishConfig.self, from: Data(#"{"allowChatGPTAuthFallback":false}"#.utf8))
    #expect(old.provider == .chatGPTAuth)
    #expect(!old.chatGPTAuthEnabled)
    let data = try JSONEncoder().encode(qwenConfig())
    #expect(try JSONDecoder().decode(TextPolishConfig.self, from: data).provider == .qwenFlash)
    #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-qwen-key"))
    var config = qwenConfig()
    config.chatGPTAuthEnabled = false
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: false, qwenKeyAvailable: true)?.id == .qwenFlash)
    config.mode = .disabled
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: true, qwenKeyAvailable: true) == nil)
}

@Test func qwenRequestUsesIndependentKeyFixedDestinationAndSharedPrompt() async throws {
    let auth = FakeChatGPTAuthManager()
    let stream = try qwenEvent("保留 ChatType v0.5。") + qwenEvent(reason: "stop")
    let result = try await OpenAICompatibleTextPolisher(
        config: qwenConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
        qwenKeyStore: MemoryQwenKeys(), dataLoader: { request in
            #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-qwen-key")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["model"] as? String == "qwen-flash")
            #expect(body["stream"] as? Bool == true)
            #expect(body["enable_thinking"] as? Bool == false)
            #expect(body["thinking"] == nil)
            #expect(body["temperature"] as? Double == 0.2)
            #expect(body["max_tokens"] as? Int == 1200)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages[0]["content"]?.contains("ChatType aliases: 聊天类型") == true)
            #expect(messages[1]["content"] == "保留聊天类型 v0.5。")
            return (Data(stream.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ).polish(text: "保留聊天类型 v0.5。", terminologyEntries: [TerminologyEntry(canonical: "ChatType", aliases: ["聊天类型"])], hintTerms: [])
    #expect(result.text == "保留 ChatType v0.5。")
    #expect(result.provider == .qwenFlash)
    #expect(auth.bestCallCount == 0)
    #expect(auth.refreshCallCount == 0)
}

@Test func qwenMissingKeyStopsBeforeNetworkOrOAuth() async {
    let auth = FakeChatGPTAuthManager()
    await #expect(throws: TextPolishError.self) {
        try await OpenAICompatibleTextPolisher(
            config: qwenConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
            qwenKeyStore: MemoryQwenKeys(nil), dataLoader: { _ in
                Issue.record("Missing key reached network")
                throw TextPolishError.invalidResponse
            }
        ).polish(text: "测试", terminologyEntries: [], hintTerms: [])
    }
    #expect(auth.bestCallCount == 0)
}

@Test func qwenRejectsIncompleteInvalidAndNonStopStreams() async throws {
    let streams = try [
        qwenEvent("partial"),
        qwenEvent("partial", reason: "length"),
        qwenEvent("partial", reason: "content_filter"),
        qwenEvent(reason: "stop"),
        "data: [DONE]\n\n",
        "data: bad-json\n\n",
        "data: {\"error\":{\"message\":\"synthetic-secret-body\"}}\n\n",
    ]
    for stream in streams {
        await #expect(throws: TextPolishError.self) {
            try await OpenAICompatibleTextPolisher(
                config: qwenConfig(), chatGPTAuthAvailable: false, qwenKeyStore: MemoryQwenKeys(),
                dataLoader: { request in
                    (Data(stream.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            ).polish(text: "测试", terminologyEntries: [], hintTerms: [])
        }
    }
}

@Test func qwenStopsAtSemanticCompletionAndIgnoresReasoning() throws {
    var stream = ChatCompletionPolishStream()
    #expect(try !stream.consume("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden\"}}]}"))
    #expect(stream.text.isEmpty)
    #expect(try !stream.consume(qwenEvent("visible").trimmingCharacters(in: .newlines)))
    #expect(try stream.consume(qwenEvent(reason: "stop").trimmingCharacters(in: .newlines)))
    #expect(stream.text == "visible")
}

@Test func qwenRateLimitIsSafeAndCancellationPropagates() async throws {
    let auth = FakeChatGPTAuthManager()
    do {
        _ = try await OpenAICompatibleTextPolisher(
            config: qwenConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true, qwenKeyStore: MemoryQwenKeys(),
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
        config: qwenConfig(), chatGPTAuthAvailable: false, qwenKeyStore: MemoryQwenKeys(),
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


private struct UntouchedGLMKeys: GLMKeyStoring {
    func contains() -> Bool { Issue.record("Qwen accessed GLM metadata"); return true }
    func load() throws -> String? { Issue.record("Qwen accessed GLM secret"); return nil }
    func save(_ key: String) throws { Issue.record("Qwen wrote GLM secret") }
}

@Test func qwenDoesNotAccessOtherCredentialsOrDestinations() async throws {
    let auth = FakeChatGPTAuthManager()
    let text = try qwenEvent("complete", reason: "stop")
    let result = try await OpenAICompatibleTextPolisher(
        config: qwenConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
        glmKeyStore: UntouchedGLMKeys(), qwenKeyStore: MemoryQwenKeys(), dataLoader: { request in
            #expect(request.url?.host == "dashscope.aliyuncs.com")
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ).polish(text: "test", terminologyEntries: [], hintTerms: [])
    #expect(result.provider == .qwenFlash)
    #expect(auth.bestCallCount == 0)
    #expect(auth.refreshCallCount == 0)
}

@Test func chatGPTLeavesQwenKeyUntouched() async throws {
    let keys = MemoryQwenKeys()
    let auth = FakeChatGPTAuthManager(bestTokens: [.success("synthetic-oauth")])
    _ = try await OpenAICompatibleTextPolisher(
        config: TextPolishConfig(), chatGPTAuthProvider: auth, chatGPTAuthAvailable: true,
        qwenKeyStore: keys, dataLoader: { request in
            #expect(request.url?.host == "chatgpt.com")
            return (Data(#"{"status":"completed","output_text":"complete"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    ).polish(text: "test", terminologyEntries: [], hintTerms: [])
    #expect(keys.loads == 0)
}
