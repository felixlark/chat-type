import Foundation
import CryptoKit
@preconcurrency import AVFoundation
import Speech
import CoreGraphics
import OSLog

struct LocalTranscriptionFailure: LocalizedError {
    let partialText: String
    let detail: String
    var errorDescription: String? { "本地转写未完成，录音和已定稿文字已保留。\(detail)" }
}

/// Speech results replace overlapping provisional ranges; finalized ranges remain stable.
struct StreamingTranscript: Sendable {
    struct Segment: Sendable {
        let start: Double
        let end: Double
        let text: String
        let final: Bool
    }
    private(set) var segments: [Segment] = []
    mutating func apply(start: Double, end: Double, text: String, final: Bool) {
        guard !text.isEmpty, end >= start else { return }
        guard !segments.contains(where: { $0.final && $0.start < end && start < $0.end }) else { return }
        segments.removeAll { !$0.final && ($0.start == start || ($0.start < end && start < $0.end)) }
        segments.append(Segment(start: start, end: end, text: text, final: final))
        segments.sort { $0.start < $1.start }
    }
    var text: String { segments.map(\.text).joined() }
    var finalText: String { segments.filter(\.final).map(\.text).joined() }
}

/// A single microphone tap writes recovery PCM and feeds Apple's on-device analyzer.
@available(macOS 26.0, *)
@MainActor
final class LocalSpeechRecorder: RecordingControlling {
    private let sampleRateHz: Int
    private let store: RecoveryStore
    private let hintTerms: [String]
    private let finalizationTimeoutSeconds: Double
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var sink: LocalAudioSink?
    private var fileURL: URL?
    private var results: Task<String, Error>?
    private var previewTask: Task<Void, Never>?
    private var previewUnavailable = false
    private var transcript = StreamingTranscript()
    private var persistenceTimer: Timer?
    private var failure: String?
    private var generation = UUID()
    private var firstPreviewReported = false
    private var recordingStarted = Date()
    private let logger = Logger(subsystem: "me.longbiaochen.chattype", category: "LocalSpeech")
    private var health = RecordingInputHealthMonitor()
    var liveTranscript: String {
        if previewUnavailable || sink?.previewUnavailable == true {
            let status = "实时预览暂不可用；录音继续，停录后完成识别。"
            return transcript.text.isEmpty ? status : transcript.text + "\n" + status
        }
        return transcript.text
    }

    init(sampleRateHz: Int, store: RecoveryStore, finalizationTimeoutSeconds: Double = 10, hintTerms: [String] = []) {
        self.hintTerms = hintTerms
        self.sampleRateHz = sampleRateHz
        self.store = store
        self.finalizationTimeoutSeconds = finalizationTimeoutSeconds
    }

