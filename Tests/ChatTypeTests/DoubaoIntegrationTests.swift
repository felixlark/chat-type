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
    try transcript.consume(result(0, "第一段。", true), responseOrdinal: 0)
    try transcript.consume(result(0, "迟到的预览", false), responseOrdinal: 1)
    try transcript.consume(result(1, "第一段。", false), responseOrdinal: 2)
    #expect(!transcript.complete)
    try transcript.consume(result(1, "第一段。", true), responseOrdinal: 3)
    try transcript.consume(result(1, "第一段。", true), responseOrdinal: 4)
    #expect(transcript.finalText == "第一段。第一段。")
    #expect(transcript.complete)
    let audit = transcript.auditSnapshot()
    #expect(audit.responseCount == 5)
    #expect(audit.uniqueSegmentCount == 2)
    #expect(audit.finalSegmentCount == 2)
    #expect(audit.segments.map(\.action) == ["acceptedNew", "ignoredLateInterim", "acceptedNew", "replacedInterim", "replacedFinal"])
    #expect(audit.finalTextLength == "第一段。第一段。".count)
    #expect(audit.finalTextSHA256.count == 64)
    #expect(audit.segments.allSatisfy { $0.textSHA256.count == 64 })
}

@Test func singleFinalSegmentIsAuditedAsCompleteWithoutClaimingAudioCoverage() throws {
    var transcript = DoubaoTranscript()
    try transcript.consume(doubaoJSON(["results": [["index": 7, "text": "只有末句", "is_interim": false, "is_vad_finished": true]]]), responseOrdinal: 0)
    let audit = transcript.auditSnapshot()
    #expect(audit.complete)
    #expect(audit.uniqueSegmentCount == 1)
    #expect(audit.finalSegmentCount == 1)
    #expect(audit.finalTextLength == "只有末句".count)
    #expect(audit.segments[0].key == "index:7")
    #expect(audit.segments[0].action == "acceptedNew")
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
    var discoveryFailure = false
    var partialBeforeDiscovery = false
    var startDelayMs = 0
    private var receiveFailure: (any Error)?
    private var startPayload: Data?
    private let onSend: (@Sendable (String) -> Void)?
    init(onSend: (@Sendable (String) -> Void)? = nil) {
        self.onSend = onSend
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
        if name == "StartSession", case .bytes(let payload) = fields[6] { lock.withLock { startPayload = payload } }
        if name == "StartSession", startDelayMs > 0 {
            try await Task.sleep(for: .milliseconds(startDelayMs))
        }
        try lock.withLock {
            if closed { throw URLError(.cancelled) }
            sent.append(name)
        }
        onSend?(name)
        if name == "StartSession", discoveryFailure {
            if partialBeforeDiscovery {
                enqueue(Self.reply("", result: try doubaoJSON(["results": [["index": 0, "text": "已有部分识别", "is_interim": true, "is_vad_finished": false]]])))
            }
            enqueue(DoubaoProtobuf.text(4, "SessionFailed") + DoubaoProtobuf.varint(5 << 3)
                + DoubaoProtobuf.varint(50_700_000) + DoubaoProtobuf.text(6, "read backend response: rpc error: code = 2 desc = service discovery failure"))
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
    var sessionPayload: Data? { lock.withLock { startPayload } }
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
    #expect(result.metrics.uploadedBytes == 4 * 160) // 4 x 20ms at64kbps, not codec defaults.
    let payload = try #require(socket.sessionPayload)
    let session = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let extra = try #require(session["extra"] as? [String: Any])
    #expect(extra["cell_compress_rate"] as? Int == 4)
    #expect(extra["input_mode"] as? String == "shortcut_single")
    #expect(try Data(contentsOf: path) == doubaoTestWAV())
}

@Test func speechOpusPreservesConstantFidelityAcrossSilenceAndSpeechFrames() throws {
    let encoder = try DoubaoOpusEncoder()
    for frame in 0..<50 {
        var pcm = Data()
        for sample in 0..<320 {
            let value: Int16 = frame % 3 == 0 ? 0 : Int16(sin(Double(frame * 320 + sample) * .pi / 8) * 12000)
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        let original = pcm
        #expect(try encoder.encode(pcm).count == 160)
        #expect(pcm == original)
    }
    #expect(try encoder.encode(Data([0, 0])).count == 160) // partial tail is padded, not dropped.
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

private final class RecoverySocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let sockets: [TestDoubaoSocket]
    private var count = 0
    init(_ sockets: [TestDoubaoSocket]) { self.sockets = sockets }
    func make() -> any DoubaoSocket {
        lock.withLock {
            let i = min(count, sockets.count - 1); count += 1; return sockets[i]
        }
    }
    var created: Int { lock.withLock { count } }
}

@Test func discoveryRecoveryUsesSameAudioAndRetainsBothSessionIDs() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try doubaoTestWAV().write(to: url)
    let first = TestDoubaoSocket(); first.discoveryFailure = true
    let next = TestDoubaoSocket(); let sequence = RecoverySocketSequence([first, next])
    let r = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in sequence.make() })
        .transcribe(RecordedAudio(fileURL: url, durationMs: 80))
    #expect(sequence.created == 2)
    #expect(r.text == "完整识别。")
    #expect(r.metrics.protocolSessions?.map(\.outcome) == ["failed", "success"])
    #expect(r.metrics.protocolSessions?.first?.code == 50_700_000)
    #expect(Set(r.metrics.protocolSessions!.map(\.requestID)).count == 2)
    #expect(first.wasClosed && next.wasClosed)
    #expect(next.methods.filter { $0 == "TaskRequest" }.count == 4)
}

