import CryptoKit
import Foundation

/// Explicit acceptance entry: actual live worker and pipeline, paced PCM input.
/// It does not simulate HID, use the microphone, inject text, or change settings.
enum StreamingEvaluationCLI {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [DoubaoSessionAttempt] = []
        private var asrReady: UInt64?
        func receive(_ value: [DoubaoSessionAttempt]) { lock.withLock { sessions = value } }
        func stage(_ value: DictationStageAudit) {
            if value.asrText != nil { lock.withLock { if asrReady == nil { asrReady = ProcessingTiming.now() } } }
        }
        func snapshot() -> ([DoubaoSessionAttempt], UInt64?) { lock.withLock { (sessions, asrReady) } }
    }

    enum EvaluationError: Error { case invalidArguments, unsupportedRoute, outputExists, emptyAudio }

    @MainActor static func run(arguments: [String]) async throws {
        var options: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            guard ["--audio", "--output", "--config-snapshot"].contains(arguments[i]),
                  i + 1 < arguments.count, options[arguments[i]] == nil else { throw EvaluationError.invalidArguments }
            options[arguments[i]] = arguments[i + 1]; i += 2
        }
        guard let source = options["--audio"], let destination = options["--output"],
              let snapshot = options["--config-snapshot"] else { throw EvaluationError.invalidArguments }
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: snapshot)))
        let t = config.transcription
        guard (t.provider == .doubaoIME && t.textPolish.provider == .doubaoIME)
            || (t.provider == .chatGPTManagedAuth && t.textPolish.provider == .chatGPTAuth) else {
            throw EvaluationError.unsupportedRoute
        }
        let output = URL(fileURLWithPath: destination)
        let growing = output.deletingPathExtension().appendingPathExtension("wav")
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: growing.path) else { throw EvaluationError.outputExists }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let sourceURL = URL(fileURLWithPath: source)
        let reader = try DoubaoFilePCM(url: sourceURL)
        var pcm = Data()
        while let frame = try reader.next() { pcm.append(frame) }
        guard !pcm.isEmpty else { throw EvaluationError.emptyAudio }
        try header(pcmBytes: 0).write(to: growing)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: growing.path)
        let auth = ChatGPTAuthManager()
        if t.needsChatGPT { await auth.prewarmSession() }
        let observations = Observations()
        let live = t.provider == .doubaoIME ? DoubaoLiveRecognition(url: growing, sessionAudit: { observations.receive($0) }) : nil
        defer { live?.cancel() }
        let handle = try FileHandle(forWritingTo: growing)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let clock = ContinuousClock()
        let began = clock.now
        let captureTick = ProcessingTiming.now()
        var offset = 0
        var firstPreviewMs: Double?
        while offset < pcm.count {
            let end = min(offset + 640, pcm.count)
            let frameEndNs = Int64(end) * 1_000_000_000 / 32_000
            try await clock.sleep(until: began.advanced(by: .nanoseconds(frameEndNs)))
            try handle.write(contentsOf: pcm[offset..<end]); offset = end
            if firstPreviewMs == nil, let live, !(await live.state.preview).isEmpty {
                firstPreviewMs = ProcessingTiming.milliseconds(since: captureTick)
            }
        }
        // This boundary corresponds to entering stopRecording(), before sealing.
        let stopTick = ProcessingTiming.now()
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header(pcmBytes: pcm.count))
        try handle.synchronize(); try handle.close()
        let sealMs = ProcessingTiming.milliseconds(since: stopTick)
        var audio = RecordedAudio(fileURL: growing, durationMs: pcm.count * 1000 / 32_000)
        if let live { audio.cloudTranscript = live.finish(audio) }
        let pipeline = DictationPipeline(transcriber: ChatGPTTranscriber(authManager: auth, config: t,
            usesLocalSpeechForFiles: false).selectedRoute, normalizer: TerminologyNormalizer(),
            importedEntries: t.activeDictionaryEntries, hintTerms: t.prioritizedHintTerms,
            textPolisher: t.textPolish.isEnabled ? OpenAICompatibleTextPolisher(config: t.textPolish,
                chatGPTAuthProvider: auth, chatGPTAuthAvailable: t.needsChatGPT && auth.authSnapshot().state == .ready) : nil,
            alignmentEnabled: t.terminologyAlignmentEnabled, correctionsEnabled: t.correctionRulesEnabled,
            audit: { observations.stage($0) })
        var row: [String: Any] = ["mode": "paced-growing-WAV-production-live-worker",
            "boundary": "stop/seal entry to prepared final; excludes HID, microphone and GUI insertion",
            "provider": t.provider.rawValue, "polishProvider": t.textPolish.provider.rawValue,
            "audioDurationMs": audio.durationMs, "captureWallMs": Double(stopTick - captureTick) / 1_000_000,
            "sourceSHA256": hash(try Data(contentsOf: sourceURL)), "replayedPCMSHA256": hash(pcm),
            "sealMs": sealMs, "stopTickNs": stopTick]
        row["firstPreviewMs"] = firstPreviewMs
        do {
            let result = try await pipeline.prepare(audio: audio)
            let readyTick = ProcessingTiming.now()
            row["readyTickNs"] = readyTick
            row["stopToFinalMs"] = Double(readyTick - stopTick) / 1_000_000
            row["status"] = "success"; row["rawText"] = result.rawText; row["finalText"] = result.finalText
            row["asrTotalMs"] = result.metrics.transcription.transcribeMs
            row["polishMs"] = result.metrics.polishMs
            row["polishInput"] = result.stages?.polishInput
            row["polishProviderOutput"] = result.stages?.polishOutput
            row["polishProtectionReason"] = result.stages?.polishProtectionReason
        } catch {
            row["status"] = "failed"; row["error"] = error.localizedDescription
            row["stopToFailureMs"] = ProcessingTiming.milliseconds(since: stopTick)
            if let failure = error as? DoubaoTranscriptionFailure { observations.receive(failure.sessions ?? []) }
        }
        let observed = observations.snapshot()
        if let asrReady = observed.1 { row["stopToASRMs"] = Double(asrReady - stopTick) / 1_000_000 }
        row["sessions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed.0))
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
