import Foundation

enum HistoryStagePosition: Int, CaseIterable, Sendable, Identifiable, Hashable {
    case audio
    case asr
    case alignment
    case polish
    case correction
    case output

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .audio: return "原声"
        case .asr: return "转写"
        case .alignment: return "对齐"
        case .polish: return "润色"
        case .correction: return "校正"
        case .output: return "输出"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .asr: return "text.alignleft"
        case .alignment: return "character.book.closed"
        case .polish: return "sparkles"
        case .correction: return "text.badge.checkmark"
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
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asr: return "ASR 原文"
        case .aligned: return "对齐后"
        case .output: return "润色输出"
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

struct HistoryTextChange: Identifiable, Sendable, Equatable {
    let id: Int
    let from: String
    let to: String

    var display: String {
        if from.isEmpty { return "新增「\(to)」" }
        if to.isEmpty { return "删除「\(from)」" }
        return "\(from) → \(to)"
    }
}

struct HistoryTextChangeSummary: Sendable, Equatable {
    let changes: [HistoryTextChange]

    var count: Int { changes.count }

    var uniqueTermCount: Int {
        Set(changes.map { "\($0.from)\u{1F}\($0.to)" }).count
    }

    var shortDetail: String {
        guard !changes.isEmpty else { return "无词级变化" }
        let countText = count == uniqueTermCount ? "\(count) 处" : "\(count) 处 · \(uniqueTermCount) 个词"
        return "\(countText)：\(samples)"
    }

    var samples: String {
        let sample = changes.prefix(3).map(\.display).joined(separator: "；")
        return changes.count > 3 ? "\(sample)…" : sample
    }
}

enum HistoryTextChangeAnalyzer {
    static func summarize(from old: String?, to new: String?) -> HistoryTextChangeSummary {
        guard let old, let new, old != new else {
            return HistoryTextChangeSummary(changes: [])
        }
        let oldTokens = tokens(in: old)
        let newTokens = tokens(in: new)
        guard oldTokens != newTokens else {
            return HistoryTextChangeSummary(changes: [])
        }

        let difference = newTokens.difference(from: oldTokens)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }

        var groups: [(from: String, to: String)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            if oldIndex < oldTokens.count, !removed.contains(oldIndex),
               newIndex < newTokens.count, !inserted.contains(newIndex) {
                oldIndex += 1
                newIndex += 1
                continue
            }

            let oldStart = oldIndex
            let newStart = newIndex
            while oldIndex < oldTokens.count, removed.contains(oldIndex) {
                oldIndex += 1
            }
            while newIndex < newTokens.count, inserted.contains(newIndex) {
                newIndex += 1
            }

            if oldIndex == oldStart, newIndex == newStart {
                if oldIndex < oldTokens.count { oldIndex += 1 }
                if newIndex < newTokens.count { newIndex += 1 }
                continue
            }

            let from = render(Array(oldTokens[oldStart..<oldIndex]))
            let to = render(Array(newTokens[newStart..<newIndex]))
            groups.append((from, to))
        }

        return HistoryTextChangeSummary(changes: groups.enumerated().map {
            HistoryTextChange(id: $0.offset, from: $0.element.from, to: $0.element.to)
        })
    }

    private static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            result.append(word)
            word = ""
        }

        for character in text {
            if isCJK(character) {
                flush()
                result.append(String(character))
            } else if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func render(_ tokens: [String]) -> String {
        var result = ""
        for token in tokens {
            if needsSpace(between: result.last, and: token.first) {
                result.append(" ")
            }
            result.append(token)
        }
        return result
    }

    private static func needsSpace(between lhs: Character?, and rhs: Character?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.isASCII && rhs.isASCII && (lhs.isLetter || lhs.isNumber) && (rhs.isLetter || rhs.isNumber)
    }
}