@Test func discoveryBudgetAndManualSingleAttemptRemainBounded() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try doubaoTestWAV().write(to: url)
    for budget in [1, 3] {
        let sockets = (0..<budget).map { _ in let s = TestDoubaoSocket(); s.discoveryFailure = true; return s }
        let sequence = RecoverySocketSequence(sockets)
        do {
            _ = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in sequence.make() }, maximumSessionAttempts: budget)
                .transcribe(RecordedAudio(fileURL: url, durationMs: 80))
            Issue.record("Exhausted discovery must remain failure")
        } catch let failure as DoubaoTranscriptionFailure {
            #expect(failure.underlyingError as? DoubaoError == .serviceDiscoveryFailure)
            #expect(failure.sessions?.count == budget)
            #expect(failure.sessions?.allSatisfy { $0.code == 50_700_000 && $0.outcome == "failed" } == true)
        }
        #expect(sequence.created == budget)
    }
}

@Test func discoveryAfterAnyTextMustNotReconnectAndUnknown507IsNotClassifiedTransient() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try doubaoTestWAV().write(to: url)
    let socket = TestDoubaoSocket(); socket.discoveryFailure = true; socket.partialBeforeDiscovery = true
    let sequence = RecoverySocketSequence([socket])
    do {
        _ = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in sequence.make() })
            .transcribe(RecordedAudio(fileURL: url, durationMs: 80))
        Issue.record("Partial recognition must not be hidden by reconnect")
    } catch let f as DoubaoTranscriptionFailure { #expect(f.partialText == "已有部分识别") }
    #expect(sequence.created == 1)
    let unknown = DoubaoProtobuf.text(4, "SessionFailed") + DoubaoProtobuf.varint(5 << 3)
        + DoubaoProtobuf.varint(50_700_000) + DoubaoProtobuf.text(6, "unrecognized private server message")
    do { _ = try DoubaoReply(unknown); Issue.record("Must reject") }
    catch { #expect(error as? DoubaoError == .rejected(50_700_000)) }
}

@Test func cancellationDuringReconnectPreservesIncrementalFailureAuditAndOriginalAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(directoryURL: directory)
    let url = try store.beginRecording(); try doubaoTestWAV().write(to: url)
    let id = UUID()
    try store.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: url, durationMs: 80,
        asrText: nil, polishText: nil, appName: nil, appBundleIdentifier: nil, outcome: "recording",
        errorMessage: nil, snapshot: TranscriptionConfig(), attemptID: id))
    let first = TestDoubaoSocket(); first.discoveryFailure = true
    let next = TestDoubaoSocket(); next.holdCompletion = true
    let sequence = RecoverySocketSequence([first, next])
    let task = Task {
        try await DoubaoSessionAudit.$observer.withValue({ sessions in
            try store.recordASRSessions(audioURL: url, attemptID: id, sessions: sessions)
        }) {
            try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in sequence.make() })
                .transcribe(RecordedAudio(fileURL: url, durationMs: 80))
        }
    }
    while !next.methods.contains("FinishSession") { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled reconnect cannot succeed") }
    catch { #expect(error is CancellationError) }
    try store.finishRecording(RecordedAudio(fileURL: url, durationMs: 80), outcome: "cancelled")
    let record = try #require(store.loadRecent().first)
    #expect(record.outcome == "cancelled")
    #expect(record.attempts?.last?.outcome == "cancelled")
    #expect(record.attempts?.last?.stages.asrSessions?.map(\.outcome) == ["failed", "cancelled"])
    #expect(record.attempts?.last?.stages.asrSessions?.first?.code == 50_700_000)
    #expect(next.wasClosed)
    #expect(try Data(contentsOf: url) == doubaoTestWAV())
}

@Test func unsafeNegationPunctuationIsProtectedWithoutTreatingExistingBoundariesAsErrors() {
    let original = "原来的登录方式要保留，不要删除历史录音识别和润色都默认使用豆包。"
    #expect(DoubaoPolishSafety.hasDetachedNegatedPredicate(original: original,
        rewritten: "原来的登录方式要保留，不要删除；历史录音识别和润色都默认使用豆包。"))
    #expect(DoubaoPolishSafety.hasDetachedNegatedPredicate(original: original,
        rewritten: "不要删除历史录音，不要删除。历史录音识别和润色都默认使用豆包。"))
    #expect(!DoubaoPolishSafety.hasDetachedNegatedPredicate(original: original,
        rewritten: "保留原来的登录方式，不要删除历史录音。识别和润色都默认使用豆包。"))
    #expect(!DoubaoPolishSafety.hasDetachedNegatedPredicate(original: "不要删除。历史录音要保留。", rewritten: "不要删除；历史录音要保留。"))
    #expect(!DoubaoPolishSafety.hasDetachedNegatedPredicate(original: "请保留历史录音。", rewritten: "请保留。历史录音。"))
}

