import Foundation
import Testing
@testable import ChatType

private func doubaoJSON(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

@Test func doubaoFreshDefaultsAndLegacyMigrationAreDistinct() throws {
    let fresh = AppConfig()
    #expect(fresh.transcription.provider == .doubaoIME)
    #expect(fresh.transcription.textPolish.provider == .doubaoIME)
    let legacy = try JSONDecoder().decode(AppConfig.self, from: Data("{\"transcription\":{}}".utf8))
    #expect(legacy.transcription.provider == .chatGPTManagedAuth)
    #expect(legacy.transcription.textPolish.provider == .chatGPTAuth)
    var mixed = fresh
    mixed.transcription.textPolish.provider = .chatGPTAuth
    mixed.transcription.livePreviewEnabled = false
    mixed.transcription.terminologyAlignmentEnabled = false
    mixed.transcription.correctionRulesEnabled = false
    mixed.injection.clipboardOnly = true
    #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(mixed)) == mixed)
}

@Test func eitherSelectedChatGPTStageRequiresAccountButDoubaoDoesNot() {
    var config = AppConfig()
    let signedOut = { ChatGPTAuthSnapshot(state: .signedOut, detail: "test", userEmail: nil) }
    #expect(RuntimePreflight.issues(for: config, environment: [:], authSnapshotProvider: signedOut).isEmpty)
    config.transcription.textPolish.provider = .chatGPTAuth
    #expect(RuntimePreflight.issues(for: config, environment: [:], authSnapshotProvider: signedOut) == [.chatGPTLoginRequired])
    config.transcription.textPolish.provider = .doubaoIME
    config.transcription.provider = .chatGPTManagedAuth
    #expect(RuntimePreflight.issues(for: config, environment: [:], authSnapshotProvider: signedOut) == [.chatGPTLoginRequired])
}

@Test func protobufRejectsTruncatedLengthsAndOverflowRatherThanAcceptingPrefix() throws {
    let message = DoubaoProtobuf.request(token: "test-only", method: "TaskRequest", id: "id", audio: Data([1,2]), frame: 3)
    #expect(try DoubaoProtobuf.decode(message)[2] == .bytes(Data("test-only".utf8)))
    #expect(throws: DoubaoError.self) { try DoubaoProtobuf.decode(Data([0x12, 0x7f, 1])) }
    #expect(throws: DoubaoError.self) { try DoubaoProtobuf.decode(Data(repeating: 0xff, count: 11)) }
}

@Test func indexedVadSegmentsRetainRepeatedSpeechAndIgnoreLateInterim() throws {
    var transcript = DoubaoTranscript()
    func result(_ index: Int, _ text: String, _ final: Bool) throws -> Data {
        try doubaoJSON(["results": [["index": index, "text": text, "is_interim": !final, "is_vad_finished": final]]])
    }
    try transcript.consume(result(0, "第一段。", true))
    try transcript.consume(result(0, "迟到的预览", false))
    try transcript.consume(result(1, "第一段。", false))
    #expect(!transcript.complete)
    try transcript.consume(result(1, "第一段。", true))
    try transcript.consume(result(1, "第一段。", true))
    #expect(transcript.finalText == "第一段。第一段。")
    #expect(transcript.complete)
}

@Test func unindexedNewFinalCannotSilentlyReplaceAnEarlierSegment() throws {
    var transcript = DoubaoTranscript()
    func final(_ text: String) throws -> Data { try doubaoJSON(["results": [["text": text, "is_interim": false, "is_vad_finished": true]]]) }
    try transcript.consume(final("前缀"))
    #expect(throws: DoubaoError.self) { try transcript.consume(final("后段")) }
    #expect(transcript.finalText == "前缀")
}

@Test func organizerRequiresBothCompletionSignalsAndAcceptsMultilineEventData() throws {
    var stream = DoubaoOrganizationStream()
    for line in ["event: scene.completed", "data: {\"content\":", "data: \"保留否定要求。\"}", ""] {
        try stream.consume(line: line)
    }
    #expect(throws: DoubaoError.self) { try stream.result() }
    for line in ["event: done", "data: [DONE]", ""] { try stream.consume(line: line) }
    #expect(try stream.result() == "保留否定要求。")
}

@Test func organizerUsesFixedFiveFieldSchemaAndNoAccountCredentials() async throws {
    let organizer = DoubaoTextOrganizer(loader: { request in
        #expect(request.url?.absoluteString == "https://ime.doubao.com/api/v2/ai/text_organization")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(Set(object.keys) == ["query", "scene", "stream", "space_at_cn_en_nb", "space_at_newline"])
        #expect(object["scene"] as? Int == 6)
        #expect(String(cString: (object["space_at_cn_en_nb"] as! NSNumber).objCType) != "c")
        return (Data("event: scene.completed\ndata: {\"content\":\"终稿\"}\n\nevent: done\ndata: [DONE]\n\n".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await organizer.polish(text: "原文", terminologyEntries: [], hintTerms: [])
    #expect(result.text == "终稿")
    #expect(result.provider == .doubaoIME)
}

@Test func noRewriteRequiresAnExplicitFlagAndBothCompletionSignals() throws {
    let original = "请保留测试草稿。"
    var stream = DoubaoOrganizationStream()
    for line in ["event:scene.delta", "data:{\"content\":\"\",\"no_rewrite\":true}", ""] {
        try stream.consume(line: line)
    }
    #expect(throws: DoubaoError.self) { try stream.result(originalText: original) }
    for line in ["event:scene.completed", "data:{\"content\":\"\"}", ""] { try stream.consume(line: line) }
    #expect(throws: DoubaoError.self) { try stream.result(originalText: original) }
    for line in ["event:done", "data:[DONE]", ""] { try stream.consume(line: line) }
    #expect(try stream.result(originalText: original) == original)
    #expect(throws: DoubaoError.self) { try stream.result() }
    #expect(throws: DoubaoError.self) { try stream.result(originalText: " ") }

    for delta in ["{\"content\":\"\"}", "{\"content\":\"\",\"no_rewrite\":false}",
                  "{\"content\":\"部分输出\",\"no_rewrite\":true}"] {
        var invalid = DoubaoOrganizationStream()
        for line in ["event:scene.delta", "data:" + delta, "", "event:scene.completed",
                     "data:{\"content\":\"\"}", "", "event:done", "data:[DONE]", ""] {
            try invalid.consume(line: line)
        }
        #expect(throws: DoubaoError.self) { try invalid.result(originalText: original) }
    }
}

@Test func organizerExplicitNoRewriteReturnsOriginalAsUnchangedSuccess() async throws {
    let organizer = DoubaoTextOrganizer(loader: { request in
        let body = "event:scene.delta\ndata:{\"content\":\"\",\"no_rewrite\":true}\n\nevent:scene.completed\ndata:{\"content\":\"\"}\n\nevent:done\ndata:[DONE]\n\n"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
    })
    let result = try await organizer.polish(text: "请保留测试草稿。", terminologyEntries: [], hintTerms: [])
    #expect(result.text == "请保留测试草稿。")
    #expect(result.provider == .doubaoIME)
    #expect(!result.applied)
}

private final class TestDoubaoKeys: DoubaoKeyStoring, @unchecked Sendable {
    let lock = NSLock()
    private var value: String?
    func load() throws -> String? { lock.withLock { value } }
    func save(_ value: String) throws { lock.withLock { self.value = value } }
}

@Test func configurationKeyPersistsThroughInjectedStoreWithoutAccountData() async throws {
    let store = TestDoubaoKeys()
    let first = DoubaoCredentials(store: store, loader: { request in
        #expect(request.url?.host == "is.snssdk.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (try doubaoJSON(["data": ["settings": ["asr_config": ["app_key": "test-only-key"]]]]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    #expect(try await first.key() == "test-only-key")
    let restarted = DoubaoCredentials(store: store, loader: { _ in Issue.record("Cached key should not refresh settings"); throw DoubaoError.credentials })
    #expect(try await restarted.key() == "test-only-key")
}

private func doubaoTestWAV(samples: Int = 1280, rate: UInt32 = 16000, dataLength: UInt32? = nil) -> Data {
    func u16(_ v: UInt16) -> Data { Data([UInt8(v & 255), UInt8(v >> 8)]) }
    func u32(_ v: UInt32) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)]) }
    var result = Data("RIFF".utf8) + u32(UInt32(36 + samples * 2)) + Data("WAVEfmt ".utf8) + u32(16)
    result += u16(1) + u16(1) + u32(rate) + u32(rate * 2) + u16(2) + u16(16)
    result += Data("data".utf8) + u32(dataLength ?? UInt32(samples * 2))
    for i in 0..<samples { result += u16(i % 2 == 0 ? 2000 : 60000) }
    return result
}

@Test func growingWavUsesActualBytesAndDoesNotLoseAnIncompleteFrame() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try doubaoTestWAV(samples: 100, dataLength: 0).write(to: path)
    let reader = try DoubaoGrowingPCM(url: path)
    #expect(try reader.next(final: false) == nil)
    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 2, count: 440)); try handle.close()
    #expect(try reader.next(final: false)?.count == 640)
    let finalHeader = try FileHandle(forUpdating: path)
    try finalHeader.seek(toOffset: 40); try finalHeader.write(contentsOf: Data([0x80,0x02,0,0])); try finalHeader.close()
    #expect(try reader.next(final: true) == nil)
}