    static func transcribeFile(_ url: URL, hintTerms: [String] = []) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else {
            throw LocalTranscriptionFailure(partialText: "", detail: "当前设备不支持中文设备端转写。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = hintTerms
        try await analyzer.setContext(context)
        let collect = Task { () throws -> String in
            var text = ""
            for try await result in module.results { text += String(result.text.characters) }
            return text
        }
        do {
            let file = try AVAudioFile(forReading: url)
            return try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                return try await collect.value
            } onCancel: {
                collect.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func startRecording() async throws {
        generation = UUID()
        let session = generation
        previewTask?.cancel()
        results?.cancel()
        let previousAnalyzer = analyzer
        Task { await previousAnalyzer?.cancelAndFinishNow() }
        analyzer = nil
        try await AudioRecorder.ensureMicrophoneAccess()
        try Task.checkCancellation()
        let audioURL = try store.beginRecording()
        fileURL = audioURL
        transcript = StreamingTranscript()
        firstPreviewReported = false
        previewUnavailable = false
        health = RecordingInputHealthMonitor()
        failure = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        let sink = try LocalAudioSink(url: audioURL, sourceFormat: sourceFormat,
            analysisFormat: nil, sampleRate: sampleRateHz, continuation: stream.continuation)
        self.sink = sink
        self.engine = engine
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, _ in sink.accept(buffer) }
        do {
            engine.prepare()
            recordingStarted = Date()
            try engine.start()
        } catch {
            engine.stop()
            input.removeTap(onBus: 0)
            sink.finish()
            self.engine = nil
            throw error
        }
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let url = self.fileURL else { return }
                do { try RecoveryStore.synchronize(url) }
                catch { self.failure = error.localizedDescription }
            }
        }
        // Capture is already running. Preview setup and results never gate the WAV.
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else {
                    throw RecorderError.recorderInitFailed
                }
                try Task.checkCancellation()
                guard self.generation == session else { return }
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
                let analyzer = SpeechAnalyzer(modules: [module])
                self.analyzer = analyzer
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw RecorderError.recorderInitFailed
                }
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                guard self.generation == session else { return }
                let results = Task { [weak self] () throws -> String in
                    for try await result in module.results {
                        try Task.checkCancellation()
                        guard let self, self.generation == session else { throw CancellationError() }
                        self.transcript.apply(start: result.range.start.seconds,
                            end: CMTimeRangeGetEnd(result.range).seconds,
                            text: String(result.text.characters), final: result.isFinal)
                        if !self.firstPreviewReported, !self.transcript.text.isEmpty {
                            self.firstPreviewReported = true
                            let ms = Int(Date().timeIntervalSince(self.recordingStarted) * 1000)
                            self.logger.info("First local preview: ms=\(ms) final=\(result.isFinal)")
                        }
                    }
                    return ""
                }
                self.results = results
                try await analyzer.start(inputSequence: stream.stream)
                try Task.checkCancellation()
                guard self.generation == session else { return }
                try sink.attachPreview(sourceFormat: sourceFormat, analysisFormat: format)
                _ = try await results.value
                try Task.checkCancellation()
                if self.generation == session { throw RecorderError.noActiveRecording }
            } catch {
                guard self.generation == session, !Task.isCancelled else { return }
                self.previewUnavailable = true
                sink.disablePreview()
                self.results?.cancel()
                await self.analyzer?.cancelAndFinishNow()
                self.logger.warning("Local preview unavailable; continuing complete audio capture")
            }
        }
    }

    func stopRecording() throws -> RecordedAudio {
        guard let engine, let fileURL, let sink else {
            throw RecorderError.noActiveRecording
        }
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let duration = sink.duration
        sink.finish()
        self.engine = nil
        generation = UUID()
        previewTask?.cancel()
        results?.cancel()
        let stoppedAnalyzer = analyzer
        Task { await stoppedAnalyzer?.cancelAndFinishNow() }
        analyzer = nil
        try saveProgress(outcome: "recorded")
        try RecoveryStore.synchronize(fileURL)
        if let captureFailure = failure ?? sink.errorMessage {
            throw LocalTranscriptionFailure(partialText: "", detail: captureFailure)
        }
        // Only the original account ASR supplies the final transcript.
        return RecordedAudio(fileURL: fileURL, durationMs: Int(duration * 1000), previewText: transcript.text)
    }

    func cancelRecording() throws {
        let audio = try stopRecording()
        audio.localTranscript?.cancel()
        try saveProgress(outcome: "cancelled")
    }

    func currentLevel() -> CGFloat? {
        guard let sink, engine != nil else { return nil }
        let power = sink.power
        health.observe(powerDBFS: power, elapsedSeconds: sink.duration)
        return WaveformNormalizer.normalizedLevel(fromAveragePower: power)
    }
    func inputInterruptionDetected() -> Bool {
        health.interruptionDetected || failure != nil || sink?.errorMessage != nil
    }
    private func saveProgress(outcome: String) throws {
        guard let fileURL else { return }
        try store.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: fileURL,
            durationMs: Int((sink?.duration ?? 0) * 1000), asrText: nil,
            polishText: nil, appName: nil, appBundleIdentifier: nil,
            outcome: outcome, errorMessage: failure ?? sink?.errorMessage))
    }
}