@Test func protectedOrganizerRetainsUnsafeProviderOutputAndProtectionReason() async throws {
    let original = "不要删除历史录音识别和润色都默认使用豆包。"
    let bad = "不要删除。历史录音识别和润色都默认使用豆包。"
    let organizer = DoubaoTextOrganizer(loader: { request in
        (Data("event:scene.completed\ndata:{\"content\":\"\(bad)\"}\n\nevent:done\ndata:[DONE]\n\n".utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let r = try await organizer.polish(text: original, terminologyEntries: [], hintTerms: [])
    #expect(r.text == original)
    #expect(!r.applied)
    #expect(r.providerText == bad)
    #expect(r.protectionReason != nil)
}

@Test(.timeLimit(.minutes(1))) func liveDiscoveryRecoveryKeepsRecordingAndResetsSessionState() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try doubaoTestWAV().write(to: url)
    let state = DoubaoLiveState()
    let bad = TestDoubaoSocket(); bad.discoveryFailure = true
    let (events, progress) = AsyncStream<Bool>.makeStream()
    let next = TestDoubaoSocket(onSend: { if $0 == "TaskRequest" { progress.yield(true) } })
    let sequence = RecoverySocketSequence([bad, next])
    let task = Task {
        defer { progress.yield(false); progress.finish() }
        return try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in sequence.make() })
            .run(url: url, durationMs: 0, live: state)
    }
    defer { task.cancel(); progress.finish() }
    // Observe the required protocol transition directly. A busy shared CI runner
    // can delay scheduling past the old two-second polling deadline; the test
    // watchdog still detects a sender that never wakes.
    var iterator = events.makeAsyncIterator()
    let resumedSending = await iterator.next()
    try #require(resumedSending == true, "Receiver failure must wake a sender waiting for audio")
    await state.finish(RecordedAudio(fileURL: url, durationMs: 80))
    let r = try await task.value
    #expect(r.text == "完整识别。")
    #expect(r.metrics.audioDurationMs == 80)
    #expect(r.metrics.protocolSessions?.map(\.outcome) == ["failed", "success"])
    #expect(sequence.created == 2)
}

private struct SafetyTestASR: Transcriber {
    let text: String
    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, metrics: .init(provider: .doubaoIME, audioDurationMs: 100,
            audioBytes: 0, authMs: 0, transcribeMs: 1, promptIncluded: false))
    }
}

