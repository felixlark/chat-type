import Foundation
import Testing
@testable import ChatType

private final class MemoryMarkpipeKeys: MarkpipeKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private(set) var loadCount = 0

    init(_ key: String? = "markpipe-test-key") {
        self.key = key
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadCount += 1
        return key
    }

    func save(_ key: String) throws {
        lock.lock()
        self.key = key
        lock.unlock()
    }

    func contains() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return key != nil
    }
}

private final class DeepSeekRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        bodies.append(request.httpBody ?? Data())
        lock.unlock()
    }
}

private struct UntouchedGLMStore: GLMKeyStoring {
    func load() throws -> String? {
        Issue.record("DeepSeek polish accessed GLM credentials")
        return nil
    }

    func save(_ key: String) throws {
        Issue.record("DeepSeek polish wrote GLM credentials")
    }

    func contains() -> Bool {
        Issue.record("DeepSeek polish accessed GLM metadata")
        return false
    }
}

private struct UntouchedQwenStore: QwenKeyStoring {
    func load() throws -> String? {
        Issue.record("DeepSeek polish accessed Qwen credentials")
        return nil
    }

    func save(_ key: String) throws {
        Issue.record("DeepSeek polish wrote Qwen credentials")
    }

    func contains() -> Bool {
        Issue.record("DeepSeek polish accessed Qwen metadata")
        return false
    }
}

private func deepSeekConfig() -> TextPolishConfig {
    var config = TextPolishConfig()
    config.provider = .deepSeekFlash
    config.mode = .automaticWhenKeyAvailable
    return config
}

private func deepSeekEvent(_ content: String = "", reason: String? = nil) throws -> String {
    var choice: [String: Any] = ["index": 0, "delta": content.isEmpty ? [:] : ["content": content]]
    if let reason { choice["finish_reason"] = reason }
    let event: [String: Any] = [
        "id": "chatcmpl-deepseek",
        "object": "chat.completion.chunk",
        "choices": [choice],
    ]
    return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
}

private func deepSeekAudioFixture(
    durationMs: Int = 1_000,
    samples: Int = 2_400
) throws -> RecordedAudio {
    let sampleRate: UInt32 = 24_000
    var audio = Data()
    for index in 0..<samples {
        let sample: Int16 = index.isMultiple(of: 2) ? 1_200 : -1_200
        let raw = UInt16(bitPattern: sample)
        audio.append(UInt8(raw & 0xFF))
        audio.append(UInt8((raw >> 8) & 0xFF))
    }
    var wav = Data("RIFF".utf8)
    func append16(_ value: UInt16) {
        wav.append(UInt8(value & 0xFF))
        wav.append(UInt8((value >> 8) & 0xFF))
    }
    func append32(_ value: UInt32) {
        wav.append(UInt8(value & 0xFF))
        wav.append(UInt8((value >> 8) & 0xFF))
        wav.append(UInt8((value >> 16) & 0xFF))
        wav.append(UInt8((value >> 24) & 0xFF))
    }
    append32(UInt32(36 + audio.count))
    wav.append(Data("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(sampleRate)
    append32(sampleRate * 2)
    append16(2)
    append16(16)
    wav.append(Data("data".utf8))
    append32(UInt32(audio.count))
    wav.append(audio)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try wav.write(to: url)
    return RecordedAudio(fileURL: url, durationMs: durationMs)
}

@Test func deepSeekWorkflowConfigRoundTripsWithoutCredentialMaterial() throws {
    var config = AppConfig()
    config.transcription.provider = .deepSeek
    config.transcription.livePreviewProvider = .automatic
    config.transcription.textPolish.provider = .deepSeekFlash
    config.transcription.textPolish.setEnabled(true)

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.transcription.provider == .deepSeek)
    #expect(decoded.transcription.textPolish.provider == .deepSeekFlash)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("markpipe-test-key"))
    #expect(!json.contains("apiKey"))
}

@Test func deepSeekWorkflowReflectsSharedKeyReadiness() {
    var config = TranscriptionConfig()
    config.provider = .deepSeek
    config.textPolish.provider = .deepSeekFlash
    config.textPolish.setEnabled(true)

    let missing = ProcessingStage.stages(
        config: config,
        localPreviewSupported: true,
        chatGPTReady: false,
        glmReady: false,
        qwenReady: false,
        deepSeekReady: false
    )
    #expect(missing[1].service.contains("key required"))
    #expect(missing[1].output.contains("No output"))
    #expect(missing[3].output.contains("No output"))

    let ready = ProcessingStage.stages(
        config: config,
        localPreviewSupported: true,
        chatGPTReady: false,
        glmReady: false,
        qwenReady: false,
        deepSeekReady: true
    )
    #expect(ready[1].service.contains("api.markpipe.app/v1/tools/asr"))
    #expect(ready[3].service.contains("api.markpipe.app"))
}

@Test func deepSeekPolishRequiresMarkpipeKeyAndUsesFixedDestination() async throws {
    let keys = MemoryMarkpipeKeys()
    #expect(TextPolishProviderSelector().selectProvider(
        config: deepSeekConfig(),
        chatGPTAuthAvailable: true,
        markpipeKeyAvailable: keys.contains()
    )?.id == .deepSeekFlash)
    #expect(TextPolishProviderSelector().selectProvider(
        config: deepSeekConfig(),
        chatGPTAuthAvailable: true,
        markpipeKeyAvailable: false
    ) == nil)

    let capture = DeepSeekRequestCapture()
    let stream = try [
        deepSeekEvent("保留 ChatType 与 F5。"),
        deepSeekEvent(reason: "stop"),
    ].joined(separator: "\n")
    let polisher = OpenAICompatibleTextPolisher(
        config: deepSeekConfig(),
        chatGPTAuthProvider: FakeChatGPTAuthManager(),
        chatGPTAuthAvailable: true,
        glmKeyStore: UntouchedGLMStore(),
        qwenKeyStore: UntouchedQwenStore(),
        markpipeKeyStore: keys,
        dataLoader: { request in
            capture.append(request)
            return (Data(stream.utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!)
        }
    )

    let result = try await polisher.polish(
        text: "保留 ChatType 与 F5。",
        terminologyEntries: [],
        hintTerms: []
    )
    #expect(result.text == "保留 ChatType 与 F5。")
    #expect(result.provider == .deepSeekFlash)
    let request = try #require(capture.requests.first)
    #expect(request.url?.absoluteString == "https://api.markpipe.app/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer markpipe-test-key")
    let bodyData = try #require(capture.bodies.first)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "deepseek-flash")
    #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    #expect(body["stream"] as? Bool == true)
}

