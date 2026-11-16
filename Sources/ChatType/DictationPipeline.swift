import Foundation

protocol Transcriber: Sendable {
    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult
}

protocol DictationPreparing: Sendable {
    func prepare(audio: RecordedAudio) async throws -> PreparedDictation
}

protocol TranscriptNormalizing: Sendable {
    func normalize(
        text: String,
        importedEntries: [TerminologyEntry],
        hintTerms: [String]
    ) -> NormalizationResult
}

struct DictationMetrics: Sendable, Equatable {
    let transcription: TranscriptionMetrics
    let normalizationMs: Int
    let polishMs: Int
    let textPolishAttempted: Bool
    let textPolishProvider: TextPolishProviderID?
    let textPolishErrorMessage: String?
    let estimatedPolishInputTokens: Int
    let estimatedPolishOutputTokens: Int
    let timing: ProcessingTimingSnapshot?

    init(
        transcription: TranscriptionMetrics,
        normalizationMs: Int,
        polishMs: Int = 0,
        textPolishAttempted: Bool = false,
        textPolishProvider: TextPolishProviderID? = nil,
        textPolishErrorMessage: String? = nil,
        estimatedPolishInputTokens: Int = 0,
        estimatedPolishOutputTokens: Int = 0,
        timing: ProcessingTimingSnapshot? = nil
    ) {
        self.transcription = transcription
        self.normalizationMs = normalizationMs
        self.polishMs = polishMs
        self.textPolishAttempted = textPolishAttempted
        self.textPolishProvider = textPolishProvider
        self.textPolishErrorMessage = textPolishErrorMessage
        self.estimatedPolishInputTokens = estimatedPolishInputTokens
        self.estimatedPolishOutputTokens = estimatedPolishOutputTokens
        self.timing = timing
    }
}

struct PreparedDictation: Sendable, Equatable {
    let rawText: String
    let finalText: String
    let normalizationApplied: Bool
    let exactReplacementCount: Int
    let fuzzyReplacementCount: Int
    let metrics: DictationMetrics
    var stages: DictationStageAudit? = nil
}

struct DictationPipeline: DictationPreparing {
    let transcriber: any Transcriber
    let normalizer: any TranscriptNormalizing
    let importedEntries: [TerminologyEntry]
    let hintTerms: [String]
    var textPolisher: (any TextPolishing)?
    var alignmentEnabled: Bool = true
    var correctionsEnabled: Bool = true
    var audit: (@Sendable (DictationStageAudit) throws -> Void)? = nil

    func prepare(audio: RecordedAudio) async throws -> PreparedDictation {
        let trace = ProcessingTiming()
        return try await ProcessingTrace.$current.withValue(trace) {
            try await prepareMeasured(audio: audio, trace: trace)
        }
    }

