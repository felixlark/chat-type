import AppKit
import AVFoundation
import SwiftUI

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case output
    case anomaly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .output: return "已出字"
        case .anomaly: return "异常"
        }
    }

    func includes(_ summary: RecoveryHistorySummary) -> Bool {
        switch self {
        case .all:
            return true
        case .output:
            return ["pasted", "clipboard"].contains(summary.outcome)
        case .anomaly:
            return ["error", "readyToInject", "outputUnknown", "interrupted", "cancelled"].contains(summary.outcome)
        }
    }
}

struct HistoryDayGroup: Identifiable {
    let id: Date
    let title: String
    let records: [RecoveryHistorySummary]
}

@MainActor
final class HistoryWorkspaceModel: ObservableObject {
    @Published private(set) var index = RecoveryHistoryIndex(records: [], unreadableCount: 0)
    @Published var selectedRecordID: UUID?
    @Published var selectedAttemptID: UUID?
    @Published var query = ""
    @Published var filter: HistoryFilter = .all
    @Published private(set) var selectedRecord: RecoveryRecord?
    @Published private(set) var isLoadingIndex = false
    @Published private(set) var isLoadingRecord = false
    @Published private(set) var indexError: String?
    @Published private(set) var recordError: String?

    private let recoveryDirectoryURL: URL
    private let onLoadIndex: @Sendable () throws -> RecoveryHistoryIndex
    private let onLoadRecord: @Sendable (UUID) throws -> RecoveryRecord?
    private var indexTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?
    private var indexGeneration = UUID()
    private var recordGeneration = UUID()
    private var pendingRecordUpdates: [UUID: RecoveryHistorySummary] = [:]
    private var hasActivated = false

    init(
        recoveryDirectoryURL: URL,
        onLoadIndex: @escaping @Sendable () throws -> RecoveryHistoryIndex,
        onLoadRecord: @escaping @Sendable (UUID) throws -> RecoveryRecord?
    ) {
        self.recoveryDirectoryURL = recoveryDirectoryURL
        self.onLoadIndex = onLoadIndex
        self.onLoadRecord = onLoadRecord
    }

    var filteredRecords: [RecoveryHistorySummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return index.records.filter { summary in
            guard filter.includes(summary) else { return false }
            guard !needle.isEmpty else { return true }
            return summary.searchableText.contains(needle)
                || (summary.appName?.lowercased().contains(needle) ?? false)
        }
    }