@Test func deepSeekPolishMissingKeyStopsBeforeNetwork() async {
    let keys = MemoryMarkpipeKeys(nil)
    let polisher = OpenAICompatibleTextPolisher(
        config: deepSeekConfig(),
        chatGPTAuthProvider: FakeChatGPTAuthManager(),
        chatGPTAuthAvailable: true,
        markpipeKeyStore: keys,
        dataLoader: { _ in
            Issue.record("Missing Markpipe key reached the network")
            throw URLError(.badServerResponse)
        }
    )
    await #expect(throws: TextPolishError.self) {
        _ = try await polisher.polish(text: "test", terminologyEntries: [], hintTerms: [])
    }
}

@Test func deepSeekASRSendsCompleteWAVWithoutPromptAndRecordsRequestID() async throws {
    let capture = DeepSeekRequestCapture()
    let transcriber = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(),
        dataLoader: { request in
            capture.append(request)
            return (Data(#"{"request_id":"req-deepseek","text":"DeepSeek transcript","duration_ms":1000}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    )

    let audio = try deepSeekAudioFixture()
    let result = try await transcriber.transcribe(audio)
    #expect(result.text == "DeepSeek transcript")
    #expect(result.metrics.provider == .deepSeek)
    #expect(result.metrics.protocolRequestID == "req-deepseek")
    #expect(result.metrics.promptIncluded == false)
    let request = try #require(capture.requests.first)
    #expect(request.url?.absoluteString == "https://api.markpipe.app/v1/tools/asr")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer markpipe-test-key")
    let body = String(decoding: try #require(capture.bodies.first), as: UTF8.self)
    #expect(body.contains("name=\"file\""))
    #expect(!body.contains("name=\"prompt\""))
    #expect(!body.contains("name=\"model\""))
    #expect(body.contains("DeepSeek transcript") == false)
}

@Test func deepSeekASRMissingKeyAndOversizeStopBeforeNetwork() async throws {
    let missing = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(nil),
        dataLoader: { _ in
            Issue.record("Missing key reached DeepSeek network")
            throw URLError(.badServerResponse)
        }
    )
    await #expect(throws: DeepSeekTranscriptionError.self) {
        _ = try await missing.transcribe(try deepSeekAudioFixture())
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try Data(repeating: 0x2A, count: MarkpipeDeepSeekRoute.maximumAudioBytes + 1).write(to: url)
    let oversize = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(),
        dataLoader: { _ in
            Issue.record("Oversized audio reached DeepSeek network")
            throw URLError(.badServerResponse)
        }
    )
    await #expect(throws: DeepSeekTranscriptionError.self) {
        _ = try await oversize.transcribe(RecordedAudio(fileURL: url, durationMs: 1_000))
    }
}

@Test func deepSeekRejectsPartialOrInvalidResponses() async throws {
    let transcriber = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(),
        dataLoader: { request in
            (Data(#"{"request_id":"req-empty","text":"   ","duration_ms":1000}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    )
    await #expect(throws: DeepSeekTranscriptionError.self) {
        _ = try await transcriber.transcribe(try deepSeekAudioFixture())
    }
}

@Test func deepSeekClassifiesCloudflareChallengeWithoutCallingItAnAuthFailure() async throws {
    let transcriber = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(),
        dataLoader: { request in
            (Data("<html><body>Cloudflare challenge</body></html>".utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=UTF-8", "Server": "cloudflare"]
                )!)
        }
    )
    do {
        _ = try await transcriber.transcribe(try deepSeekAudioFixture())
        Issue.record("Cloudflare challenge was accepted")
    } catch let error as DeepSeekTranscriptionError {
        #expect(error.localizedDescription.contains("Cloudflare 403 challenge"))
        #expect(!error.localizedDescription.contains("鉴权失败"))
        #expect(!DeepSeekTranscriber.isRetryable(error))
    }
}

@Test func deepSeekTreatsMarkpipeFiveHundredsAsRetryableServiceFailure() async throws {
    let transcriber = DeepSeekTranscriber(
        keyStore: MemoryMarkpipeKeys(),
        dataLoader: { request in
            (Data("error code: 523".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 523, httpVersion: nil, headerFields: nil)!)
        }
    )
    do {
        _ = try await transcriber.transcribe(try deepSeekAudioFixture())
        Issue.record("HTTP 523 was accepted")
    } catch let error as DeepSeekTranscriptionError {
        #expect(error.localizedDescription.contains("暂时不可用"))
        #expect(DeepSeekTranscriber.isRetryable(error))
    }
}
