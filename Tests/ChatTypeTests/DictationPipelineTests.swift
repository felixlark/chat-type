import Foundation
import Testing
@testable import ChatType

@Test
func terminologyNormalizerKeepsLargeDictionaryWithinInteractiveBudget() {
    let entries = (0..<15_000).map { index in
        TerminologyEntry(
            canonical: "联系人\(index)",
            aliases: []
        )
    } + [TerminologyEntry(canonical: "OpenClaw", aliases: ["open cloud"])]

    let normalizer = TerminologyNormalizer()
    _ = normalizer.normalize(
        text: "预热联系人索引。",
        importedEntries: entries,
        hintTerms: []
    )

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        _ = normalizer.normalize(
            text: "请在 Open Cloud 里联系联系人14999。",
            importedEntries: entries,
            hintTerms: []
        )
    }

    #expect(
        elapsed < .milliseconds(100),
        "Large-dictionary normalization took \(elapsed); keep it below 100 ms."
    )
}

@Test
func terminologyNormalizerInvalidatesCandidateIndexWhenEntriesChange() {
    let normalizer = TerminologyNormalizer()
    var entries = [TerminologyEntry(canonical: "OpenClaw", aliases: ["open cloud"])]

    let first = normalizer.normalize(
        text: "请打开 open cloud。",
        importedEntries: entries,
        hintTerms: []
    )
    #expect(first.text == "请打开 OpenClaw。")

    entries[0] = TerminologyEntry(canonical: "Codex", aliases: ["code x"])
    let second = normalizer.normalize(
        text: "请打开 code x。",
        importedEntries: entries,
        hintTerms: []
    )

    #expect(second.text == "请打开 Codex。")
}

private let acceptanceTranscript = "王老师 呃 我们这周三下午三点应该可以开会 你帮我发个邮件给大家 主题就是第二版预算 review 然后附件是 budget v2.xlsx"

private struct FakeTranscriber: Transcriber {
    let result: TranscriptionResult

    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        result
    }
}

private struct FakeTextPolisher: TextPolishing {
    let result: Result<TextPolishResult, Error>

    func polish(
        text: String,
        terminologyEntries: [TerminologyEntry],
        hintTerms: [String]
    ) async throws -> TextPolishResult {
        try result.get()
    }
}

private struct FakePolishError: Error {}

private actor SequencedTextPolisher: TextPolishing {
    private var results: [Result<TextPolishResult, Error>]
    private(set) var callCount = 0

    init(results: [Result<TextPolishResult, Error>]) {
        self.results = results
    }

    func polish(
        text: String,
        terminologyEntries: [TerminologyEntry],
        hintTerms: [String]
    ) async throws -> TextPolishResult {
        callCount += 1
        return try results.removeFirst().get()
    }
}

@Test
func transcribeOnlyStopsAfterASRAndCarriesNoPolishState() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(result: TranscriptionResult(
            text: "只做转写",
            metrics: .init(
                provider: .chatGPTManagedAuth,
                audioDurationMs: 1_000,
                audioBytes: 32_000,
                authMs: 1,
                transcribeMs: 2,
                promptIncluded: false
            )
        )),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: [],
        textPolisher: FakeTextPolisher(result: .success(TextPolishResult(
            text: "不应出现",
            provider: .doubaoIME,
            applied: true,
            estimatedInputTokens: 0,
            estimatedOutputTokens: 0
        )))
    )
    let stages = try await pipeline.transcribeOnly(audio: RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.wav"),
        durationMs: 1_000
    ))
    #expect(stages.asrText == "只做转写")
    #expect(stages.polishInput == nil)
    #expect(stages.polishOutput == nil)
    #expect(stages.finalText == nil)
}

@Test
func polishOnlyReusesASRAndProducesIndependentFinalization() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(result: TranscriptionResult(
            text: "不应重新转写",
            metrics: .init(
                provider: .chatGPTManagedAuth,
                audioDurationMs: 1_000,
                audioBytes: 32_000,
                authMs: 1,
                transcribeMs: 2,
                promptIncluded: false
            )
        )),
        normalizer: TerminologyNormalizer(),
        importedEntries: [TerminologyEntry(canonical: "ChatType", aliases: ["chattype"])],
        hintTerms: [],
        textPolisher: FakeTextPolisher(result: .success(TextPolishResult(
            text: "ChatType 可以单独重新润色。",
            provider: .doubaoIME,
            applied: true,
            estimatedInputTokens: 10,
            estimatedOutputTokens: 12
        )))
    )
    let stages = try await pipeline.polishOnly(asrText: "chattype 可以单独重新润色", partialAudio: false)
    #expect(stages.asrText == "chattype 可以单独重新润色")
    #expect(stages.polishInput == "ChatType 可以单独重新润色")
    #expect(stages.polishOutput == "ChatType 可以单独重新润色。")
    #expect(stages.finalText == "ChatType 可以单独重新润色。")
}