    var groups: [HistoryDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecords) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return grouped.keys.sorted(by: >).map { day in
            let records = (grouped[day] ?? []).sorted { $0.timestamp > $1.timestamp }
            let title: String
            if calendar.isDateInToday(day) {
                title = "今天"
            } else if calendar.isDateInYesterday(day) {
                title = "昨天"
            } else {
                title = day.formatted(.dateTime.month().day())
            }
            return HistoryDayGroup(id: day, title: title, records: records)
        }
    }

    var selectedSummary: RecoveryHistorySummary? {
        index.records.first { $0.id == selectedRecordID }
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        refreshIndex()
    }

    func refreshIndex() {
        indexGeneration = UUID()
        let generation = indexGeneration
        isLoadingIndex = true
        indexError = nil
        let loader = onLoadIndex
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try loader() }
            }.value
            guard let self, self.indexGeneration == generation else { return }
            self.isLoadingIndex = false
            switch result {
            case .success(let loaded):
                var records = loaded.records
                for (id, summary) in self.pendingRecordUpdates {
                    records.removeAll { $0.id == id }
                    records.append(summary)
                }
                records.sort { $0.timestamp > $1.timestamp }
                self.pendingRecordUpdates.removeAll()
                self.index = RecoveryHistoryIndex(records: records, unreadableCount: loaded.unreadableCount)
                self.indexError = nil
                let selectedStillExists = records.contains { $0.id == self.selectedRecordID }
                if !selectedStillExists {
                    self.selectedRecord = nil
                    self.selectedAttemptID = nil
                    self.selectedRecordID = records.first?.id
                    if let id = self.selectedRecordID {
                        self.loadRecord(id: id)
                    }
                } else {
                    self.reconcileSelection()
                }
            case .failure(let error):
                self.indexError = error.localizedDescription
            }
        }
    }

    func selectRecord(_ id: UUID?) {
        guard id != selectedRecordID else { return }
        selectedRecordID = id
        selectedAttemptID = nil
        selectedRecord = nil
        recordError = nil
        guard let id else {
            recordTask?.cancel()
            isLoadingRecord = false
            return
        }
        loadRecord(id: id)
    }

    func reconcileSelection() {
        let visible = filteredRecords
        guard let first = visible.first else {
            selectedRecordID = nil
            selectedAttemptID = nil
            selectedRecord = nil
            recordError = nil
            recordTask?.cancel()
            isLoadingRecord = false
            return
        }
        if let selectedRecordID, visible.contains(where: { $0.id == selectedRecordID }) {
            return
        }
        selectRecord(first.id)
    }

    func loadRecord(id: UUID) {
        recordGeneration = UUID()
        let generation = recordGeneration
        isLoadingRecord = true
        recordError = nil
        let loader = onLoadRecord
        recordTask?.cancel()
        recordTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try loader(id) }
            }.value
            guard let self, self.recordGeneration == generation, self.selectedRecordID == id else { return }
            self.isLoadingRecord = false
            switch result {
            case .success(let record):
                self.selectedRecord = record
                if let record, !(record.attempts ?? []).isEmpty {
                    let selectedExists = record.attempts?.contains { $0.id == self.selectedAttemptID } == true
                    if !selectedExists {
                        self.selectedAttemptID = record.attempts?.last(where: { $0.resolvedKind == .full })?.id
                            ?? record.attempts?.last?.id
                    }
                }
            case .failure(let error):
                self.recordError = error.localizedDescription
            }
        }
    }

    func recordDidChange(_ record: RecoveryRecord, directory: String) {
        guard directory == recoveryDirectoryURL.path else { return }
        let summary = RecoveryHistorySummary(record: record, recoveryDirectoryURL: recoveryDirectoryURL)
        pendingRecordUpdates[record.id] = summary
        var records = index.records.filter { $0.id != record.id }
        records.append(summary)
        records.sort { $0.timestamp > $1.timestamp }
        index = RecoveryHistoryIndex(records: records, unreadableCount: index.unreadableCount)
        if selectedRecordID == record.id {
            loadRecord(id: record.id)
        } else if selectedRecordID == nil {
            selectRecord(record.id)
        }
    }

    func cancel() {
        indexGeneration = UUID()
        recordGeneration = UUID()
        indexTask?.cancel()
        recordTask?.cancel()
        indexTask = nil
        recordTask = nil
        isLoadingIndex = false
        isLoadingRecord = false
    }
}

struct HistoryWorkspaceView: View {
    @ObservedObject var model: HistoryWorkspaceModel
    let recoveryDirectoryURL: URL
    let onRetryRecoveryRecord: (RecoveryRecord, UUID?) -> Void
    let onReprocessRecoveryRecord: (RecoveryRecord, UUID?) -> Void