private final class TestDoubaoSocket: DoubaoSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var sent: [String] = []
    private var closed = false
    var holdCompletion = false
    var rejectDuringAudio = false
    var networkFailureDuringAudio = false
    private var receiveFailure: (any Error)?
    init() {
        queue = [Self.reply("TaskStarted"), Self.reply("SessionStarted")]
    }
    static func reply(_ kind: String, result: Data? = nil) -> Data {
        var data = DoubaoProtobuf.text(4, kind) + DoubaoProtobuf.varint(5 << 3) + DoubaoProtobuf.varint(20_000_000)
        if let result { data += DoubaoProtobuf.bytes(7, result) }
        return data
    }
    private func enqueue(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            if let waiter = self.waiter { self.waiter = nil; return waiter }
            queue.append(data); return nil
        }
        waiter?.resume(returning: data)
    }
    func send(_ data: Data) async throws {
        let fields = try DoubaoProtobuf.decode(data)
        guard case .bytes(let method) = fields[5] else { throw DoubaoError.malformedMessage }
        let name = String(decoding: method, as: UTF8.self)
        try lock.withLock {
            if closed { throw URLError(.cancelled) }
            sent.append(name)
        }
        if name == "TaskRequest", networkFailureDuringAudio {
            let waiter = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
                let value = self.waiter; self.waiter = nil
                if value == nil { receiveFailure = URLError(.networkConnectionLost) }
                return value
            }
            waiter?.resume(throwing: URLError(.networkConnectionLost))
        }
        if name == "TaskRequest", rejectDuringAudio {
            let failure = DoubaoProtobuf.text(4, "SessionFailed") + DoubaoProtobuf.varint(5 << 3) + DoubaoProtobuf.varint(40_200_011)
            enqueue(failure)
        }
        if name == "FinishSession", !holdCompletion {
            enqueue(Self.reply("", result: try doubaoJSON(["results": [["index": 0, "text": "完整识别。", "is_interim": false, "is_vad_finished": true]]])))
            enqueue(Self.reply("SessionFinished"))
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var failure: (any Error)?
            let next = lock.withLock { () -> (Data?, Bool) in
                if let error = receiveFailure { receiveFailure = nil; failure = error; return (nil, false) }
                if !queue.isEmpty { return (queue.removeFirst(), false) }
                if closed { return (nil, true) }
                waiter = continuation; return (nil, false)
            }
            if let failure { continuation.resume(throwing: failure) }
            else if let data = next.0 { continuation.resume(returning: data) }
            else if next.1 { continuation.resume(throwing: URLError(.cancelled)) }
        }
    }
    func close() {
        let waiter = lock.withLock { closed = true; let value = self.waiter; self.waiter = nil; return value }
        waiter?.resume(throwing: URLError(.cancelled))
    }
    var wasClosed: Bool { lock.withLock { closed } }
    var methods: [String] { lock.withLock { sent } }
}

