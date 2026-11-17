import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    private static let historyPageSize = 10

    func refreshTextPolishStatus() { usage.refresh() }
    func refreshRecentHistory(resetPage: Bool = true) {
        if resetPage { historyOffset = 0 }
        let offset = historyOffset
        let pageSize = 10
        history.refresh(using: { try onLoadRecentHistory(offset, pageSize) })
    }
    func refreshRecoveryHistory(resetPage: Bool = true) {
        if resetPage { recoveryOffset = 0 }
        let offset = recoveryOffset
        let pageSize = 10
        recovery.refresh(using: { try onLoadRecoveryHistory(offset, pageSize) })
    }
    func refreshVisibleSection() {
        guard selectedSection == .recovery else { return }
        if recentHistoryRecords.isEmpty && !history.isLoading { refreshRecentHistory() }
        if recentRecoveryRecords.isEmpty && !recovery.isLoading { refreshRecoveryHistory() }
    }

    func loadPreviousHistoryPage() {
        historyOffset = max(0, historyOffset - Self.historyPageSize)
        refreshRecentHistory(resetPage: false)
    }

    func loadNextHistoryPage() {
        guard history.value.hasNext else { return }
        historyOffset += Self.historyPageSize
        refreshRecentHistory(resetPage: false)
    }

    func loadPreviousRecoveryPage() {
        recoveryOffset = max(0, recoveryOffset - Self.historyPageSize)
        refreshRecoveryHistory(resetPage: false)
    }

    func loadNextRecoveryPage() {
        guard recovery.value.hasNext else { return }
        recoveryOffset += Self.historyPageSize
        refreshRecoveryHistory(resetPage: false)
    }

    var recentRecoveryItems: [RecoveryHistoryPreview] {
        RecoveryHistoryPreview.recentItems(
            from: recentRecoveryRecords,
            kind: selectedRecoveryKind,
            limit: 10
        )
    }

    var recentDictationHistoryItems: [TranscriptionHistoryPreview] {
        TranscriptionHistoryPreview.recentItems(
            from: recentHistoryRecords,
            limit: Self.historyPageSize,
            textSource: .dictation
        )
    }

    var recentPolishHistoryItems: [TranscriptionHistoryPreview] {
        TranscriptionHistoryPreview.recentItems(
            from: recentHistoryRecords,
            limit: Self.historyPageSize,
            textSource: .polish
        )
    }

    var recoveryHistoryCard: some View {
        settingsCard(title: "Recent Records") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Record type", selection: $selectedRecoveryKind) {
                    Text("原始语音").tag(RecoveryHistoryKind.audio)
                    Text("ASR 转录结果").tag(RecoveryHistoryKind.asr)
                    Text("AI polish 结果").tag(RecoveryHistoryKind.polish)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("第 \(recoveryOffset / Self.historyPageSize + 1) 页 · 最近 10 条")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        refreshRecoveryHistory()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("上一页") { loadPreviousRecoveryPage() }
                        .disabled(!recovery.value.hasPrevious || recovery.isLoading)
                    Button("下一页") { loadNextRecoveryPage() }
                        .disabled(!recovery.value.hasNext || recovery.isLoading)
                    Text("共约 \(recovery.value.totalCount) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if recovery.isLoading { ProgressView("Loading saved recordings…").controlSize(.small) }
                if let error = recovery.error { Text("History could not refresh: \(error)").foregroundStyle(.red) }
                if recentRecoveryItems.isEmpty && !recovery.isLoading && recovery.error == nil {
                    Text("No recoverable records yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recentRecoveryItems) { item in
                            recoveryHistoryRow(item)
                        }
                    }
                }
            }
        }
    }

    func recoveryHistoryRow(_ item: RecoveryHistoryPreview) -> some View {
        let isCopied = copiedHistoryItemID == item.id

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("来源：\(item.target)")
                        .font(.system(size: 11, weight: .medium))
                    Text(item.outcome)
                        .font(.system(size: 10))
                        .foregroundStyle(item.outcome == "error" ? .red : .secondary)
                    Text(item.timestamp.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let record = recentRecoveryRecords.first(where: { $0.id == item.recordID }),
                   let snapshot = record.attempts?.last?.snapshot ?? record.snapshot {
                    Text("本次流程 · ASR：\(snapshot.provider.title) · 润色：\(snapshot.textPolish.isEnabled ? snapshot.textPolish.provider.title : "关闭")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let errorMessage = item.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if isCopied {
                    Text("Copied")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button {
                    copyRecoveryHistoryItem(item)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 12, height: 12)
                }
                .help("Copy")
                .accessibilityLabel("Copy")
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    if let record = recentRecoveryRecords.first(where: { $0.id == item.recordID }) { onReprocessRecoveryRecord(record) }
                } label: {
                    Text("按当前流程重跑")
                }
                .help("应用 Workflow 当前选择，以新尝试重新处理；原声和旧尝试保留。")
                .accessibilityLabel("按当前流程重跑")
                .buttonStyle(.bordered)
                .controlSize(.small)
                Menu("更多") {
                    Button("重试原路线") { retryRecoveryHistoryItem(item) }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func copyRecoveryHistoryItem(_ item: RecoveryHistoryPreview) {
        NSPasteboard.general.clearContents()
        switch item.copyKind {
        case .text:
            NSPasteboard.general.setString(item.copyText, forType: .string)
        case .audioFile:
            let audioURL = recoveryDirectoryURL
                .appendingPathComponent("Audio", isDirectory: true)
                .appendingPathComponent(item.audioFileName)
            NSPasteboard.general.writeObjects([audioURL as NSURL])
        }

        withAnimation(.easeOut(duration: 0.12)) {
            copiedHistoryItemID = item.id
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard copiedHistoryItemID == item.id else {
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                copiedHistoryItemID = nil
            }
        }
    }

    func retryRecoveryHistoryItem(_ item: RecoveryHistoryPreview) {
        guard let record = recentRecoveryRecords.first(where: { $0.id == item.recordID }) else {
            return
        }
        onRetryRecoveryRecord(record)
    }

    var polishStatusSection: some View {
        let provider = config.transcription.textPolish.provider
        let usage = textPolishUsage[provider] ?? TextPolishUsage()
        let ready = provider == .qwenFlash ? qwenKeySaved : provider == .glmFlash ? glmKeySaved : provider == .doubaoIME ? true : authSnapshot.state == .ready
        let detail: String
        switch provider {
        case .doubaoIME:
            detail = "仅发送整理输入文本到 ime.doubao.com。无须账户登录，服务可用性与费用未作保证；未实测前不显示已连接。"
        case .chatGPTAuth:
            detail = ready ? "Account connected. Selected model: \(config.transcription.textPolish.chatGPTResponseModel)." : authSnapshot.detail
        case .glmFlash:
            detail = ready ? "GLM key saved. API availability is checked when polishing." : "Save a GLM API Key first."
        case .qwenFlash:
            detail = ready ? "Qwen key saved. Free quota and usage billing follow your Beijing account." : "Save a Qwen API Key first."
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(provider.title) rewrite")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(provider == .doubaoIME ? "记录：\(usage.attempts) 次尝试，\(usage.succeeded) 次完成；服务未提供 token 用量与费用。" : "Attributed usage: \(usage.attempts) attempts, \(usage.succeeded) succeeded, \(usage.inputTokens) input tokens, \(usage.outputTokens) output tokens.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if unattributedPolishAttempts > 0 {
                    Text("\(unattributedPolishAttempts) attempts have an unknown provider, including failed polish attempts.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func historySection(
        title: String,
        textSource: TranscriptionHistoryTextSource
    ) -> some View {
        let items = textSource == .dictation ? recentDictationHistoryItems : recentPolishHistoryItems

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") {
                    refreshRecentHistory()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("上一页") { loadPreviousHistoryPage() }
                    .disabled(!history.value.hasPrevious || history.isLoading)
                Button("下一页") { loadNextHistoryPage() }
                    .disabled(!history.value.hasNext || history.isLoading)
                Text("第 \(historyOffset / Self.historyPageSize + 1) 页 · 共约 \(history.value.totalCount) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("No recent transcripts yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        recentHistoryRow(item)
                    }
                }
            }
        }
    }

    func recentHistoryRow(_ item: TranscriptionHistoryPreview) -> some View {
        let isCopied = copiedHistoryItemID == item.id

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.target)
                        .font(.system(size: 11, weight: .medium))
                    Text(item.sourceLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(item.outcome)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(item.timestamp.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if isCopied {
                    Text("Copied")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button {
                    copyRecentHistoryItem(item)
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 12, height: 12)
                }
                .help(isCopied ? "Copied" : "Copy transcript")
                .accessibilityLabel(isCopied ? "Copied transcript" : "Copy transcript")
                .disabled(item.copyText.isEmpty)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func copyRecentHistoryItem(_ item: TranscriptionHistoryPreview) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.copyText, forType: .string)

        withAnimation(.easeOut(duration: 0.12)) {
            copiedHistoryItemID = item.id
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard copiedHistoryItemID == item.id else {
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                copiedHistoryItemID = nil
            }
        }
    }

}
