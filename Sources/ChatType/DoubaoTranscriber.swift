import Foundation

struct DoubaoTranscriptionFailure: LocalizedError, Sendable {
    let partialText: String
    let detail: String
    var requestID: String? = nil
    var underlyingError: (any Error)? = nil
    var sessions: [DoubaoSessionAttempt]? = nil
    var errorDescription: String? {
        (partialText.isEmpty ? "豆包识别未完成，原声保留。" : "豆包识别未完成，已取得的部分文字保留。") + detail
    }
}

protocol DoubaoSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

final class DoubaoURLSocket: DoubaoSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(deviceID: String) {
        var request = URLRequest(url: URL(string: "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=685343&device_id=\(deviceID)")!)
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")
        request.setValue("ChatType/macOS", forHTTPHeaderField: "User-Agent")
        task = DoubaoHTTP.session.webSocketTask(with: request)
        task.resume()
    }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            switch try await task.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw DoubaoError.malformedMessage
            }
        } onCancel: { self.close() }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

actor DoubaoLiveState {
    private(set) var finished: RecordedAudio?
    private(set) var finishedAtNs: UInt64?
    private(set) var preview = ""
    private(set) var firstTextAtNs: UInt64?
    private(set) var finishRequested = false
    private var receiverFailure: (any Error)?
    func finish(_ audio: RecordedAudio) {
        finishedAtNs = DispatchTime.now().uptimeNanoseconds
        finished = audio
    }
    func update(_ text: String) {
        if firstTextAtNs == nil, !text.isEmpty { firstTextAtNs = DispatchTime.now().uptimeNanoseconds }
        preview = text
    }
    func failed() { preview += "\n豆包连接中断；原声继续保存，停录后可重试。" }
    func requestFinish() { finishRequested = true }
    func receiverFailed(_ error: any Error) { receiverFailure = error }
    func checkReceiver() throws { if let receiverFailure { throw receiverFailure } }
}

@MainActor
final class DoubaoLiveRecognition {
    let state: DoubaoLiveState
    private let task: Task<TranscriptionResult, Error>
    init(url: URL, sessionAudit: (@Sendable ([DoubaoSessionAttempt]) throws -> Void)? = nil) {
        let state = DoubaoLiveState()
        self.state = state
        task = Task.detached {
            do {
                return try await DoubaoSessionAudit.$observer.withValue(sessionAudit) {
                    try await DoubaoTranscriber().run(url: url, durationMs: 0, live: state)
                }
            }
            catch { await state.failed(); throw error }
        }
    }
    func finish(_ audio: RecordedAudio) -> Task<TranscriptionResult, Error> {
        let state = state; let task = task
        return Task {
            await state.finish(audio)
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }
    func cancel() { task.cancel() }
}

struct DoubaoTranscriber: Transcriber {
    typealias KeyProvider = @Sendable () async throws -> String
    typealias SocketFactory = @Sendable (String) -> any DoubaoSocket
    var keyProvider: KeyProvider = { try await DoubaoCredentials.shared.key() }
    var socketFactory: SocketFactory = { DoubaoURLSocket(deviceID: $0) }
    // Existing product budget: initial automatic work has three attempts;
    // explicit manual Retry passes one through SelectedRouteTranscriber.
    var maximumSessionAttempts = 3

    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        if let live = audio.cloudTranscript {
            return try await withTaskCancellationHandler { try await live.value } onCancel: { live.cancel() }
        }
        let data = try Data(contentsOf: audio.fileURL)
        switch PCMRecordingIntegrityAnalyzer().analyze(wavData: data) {
        case .noUsableSignal: throw TranscriptionError.noUsableAudioSignal
        case .interruptedInput(let captured, let tail):
            if !audio.isPartialReplay {
                throw TranscriptionError.interruptedAudioInput(capturedSignalSeconds: captured, silentTailSeconds: tail)
            }
        case nil: break
        }
        return try await run(url: audio.fileURL, durationMs: audio.durationMs)
    }

