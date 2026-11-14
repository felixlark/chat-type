import Foundation

struct DictationStageAudit: Codable, Sendable, Equatable {
    var asrText: String?
    var polishInput: String?
    var polishOutput: String?
    var finalText: String?
    var error: String?
    var polishOutputs: [String]? = nil
    var asrRequestID: String? = nil
    var protocolVersion: String? = nil
    var partialAudio: Bool? = nil
    var asrPartialText: String? = nil

    func merging(_ update: Self) -> Self {
        var result = self
        result.asrText = update.asrText ?? asrText
        result.polishInput = update.polishInput ?? polishInput
        result.polishOutput = update.polishOutput ?? polishOutput
        result.finalText = update.finalText ?? finalText
        result.error = update.error ?? error
        result.polishOutputs = update.polishOutputs ?? polishOutputs
        result.asrRequestID = update.asrRequestID ?? asrRequestID
        result.protocolVersion = update.protocolVersion ?? protocolVersion
        result.partialAudio = update.partialAudio ?? partialAudio
        result.asrPartialText = update.asrPartialText ?? asrPartialText
        return result
    }
}

struct DictationAttempt: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    var snapshot: TranscriptionConfig
    var stages: DictationStageAudit
    var outcome: String
    var schemaVersion: Int? = 1
}

struct DictationPipelineFailure: LocalizedError, Sendable {
    let stages: DictationStageAudit
    let detail: String
    var errorDescription: String? { "处理未完成；原声与已完成阶段已保留。\(detail)" }
}
