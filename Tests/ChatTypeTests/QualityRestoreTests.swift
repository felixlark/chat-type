import Foundation
import Testing
import AVFoundation
import Speech
@testable import ChatType

@Test func explicitTermsSurviveUnrecognizableASRAndSmallPolishBudget() {
    var config = TextPolishConfig()
    config.glossaryBudgetCharacters = 240
    let messages = TextPolishPromptBuilder().buildMessages(
        transcript: "请用 peacteg 评审 smar shade，先不要发布。",
        terminologyEntries: [TerminologyEntry(canonical: "pstack", aliases: ["peacteg"]),
                             TerminologyEntry(canonical: "SmartShadow", aliases: ["smar shade"])],
        config: config, priorityTerms: ["pstack", "SmartShadow"])
    #expect(messages[0].content.contains("- pstack aliases: peacteg"))
    #expect(messages[0].content.contains("- SmartShadow aliases: smar shade"))
    #expect(messages[1].content == "请用 peacteg 评审 smar shade，先不要发布。")
    let absent = TextPolishPromptBuilder().buildMessages(transcript: "请用那个工具评审项目。",
        terminologyEntries: [], config: config, priorityTerms: ["pstack", "SmartShadow"])
    #expect(absent[0].content.contains("- pstack"))
    #expect(absent[0].content.contains("- SmartShadow"))
}

@Test func audioHintsPrioritizeExplicitTermsThenUsageAndStableSpelling() {
    var config = TranscriptionConfig()
    config.hintTerms = ["pstack", "SmartShadow"]
    var popular = TerminologyEntry(canonical: "Popular", aliases: [])
    popular.usageCount = 10
    config.terminology.entries = [TerminologyEntry(canonical: "Zebra", aliases: []),
        TerminologyEntry(canonical: "SmartShadow", aliases: []), popular,
        TerminologyEntry(canonical: "Alpha", aliases: [])]
    #expect(config.promptHintTerms == ["pstack", "SmartShadow", "Popular", "Alpha", "Zebra"])
}

@Test func recoverableAccountFailuresIncludeEmptyNetworkAndTimeout() {
    #expect(ChatGPTTranscriber.isRetryable(URLError(.timedOut)))
    #expect(ChatGPTTranscriber.isRetryable(URLError(.dnsLookupFailed)))
    #expect(ChatGPTTranscriber.isRetryable(URLError(.notConnectedToInternet)))
    #expect(ChatGPTTranscriber.isRetryable(TranscriptionError.invalidResponse))
    #expect(!ChatGPTTranscriber.isRetryable(URLError(.cancelled)))
    #expect(!ChatGPTTranscriber.isRetryable(TranscriptionError.invalidAudio))
}

@available(macOS 26.0, *)
@Test func previewConversionFailurePreservesAllSubsequentDiskAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("capture.wav")
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                           channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    for i in 0..<2_400 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.2 }
    let stream = AsyncStream<AnalyzerInput>.makeStream()
    let sink = try LocalAudioSink(url: url, sourceFormat: format, analysisFormat: format,
        sampleRate: 24_000, continuation: stream.continuation,
        previewConsumer: { _ in throw URLError(.cannotDecodeContentData) })
    sink.accept(buffer)
    sink.accept(buffer)
    sink.accept(buffer)
    sink.finish()
    let recorded = try AVAudioFile(forReading: url)
    #expect(recorded.length == 7_200)
    #expect(sink.errorMessage == nil)
    #expect(abs(sink.duration - 0.3) < 0.001)
}

