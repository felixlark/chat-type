import Foundation

enum HistoryStagePosition: Int, CaseIterable, Sendable, Identifiable {
    case audio
    case asr
    case alignment
    case polish
    case finalization
    case output

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .audio: return "原声"
        case .asr: return "转写"
        case .alignment: return "对齐"
        case .polish: return "润色"
        case .finalization: return "终稿"
        case .output: return "输出"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .asr: return "text.alignleft"
        case .alignment: return "character.book.closed"
        case .polish: return "sparkles"
        case .finalization: return "doc.text"
        case .output: return "arrow.right.to.line"
        }
    }
}

enum HistoryStageState: String, Sendable, Equatable {
    case complete
    case skipped
    case failed
    case attention
    case pending
    case unavailable
}

struct HistoryStagePresentation: Identifiable, Sendable, Equatable {
    let position: HistoryStagePosition
    let state: HistoryStageState
    let detail: String

    var id: Int { position.rawValue }
}

enum HistoryStatusTone: Sendable, Equatable {
    case neutral
    case success
    case attention
    case failure
    case active
}

struct HistoryStatusPresentation: Sendable, Equatable {
    let label: String
    let detail: String?
    let tone: HistoryStatusTone
}

enum HistoryTextArtifactKind: String, Sendable, Identifiable {
    case asr
    case aligned
    case polish
    case final

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asr: return "ASR 原文"
        case .aligned: return "对齐后 · 润色输入"
        case .polish: return "润色输出"
        case .final: return "最终化结果"
        }
    }
}

struct HistoryTextArtifact: Identifiable, Sendable, Equatable {
    let kind: HistoryTextArtifactKind
    let text: String?
    let note: String?
    let isFailurePartial: Bool

    var id: String { kind.rawValue }
    var isAvailable: Bool { text?.isEmpty == false }
}

struct HistoryAttemptOption: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let status: HistoryStatusPresentation
    let isDiagnostic: Bool
}

struct HistoryRecordPresentation: Sendable, Equatable {
    let record: RecoveryRecord
    let selectedAttempt: DictationAttempt?
    let selectedAttemptID: UUID?
    let attemptOptions: [HistoryAttemptOption]
    let status: HistoryStatusPresentation
    let stages: [HistoryStagePresentation]
    let artifacts: [HistoryTextArtifact]
    let legacy: Bool
    let title: String
    let routeSummary: String
    let canRerunTranscription: Bool
    let canRerunPolish: Bool