@Test
func terminologyNormalizerPreservesHintTermsWithoutModelRewrite() {
    let result = TerminologyNormalizer().normalize(
        text: "请帮我把 Budget V2.XLSX 发给大家 review 一下，顺便提一下 chattype 已经能用了。",
        importedEntries: [],
        hintTerms: ["budget v2.xlsx", "review", "ChatType"]
    )

    #expect(result.text.contains("budget v2.xlsx"))
    #expect(result.text.contains("review"))
    #expect(result.text.contains("ChatType"))
    #expect(result.applied == true)
    #expect(result.exactReplacementCount == 2)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerConvertsTraditionalChineseToSimplifiedChinese() {
    let result = TerminologyNormalizer().normalize(
        text: "請把這個檔案發過來，體驗一下 chattype。",
        importedEntries: [],
        hintTerms: ["ChatType"]
    )

    #expect(result.text == "请把这个档案发过来，体验一下 ChatType。")
    #expect(result.applied == true)
}

@Test
func terminologyNormalizerUsesFullWidthPunctuationWhenChineseIsPresent() {
    let result = TerminologyNormalizer().normalize(
        text: "请总结 ChatType, OpenClaw works well. 还有问题吗? 不要忘了: 明天 review!",
        importedEntries: [],
        hintTerms: []
    )

    #expect(result.text == "请总结 ChatType， OpenClaw works well。 还有问题吗？ 不要忘了： 明天 review！")
    #expect(result.applied == true)
}

@Test
func terminologyNormalizerPreservesTechnicalLiteralsWhenConvertingPunctuation() {
    let result = TerminologyNormalizer().normalize(
        text: "请发给我 budget v2.xlsx, API 是 https://example.com/v1/chat, 版本是 v1.2.3.",
        importedEntries: [],
        hintTerms: ["budget v2.xlsx"]
    )

    #expect(result.text == "请发给我 budget v2.xlsx， API 是 https://example.com/v1/chat， 版本是 v1.2.3。")
}