struct HistoryRecordPresentation: Sendable, Equatable {
    let record: RecoveryRecord
    let selectedAttempt: DictationAttempt?
    let selectedAttemptID: UUID?
    let attemptOptions: [HistoryAttemptOption]
    let status: HistoryStatusPresentation
    let stages: [HistoryStagePresentation]
    let artifacts: [HistoryTextArtifact]
    let alignmentChanges: HistoryTextChangeSummary
    let correctionChanges: HistoryTextChangeSummary
    let legacy: Bool
    let title: String
    let routeSummary: String

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
        let selectedStages = selected?.stages
        self.alignmentChanges = HistoryTextChangeAnalyzer.summarize(
            from: selectedStages?.asrText ?? record.asrText,
            to: selectedStages?.polishInput
        )
        self.correctionChanges = HistoryTextChangeAnalyzer.summarize(
            from: selectedStages?.correctionInput ?? selectedStages?.polishOutput,
            to: selectedStages?.finalText
        )

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
        switch selected?.resolvedKind {
        case .asrOnly:
            self.routeSummary = "仅转写 · \(recognition)"
        case .polishOnly:
            self.routeSummary = "仅润色 · \(polish)"
        default:
            self.routeSummary = "\(recognition) · \(polish)"
        }

    }

    var formattedDuration: String {
        Self.formatDuration(record.audioDurationMs)
    }

    func stageNarrative(for position: HistoryStagePosition) -> String {
        guard let stage = stages.first(where: { $0.position == position }) else {
            return "旧记录未保存分阶段明细。"
        }
        let snapshot = selectedAttempt?.snapshot ?? record.snapshot
        switch position {
        case .audio:
            return stage.state == .complete
                ? "本机原始 WAV · \(formattedDuration) · 可播放"
                : "原始 WAV 缺失；文本仍可查看和复制。"
        case .asr:
            if stage.state == .skipped {
                let count = artifacts.first(where: { $0.kind == .asr })?.text?.count ?? 0
                return "仅润色尝试；复用已有转写 · \(count) 字。"
            }
            if stage.state == .failed {
                return "转写失败；原始录音已保留。"
            }
            if stage.state == .unavailable {
                return "这次尝试没有生成转写文本。"
            }
            guard let snapshot else { return "旧记录未保存识别路线。" }
            let count = artifacts.first(where: { $0.kind == .asr })?.text?.count ?? 0
            let partial = selectedAttempt?.stages.partialAudio == true ? " · 部分录音" : ""
            let model = snapshot.provider == .openAICompatible
                ? snapshot.provider.modelLabel(config: snapshot)
                : "\(snapshot.provider.modelLabel(config: snapshot)) · 服务端选择模型"
            return "\(model) · \(count) 字\(partial)"
        case .alignment:
            if stage.state == .skipped {
                return selectedAttempt?.resolvedKind == .asrOnly
                    ? "仅转写尝试；未执行对齐。"
                    : "已关闭；转写文本直接进入下一阶段。"
            }
            if stage.state == .unavailable {
                return "未执行；没有可对齐的转写文本。"
            }
            guard let attempt = selectedAttempt else { return "旧记录未保存对齐阶段。" }
            guard attempt.snapshot.terminologyAlignmentEnabled else {
                return "已关闭；转写文本直接进入下一阶段。"
            }
            guard artifacts.first(where: { $0.kind == .aligned })?.text?.isEmpty == false else {
                return "已执行；这次尝试没有单独保存对齐文本。"
            }
            return "本地词库 · \(alignmentChanges.shortDetail)"
        case .polish:
            if stage.state == .skipped {
                return selectedAttempt?.resolvedKind == .asrOnly
                    ? "仅转写尝试；未执行润色。"
                    : "润色已关闭；对齐文本直接进入校正。"
            }
            if stage.state == .failed {
                if let note = artifacts.first(where: { $0.kind == .output })?.note,
                   note.contains("失败前部分") {
                    return note
                }
                return "润色失败；没有生成可用输出。"
            }
            if stage.state == .unavailable {
                return "这次尝试没有生成润色输出。"
            }
            guard let snapshot else { return "旧记录未保存润色路线。" }
            guard snapshot.textPolish.isEnabled else {
                return "润色已关闭；对齐文本直接进入校正。"
            }
            let count = artifacts.first(where: { $0.kind == .output })?.text?.count ?? 0
            let protection = selectedAttempt?.stages.polishProtectionReason
                .map { " · 安全保护：\($0)" } ?? ""
            let model = snapshot.textPolish.provider.modelLabel(config: snapshot.textPolish)
            let service = snapshot.textPolish.provider == .doubaoIME
                ? "\(model) · 服务端选择模型"
                : model
            return "\(service) · \(count) 字\(protection)"
        case .correction:
            if stage.state == .skipped {
                return selectedAttempt?.resolvedKind == .asrOnly
                    ? "仅诊断尝试；未执行校正。"
                    : "本地校正已关闭；输出保持校正前文本。"
            }
            if stage.state == .failed {
                return "校正失败；没有生成最终文本。"
            }
            if stage.state == .unavailable {
                return "这次尝试没有生成校正后的文本。"
            }
            guard let snapshot else { return "旧记录未保存校正配置。" }
            guard snapshot.correctionRulesEnabled else {
                return "本地校正已关闭；输出保持润色文本。"
            }
            return correctionChanges.shortDetail
        case .output:
            if stage.state == .skipped {
                if selectedAttempt?.resolvedKind != .full, selectedAttempt != nil {
                    return "仅诊断尝试，没有执行输出。"
                }
                return "\(stage.detail) · \(record.appName ?? "目标未记录")"
            }
            if stage.state == .failed {
                return "输出失败；\(status.detail ?? status.label)"
            }
            return "\(status.label) · \(record.appName ?? "目标未记录")"
        }
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
        var asrState: HistoryStageState
        var asrDetail: String
        if hasASR {
            asrState = .complete
            asrDetail = snapshot.provider.modelLabel(config: snapshot)
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

        var alignmentState: HistoryStageState
        var alignmentDetail: String
        if !snapshot.terminologyAlignmentEnabled {
            alignmentState = .skipped
            alignmentDetail = "已关闭"
        } else if hasAligned {
            alignmentState = .complete
            let changes = HistoryTextChangeAnalyzer.summarize(
                from: stages.asrText,
                to: stages.polishInput
            )
            alignmentDetail = changes.count == 0 ? "无词级变化" : "对齐 \(changes.count) 处"
        } else if hasASR {
            alignmentState = .complete
            alignmentDetail = "已执行 · 未归档中间文本"
        } else {
            alignmentState = .unavailable
            alignmentDetail = "未执行"
        }

        var polishState: HistoryStageState
        var polishDetail: String
        if !snapshot.textPolish.isEnabled {
            polishState = .skipped
            polishDetail = "已关闭"
        } else if hasPolish, stages.polishProtectionReason != nil {
            polishState = .complete
            polishDetail = "保留原文"
        } else if hasPolish, hasFinal || stages.error == nil {
            polishState = .complete
            polishDetail = snapshot.textPolish.provider.modelLabel(config: snapshot.textPolish)
        } else if hasPolish {
            polishState = .failed
            polishDetail = "部分输出 · 未采用"
        } else if stages.error != nil {
            polishState = .failed
            polishDetail = "未完成"
        } else {
            polishState = .unavailable
            polishDetail = "未生成"
        }

        var correctionState: HistoryStageState
        var correctionDetail: String
        if hasFinal {
            correctionState = .complete
            let changes = HistoryTextChangeAnalyzer.summarize(
                from: stages.correctionInput ?? stages.polishOutput,
                to: stages.finalText
            )
            if !snapshot.correctionRulesEnabled {
                correctionState = .skipped
                correctionDetail = "已关闭"
            } else {
                correctionDetail = changes.count == 0 ? "无词级变化" : "校正 \(changes.count) 处"
            }
        } else if stages.error != nil {
            correctionState = .failed
            correctionDetail = "未生成"
        } else {
            correctionState = .unavailable
            correctionDetail = "未生成"
        }

        if attempt.resolvedKind == .asrOnly {
            alignmentState = .skipped
            alignmentDetail = "仅转写尝试"
            polishState = .skipped
            polishDetail = "未执行"
            correctionState = .skipped
            correctionDetail = "仅诊断"
        } else if attempt.resolvedKind == .polishOnly {
            asrState = .skipped
            asrDetail = "复用已有转写"
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
            .init(position: .correction, state: correctionState, detail: correctionDetail),
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
                HistoryTextArtifact(kind: .aligned, text: nil, note: "旧记录未保存对齐文本", isFailurePartial: false),
                HistoryTextArtifact(kind: .output, text: record.polishText, note: "旧版润色文本", isFailurePartial: false)
            ]
        }

        let stages = attempt.stages
        let asrNote: String?
        if attempt.resolvedKind == .polishOnly {
            asrNote = "复用已有转写"
        } else if stages.asrText == nil && stages.asrPartialText != nil {
            asrNote = "部分转写"
        } else {
            asrNote = nil
        }

        var alignmentNote: String?
        if attempt.resolvedKind == .asrOnly {
            alignmentNote = "仅转写尝试"
        } else if stages.polishInput?.isEmpty != false && attempt.snapshot.terminologyAlignmentEnabled && stages.asrText?.isEmpty == false {
            alignmentNote = "对齐已执行，中间文本未单独归档"
        } else if !attempt.snapshot.terminologyAlignmentEnabled {
            alignmentNote = "术语对齐已关闭"
        } else {
            alignmentNote = nil
        }

        var polishNote: String?
        var polishFailure = false
        if attempt.resolvedKind == .asrOnly {
            polishNote = "未执行"
        } else if !attempt.snapshot.textPolish.isEnabled {
            polishNote = "润色已关闭"
        } else if stages.error != nil && stages.polishOutput?.isEmpty == false {
            polishNote = "失败前部分输出 · 未采用"
            polishFailure = true
        } else if let reason = stages.polishProtectionReason {
            polishNote = "安全保护：\(reason)"
        } else {
            polishNote = nil
        }

        var outputNote: String?
        var outputText = stages.polishOutput
        var outputFailure = polishFailure
        if attempt.resolvedKind == .asrOnly {
            outputNote = "仅诊断"
            outputText = nil
            outputFailure = false
        } else if stages.finalText?.isEmpty == false {
            outputText = stages.finalText
            let comparisonSource = stages.correctionInput ?? stages.polishOutput
            let changes = HistoryTextChangeAnalyzer.summarize(
                from: comparisonSource,
                to: stages.finalText
            )
            if !attempt.snapshot.textPolish.isEnabled {
                outputNote = changes.count == 0 ? "润色已关闭" : "已含 \(changes.count) 处校正"
            } else if comparisonSource != stages.finalText {
                outputNote = changes.count == 0 ? "已统一格式" : "已含 \(changes.count) 处校正"
            }
        } else if stages.error != nil {
            outputNote = stages.polishOutput?.isEmpty == false ? "失败前部分输出 · 未采用" : "未生成"
            outputFailure = stages.polishOutput?.isEmpty == false
        } else {
            outputNote = stages.polishOutput?.isEmpty == false ? "润色输出已保存" : "未生成"
        }

        return [
            HistoryTextArtifact(kind: .asr, text: stages.asrText ?? stages.asrPartialText, note: asrNote, isFailurePartial: false),
            HistoryTextArtifact(kind: .aligned, text: stages.polishInput, note: alignmentNote, isFailurePartial: false),
            HistoryTextArtifact(kind: .output, text: outputText, note: outputNote ?? polishNote, isFailurePartial: outputFailure)
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
            return .init(label: "输出待核对", detail: "输出文本已保存，输出状态未确认", tone: .attention)
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
        let dateText = [
            timestamp.formatted(date: .numeric, time: .shortened),
            timestamp.formatted(date: .abbreviated, time: .omitted),
            timestamp.formatted(date: .numeric, time: .omitted)
        ]
        searchableText = ([
            record.asrText,
            record.polishText,
            record.errorMessage,
            record.appName,
            record.attempts?.flatMap { attempt in
                [
                    attempt.stages.asrText,
                    attempt.stages.polishInput,
                    attempt.stages.polishOutput,
                    attempt.stages.correctionInput,
                    attempt.stages.finalText
                ].compactMap { $0 }
            }.joined(separator: "\n")
        ] + dateText)
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
    }
}

struct RecoveryHistoryIndex: Sendable, Equatable {
    let records: [RecoveryHistorySummary]
    let unreadableCount: Int
}