@Test func observedTermAliasesPreserveOrdinaryShadowAndCodeLiterals() {
    let entries = [TerminologyEntry(canonical: "pstack", aliases: []),
                   TerminologyEntry(canonical: "SmartShadow", aliases: []),
                   TerminologyEntry(type: .correction, original: "peacteg", replacement: "pstack", aliases: [], source: "user", usageCount: 0, createdAt: "2026-11-10"),
                   TerminologyEntry(type: .correction, original: "smar shade", replacement: "SmartShadow", aliases: [], source: "user", usageCount: 0, createdAt: "2026-11-10")]
    let protectedEntries = entries + [TerminologyEntry(type: .correction, original: "smart shade", replacement: "smart shade", aliases: [], source: "user", usageCount: 0, createdAt: "2026-11-10")]
    let normalizer = TerminologyNormalizer()
    #expect(normalizer.normalize(text: "请用 peacteg 评审 smar shade。", importedEntries: protectedEntries,
                                hintTerms: []).text == "请用 pstack 评审 SmartShadow。")
    let input = "smart shade and shadow; `peacteg` /tmp/peacteg.swift"
    let output = normalizer.normalize(text: input, importedEntries: protectedEntries, hintTerms: []).text
    #expect(output == input, "actual: \(output)")
    for ordinary in ["smart shade", "shadow", "请保留 smart shade 和 shadow。", "```swift\nlet peacteg = 1\n```"] {
        let unchanged = normalizer.normalize(text: ordinary, importedEntries: protectedEntries, hintTerms: []).text
        #expect(unchanged == ordinary, "actual: \(unchanged)")
    }
}

@Test func rateLimitWaitAcceptsSecondsAndHTTPDate() {
    #expect(ChatGPTTranscriber.retryAfterSeconds("30") == 30)
    #expect(ChatGPTTranscriber.retryAfterSeconds("-1") == nil)
    #expect(ChatGPTTranscriber.retryAfterSeconds("invalid") == nil)
    #expect(ChatGPTTranscriber.retryAfterSeconds("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0)) == 60)
}

@available(macOS 26.0, *)
@Test func diskFailureIsReportedWhilePreviewDisableKeepsRecording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                           channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    buffer.floatChannelData![0].initialize(repeating: 0.1, count: 2_400)
    let stream = AsyncStream<AnalyzerInput>.makeStream()
    let url = root.appendingPathComponent("continued.wav")
    let sink = try LocalAudioSink(url: url, sourceFormat: format, analysisFormat: nil,
        sampleRate: 24_000, continuation: stream.continuation)
    sink.disablePreview()
    sink.accept(buffer)
    sink.accept(buffer)
    sink.finish()
    #expect(sink.previewUnavailable)
    #expect(sink.errorMessage == nil)
    #expect(try AVAudioFile(forReading: url).length == 4_800)
    let failedStream = AsyncStream<AnalyzerInput>.makeStream()
    let failed = try LocalAudioSink(url: root.appendingPathComponent("disk-failed.wav"),
        sourceFormat: format, analysisFormat: nil, sampleRate: 24_000,
        continuation: failedStream.continuation,
        writeBuffer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
    failed.accept(buffer)
    failed.accept(buffer)
    failed.finish()
    #expect(failed.errorMessage != nil)
    #expect(failed.duration == 0)
}

@Test func finalTypographySeparatesChineseEnglishAndNumbersPreservingLiterals() {
    let formatter = DictationTextFormatter()
    #expect(formatter.format("请用pstack评审SmartShadow，预算3500元，版本v0.5.1。") == "请用 pstack 评审 SmartShadow，预算 3500 元，版本 v0.5.1。")
    #expect(formatter.format("使用 API 和 3 个模型。") == "使用 API 和 3 个模型。")
    let literal = "保留 `let中文=1` 与 ```swift\nlet中文=2\n```，链接 https://example.com/中文a 和路径 /tmp/中文a.swift，邮箱 a@example.com。"
    #expect(formatter.format(literal) == literal)
    let once = formatter.format("F5开始，按F5结束，20分钟后处理3.5秒。")
    #expect(once == "F5 开始，按 F5 结束，20 分钟后处理 3.5 秒。")
    #expect(formatter.format(once) == once)
}