@Test func pipelineAndHistoryExposeAcceptedOriginalWhileRetainingRawUnsafePolish() async throws {
    let original = "不要删除历史录音识别和润色都默认使用豆包。"
    let bad = "不要删除。历史录音识别和润色都默认使用豆包。"
    let organizer = DoubaoTextOrganizer(loader: { request in
        (Data("event:scene.completed\ndata:{\"content\":\"\(bad)\"}\n\nevent:done\ndata:[DONE]\n\n".utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    let r = try await DictationPipeline(transcriber: SafetyTestASR(text: original), normalizer: TerminologyNormalizer(),
        importedEntries: [], hintTerms: [], textPolisher: organizer).prepare(audio: RecordedAudio(fileURL: url, durationMs: 100))
    #expect(r.finalText == original)
    #expect(r.stages?.polishOutput == bad)
    #expect(r.stages?.polishProtectionReason != nil)
    let config = TranscriptionConfig()
    let record = RecoveryRecord(id: UUID(), timestamp: Date(), audioFileName: "test.wav", audioDurationMs: 100,
        asrText: original, polishText: bad, appName: nil, appBundleIdentifier: nil, outcome: "copied", errorMessage: nil,
        snapshot: config, attempts: [.init(id: UUID(), startedAt: Date(), snapshot: config, stages: r.stages!, outcome: "copied")])
    let preview = try #require(RecoveryHistoryPreview.recentItems(from: [record], kind: .polish, limit: 1).first)
    #expect(preview.copyText == original)
    #expect(preview.text.hasPrefix("已保留原文"))
    #expect(preview.errorMessage != nil)
    #expect(try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record)) == record)
}

@Test func capturedBacklogDrainsAfterSlowHandshakeWithoutASecondMediaClock() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try doubaoTestWAV(samples: 128_000).write(to: url)
    let socket = TestDoubaoSocket(); socket.startDelayMs = 150
    let state = DoubaoLiveState()
    await state.finish(RecordedAudio(fileURL: url, durationMs: 8_000))
    let began = ContinuousClock().now
    let result = try await DoubaoTranscriber(keyProvider: { "test-only" }, socketFactory: { _ in socket })
        .run(url: url, durationMs: 0, live: state)
    // Eight seconds of available audio separates the old media-clock delay
    // from cloud CI scheduling noise. This is a regression bound, not an SLO.
    #expect(began.duration(to: .now) < .seconds(4))
    #expect(socket.methods.filter { $0 == "TaskRequest" }.count == 400)
    #expect(result.text == "完整识别。")
    #expect(result.metrics.liveFinishToLastSendMs != nil)
    #expect(result.metrics.sessionFinishWaitMs != nil)
}
