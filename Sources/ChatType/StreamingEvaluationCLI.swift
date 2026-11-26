import CryptoKit
import Foundation

/// Explicit acceptance entry: production transcription pipeline with paced live
/// input or a completed-file replay. It never uses HID, the microphone, GUI or
/// changes settings.
enum StreamingEvaluationCLI {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [DoubaoSessionAttempt] = []
        private var diagnostics: [DoubaoSessionDiagnostic] = []
        private var asrReady: UInt64?
        func receive(_ value: [DoubaoSessionAttempt]) { lock.withLock { sessions = value } }
        func receive(_ value: DoubaoSessionDiagnostic) { lock.withLock { diagnostics.append(value) } }
        func stage(_ value: DictationStageAudit) {
            if value.asrText != nil { lock.withLock { if asrReady == nil { asrReady = ProcessingTiming.now() } } }
        }
        func snapshot() -> ([DoubaoSessionAttempt], [DoubaoSessionDiagnostic], UInt64?) {
            lock.withLock { (sessions, diagnostics, asrReady) }
        }
    }

    enum EvaluationError: Error { case invalidArguments, unsupportedRoute, outputExists, emptyAudio }

    @MainActor static func run(arguments: [String]) async throws {
        var options: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            guard ["--audio", "--output", "--config-snapshot", "--mode"].contains(arguments[i]),
                  i + 1 < arguments.count, options[arguments[i]] == nil else { throw EvaluationError.invalidArguments }
            options[arguments[i]] = arguments[i + 1]; i += 2
        }
        let mode = options["--mode"] ?? "paced-live"
        guard mode == "paced-live" || mode == "file-replay" else { throw EvaluationError.invalidArguments }
        guard let source = options["--audio"], let destination = options["--output"],
              let snapshot = options["--config-snapshot"] else { throw EvaluationError.invalidArguments }
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: snapshot)))
        let t = config.transcription
        guard (t.provider == .doubaoIME && t.textPolish.provider == .doubaoIME)
            || (t.provider == .chatGPTManagedAuth && t.textPolish.provider == .chatGPTAuth) else {
            throw EvaluationError.unsupportedRoute
        }
        let output = URL(fileURLWithPath: destination)
        let archive = output.deletingPathExtension().appendingPathExtension("recovery")
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: archive.path) else { throw EvaluationError.outputExists }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let sourceURL = URL(fileURLWithPath: source)
        let reader = try DoubaoFilePCM(url: sourceURL)
        var pcm = Data()
        while let frame = try reader.next() { pcm.append(frame) }
        guard !pcm.isEmpty else { throw EvaluationError.emptyAudio }
        let recovery = RecoveryStore(directoryURL: archive)
        let growing = try recovery.beginRecording()
        let attemptID = UUID()
        try header(pcmBytes: 0).write(to: growing)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: growing.path)
        let auth = ChatGPTAuthManager()
        if t.needsChatGPT { await auth.prewarmSession() }
        let observations = Observations()
        // A detached producer keeps the actual capture clock running even while
        // the main actor persists a large first snapshot or opens the socket.
        let captureTick = ProcessingTiming.now()
        let began = ContinuousClock().now
        let capturePCM = pcm
        let capture = Task.detached {
            let handle = try FileHandle(forWritingTo: growing)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let clock = ContinuousClock()
            var offset = 0
            while mode == "paced-live" && offset < capturePCM.count {
                let end = min(offset + 640, capturePCM.count)
                try await clock.sleep(until: began.advanced(by: .nanoseconds(Int64(end) * 1_000_000_000 / 32_000)))
                try handle.write(contentsOf: capturePCM[offset..<end]); offset = end
            }
            if mode == "file-replay" {
                try handle.write(contentsOf: capturePCM)
                offset = capturePCM.count
            }
            let stop = ProcessingTiming.now()
            try handle.seek(toOffset: 0); try handle.write(contentsOf: header(pcmBytes: capturePCM.count))
            try handle.synchronize()
            return (stop, ProcessingTiming.milliseconds(since: stop))
        }
        defer { capture.cancel() }
        try recovery.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: growing,
            durationMs: 0, asrText: nil, polishText: nil, appName: nil, appBundleIdentifier: nil,
            outcome: "recording", errorMessage: nil, snapshot: t, attemptID: attemptID,
            injectionSnapshot: config.injection))
        let sessionAudit: @Sendable ([DoubaoSessionAttempt]) throws -> Void = { sessions in
            observations.receive(sessions)
            try recovery.recordASRSessions(audioURL: growing, attemptID: attemptID, sessions: sessions)
        }
        let diagnosticAudit: @Sendable (DoubaoSessionDiagnostic) throws -> Void = { diagnostic in
            observations.receive(diagnostic)
        }
        let live = t.provider == .doubaoIME && mode == "paced-live"
            ? DoubaoLiveRecognition(url: growing, sessionAudit: sessionAudit, diagnosticAudit: diagnosticAudit)
            : nil
        defer { live?.cancel() }
        let (stopTick, sealMs) = try await capture.value
        var audio = RecordedAudio(fileURL: growing, durationMs: pcm.count * 1000 / 32_000)
        try recovery.finishRecording(audio, outcome: "recorded")
        if let live { audio.cloudTranscript = live.finish(audio) }
        let durationMs = audio.durationMs
        let audit: @Sendable (DictationStageAudit) throws -> Void = { stages in
            observations.stage(stages)
            let started = ProcessingTiming.now()
            defer { ProcessingTrace.current?.recordStage("recoveryAudit", since: started) }
            try recovery.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: growing,
                durationMs: durationMs, asrText: stages.asrText, polishText: stages.polishOutput,
                appName: nil, appBundleIdentifier: nil, outcome: "processing", errorMessage: stages.error,
                snapshot: t, attemptID: attemptID, stages: stages, injectionSnapshot: config.injection))
        }
        let pipeline = DictationPipeline(transcriber: ChatGPTTranscriber(authManager: auth, config: t,
            usesLocalSpeechForFiles: false).selectedRoute, normalizer: TerminologyNormalizer(),
            importedEntries: t.activeDictionaryEntries, hintTerms: t.prioritizedHintTerms,
            textPolisher: t.textPolish.isEnabled ? OpenAICompatibleTextPolisher(config: t.textPolish,
                chatGPTAuthProvider: auth, chatGPTAuthAvailable: t.needsChatGPT && auth.authSnapshot().state == .ready) : nil,
            alignmentEnabled: t.terminologyAlignmentEnabled, correctionsEnabled: t.correctionRulesEnabled,
            audit: audit)
        var row: [String: Any] = ["mode": mode == "paced-live" ? "paced-growing-WAV-production-live-worker" : "completed-WAV-file-replay",
            "boundary": "stop/seal entry to prepared final; excludes HID, microphone and GUI insertion",
            "provider": t.provider.rawValue, "polishProvider": t.textPolish.provider.rawValue,
            "audioDurationMs": audio.durationMs, "captureWallMs": Double(stopTick - captureTick) / 1_000_000,
            "sourceSHA256": hash(try Data(contentsOf: sourceURL)), "replayedPCMSHA256": hash(pcm),
            "sealMs": sealMs, "stopTickNs": stopTick]
        do {
            try audit(.init())
            let result = try await DoubaoSessionAudit.$observer.withValue(sessionAudit) {
                try await DoubaoSessionAudit.$diagnosticsObserver.withValue({ diagnostic in
                    observations.receive(diagnostic)
                }) {
                    try await pipeline.prepare(audio: audio)
                }
            }
            try recovery.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: growing,
                durationMs: durationMs, asrText: result.rawText, polishText: result.stages?.polishOutput,
                appName: nil, appBundleIdentifier: nil, outcome: "readyToInject", errorMessage: nil,
                snapshot: t, attemptID: attemptID, stages: result.stages, injectionSnapshot: config.injection))
            let readyTick = ProcessingTiming.now()
            row["readyTickNs"] = readyTick
            row["stopToFinalMs"] = Double(readyTick - stopTick) / 1_000_000
            row["status"] = "success"; row["rawText"] = result.rawText; row["finalText"] = result.finalText
            row["asrTotalMs"] = result.metrics.transcription.transcribeMs
            row["liveFinishToLastSendMs"] = result.metrics.transcription.liveFinishToLastSendMs
            row["sessionFinishWaitMs"] = result.metrics.transcription.sessionFinishWaitMs
            row["processingTiming"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.metrics.timing))
            try recovery.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: growing,
                durationMs: durationMs, asrText: result.rawText, polishText: result.stages?.polishOutput,
                appName: nil, appBundleIdentifier: nil, outcome: "prepared", errorMessage: nil,
                snapshot: t, attemptID: attemptID, stages: result.stages, injectionSnapshot: config.injection))
            row["polishMs"] = result.metrics.polishMs
            row["polishInput"] = result.stages?.polishInput
            row["polishProviderOutput"] = result.stages?.polishOutput
            row["polishProtectionReason"] = result.stages?.polishProtectionReason
        } catch {
            row["status"] = "failed"; row["error"] = error.localizedDescription
            row["stopToFailureMs"] = ProcessingTiming.milliseconds(since: stopTick)
            var stages = (error as? DictationPipelineFailure)?.stages ?? .init()
            if let failure = error as? DoubaoTranscriptionFailure {
                observations.receive(failure.sessions ?? [])
                stages.asrSessions = failure.sessions; stages.asrPartialText = failure.partialText
            }
            stages.error = error.localizedDescription
            try recovery.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: growing,
                durationMs: durationMs, asrText: stages.asrText, polishText: stages.polishOutput,
                appName: nil, appBundleIdentifier: nil, outcome: "error", errorMessage: stages.error,
                snapshot: t, attemptID: attemptID, stages: stages, injectionSnapshot: config.injection))
        }
        if let live, let tick = await live.state.firstTextAtNs {
            row["firstPreviewMs"] = Double(tick - captureTick) / 1_000_000
            row["previewDuringCapture"] = tick < stopTick
        }
        row["auditWriteStats"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recovery.persistenceStats()))
        row["archive"] = archive.path
        let observed = observations.snapshot()
        if let asrReady = observed.2 { row["stopToASRMs"] = Double(asrReady - stopTick) / 1_000_000 }
        row["sessions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed.0))
        row["doubaoDiagnostics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed.1))
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .prettyPrinted]).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Streaming evaluation \(row["status"] ?? "unknown"); evidence retained.")
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func header(pcmBytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcmBytes)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(pcmBytes))
        return data
    }
}