@available(macOS 26.0, *)
final class LocalAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let diskConverter: AVAudioConverter
    private var analysisFormat: AVAudioFormat?
    private let diskFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var frameCount: Int64 = 0
    private var powerValue: Float = -160
    private var failure: String?
    private var ended = false
    private var previewFailed = false
    private let previewConsumer: ((AVAudioPCMBuffer) throws -> Void)?
    private let writeBuffer: ((AVAudioPCMBuffer) throws -> Void)?
    var previewUnavailable: Bool { lock.withLock { previewFailed } }
    var duration: Double { lock.withLock { Double(frameCount) / diskFormat.sampleRate } }
    var power: Float { lock.withLock { powerValue } }
    var errorMessage: String? { lock.withLock { failure } }
    init(url: URL, sourceFormat: AVAudioFormat, analysisFormat: AVAudioFormat?, sampleRate: Int,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         previewConsumer: ((AVAudioPCMBuffer) throws -> Void)? = nil,
         writeBuffer: ((AVAudioPCMBuffer) throws -> Void)? = nil) throws {
        guard let diskFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let diskConverter = AVAudioConverter(from: sourceFormat, to: diskFormat) else { throw RecorderError.recorderInitFailed }
        self.diskFormat = diskFormat
        self.analysisFormat = analysisFormat
        self.converter = analysisFormat.flatMap { AVAudioConverter(from: sourceFormat, to: $0) }
        self.diskConverter = diskConverter
        self.continuation = continuation
        self.previewConsumer = previewConsumer
        self.writeBuffer = writeBuffer
        self.file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func disablePreview() {
        lock.withLock {
            previewFailed = true
            converter = nil
            continuation.finish()
        }
    }
    func attachPreview(sourceFormat: AVAudioFormat, analysisFormat: AVAudioFormat) throws {
        try lock.withLock {
            guard !ended else { throw CancellationError() }
            guard let converter = AVAudioConverter(from: sourceFormat, to: analysisFormat) else {
                throw RecorderError.recorderInitFailed
            }
            self.converter = converter
            self.analysisFormat = analysisFormat
        }
    }
    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !ended, failure == nil else { return }
            do {
                let disk = try convert(buffer, using: diskConverter, format: diskFormat)
                if let writeBuffer { try writeBuffer(disk) }
                else { try file?.write(from: disk) }
                frameCount += Int64(disk.frameLength)
                if let samples = disk.floatChannelData?[0], disk.frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<Int(disk.frameLength) { sum += samples[i] * samples[i] }
                    powerValue = 10 * log10(max(sum / Float(disk.frameLength), 1e-16))
                }
            } catch {
                failure = error.localizedDescription
                continuation.finish()
                return
            }
            guard !previewFailed else { return }
            do {
                if let previewConsumer {
                    try previewConsumer(buffer)
                } else if let converter, let analysisFormat {
                    let audio = try convert(buffer, using: converter, format: analysisFormat)
                    continuation.yield(AnalyzerInput(buffer: audio))
                }
            } catch {
                previewFailed = true
                continuation.finish()
            }
        }
    }
    private func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw RecorderError.recorderInitFailed }
        var used = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return output
    }
    func finish() {
        lock.withLock { ended = true; file = nil; continuation.finish() }
    }
}

/// File-only observation of the same audited live preview engine.
@available(macOS 26.0, *)
enum LocalSpeechPreviewTrace {
    enum Failure: Error { case unsupported, outputExists, conversion }
    static func capture(audio: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.outputExists }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { throw Failure.unsupported }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw Failure.unsupported }
        let preparationStarted = ProcessingTiming.now()
        try await analyzer.prepareToAnalyze(in: format)
        let preparationMs = ProcessingTiming.milliseconds(since: preparationStarted)
        let file = try AVAudioFile(forReading: audio)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw Failure.conversion }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.outputExists }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let started = ProcessingTiming.now()
        let state = PreviewTraceState(handle: handle, started: started)
        try await state.write(["event": "start", "realTimePaced": true, "preparationMs": preparationMs,
                               "sourceAudioSHA256": SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined(),
                               "audioSeconds": Double(file.length) / file.processingFormat.sampleRate,
                               "reportingOptions": ["fastResults", "volatileResults"]])
        let collect = Task {
            for try await result in module.results {
                try await state.apply(start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                    text: String(result.text.characters), final: result.isFinal)
            }
        }
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream.stream)
            var fed: Int64 = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { throw Failure.conversion }
                try file.read(into: buffer, frameCount: 1024)
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.conversion }
                var used = false, conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData; return buffer
                }
                if let conversionError { throw conversionError }
                fed += Int64(buffer.frameLength)
                let targetNs = UInt64(Double(fed) / file.processingFormat.sampleRate * 1_000_000_000)
                let elapsedNs = ProcessingTiming.now() - started
                if targetNs > elapsedNs { try await Task.sleep(nanoseconds: targetNs - elapsedNs) }
                stream.continuation.yield(AnalyzerInput(buffer: converted))
            }
            try await state.write(["event": "audioEnd", "framesFed": fed])
            stream.continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await collect.value
            try await state.write(["event": "completed"])
            try handle.synchronize()
        } catch {
            stream.continuation.finish(); collect.cancel()
            await analyzer.cancelAndFinishNow()
            try? await state.write(["event": "failed", "errorType": String(describing: type(of: error))])
            throw error
        }
    }
}

private actor PreviewTraceState {
    let handle: FileHandle
    let started: UInt64
    var transcript = StreamingTranscript()
    var version = 0
    init(handle: FileHandle, started: UInt64) { self.handle = handle; self.started = started }
    func apply(start: Double, end: Double, text: String, final: Bool) throws {
        transcript.apply(start: start, end: end, text: text, final: final)
        version += 1
        try write(["event": "preview", "version": version, "text": transcript.text,
                   "segmentStart": start, "segmentEnd": end, "segmentFinal": final])
    }
    func write(_ event: [String: Any]) throws {
        var event = event; event["elapsedMs"] = ProcessingTiming.milliseconds(since: started)
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([10]))
    }
}