@Test func fileSessionSendsEveryFrameAndWaitsForSessionFinished() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try doubaoTestWAV().write(to: path)
    let socket = TestDoubaoSocket()
    let transcriber = DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in socket })
    let result = try await transcriber.transcribe(RecordedAudio(fileURL: path, durationMs: 80))
    #expect(result.text == "完整识别。")
    #expect(result.metrics.provider == .doubaoIME)
    #expect(socket.methods == ["StartTask", "StartSession"] + Array(repeating: "TaskRequest", count: 4) + ["FinishSession"])
    #expect(socket.wasClosed)
}

@Test func cancellingAWaitingSessionClosesSocketAndRetainsAudio() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try doubaoTestWAV().write(to: path)
    let socket = TestDoubaoSocket(); socket.holdCompletion = true
    let worker = Task { try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in socket })
        .transcribe(RecordedAudio(fileURL: path, durationMs: 80)) }
    while !socket.methods.contains("FinishSession") { await Task.yield() }
    worker.cancel()
    do { _ = try await worker.value; Issue.record("Cancelled session must not succeed") }
    catch { #expect(error is CancellationError) }
    #expect(socket.wasClosed)
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test func receivingRejectionMustNotBeMaskedAsSenderCancellation() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try doubaoTestWAV().write(to: path)
    let socket = TestDoubaoSocket(); socket.rejectDuringAudio = true
    do {
        _ = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in socket })
            .transcribe(RecordedAudio(fileURL: path, durationMs: 80))
        Issue.record("Rejected session must not return a result")
    } catch let error as DoubaoTranscriptionFailure { #expect(error.underlyingError as? DoubaoError == .rejected(40_200_011)) }
}