    init(record: RecoveryRecord, selectedAttemptID: UUID?, audioAvailable: Bool) {
        self.record = record
        let attempts = record.attempts ?? []
        let selected = attempts.first(where: { $0.id == selectedAttemptID })
            ?? attempts.last(where: { $0.resolvedKind == .full })
            ?? attempts.last
        self.selectedAttempt = selected
        self.selectedAttemptID = selected?.id
        self.legacy = attempts.isEmpty
        self.attemptOptions = attempts.enumerated().map { index, attempt in
            let status = HistoryStatusPresentation.make(
                outcome: attempt.outcome,
                error: attempt.stages.error
            )
            return HistoryAttemptOption(
                id: attempt.id,
                title: "尝试 \(index + 1) · \(status.label)",
                status: status,
                isDiagnostic: attempt.resolvedKind != .full
            )
        }

        let effectiveOutcome = selected?.outcome ?? record.outcome
        let effectiveError = selected?.stages.error ?? record.errorMessage
        self.status = HistoryStatusPresentation.make(outcome: effectiveOutcome, error: effectiveError)
        self.stages = selected.map {
            Self.makeStages(record: record, attempt: $0, audioAvailable: audioAvailable)
        } ?? []
        self.artifacts = Self.makeArtifacts(record: record, attempt: selected)

        let summary = selected?.stages.finalText
            ?? selected?.stages.polishOutput
            ?? selected?.stages.asrText
            ?? record.asrText
            ?? record.polishText
            ?? record.errorMessage
            ?? "未命名语音"
        self.title = Self.collapse(summary, limit: 90)

        let snapshot = selected?.snapshot ?? record.snapshot
        let recognition = snapshot?.provider.title ?? "识别路线未记录"
        let polish: String
        if let snapshot {
            polish = snapshot.textPolish.isEnabled ? snapshot.textPolish.provider.title : "润色关闭"
        } else {
            polish = "润色路线未记录"
        }
        self.routeSummary = "\(recognition) · \(polish)"

        let asrText = selected?.stages.asrText
            ?? selected?.stages.asrPartialText
            ?? record.asrText
        self.canRerunTranscription = audioAvailable
        self.canRerunPolish = asrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var formattedDuration: String {
        Self.formatDuration(record.audioDurationMs)
    }

    var selectedAttemptIsDiagnostic: Bool {
        selectedAttempt?.resolvedKind != .full && selectedAttempt != nil
    }

    static func collapse(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    static func formatDuration(_ durationMs: Int) -> String {
        let seconds = max(0, durationMs) / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func textDifferenceSummary(from old: String?, to new: String?) -> String? {
        guard let old, let new, old != new else { return nil }
        let difference = Array(new).difference(from: Array(old))
        let insertions = difference.insertions.count
        let removals = difference.removals.count
        guard insertions + removals > 0 else { return "文本未变化" }
        return "新增 \(insertions) 字符 · 删除 \(removals) 字符"
    }

    private static func makeStages(
        record: RecoveryRecord,
        attempt: DictationAttempt,
        audioAvailable: Bool
    ) -> [HistoryStagePresentation] {
        let stages = attempt.stages
        let snapshot = attempt.snapshot
        let hasASR = stages.asrText?.isEmpty == false
        let hasPartialASR = stages.asrPartialText?.isEmpty == false
        let hasAligned = stages.polishInput?.isEmpty == false
        let hasPolish = stages.polishOutput?.isEmpty == false
        let hasFinal = stages.finalText?.isEmpty == false

        let audioState: HistoryStageState = audioAvailable ? .complete : .attention
        let asrState: HistoryStageState
        let asrDetail: String
        if hasASR {
            asrState = .complete
            asrDetail = "\(stages.asrText?.count ?? 0) 字"
        } else if hasPartialASR {
            asrState = .attention
            asrDetail = "部分转写"
        } else if attempt.outcome == "error" {
            asrState = .failed
            asrDetail = "未完成"
        } else {
            asrState = .unavailable
            asrDetail = "未生成"
        }

        let alignmentState: HistoryStageState
        let alignmentDetail: String
        if !snapshot.terminologyAlignmentEnabled {
            alignmentState = .skipped
            alignmentDetail = "已关闭"
        } else if hasAligned {
            alignmentState = .complete
            alignmentDetail = "已对齐"
        } else if hasASR {
            alignmentState = .complete
            alignmentDetail = "已执行 · 未归档中间文本"
        } else {
            alignmentState = .unavailable
            alignmentDetail = "未执行"
        }

        let polishState: HistoryStageState
        let polishDetail: String
        if !snapshot.textPolish.isEnabled {
            polishState = .skipped
            polishDetail = "已关闭"
        } else if stages.error != nil && hasPolish {
            polishState = .failed
            polishDetail = "部分输出 · 未采用"
        } else if hasPolish {
            polishState = .complete
            polishDetail = snapshot.textPolish.provider.title
        } else if stages.error != nil {
            polishState = .failed
            polishDetail = "未完成"
        } else {
            polishState = .unavailable
            polishDetail = "未生成"
        }

        let finalState: HistoryStageState
        let finalDetail: String
        if hasFinal && stages.error == nil {
            finalState = .complete
            finalDetail = "\(stages.finalText?.count ?? 0) 字"
        } else if stages.error != nil {
            finalState = .failed
            finalDetail = "未生成"
        } else {
            finalState = .unavailable
            finalDetail = "未生成"
        }

        let outputState: HistoryStageState
        let outputDetail: String
        if attempt.resolvedKind != .full {
            outputState = .skipped
            outputDetail = "仅诊断"
        } else {
            let outputStatus = HistoryStatusPresentation.make(
                outcome: attempt.outcome,
                error: stages.error
            )
            switch outputStatus.tone {
            case .success:
                outputState = .complete
            case .attention:
                outputState = .attention
            case .failure:
                outputState = .failed
            case .active:
                outputState = .pending
            case .neutral:
                outputState = .skipped
            }
            outputDetail = outputStatus.label
        }

        return [
            .init(position: .audio, state: audioState, detail: audioAvailable ? formatDuration(record.audioDurationMs) : "音频缺失"),
            .init(position: .asr, state: asrState, detail: asrDetail),
            .init(position: .alignment, state: alignmentState, detail: alignmentDetail),
            .init(position: .polish, state: polishState, detail: polishDetail),
            .init(position: .finalization, state: finalState, detail: finalDetail),
            .init(position: .output, state: outputState, detail: outputDetail)
        ]
    }

    private static func makeArtifacts(
        record: RecoveryRecord,
        attempt: DictationAttempt?
    ) -> [HistoryTextArtifact] {
        guard let attempt else {
            return [
                HistoryTextArtifact(kind: .asr, text: record.asrText, note: "旧记录", isFailurePartial: false),
                HistoryTextArtifact(kind: .polish, text: record.polishText, note: "旧版润色文本，未区分最终化", isFailurePartial: false)
            ]
        }

        let stages = attempt.stages
        let alignmentNote: String?
        if stages.polishInput?.isEmpty != false && attempt.snapshot.terminologyAlignmentEnabled && stages.asrText?.isEmpty == false {
            alignmentNote = "对齐已执行，中间文本未单独归档"
        } else if !attempt.snapshot.terminologyAlignmentEnabled {
            alignmentNote = "术语对齐已关闭"
        } else {
            alignmentNote = nil
        }

        let polishNote: String?
        let polishFailure: Bool
        if !attempt.snapshot.textPolish.isEnabled {
            polishNote = "润色已关闭"
            polishFailure = false
        } else if stages.error != nil && stages.polishOutput?.isEmpty == false {
            polishNote = "失败前部分输出 · 未采用"
            polishFailure = true
        } else if let reason = stages.polishProtectionReason {
            polishNote = "安全保护：\(reason)"
            polishFailure = false
        } else {
            polishNote = nil
            polishFailure = false
        }

        let finalNote: String?
        if stages.finalText?.isEmpty == false {
            if stages.polishOutput == stages.finalText {
                finalNote = "终稿未再改写"
            } else {
                finalNote = textDifferenceSummary(from: stages.polishOutput, to: stages.finalText)
            }
        } else {
            finalNote = "未生成"
        }

        return [
            HistoryTextArtifact(kind: .asr, text: stages.asrText ?? stages.asrPartialText, note: stages.asrText == nil && stages.asrPartialText != nil ? "部分转写" : nil, isFailurePartial: false),
            HistoryTextArtifact(kind: .aligned, text: stages.polishInput, note: alignmentNote, isFailurePartial: false),
            HistoryTextArtifact(kind: .polish, text: stages.polishOutput, note: polishNote, isFailurePartial: polishFailure),
            HistoryTextArtifact(kind: .final, text: stages.finalText, note: finalNote, isFailurePartial: false)
        ]
    }
}

extension HistoryStatusPresentation {
    static func make(outcome: String, error: String?) -> Self {
        switch outcome {
        case "pasted":
            return .init(label: "已粘贴", detail: nil, tone: .success)
        case "clipboard":
            return .init(label: "已复制", detail: nil, tone: .success)
        case "recording":
            return .init(label: "正在录音", detail: nil, tone: .active)
        case "recorded":
            return .init(label: "已保存原声", detail: nil, tone: .neutral)
        case "processing":
            return .init(label: "处理中", detail: nil, tone: .active)
        case "readyToInject":
            return .init(label: "输出待核对", detail: "终稿已保存，输出状态未确认", tone: .attention)
        case "outputUnknown":
            return .init(label: "输出未知", detail: "请先核对原文档", tone: .attention)
        case "cancelled":
            return .init(label: "已取消", detail: nil, tone: .neutral)
        case "interrupted":
            return .init(label: "已中断", detail: "原声已保留", tone: .attention)
        case "asrComplete":
            return .init(label: "仅转写完成", detail: nil, tone: .neutral)
        case "polishComplete":
            return .init(label: "仅润色完成", detail: nil, tone: .neutral)
        case "error":
            return .init(label: "处理失败", detail: error, tone: .failure)
        default:
            return .init(label: outcome, detail: error, tone: .neutral)
        }
    }
}

struct RecoveryHistorySummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let audioFileName: String
    let audioDurationMs: Int
    let appName: String?
    let appBundleIdentifier: String?
    let outcome: String
    let errorMessage: String?
    let asrText: String?
    let polishText: String?
    let primaryAttemptID: UUID?
    let attemptCount: Int
    let stageStates: [HistoryStageState]
    let audioAvailable: Bool
    let searchableText: String

    var status: HistoryStatusPresentation {
        .make(outcome: outcome, error: errorMessage)
    }

    var displayTitle: String {
        HistoryRecordPresentation.collapse(
            asrText ?? polishText ?? errorMessage ?? "未命名语音",
            limit: 110
        )
    }

    var formattedDuration: String {
        HistoryRecordPresentation.formatDuration(audioDurationMs)
    }

    init(record: RecoveryRecord, recoveryDirectoryURL: URL) {
        id = record.id
        timestamp = record.timestamp
        audioFileName = record.audioFileName
        audioDurationMs = record.audioDurationMs
        appName = record.appName
        appBundleIdentifier = record.appBundleIdentifier
        outcome = record.outcome
        errorMessage = record.errorMessage
        asrText = record.asrText
        polishText = record.polishText
        attemptCount = record.attempts?.count ?? 0
        let audioURL = record.audioURL(baseDirectory: recoveryDirectoryURL)
        audioAvailable = FileManager.default.fileExists(atPath: audioURL.path)

        let primary = record.attempts?.last(where: { $0.resolvedKind == .full })
            ?? record.attempts?.last
        primaryAttemptID = primary?.id
        let presentation = HistoryRecordPresentation(
            record: record,
            selectedAttemptID: primary?.id,
            audioAvailable: audioAvailable
        )
        stageStates = presentation.stages.isEmpty
            ? Array(repeating: .unavailable, count: HistoryStagePosition.allCases.count)
            : presentation.stages.map(\.state)
        searchableText = [
            record.asrText,
            record.polishText,
            record.errorMessage,
            record.appName,
            record.attempts?.flatMap { attempt in
                [
                    attempt.stages.asrText,
                    attempt.stages.polishInput,
                    attempt.stages.polishOutput,
                    attempt.stages.finalText
                ].compactMap { $0 }
            }.joined(separator: "\n")
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
    }
}

struct RecoveryHistoryIndex: Sendable, Equatable {
    let records: [RecoveryHistorySummary]
    let unreadableCount: Int
}
