import Foundation
import Testing
@testable import ChatType

private let identityShade = TerminologyEntry(type: .correction,
    original: "smart shade", replacement: "smart shade", aliases: [],
    source: "user", usageCount: 0, createdAt: "test")

@Test(arguments: ["Keep the existing settings and do not publish.", "请保留现有设置。", "请 review this change，先不要发布。"])
func polishPreservesOriginalLanguageContract(transcript: String) {
    let messages = TextPolishPromptBuilder().buildMessages(transcript: transcript,
        terminologyEntries: [], config: TextPolishConfig(), locale: "zh-CN")
    #expect(messages[0].content.contains("Keep English in English"))
    #expect(messages[0].content.contains("preserve the original language of each passage"))
    #expect(messages[1].content == transcript)
}

@Test func spacedUserCorrectionWinsBeforeGenericCloudFuzzyMatch() {
    let entries = [TerminologyEntry(canonical: "Claude", aliases: []),
        TerminologyEntry(canonical: "OpenClaw", aliases: []),
        TerminologyEntry(type: .correction, original: "opencloud", replacement: "OpenClaw",
            aliases: ["open cloud"], source: "user", usageCount: 0, createdAt: "test")]
    let normalizer = TerminologyNormalizer()
    #expect(normalizer.normalize(text: "检查 Open Cloud 的连接。", importedEntries: entries,
        hintTerms: []).text == "检查 OpenClaw 的连接。")
    let literal = "`open cloud` /tmp/opencloud.swift"
    #expect(normalizer.normalize(text: literal, importedEntries: entries, hintTerms: []).text == literal)
}

@Test func identityCorrectionsProtectMixedScriptPhrasesAndWordBoundaries() {
    let protection = SelfMappedPolishLiterals(
        transcript: "画的Smart Shade是普通阴影，保留 smart shade。", entries: [identityShade])
    #expect(protection.literals == ["smart shade"])
    #expect(SelfMappedPolishLiterals(transcript: "smart shaders", entries: [identityShade]).literals.isEmpty)
    #expect(SelfMappedPolishLiterals(transcript: "SmartShadow", entries: [identityShade]).literals.isEmpty)
}

private struct ProtectedLiteralTranscriber: Transcriber {
    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        TranscriptionResult(text: "把 smart shade 设置成灰色，不，先不要改 smart shade。",
            metrics: TranscriptionMetrics(provider: .chatGPTManagedAuth, audioDurationMs: 6000,
                audioBytes: 100, authMs: 0, transcribeMs: 1, promptIncluded: true,
                uploadFormat: "test"))
    }
}

@Test func identityPhraseProtectionAcceptsLaterSelfCorrections() async throws {
    let polisher = OpenAICompatibleTextPolisher(config: TextPolishConfig(),
        chatGPTAuthProvider: FakeChatGPTAuthManager(bestTokens: [.success("test-token")]),
        chatGPTAuthAvailable: true, dataLoader: { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("map a phrase to itself"))
            #expect(body.contains("remove superseded clauses as usual"))
            return (Data(#"{"status":"completed","output_text":"先不要改 smart shade。"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    let result = try await DictationPipeline(transcriber: ProtectedLiteralTranscriber(),
        normalizer: TerminologyNormalizer(), importedEntries: [identityShade], hintTerms: [],
        textPolisher: polisher).prepare(audio: RecordedAudio(
            fileURL: URL(fileURLWithPath: "/tmp/unused-protected-literal-test.wav"), durationMs: 6000))
    #expect(result.finalText == "先不要改 smart shade。")
    #expect(result.metrics.textPolishErrorMessage == nil)
    #expect(result.metrics.textPolishAttempted)
}