@Test func captureProgressWatchdogWorksWhenAudioClockAndLevelAreFrozen() {
    var health = RecordingInputHealthMonitor()
    health.observe(powerDBFS: -10, elapsedSeconds: 1)
    health.observeCapturedFrames(16000, now: 100)
    health.observe(powerDBFS: -10, elapsedSeconds: 1)
    health.observeCapturedFrames(16000, now: 116)
    #expect(health.interruptionDetected)
}

@Test func noPreviewNetworkLossRetainsItsOriginalClassification() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try doubaoTestWAV().write(to: path)
    let socket = TestDoubaoSocket(); socket.networkFailureDuringAudio = true
    do {
        _ = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in socket })
            .transcribe(RecordedAudio(fileURL: path, durationMs: 80))
        Issue.record("Broken socket must not succeed")
    } catch let failure as DoubaoTranscriptionFailure {
        #expect((failure.underlyingError as? URLError)?.code == .networkConnectionLost)
        #expect(ChatGPTTranscriber.isRetryable(failure.underlyingError!))
        #expect(failure.requestID != nil)
    }
}

@Test func unindexedOfflineFinalCannotDuplicateAnIndexedFinal() throws {
    var transcript = DoubaoTranscript()
    try transcript.consume(doubaoJSON(["results": [["index": 0, "text": "第一段。", "is_interim": false, "is_vad_finished": true]]]))
    #expect(throws: DoubaoError.self) {
        try transcript.consume(doubaoJSON(["results": [["text": "第一段。", "extra": ["nonstream_result": true]]]]))
    }
    #expect(transcript.finalText == "第一段。")
}

@Test func explicitChatGPTStageSelectionReenablesLegacyDisabledFlag() {
    var config = TextPolishConfig()
    config.chatGPTAuthEnabled = false
    #expect(!config.isEnabled)
    config.selectProvider(.chatGPTAuth)
    #expect(config.isEnabled)
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: true)?.id == .chatGPTAuth)
    config.chatGPTAuthEnabled = false
    config.setEnabled(true)
    #expect(TextPolishProviderSelector().selectProvider(config: config, chatGPTAuthAvailable: true)?.id == .chatGPTAuth)
}