    @State private var copiedKey: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                voiceList
                Divider()
                detail
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.activate() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("ChatType")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    Text("History")
                }
                .font(SettingsTypography.caption)
                .foregroundStyle(.secondary)
                Text("History")
                    .font(SettingsTypography.pageTitle)
                Text("原声、转写、对齐、润色与校正，一屏查看。")
                    .font(SettingsTypography.pageSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if model.isLoadingIndex {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.refreshIndex()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isLoadingIndex)
                .help("重新读取本地语音索引")
                Text("\(model.index.records.count) 条")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Label("本机保存", systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var voiceList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索文字、应用或日期", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .onChange(of: model.query) { _ in
                            model.reconcileSelection()
                        }
                }
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                )

                HStack(spacing: 3) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Button {
                            model.filter = filter
                            model.reconcileSelection()
                        } label: {
                            Text(filter.title)
                                .font(.system(size: 12.5, weight: model.filter == filter ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(
                                    model.filter == filter
                                        ? Color(nsColor: .textBackgroundColor)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color(nsColor: .separatorColor).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(13)

            Divider()

            if let error = model.indexError {
                HistoryEmptyState(title: "History 读取失败", symbol: "exclamationmark.triangle", detail: error)
            } else if model.index.records.isEmpty && model.isLoadingIndex {
                ProgressView("正在读取语音记录…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.index.records.isEmpty {
                HistoryEmptyState(title: "还没有语音记录", symbol: "waveform", detail: "按 F5 完成一次录音后会出现在这里。")
            } else if model.filteredRecords.isEmpty {
                HistoryEmptyState(title: "没有匹配的语音", symbol: "magnifyingglass", detail: "换一个关键词或筛选条件。")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.groups) { group in
                                Text(group.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)

                                ForEach(group.records) { record in
                                    voiceRow(record)
                                        .id(record.id)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.selectedRecordID) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Label("原声与阶段证据仅保存在本机", systemImage: "lock")
                Spacer()
                if model.index.unreadableCount > 0 {
                    Text("\(model.index.unreadableCount) 条不可读")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: SettingsLayout.historyListWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func voiceRow(_ record: RecoveryHistorySummary) -> some View {
        let selected = model.selectedRecordID == record.id
        return Button {
            model.selectRecord(record.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(record.status.tone.color)
                        .frame(width: 7, height: 7)
                    Text(record.status.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(record.status.tone.color)
                    Spacer()
                    Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Text(record.displayTitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 7) {
                    Text(record.appName ?? "未记录目标")
                        .lineLimit(1)
                    Spacer()
                    Text(record.formattedDuration)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack(spacing: 3) {
                    ForEach(Array(record.stageStates.enumerated()), id: \.offset) { _, state in
                        Capsule()
                            .fill(state.color.opacity(state == .unavailable ? 0.18 : 0.72))
                            .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.11) : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if model.isLoadingRecord && model.selectedRecord == nil {
            ProgressView("正在读取完整记录…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.recordError {
            HistoryEmptyState(title: "这条语音无法读取", symbol: "exclamationmark.triangle", detail: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let record = model.selectedRecord {
            HistoryDetailView(
                record: record,
                recoveryDirectoryURL: recoveryDirectoryURL,
                selectedAttemptID: $model.selectedAttemptID,
                copiedKey: $copiedKey,
                onRetry: { onRetryRecoveryRecord(record, model.selectedAttemptID) },
                onReprocess: { onReprocessRecoveryRecord(record, model.selectedAttemptID) }
            )
        } else {
            HistoryEmptyState(title: "选择一条语音", symbol: "waveform", detail: "查看原声、转写、对齐、润色与校正。")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HistoryEmptyState: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct HistoryDetailView: View {
    let record: RecoveryRecord
    let recoveryDirectoryURL: URL
    @Binding var selectedAttemptID: UUID?
    @Binding var copiedKey: String?
    let onRetry: () -> Void
    let onReprocess: () -> Void
    @State private var selectedStage: HistoryStagePosition = .asr

    private var audioURL: URL {
        record.audioURL(baseDirectory: recoveryDirectoryURL)
    }

    private var audioAvailable: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    private var presentation: HistoryRecordPresentation {
        HistoryRecordPresentation(
            record: record,
            selectedAttemptID: selectedAttemptID,
            audioAvailable: audioAvailable
        )
    }

    var body: some View {
        let view = presentation
        VStack(alignment: .leading, spacing: 11) {
            detailHeader(view)
            stages(view)
            stageSummary(view)
            textChain(view)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selectedAttemptID) { _ in
            selectedStage = .asr
        }
    }

    private func detailHeader(_ view: HistoryRecordPresentation) -> some View {
        let canRetryOriginal = audioAvailable && !view.selectedAttemptIsDiagnostic
        return VStack(alignment: .leading, spacing: 10) {
            audioPlayer

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Label(view.status.label, systemImage: view.status.tone.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(view.status.tone.color)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(view.status.tone.color.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize()
                        Text(record.timestamp.formatted(date: .numeric, time: .shortened))
                            .fixedSize()
                        Text("·")
                        Text(view.formattedDuration)
                            .fixedSize()
                        if let app = record.appName {
                            Text("·")
                            Text("目标：\(app)")
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 7) {
                        Text(view.routeSummary)
                            .lineLimit(1)
                        if view.attemptOptions.count > 1 {
                            Text("·")
                            attemptMenu(view)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    if let detail = view.status.detail,
                       view.status.tone == .attention || view.status.tone == .failure {
                        Label(detail, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(view.status.tone.color)
                            .lineLimit(1)
                            .help(detail)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 10)

                HStack(spacing: 10) {
                    Button(action: onRetry) {
                        Label("重试原路线", systemImage: "arrow.clockwise")
                            .frame(minWidth: 116)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!canRetryOriginal)
                    .help(canRetryOriginal ? "使用所选完整流程尝试的原路线重试。" : "诊断尝试请先切换到完整流程尝试。")

                    Button(action: onReprocess) {
                        Label("按当前流程重跑", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!audioAvailable)
                    .help(audioAvailable ? "使用当前 Workflow 设置重新完成整条流程。" : "原始音频缺失，不能重跑整条流程。")
                }
                .fixedSize()
            }
        }
    }

    private func attemptMenu(_ view: HistoryRecordPresentation) -> some View {
        Menu {
            ForEach(view.attemptOptions) { option in
                Button {
                    selectedAttemptID = option.id
                } label: {
                    HStack {
                        Label(option.title, systemImage: option.id == view.selectedAttemptID ? "checkmark" : option.status.tone.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text(view.attemptOptions.first(where: { $0.id == view.selectedAttemptID })?.title ?? "选择尝试")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换这次录音的历史尝试")
    }

    @ViewBuilder
    private var audioPlayer: some View {
        if audioAvailable {
            HistoryAudioPlayerView(url: audioURL, durationMs: record.audioDurationMs)
                .id(record.id)
        } else {
            HStack(spacing: 9) {
                Image(systemName: "speaker.slash")
                Text("原始音频缺失；文本、状态与复制功能仍可用。")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .padding(12)
            .background(Color.orange.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func stages(_ view: HistoryRecordPresentation) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("处理流程")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if view.legacy {
                    Text("旧记录 · 无分阶段明细")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if let attempt = view.selectedAttempt {
                    Text("尝试 \(attemptIndex(view, attempt) + 1) · \(attempt.resolvedKind.label)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            if view.legacy {
                Text("这条记录来自旧版档案。保留原声、ASR 和旧版润色文本，不推断未保存的中间阶段。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                HStack(spacing: 6) {
                    ForEach(view.stages) { stage in
                        stageButton(stage)
                    }
                }
            }
        }
    }

    private func stageButton(_ stage: HistoryStagePresentation) -> some View {
        let selected = selectedStage == stage.position
        return Button {
            selectedStage = stage.position
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: stage.position.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                    Text(stage.position.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                }
                Text(stage.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(selected ? Color.primary : stage.state.color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.11) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selected
                            ? Color.accentColor.opacity(0.38)
                            : Color(nsColor: .separatorColor).opacity(0.24),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stage.position.title)：\(stage.detail)")
        .help("\(stage.position.title)：\(stage.detail)")
    }

    @ViewBuilder
    private func stageSummary(_ view: HistoryRecordPresentation) -> some View {
        if !view.legacy, let stage = view.stages.first(where: { $0.position == selectedStage }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: stage.position.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(stage.state.color)
                    .frame(width: 18)
                Text(stage.position.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(view.stageNarrative(for: stage.position))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
        }
    }

    private func textChain(_ view: HistoryRecordPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文本链")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Text("ASR 原文 → 对齐 → 输出")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                ForEach(Array(view.artifacts.enumerated()), id: \.element.id) { index, artifact in
                    artifactColumn(artifact)
                    if index < view.artifacts.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
            )
        }
        .frame(maxHeight: .infinity)
    }

    private func artifactColumn(_ artifact: HistoryTextArtifact) -> some View {
        let isSelected = selectedArtifact == artifact.kind
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(artifact.kind.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                copyButton(for: artifact)
            }

            if let note = artifact.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(artifact.isFailurePartial ? .orange : .secondary)
                    .lineLimit(1)
                    .help(note)
            }

            ScrollView(.vertical) {
                if let text = artifact.text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(artifact.isFailurePartial ? .secondary : .primary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Text("未生成")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedStage = stagePosition(for: artifact.kind)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
                .padding(3)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(artifact.kind.title)\(isSelected ? "，已选中" : "")")
    }

    private func copyButton(for artifact: HistoryTextArtifact) -> some View {
        let key = "\(record.id)-\(artifact.kind.rawValue)"
        return Button {
            copy(artifact.text ?? "", key: key)
        } label: {
            Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(artifact.text?.isEmpty != false)
        .accessibilityLabel("复制\(artifact.kind.title)")
        .help("复制\(artifact.kind.title)")
    }

    private var selectedArtifact: HistoryTextArtifactKind? {
        switch selectedStage {
        case .asr: return .asr
        case .alignment: return .aligned
        case .polish, .correction, .output: return .output
        case .audio: return nil
        }
    }

    private func stagePosition(for artifact: HistoryTextArtifactKind) -> HistoryStagePosition {
        switch artifact {
        case .asr: return .asr
        case .aligned: return .alignment
        case .output: return .polish
        }
    }

    private func attemptIndex(_ view: HistoryRecordPresentation, _ attempt: DictationAttempt) -> Int {
        view.attemptOptions.firstIndex(where: { $0.id == attempt.id }) ?? 0
    }

    private func copy(_ text: String, key: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedKey = key
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == key { copiedKey = nil }
        }
    }
}

private struct HistoryAudioPlayerView: View {
    let url: URL
    let durationMs: Int
    @StateObject private var model: HistoryAudioPlayerModel

    init(url: URL, durationMs: Int) {
        self.url = url
        self.durationMs = durationMs
        _model = StateObject(wrappedValue: HistoryAudioPlayerModel(url: url, fallbackDurationMs: durationMs))
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.toggle()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.white)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放原始语音")

            HistoryWaveformView(peaks: model.peaks, progress: model.progress) { fraction in
                model.seek(to: fraction)
            }
            .frame(height: 40)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(format(model.currentTime)) / \(format(model.duration))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("本机原声")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onDisappear { model.stop() }
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
private final class HistoryAudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var peaks: [CGFloat] = Array(repeating: 0.08, count: 96)

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var peakTask: Task<Void, Never>?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    init(url: URL, fallbackDurationMs: Int) {
        super.init()
        duration = Double(fallbackDurationMs) / 1_000
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            player = nil
        }
        peakTask = Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                HistoryAudioPeakReader.peaks(url: url, count: 96)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.peaks = values
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
            timer = nil
        } else {
            if player.currentTime >= max(0, player.duration - 0.05) {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = duration * clamped
        currentTime = player.currentTime
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        peakTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }
}

private struct HistoryWaveformView: View {
    let peaks: [CGFloat]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let count = max(peaks.count, 1)
                let gap: CGFloat = 2
                let barWidth = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
                let playedX = size.width * progress
                for (index, peak) in peaks.enumerated() {
                    let x = CGFloat(index) * (barWidth + gap)
                    let height = max(3, min(size.height, peak * size.height))
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(x <= playedX ? Color.accentColor : Color(nsColor: .secondaryLabelColor).opacity(0.28))
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(value.location.x / max(geometry.size.width, 1))
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("原始语音波形")
            .accessibilityValue("已播放 \(Int(progress * 100))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onSeek(min(1, progress + 0.05))
                case .decrement:
                    onSeek(max(0, progress - 0.05))
                @unknown default:
                    break
                }
            }
        }
    }
}

private enum HistoryAudioPeakReader {
    static func peaks(url: URL, count: Int) -> [CGFloat] {
        guard count > 0, let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.08, count: max(count, 0))
        }
        let format = file.processingFormat
        let totalFrames = max(file.length, 1)
        let bucketSize = max(totalFrames / AVAudioFramePosition(count), 1)
        let frameCapacity: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return Array(repeating: 0.08, count: count)
        }
        var values = Array(repeating: Float.zero, count: count)
        file.framePosition = 0
        while file.framePosition < totalFrames {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            guard let channel = buffer.floatChannelData?[0] else { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            let startFrame = file.framePosition - AVAudioFramePosition(frames)
            for index in 0..<frames {
                let frame = startFrame + AVAudioFramePosition(index)
                let bucket = min(max(Int(frame / bucketSize), 0), count - 1)
                values[bucket] = max(values[bucket], abs(channel[index]))
            }
        }
        let maximum = max(values.max() ?? 0, 0.0001)
        return values.map { CGFloat(max(0.05, min(1, $0 / maximum))) }
    }
}

private extension HistoryStatusTone {
    var color: Color {
        switch self {
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        case .success: return .green
        case .attention: return .orange
        case .failure: return .red
        case .active: return .accentColor
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "circle"
        case .success: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        case .active: return "waveform"
        }
    }
}

private extension HistoryStageState {
    var color: Color {
        switch self {
        case .complete: return .green
        case .skipped: return Color(nsColor: .secondaryLabelColor)
        case .failed: return .red
        case .attention: return .orange
        case .pending: return .accentColor
        case .unavailable: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

private extension DictationAttemptKind {
    var label: String {
        switch self {
        case .full: return "完整流程"
        case .asrOnly: return "仅转写"
        case .polishOnly: return "仅润色"
        }
    }
}