    private func prepareMeasured(audio: RecordedAudio, trace: ProcessingTiming) async throws -> PreparedDictation {
        let transcription = try await transcriber.transcribe(audio)
        try Task.checkCancellation()
        var stages = DictationStageAudit(asrText: transcription.text)
        stages.asrRequestID = transcription.metrics.protocolRequestID
        stages.asrSessions = transcription.metrics.protocolSessions
        stages.partialAudio = audio.isPartialReplay
        if transcription.metrics.provider == .doubaoIME {
            stages.protocolVersion = "DoubaoIME-1.1.0/v2/Opus-16000"
        }
        try audit?(stages)
        // Identity rules are literal locks; retain them during alignment and text polish.
        let alignmentEntries = AlignmentVocabularyCache.shared.vocabulary(for: importedEntries)
            .entries(correctionsEnabled: correctionsEnabled)
        let namesStarted = ProcessingTiming.now()
        let relatedHints = hintTerms + PersonalNameHints.relatedTerms(in: transcription.text, entries: importedEntries)
        trace.recordStage("nameLookup", since: namesStarted)
        let normalizationStarted = DispatchTime.now().uptimeNanoseconds
        let prePolish = (alignmentEnabled ? normalizer : PassthroughNormalizer()).normalize(
            text: transcription.text,
            importedEntries: alignmentEntries,
            hintTerms: hintTerms
        )
        trace.recordStage("preNormalization", since: normalizationStarted)
        var normalizationMs = elapsedMilliseconds(since: normalizationStarted)

        var finalText = prePolish.text
        var textPolishAttempted = false
        var textPolishProvider: TextPolishProviderID?
        var textPolishErrorMessage: String?
        var estimatedPolishInputTokens = 0
        var estimatedPolishOutputTokens = 0
        var polishMs = 0

        if let textPolisher {
            stages.polishInput = prePolish.text
            try audit?(stages)
            textPolishAttempted = true
            let polishStarted = DispatchTime.now().uptimeNanoseconds
            do {
                var polished = try await textPolisher.polish(
                    text: prePolish.text,
                    terminologyEntries: alignmentEntries,
                    hintTerms: relatedHints
                )
                stages.polishOutput = polished.providerText ?? polished.text
                stages.polishOutputs = [polished.providerText ?? polished.text]
                stages.polishProtectionReason = polished.protectionReason
                try audit?(stages)

                if isSuspiciousPolishTruncation(original: prePolish.text, polished: polished.text) {
                    // The same long-form request can occasionally return a short but otherwise
                    // successful response. Retry once before using the existing safe fallback.
                    polished = try await textPolisher.polish(
                        text: prePolish.text,
                        terminologyEntries: alignmentEntries,
                        hintTerms: relatedHints
                    )
                    stages.polishOutput = polished.providerText ?? polished.text
                    stages.polishOutputs?.append(polished.providerText ?? polished.text)
                    stages.polishProtectionReason = polished.protectionReason
                    try audit?(stages)
                }
                polishMs = elapsedMilliseconds(since: polishStarted)
                estimatedPolishInputTokens = polished.estimatedInputTokens
                estimatedPolishOutputTokens = polished.estimatedOutputTokens

                if isSuspiciousPolishTruncation(original: prePolish.text, polished: polished.text) {
                    throw TextPolishError.invalidResponse
                } else {
                    textPolishProvider = polished.provider
                    let postPolishStarted = DispatchTime.now().uptimeNanoseconds
                    let postPolish = (alignmentEnabled ? normalizer : PassthroughNormalizer()).normalize(text: polished.text, importedEntries: alignmentEntries, hintTerms: relatedHints)
                    trace.recordStage("postNormalization", since: postPolishStarted)
                    normalizationMs += elapsedMilliseconds(since: postPolishStarted)
                    finalText = postPolish.text
                }
            } catch is CancellationError { throw CancellationError()
            } catch let error as RecorderError { throw error
            } catch {
                polishMs = elapsedMilliseconds(since: polishStarted)
                textPolishErrorMessage = error.localizedDescription
                stages.error = error.localizedDescription
                if let partial = error as? DoubaoOrganizationFailure {
                    stages.polishOutput = partial.partialText
                    stages.polishOutputs = (stages.polishOutputs ?? []) + [partial.partialText]
                }
                try audit?(stages)
                throw DictationPipelineFailure(stages: stages, detail: error.localizedDescription)
            }
        }

        let corrections = TerminologyNormalizer().applyCorrections(text: finalText, entries: correctionsEnabled ? importedEntries : [])
        finalText = corrections.text
        stages.finalText = formatted(finalText, trace: trace)
        try Task.checkCancellation()
        try audit?(stages)
        return PreparedDictation(
            rawText: transcription.text,
            finalText: stages.finalText!,
            normalizationApplied: prePolish.applied || finalText != prePolish.text,
            exactReplacementCount: prePolish.exactReplacementCount + corrections.exactReplacementCount,
            fuzzyReplacementCount: prePolish.fuzzyReplacementCount,
            metrics: DictationMetrics(
                transcription: transcription.metrics,
                normalizationMs: normalizationMs,
                polishMs: polishMs,
                textPolishAttempted: textPolishAttempted,
                textPolishProvider: textPolishProvider,
                textPolishErrorMessage: textPolishErrorMessage,
                estimatedPolishInputTokens: estimatedPolishInputTokens,
                estimatedPolishOutputTokens: estimatedPolishOutputTokens,
                            timing: trace.snapshot(ready: true)
            ),
            stages: stages
        )
    }

    private func formatted(_ text: String, trace: ProcessingTiming) -> String {
        let start = ProcessingTiming.now()
        let result = DictationTextFormatter().format(text)
        trace.recordStage("formatting", since: start)
        return result
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func isSuspiciousPolishTruncation(original: String, polished: String) -> Bool {
        let originalCount = meaningfulCharacterCount(original)
        let polishedCount = meaningfulCharacterCount(polished)

        guard originalCount >= 80 else {
            return false
        }
        guard polishedCount < max(40, Int(Double(originalCount) * 0.35)) else {
            return false
        }

        let originalTerminators = sentenceTerminatorCount(original)
        let polishedTerminators = sentenceTerminatorCount(polished)
        return originalTerminators >= 3 && polishedTerminators <= 1
    }

    private func meaningfulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
    }

    private func sentenceTerminatorCount(_ text: String) -> Int {
        text.reduce(0) { count, character in
            "。！？!?；;\n".contains(character) ? count + 1 : count
        }
    }
}

struct PassthroughNormalizer: TranscriptNormalizing {
    func normalize(text: String, importedEntries: [TerminologyEntry], hintTerms: [String]) -> NormalizationResult {
        NormalizationResult(text: text, applied: false, exactReplacementCount: 0, fuzzyReplacementCount: 0)
    }
}