@Test
func terminologyNormalizerReplacesImportedAliasesAndSeparators() {
    let result = TerminologyNormalizer().normalize(
        text: "把 Type Whisper 和 open ai compatible 都写对。",
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
            TerminologyEntry(
                canonical: "OpenAI Compatible",
                aliases: ["Open AI Compatible"]
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "把 TypeWhisper 和 OpenAI Compatible 都写对。")
    #expect(result.exactReplacementCount == 2)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerFuzzilyAlignsImportedTechnicalTerms() {
    let result = TerminologyNormalizer().normalize(
        text: "Takwiisper 这次能不能和 Codex 对齐？",
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "TypeWhisper 这次能不能和 Codex 对齐？")
    #expect(result.exactReplacementCount == 0)
    #expect(result.fuzzyReplacementCount == 1)
}

@Test
func terminologyNormalizerFuzzilyAlignsAccentedLatinTechnicalTerms() {
    let result = TerminologyNormalizer().normalize(
        text: "Type Wísper 和 ChátType 都要按术语库大小写输出。",
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
            TerminologyEntry(
                canonical: "ChatType",
                aliases: ["chat type"]
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "TypeWhisper 和 ChatType 都要按术语库大小写输出。")
    #expect(result.fuzzyReplacementCount == 2)
}

@Test
func terminologyNormalizerDoesNotExpandStandaloneLatinInsideMixedScriptTerm() {
    let result = TerminologyNormalizer().normalize(
        text: "请打开 github 看一下。",
        importedEntries: [
            TerminologyEntry(
                canonical: "玩转GitHub",
                aliases: []
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "请打开 github 看一下。")
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerCollapsesSpacedMixedScriptTermWithoutDuplicatePrefix() {
    let result = TerminologyNormalizer().normalize(
        text: "我们继续讲 玩转 github 这门课。",
        importedEntries: [
            TerminologyEntry(
                canonical: "玩转GitHub",
                aliases: []
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "我们继续讲 玩转GitHub 这门课。")
    #expect(result.exactReplacementCount == 1)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerAppliesUserCorrectionForOpenClawMisrecognition() {
    let result = TerminologyNormalizer().normalize(
        text: "现在总是把 OpenCloud 识别错，必须锁死。",
        importedEntries: [
            TerminologyEntry(
                type: .correction,
                original: "opencloud",
                replacement: "OpenClaw",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "现在总是把 OpenClaw 识别错，必须锁死。")
    #expect(result.exactReplacementCount == 1)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerIgnoresLegacyCaseSensitiveFlagForCorrections() {
    let result = TerminologyNormalizer().normalize(
        text: "OpenCloud 仍然要替换。",
        importedEntries: [
            TerminologyEntry(
                type: .correction,
                original: "opencloud",
                replacement: "OpenClaw",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "OpenClaw 仍然要替换。")
}

@Test
func terminologyNormalizerUsesEveryStoredEntryWithoutEnableFlags() {
    let result = TerminologyNormalizer().normalize(
        text: "opencloud 和 chattype 都要被改。",
        importedEntries: [
            TerminologyEntry(
                type: .correction,
                original: "opencloud",
                replacement: "OpenClaw",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
            TerminologyEntry(
                type: .term,
                original: "ChatType",
                replacement: nil,
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "OpenClaw 和 ChatType 都要被改。")
    #expect(result.exactReplacementCount == 2)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerAppliesCorrectionBeforeTermFuzzyAlignment() {
    let result = TerminologyNormalizer().normalize(
        text: "opencloud 必须先按 correction 变成 OpenClaw。",
        importedEntries: [
            TerminologyEntry(
                type: .term,
                original: "OpenCloud",
                replacement: nil,
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
            TerminologyEntry(
                type: .correction,
                original: "opencloud",
                replacement: "OpenClaw",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "OpenClaw 必须先按 correction 变成 OpenClaw。")
    #expect(result.exactReplacementCount == 1)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func terminologyNormalizerDoesNotDowncaseCorrectionReplacementWithLowercaseTerm() {
    let result = TerminologyNormalizer().normalize(
        text: "OpenCloud 应该变成 OpenClaw。",
        importedEntries: [
            TerminologyEntry(
                type: .correction,
                original: "opencloud",
                replacement: "OpenClaw",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
            TerminologyEntry(
                type: .term,
                original: "openclaw",
                replacement: nil,
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-05-07T10:00:00Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "OpenClaw 应该变成 OpenClaw。")
}

@Test
func terminologyNormalizerAppliesUserLowercaseTermCasingForShadowd() {
    let result = TerminologyNormalizer().normalize(
        text: "ShadowD 和 SHADOWD 都应该按词库输出。",
        importedEntries: [
            TerminologyEntry(
                type: .term,
                original: "shadowd",
                replacement: nil,
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-06-15T06:43:11Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "shadowd 和 shadowd 都应该按词库输出。")
    #expect(result.exactReplacementCount == 2)
}

@Test
func terminologyNormalizerAppliesExplicitLowercaseCorrectionForShadowd() {
    let result = TerminologyNormalizer().normalize(
        text: "ShadowD 应该用小写。",
        importedEntries: [
            TerminologyEntry(
                type: .correction,
                original: "ShadowD",
                replacement: "shadowd",
                aliases: [],
                source: "user",
                usageCount: 0,
                createdAt: "2026-06-15T06:43:11Z"
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "shadowd 应该用小写。")
    #expect(result.exactReplacementCount == 1)
}

@Test
func terminologyNormalizerAvoidsFuzzyRewritesInsideProtectedLiterals() {
    let result = TerminologyNormalizer().normalize(
        text: "保留 https://example.com/Takwiisper 和 --takwiisper 以及 /tmp/Takwiisper，不要乱改。",
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
        ],
        hintTerms: []
    )

    #expect(result.text == "保留 https://example.com/Takwiisper 和 --takwiisper 以及 /tmp/Takwiisper，不要乱改。")
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func transcriptionPromptBuilderIncludesDirectUseGuidanceAndHintTerms() {
    let prompt = TranscriptionPromptBuilder().buildPrompt(
        hintTerms: ["budget v2.xlsx", "ChatType"],
        locale: "zh-CN"
    )

    #expect(prompt.contains("输出带自然标点"))
    #expect(prompt.contains("直接粘贴使用"))
    #expect(prompt.contains("清理口头填充词"))
    #expect(prompt.contains("不要把系统界面、输入框提示、按钮文案当作语音内容输出"))
    #expect(prompt.contains("budget v2.xlsx"))
    #expect(prompt.contains("ChatType"))
}

@Test
func transcriptionPromptBuilderCanDisableSpeechCleanupGuidance() {
    let prompt = TranscriptionPromptBuilder().buildPrompt(
        hintTerms: [],
        speechCleanupEnabled: false,
        locale: "zh-CN"
    )

    #expect(prompt.contains("清理口头填充词") == false)
}

@Test
func transcriptionPromptBuilderClipsAndDeduplicatesDictionaryHintTerms() {
    let prompt = TranscriptionPromptBuilder().buildPrompt(
        hintTerms: Array(repeating: "OpenClaw", count: 20) + ["TypeWhisper"],
        locale: "zh-CN"
    )

    #expect(prompt.contains("OpenClaw"))
    #expect(prompt.contains("TypeWhisper"))
    #expect(prompt.components(separatedBy: "OpenClaw").count == 2)
}

@Test
func transcriptionPromptBuilderRequestsSimplifiedChineseByDefault() {
    let prompt = TranscriptionPromptBuilder().buildPrompt(
        hintTerms: [],
        locale: "zh-CN"
    )

    #expect(prompt.contains("简体中文"))
    #expect(prompt.contains("不要输出繁体中文"))
}

@Test
func dictationPipelineRunsTranscribeThenNormalizeWithoutCleanupStage() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把 Budget V2.XLSX 发出来，chattype 现在可以用了。",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
        ],
        hintTerms: ["budget v2.xlsx", "ChatType"]
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.rawText == "请把 Budget V2.XLSX 发出来，chattype 现在可以用了。")
    #expect(result.finalText == "请把 budget v2.xlsx 发出来，ChatType 现在可以用了。")
    let stages = try #require(result.stages)
    #expect(stages.polishInput == result.finalText)
    #expect(stages.correctionInput == result.finalText)
    #expect(result.metrics.normalizationMs >= 0)
    #expect(result.exactReplacementCount == 2)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func dictationPipelineReportsExactAndFuzzyReplacementCounts() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "Takwiisper 和 chattype 都得写对。",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [
            TerminologyEntry(
                canonical: "TypeWhisper",
                aliases: ["Type Whisper"]
            ),
        ],
        hintTerms: ["ChatType"]
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-2.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "TypeWhisper 和 ChatType 都得写对。")
    #expect(result.exactReplacementCount == 1)
    #expect(result.fuzzyReplacementCount == 1)
}

@Test
func dictationPipelineStripsTrailingCodexComposerArtifactFromFinalText() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。 Ask Codex anything. @ to use plugins or use files",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-3.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.rawText == "请把这段话发给产品同学确认一下。 Ask Codex anything. @ to use plugins or use files")
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
    #expect(result.exactReplacementCount == 0)
    #expect(result.fuzzyReplacementCount == 0)
}

@Test
func dictationPipelineStripsTrailingCodexComposerArtifactWhenItAppearsOnSeparateLine() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。\nAsk Codex anything. @ to use plugins or use files",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-4.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
}

@Test
func dictationPipelineStripsTrailingCodexFollowUpPlaceholder() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。 Ask for follow-up changes",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-5.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
}

@Test
func dictationPipelineStripsTrailingCodexFollowUpPlaceholderWithZeroWidthBoundaryNoise() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。 Ask for follow-up changes\u{200B}",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-6.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
}

@Test
func dictationPipelineStripsTrailingCodexFollowUpPlaceholderWithAgentHint() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。 Ask for follow-up changes or use @ to tag an agent",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-7.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
}

@Test
func dictationPipelineStripsTrailingCodexComposerArtifactForModernLocalPlaceholder() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把这段话发给产品同学确认一下。 Ask Codex anything, @ add files, / for commands, $ for skills",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: []
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-8.wav"),
        durationMs: 2_000
    )

    let result = try await pipeline.prepare(audio: audio)
    #expect(result.finalText == "请把这段话发给产品同学确认一下。")
    #expect(result.normalizationApplied == true)
}

@Test
func dictationPipelineRunsTextPolishBetweenNormalizationPasses() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "呃先做 chattype 设置页，然后不对，改成 v0.5 润色计划。",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 3_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: ["ChatType"],
        textPolisher: FakeTextPolisher(
            result: .success(
                TextPolishResult(
                    text: "- 目标：完成 chattype v0.5 润色计划\n- 验收：长句输出分点。",
                    provider: .chatGPTAuth,
                    applied: true,
                    estimatedInputTokens: 1_200,
                    estimatedOutputTokens: 400
                )
            )
        )
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-polish.wav"),
        durationMs: 3_000
    )

    let result = try await pipeline.prepare(audio: audio)

    #expect(result.finalText.contains("ChatType v0.5"))
    #expect(result.finalText.contains("- 目标"))
    let stages = try #require(result.stages)
    #expect(stages.polishOutput?.contains("chattype") == true)
    #expect(stages.correctionInput?.contains("ChatType") == true)
    #expect(result.metrics.textPolishAttempted)
    #expect(result.metrics.textPolishProvider == .chatGPTAuth)
    #expect(result.metrics.textPolishErrorMessage == nil)
    #expect(result.metrics.estimatedPolishInputTokens == 1_200)
    #expect(result.metrics.estimatedPolishOutputTokens == 400)
}

@Test
func dictationPipelinePreservesStagesAndBlocksOutputWhenTextPolishFails() async throws {
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: "请把 chattype 的术语写对。",
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 2_000,
                    audioBytes: 128_000,
                    authMs: 50,
                    transcribeMs: 400,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: ["ChatType"],
        textPolisher: FakeTextPolisher(result: .failure(FakePolishError()))
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-polish-fallback.wav"),
        durationMs: 2_000
    )

    do {
        _ = try await pipeline.prepare(audio: audio)
        Issue.record("Incomplete polish must not produce injectable output")
    } catch let failure as DictationPipelineFailure {
        #expect(failure.stages.asrText == "请把 chattype 的术语写对。")
        #expect(failure.stages.polishInput == "请把 ChatType 的术语写对。")
        #expect(failure.stages.finalText == nil)
    }

}

@Test
func dictationPipelineBlocksOutputWhenTextPolishSuspiciouslyTruncatesLongInput() async throws {
    let transcript = """
    第一点先把 Dictation 和 AI Polish 拆开。第二点 ChatGPT 的 transcribe API 属于 ASR，不要跟二次 rewrite 混在一起。第三点 ChatGPT Auth rewrite 要单独说明。第四点如果后面有新的决定，要以后面的决定为准。
    """
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: transcript,
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 12_000,
                    audioBytes: 560_000,
                    authMs: 20,
                    transcribeMs: 800,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: ["ChatGPT", "API"],
        textPolisher: FakeTextPolisher(
            result: .success(
                TextPolishResult(
                    text: "先把 Dictation 和 AI Polish 拆开。",
                    provider: .chatGPTAuth,
                    applied: true,
                    estimatedInputTokens: 1_500,
                    estimatedOutputTokens: 300
                )
            )
        )
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-polish-truncated.wav"),
        durationMs: 12_000
    )

    do {
        _ = try await pipeline.prepare(audio: audio)
        Issue.record("Truncated polish must not produce injectable output")
    } catch let failure as DictationPipelineFailure {
        #expect(failure.stages.asrText == transcript)
        #expect(failure.stages.polishOutput == "先把 Dictation 和 AI Polish 拆开。")
        #expect(failure.stages.polishOutputs?.count == 2)
        #expect(failure.stages.finalText == nil)
    }

}

@Test
func dictationPipelineRetriesOnceWhenFirstTextPolishResultLooksTruncated() async throws {
    let transcript = """
    第一点先说明云城示例学院的背景和项目合作目标。第二点说明顾主任希望补充省外专家推荐函。第三点请陶主任协助联系海城示例大学相关专家并帮忙牵线。第四点附上五到十位专家名单和完整调研报告。
    """
    let polisher = SequencedTextPolisher(results: [
        .success(
            TextPolishResult(
                text: "请陶主任协助联系专家。",
                provider: .chatGPTAuth,
                applied: true,
                estimatedInputTokens: 760,
                estimatedOutputTokens: 160
            )
        ),
        .success(
            TextPolishResult(
                text: """
                请以我的口吻给陶主任起草微信：

                1. 说明云城示例学院的背景；
                2. 说明顾主任希望补充省外专家推荐函；
                3. 请陶主任协助联系海城示例大学相关专家；
                4. 附上专家名单和调研报告。
                """,
                provider: .chatGPTAuth,
                applied: true,
                estimatedInputTokens: 760,
                estimatedOutputTokens: 160
            )
        ),
    ])
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: transcript,
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 115_000,
                    audioBytes: 5_500_000,
                    authMs: 20,
                    transcribeMs: 5_800,
                    promptIncluded: false
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: ["海城示例大学"],
        textPolisher: polisher
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-polish-retry.wav"),
        durationMs: 115_000
    )

    let result = try await pipeline.prepare(audio: audio)

    #expect(await polisher.callCount == 2)
    #expect(result.finalText.contains("省外专家推荐函"))
    #expect(result.finalText.contains("专家名单和调研报告"))
    #expect(result.metrics.textPolishProvider == .chatGPTAuth)
    #expect(result.metrics.textPolishErrorMessage == nil)
}

@Test
func dictationPipelineKeepsResequenceIntendedStepsWithPolish() async throws {
    let transcript = "我们来测试一下这个AI润色啊， 现在包括三个步骤啊，一，打开冰箱，二，然后呢再把冰箱关，呃不对，二，把大象放进去，三呢就是关上冰箱门，按这个顺序来做啊。"
    let pipeline = DictationPipeline(
        transcriber: FakeTranscriber(
            result: TranscriptionResult(
                text: transcript,
                metrics: .init(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: 9_000,
                    audioBytes: 180_000,
                    authMs: 15,
                    transcribeMs: 520,
                    promptIncluded: true
                )
            )
        ),
        normalizer: TerminologyNormalizer(),
        importedEntries: [],
        hintTerms: [],
        textPolisher: FakeTextPolisher(
            result: .success(
                TextPolishResult(
                    text: "一，打开冰箱\n二，把大象放进去\n三，关上冰箱门",
                    provider: .chatGPTAuth,
                    applied: true,
                    estimatedInputTokens: 220,
                    estimatedOutputTokens: 110
                )
            )
        )
    )

    let audio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake-polish-resequence.wav"),
        durationMs: 9_000
    )

    let result = try await pipeline.prepare(audio: audio)

    #expect(result.rawText == transcript)
    #expect(result.finalText.contains("把大象放进去"))
    #expect(result.finalText.contains("先" ) == false)
    #expect(result.metrics.textPolishProvider == .chatGPTAuth)
    #expect(result.metrics.polishMs >= 0)
}

@Test
func entryKeyMatchGateAgreesWithStringContainsAcrossUnicodeCorpus() {
    let zwjFamily = "👨\u{200D}👩\u{200D}👧"
    let corpus = [
        "",
        "a",
        "Chat",
        "chat",
        "ChatType",
        "ChatTypes",
        " chat type ",
        "ｃｈａｔ",
        "Ｃｈａｔ",
        "聊天记录",
        "café",
        "cafe\u{301}",
        "e\u{301}",
        "é",
        "각",
        "각",
        "❤",
        "❤\u{FE0F}",
        "🇨🇳",
        "🇨🇳🇺🇸",
        zwjFamily,
        "👨",
        "Straße",
        "STRASSE",
        "İstanbul",
        "istanbul",
        "https://example.com/a?b=1",
        "/Users/example/Projects",
        "全角，半角.",
        "a\nb",
        "…",
        "𠀀",
        "😀",
        "😀\u{FE0F}",
    ]

    for textKey in corpus {
        let gate = EntryKeyMatchGate(textKey: textKey)
        for key in corpus {
            #expect(
                gate.matchesKey(key) == textKey.contains(key),
                "matchesKey mismatch for textKey=\(textKey.debugDescription) key=\(key.debugDescription)"
            )
            #expect(
                gate.matchesNonEmptyKey(key) == (!key.isEmpty && textKey.contains(key)),
                "matchesNonEmptyKey mismatch for textKey=\(textKey.debugDescription) key=\(key.debugDescription)"
            )
        }
    }
}

@Test
func entryKeyMatchGateNeverRejectsARealContainingKey() {
    let textKey = "请把 ChatType 的 F5 逻辑整理成三条要点，保留 café 与 각 以及 ❤️ 和 👨\u{200D}👩\u{200D}👧。"
    let gate = EntryKeyMatchGate(textKey: textKey)

    for start in textKey.indices {
        for end in textKey.indices where end >= start {
            let key = String(textKey[start...end])
            #expect(gate.matchesKey(key) == textKey.contains(key))
        }
    }
}

@Test
func terminologyNormalizerKeepsUnicodeStressProbesStable() {
    let zwjFamily = "👨\u{200D}👩\u{200D}👧"
    let entries = [
        TerminologyEntry(canonical: "ChatType", aliases: []),
        TerminologyEntry(canonical: "ChatTypes", aliases: []),
        TerminologyEntry(canonical: "chat type", aliases: []),
        TerminologyEntry(canonical: zwjFamily, aliases: ["family emoji"]),
        TerminologyEntry(canonical: "❤\u{FE0F}", aliases: []),
        TerminologyEntry(canonical: "❤", aliases: []),
        TerminologyEntry(canonical: "🇨🇳", aliases: ["china flag"]),
        TerminologyEntry(canonical: "각", aliases: []),
        TerminologyEntry(canonical: "각", aliases: []),
        TerminologyEntry(canonical: "café", aliases: []),
        TerminologyEntry(canonical: "cafe\u{301}", aliases: []),
        TerminologyEntry(canonical: "Ｃｈａｔ", aliases: ["full width chat"]),
        TerminologyEntry(canonical: "聊天记录", aliases: []),
        TerminologyEntry(canonical: "／Users／example", aliases: []),
        TerminologyEntry(canonical: "https://example.com/a?b=1", aliases: []),
        TerminologyEntry(
            type: .correction,
            original: "gpt4o",
            replacement: "GPT-4o",
            aliases: [],
            source: "user",
            usageCount: 0,
            createdAt: "2026-10-19T00:00:00Z"
        ),
    ]
    let normalizer = TerminologyNormalizer()

    let family = normalizer.normalize(
        text: "family \(zwjFamily) 和 ❤\u{FE0F} 与 ❤ 都要保留。",
        importedEntries: entries,
        hintTerms: []
    )
    #expect(family.text == "family \(zwjFamily) 和 ❤\u{FE0F} 与 ❤ 都要保留。")
    #expect(family.applied == false)

    let hangul = normalizer.normalize(
        text: "韩国语 각 与拆分的 각 都测试一下。",
        importedEntries: entries,
        hintTerms: []
    )
    #expect(hangul.text == "韩国语 각 与拆分的 각 都测试一下。")

    let correction = normalizer.normalize(
        text: "请把 gpt4o 写成规范形式，然后再说 chat type 与 ChatTypes 的差别。",
        importedEntries: entries,
        hintTerms: []
    )
    #expect(correction.text == "请把 GPT-4o 写成规范形式，然后再说 chat type 与 ChatTypes 的差别。")
    #expect(correction.exactReplacementCount == 1)

    let width = normalizer.normalize(
        text: "全角 Ｃｈａｔ 与半角 Chat 以及中文 聊天记录 都出现一次。",
        importedEntries: entries,
        hintTerms: []
    )
    #expect(width.text == "全角 Ｃｈａｔ 与半角 Chat 以及中文 聊天记录 都出现一次。")
}

private actor NameHintCapturingPolisher: TextPolishing {
    private(set) var receivedHints: [String] = []
    func polish(text: String, terminologyEntries: [TerminologyEntry], hintTerms: [String]) async throws -> TextPolishResult {
        receivedHints = hintTerms
        return TextPolishResult(text: "请联系陶星澜。", provider: .chatGPTAuth, applied: true,
            estimatedInputTokens: 10, estimatedOutputTokens: 10)
    }
}

@Test func fullTranscriptPolishReceivesRelatedPersonalNameCandidates() async throws {
    let polisher = NameHintCapturingPolisher()
    let pipeline = DictationPipeline(transcriber: FakeTranscriber(result: TranscriptionResult(text: "请联系陶新蓝。",
        metrics: TranscriptionMetrics(provider: .chatGPTManagedAuth, audioDurationMs: 1_000, audioBytes: 100,
                                      authMs: 0, transcribeMs: 1, promptIncluded: true))),
        normalizer: TerminologyNormalizer(),
        importedEntries: [TerminologyEntry(canonical: "陶星澜", aliases: [], source: "macos-contacts")],
        hintTerms: ["pstack"], textPolisher: polisher)
    let result = try await pipeline.prepare(audio: RecordedAudio(fileURL: URL(fileURLWithPath: "/fake.wav"), durationMs: 1_000))
    let hints = await polisher.receivedHints
    #expect(hints == ["pstack", "陶星澜"])
    #expect(result.rawText == "请联系陶新蓝。")
    #expect(result.finalText == "请联系陶星澜。")
}

@Test(arguments: ["off", "failure", "truncated", "success"])
func replacementRunsOnceAtFinalOutputAcrossPolishBranches(branch: String) async throws {
    let text = "alpha 这是需要完整保留的语音转写文本。" + String(repeating: "请保留这里的全部工作内容和验收要求。", count: 9)
    let corrections = [
        TerminologyEntry(type: .correction, original: "alpha", replacement: "beta", aliases: [], source: "user", usageCount: 0, createdAt: "test"),
        TerminologyEntry(type: .correction, original: "beta", replacement: "gamma", aliases: [], source: "user", usageCount: 0, createdAt: "test")
    ]
    let polisher: (any TextPolishing)? = branch == "off" ? nil : FakeTextPolisher(result: branch == "failure"
        ? .failure(FakePolishError())
        : .success(TextPolishResult(text: branch == "truncated" ? "短句" : text, provider: .chatGPTAuth,
            applied: true, estimatedInputTokens: 10, estimatedOutputTokens: 10)))
    let pipeline = DictationPipeline(transcriber: FakeTranscriber(result: TranscriptionResult(text: text,
        metrics: .init(provider: .chatGPTManagedAuth, audioDurationMs: 2_000, audioBytes: 1000, authMs: 0, transcribeMs: 0, promptIncluded: false))),
        normalizer: TerminologyNormalizer(), importedEntries: corrections, hintTerms: [], textPolisher: polisher)
    if branch == "failure" || branch == "truncated" {
        do {
            _ = try await pipeline.prepare(audio: RecordedAudio(fileURL: URL(fileURLWithPath: "/tmp/fake.wav"), durationMs: 2_000))
            Issue.record("Failed polish must block correction and injection")
        } catch let failure as DictationPipelineFailure {
            #expect(failure.stages.finalText == nil)
            #expect(failure.stages.asrText == text)
        }
        return
    }
    let result = try await pipeline.prepare(audio: RecordedAudio(fileURL: URL(fileURLWithPath: "/tmp/fake.wav"), durationMs: 2_000))
    #expect(result.finalText.hasPrefix("beta"))
    #expect(!result.finalText.contains("gamma"))
    #expect(result.exactReplacementCount == 1)

}

@Test func aPartialSecondPolishAttemptDoesNotEraseTheFirstOutput() async throws {
    let raw = String(repeating:"请保留这一条完整要求。",count:12)
    let polisher = SequencedTextPolisher(results:[
        .success(TextPolishResult(text:"短句。",provider:.doubaoIME,applied:true,estimatedInputTokens:0,estimatedOutputTokens:0)),
        .failure(DoubaoOrganizationFailure(partialText:"第二次未完",detail:"流中断"))])
    let pipeline = DictationPipeline(transcriber:FakeTranscriber(result:TranscriptionResult(text:raw,
        metrics:.init(provider:.doubaoIME,audioDurationMs:1,audioBytes:1,authMs:0,transcribeMs:0,promptIncluded:false))),
        normalizer:TerminologyNormalizer(),importedEntries:[],hintTerms:[],textPolisher:polisher)
    do {
        _ = try await pipeline.prepare(audio:RecordedAudio(fileURL:URL(fileURLWithPath:"/tmp/not-read.wav"),durationMs:1))
        Issue.record("Partial polish must not produce a final result")
    } catch let failure as DictationPipelineFailure {
        #expect(failure.stages.polishOutputs == ["短句。","第二次未完"])
        #expect(failure.stages.finalText == nil)
    }
}