    func run(url: URL, durationMs: Int, live: DoubaoLiveState? = nil) async throws -> TranscriptionResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var sessions: [DoubaoSessionAttempt] = []
        for ordinal in 0..<max(1, maximumSessionAttempts) {
            try Task.checkCancellation()
            let id = UUID().uuidString.lowercased()
            sessions.append(.init(requestID: id, outcome: "started"))
            try DoubaoSessionAudit.observer?(sessions)
            do {
                let result = try await runSession(url: url, durationMs: durationMs, live: live, requestID: id)
                sessions[ordinal].outcome = "success"
                try DoubaoSessionAudit.observer?(sessions)
                let m = result.metrics
                return TranscriptionResult(text: result.text, metrics: TranscriptionMetrics(provider: m.provider,
                    audioDurationMs: m.audioDurationMs, audioBytes: m.audioBytes, authMs: m.authMs,
                    transcribeMs: elapsed(started) - m.authMs, promptIncluded: m.promptIncluded,
                    uploadedBytes: m.uploadedBytes, uploadFormat: m.uploadFormat,
                    protocolRequestID: id, protocolSessions: sessions,
                    liveFinishToLastSendMs: m.liveFinishToLastSendMs, sessionFinishWaitMs: m.sessionFinishWaitMs))
            } catch {
                let failure = error as? DoubaoTranscriptionFailure
                let underlying = failure?.underlyingError ?? error
                sessions[ordinal].outcome = Task.isCancelled ? "cancelled" : "failed"
                if let e = underlying as? DoubaoError {
                    switch e {
                    case .serviceDiscoveryFailure:
                        sessions[ordinal].code = 50_700_000
                        sessions[ordinal].reason = "service discovery failure"
                    case .rejected(let code): sessions[ordinal].code = code
                    default: break
                    }
                }
                try DoubaoSessionAudit.observer?(sessions)
                try Task.checkCancellation()
                // Never reconnect after any recognition text. Each new session
                // reopens the same durable WAV at zero, with fresh receive state.
                if underlying as? DoubaoError == .serviceDiscoveryFailure,
                   failure?.partialText.isEmpty == true, ordinal + 1 < maximumSessionAttempts { continue }
                throw DoubaoTranscriptionFailure(partialText: failure?.partialText ?? "",
                    detail: underlying.localizedDescription, requestID: id, underlyingError: underlying, sessions: sessions)
            }
        }
        throw DoubaoError.incomplete("识别")
    }

    private func runSession(url: URL, durationMs: Int, live: DoubaoLiveState?, requestID: String) async throws -> TranscriptionResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let token = try await keyProvider()
        let authMs = elapsed(start)
        try Task.checkCancellation()
        let did = String(UInt64.random(in: 10_000_000_000_000_000..<99_999_999_999_999_999))
        let socket = socketFactory(did)
        defer { socket.close() }
        let progress = DoubaoLiveState()
        do { return try await withTaskCancellationHandler {
            let id = requestID
            func send(_ method: String, payload: Data? = nil, audio: Data? = nil, frame: UInt64? = nil) async throws {
                try Task.checkCancellation()
                try await socket.send(DoubaoProtobuf.request(token: token, method: method, id: id,
                    payload: payload, audio: audio, frame: frame))
            }
            func awaitReply(_ expected: String) async throws {
                while true {
                    try Task.checkCancellation()
                    let reply = try DoubaoReply(await socket.receive())
                    if reply.kind == expected { return }
                    if reply.kind == "SessionFinished" { throw DoubaoError.incomplete("识别初始化") }
                }
            }
            try await send("StartTask")
            try await awaitReply("TaskStarted")
            let payload: [String: Any] = [
                "audio_info": ["channel": 1, "format": "speech_opus", "sample_rate": 16000],
                "enable_punctuation": true, "enable_speech_rejection": false,
                "extra": ["app_name": "ChatType", "did": did, "cell_compress_rate": 8,
                    "enable_asr_threepass": true, "enable_asr_twopass": true, "input_mode": "tool"]
            ]
            try await send("StartSession", payload: JSONSerialization.data(withJSONObject: payload))
            try await awaitReply("SessionStarted")
            let receiveTask = Task {
                var transcript = DoubaoTranscript()
                do {
                    while true {
                        try Task.checkCancellation()
                        let reply = try DoubaoReply(await socket.receive())
                        if let result = reply.result {
                            try transcript.consume(result)
                            await progress.update(transcript.text)
                            if let live { await live.update(transcript.text) }
                        }
                        if reply.kind == "SessionFinished" {
                            guard await progress.finishRequested else { throw DoubaoError.incomplete("识别（服务提前结束）") }
                            guard transcript.complete else { throw DoubaoError.incomplete("识别") }
                            return transcript.finalText
                        }
                    }
                } catch {
                    await progress.receiverFailed(error)
                    socket.close(); throw error
                }
            }
            defer { receiveTask.cancel() }
            do {
            let encoder = try DoubaoOpusEncoder()
            let fileReader = live == nil ? try DoubaoFilePCM(url: url) : nil
            var growingReader: DoubaoGrowingPCM?
            var sentFrames = 0
            var uploaded = 0
            var pending: Data?
            while true {
                try Task.checkCancellation()
                try await progress.checkReceiver()
                let final = live == nil ? true : await live?.finished != nil
                if live != nil, growingReader == nil {
                    do { growingReader = try DoubaoGrowingPCM(url: url) }
                    catch DoubaoError.audioNotReady where !final {
                        try await Task.sleep(for: .milliseconds(50)); continue
                    }
                }
                let next = try fileReader?.next() ?? growingReader?.next(final: final)
                if let next {
                    if let pending {
                        let opus = try encoder.encode(pending)
                        let metadata = try JSONSerialization.data(withJSONObject: ["extra": [:], "timestamp_ms": sentFrames * 20] as [String: Any])
                        // Capture already supplies the media clock. Await the
                        // socket's backpressure, but drain available frames so
                        // handshake/recording-journal latency can be caught up.
                        try await send("TaskRequest", payload: metadata, audio: opus, frame: sentFrames == 0 ? 1 : 3)
                        uploaded += opus.count; sentFrames += 1
                    }
                    pending = next
                } else if final { break }
                else { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard let pending else { throw TranscriptionError.invalidAudio }
            let opus = try encoder.encode(pending)
            let metadata = try JSONSerialization.data(withJSONObject: ["extra": [:], "timestamp_ms": sentFrames * 20] as [String: Any])
            try await send("TaskRequest", payload: metadata, audio: opus, frame: sentFrames == 0 ? 1 : 9)
            let lastSendCompleted = DispatchTime.now().uptimeNanoseconds
            let liveFinished = await live?.finishedAtNs
            uploaded += opus.count
            if live != nil {
                switch PCMRecordingIntegrityAnalyzer().analyze(wavData: try Data(contentsOf: url)) {
                case .noUsableSignal: throw TranscriptionError.noUsableAudioSignal
                case .interruptedInput(let captured, let tail):
                    throw TranscriptionError.interruptedAudioInput(capturedSignalSeconds: captured, silentTailSeconds: tail)
                case nil: break
                }
            }
            await progress.requestFinish()
            let finishStarted = DispatchTime.now().uptimeNanoseconds
            try await send("FinishSession")
            let text = try await receiveTask.value
            let finishWaitMs = elapsed(finishStarted)
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.invalidResponse }
            let duration = await live?.finished?.durationMs ?? durationMs
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return TranscriptionResult(text: text, metrics: TranscriptionMetrics(provider: .doubaoIME,
                audioDurationMs: duration, audioBytes: size, authMs: authMs, transcribeMs: elapsed(start) - authMs,
                promptIncluded: false, uploadedBytes: uploaded, uploadFormat: "opus/16000/mono", protocolRequestID: id,
                liveFinishToLastSendMs: liveFinished.map { Int(max(0, Double(lastSendCompleted) - Double($0)) / 1_000_000) },
                sessionFinishWaitMs: finishWaitMs))
            } catch {
                let sendingError = error
                socket.close()
                receiveTask.cancel()
                // A receiver-side protocol rejection closes the transport and
                // wakes send() with URLError.cancelled. Preserve the actual
                // rejection instead of misclassifying it as user cancellation.
                do { _ = try await receiveTask.value }
                catch {
                    if let url = error as? URLError, url.code == .cancelled { }
                    else if error is CancellationError { }
                    else { throw error }
                }
                throw sendingError
            }
        } onCancel: { socket.close() }
        } catch {
            try Task.checkCancellation()
            let partial = await progress.preview
            throw DoubaoTranscriptionFailure(partialText: partial, detail: error.localizedDescription,
                requestID: requestID, underlyingError: error)
        }
    }

    private func elapsed(_ start: UInt64) -> Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}
