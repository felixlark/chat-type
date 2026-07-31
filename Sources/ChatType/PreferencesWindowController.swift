import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PreferencesWindowController: NSWindowController {
    init(
        config: AppConfig,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Void,
        onImportTerminologyDictionary: @escaping (AppConfig, URL) -> Result<AppConfig, any Error>,
        onLoadRecentHistory: @escaping () -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping () -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false
    ) {
        let view = PreferencesView(
            initialConfig: config,
            authManager: authManager,
            onSave: onSave,
            onImportTerminologyDictionary: onImportTerminologyDictionary,
            onLoadRecentHistory: onLoadRecentHistory,
            onLoadRecoveryHistory: onLoadRecoveryHistory,
            recoveryDirectoryURL: recoveryDirectoryURL,
            onRetryRecoveryRecord: onRetryRecoveryRecord,
            onOpenConfigFolder: onOpenConfigFolder,
            focusRecoveryHistory: focusRecoveryHistory
        )
        let hostingController = NSHostingController(rootView: view)

        let window = CommandClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatType Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentViewController = hostingController

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class CommandClosingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandW = event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "w"

        if isCommandW {
            close()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

private struct TextPolishUsage: Equatable {
    var attempts = 0
    var succeeded = 0
    var failed = 0
    var inputTokens = 0
    var outputTokens = 0

    var summary: String {
        guard attempts > 0 else {
            return "0 attempts / 0 tokens"
        }
        return "\(attempts) attempts / \(succeeded) succeeded / \(failed) failed / \(inputTokens + outputTokens) tokens"
    }
}

private struct PreferencesView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case account = "Account"
        case dictation = "Dictation"
        case polish = "AI Polish"
        case recovery = "History"
        case terminology = "Terminology"
        case paste = "Paste"
        case advanced = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .dictation:
                return "mic"
            case .polish:
                return "wand.and.stars"
            case .recovery:
                return "clock.arrow.circlepath"
            case .terminology:
                return "text.book.closed"
            case .paste:
                return "doc.on.clipboard"
            case .advanced:
                return "gearshape"
            }
        }
    }

    private enum TerminologyFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case terms = "Terms"
        case corrections = "Replacements"

        var id: String { rawValue }
    }

    @State private var config: AppConfig
    @State private var showsAdvancedRecovery: Bool
    @State private var permissionRefreshNonce: Int = 0
    @State private var terminologyImportMessage: String?
    @State private var terminologyImportIsError = false
    @State private var terminologyFilter: TerminologyFilter = .all
    @State private var editingTerminologyIndex: Int?
    @State private var editingTerminologyType: TerminologyEntryType = .term
    @State private var editingOriginal = ""
    @State private var editingReplacement = ""
    @State private var authSnapshot: ChatGPTAuthSnapshot
    @State private var browserBridgeSnapshot: BrowserBridgeSnapshot
    @State private var isConnectingBrowserLogin = false
    @State private var selectedSection: SettingsSection = .account
    @State private var textPolishUsage: [TextPolishProviderID: TextPolishUsage] = [:]
    @State private var textPolishMessage: String?
    @State private var textPolishMessageIsError = false
    @State private var recentHistoryRecords: [TranscriptionHistoryRecord] = []
    @State private var recentRecoveryRecords: [RecoveryRecord] = []
    @State private var selectedRecoveryKind: RecoveryHistoryKind = .audio
    @State private var copiedHistoryItemID: String?

    let authManager: ChatGPTAuthManager
    let onSave: (AppConfig) -> Void
    let onImportTerminologyDictionary: (AppConfig, URL) -> Result<AppConfig, any Error>
    let onLoadRecentHistory: () -> [TranscriptionHistoryRecord]
    let onLoadRecoveryHistory: () -> [RecoveryRecord]
    let recoveryDirectoryURL: URL
    let onRetryRecoveryRecord: (RecoveryRecord) -> Void
    let onOpenConfigFolder: () -> Void

    init(
        initialConfig: AppConfig,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Void,
        onImportTerminologyDictionary: @escaping (AppConfig, URL) -> Result<AppConfig, any Error>,
        onLoadRecentHistory: @escaping () -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping () -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false
    ) {
        _config = State(initialValue: initialConfig)
        _showsAdvancedRecovery = State(initialValue: initialConfig.transcription.provider == .openAICompatible)
        _terminologyImportMessage = State(initialValue: Self.terminologyStatusMessage(for: initialConfig))
        _authSnapshot = State(initialValue: authManager.authSnapshot())
        _browserBridgeSnapshot = State(initialValue: authManager.browserBridgeSnapshot())
        _textPolishUsage = State(initialValue: Self.loadTextPolishUsage())
        _selectedSection = State(initialValue: focusRecoveryHistory ? .recovery : .account)
        self.authManager = authManager
        self.onSave = onSave
        self.onImportTerminologyDictionary = onImportTerminologyDictionary
        self.onLoadRecentHistory = onLoadRecentHistory
        self.onLoadRecoveryHistory = onLoadRecoveryHistory
        self.recoveryDirectoryURL = recoveryDirectoryURL
        self.onRetryRecoveryRecord = onRetryRecoveryRecord
        self.onOpenConfigFolder = onOpenConfigFolder
    }

    private var runtimeIssues: [RuntimePreflightIssue] {
        RuntimePreflight.issues(
            for: config,
            environment: ProcessInfo.processInfo.environment,
            authSnapshotProvider: { authSnapshot }
        )
    }

    private var chatGPTAccountStatus: SetupStatus {
        if config.transcription.provider == .openAICompatible {
            return SetupStatus(
                title: "Advanced recovery route selected",
                subtitle: "ChatGPT account checks are bypassed while you use your own compatible API."
            )
        }

        if let issue = runtimeIssues.first(where: {
            switch $0 {
            case .chatGPTLoginRequired, .chatGPTSessionExpired, .chatGPTSessionUnavailable:
                return true
            default:
                return false
            }
        }) {
            return SetupStatus(title: "Needs attention", subtitle: issue.message, isReady: false)
        }

        return SetupStatus(
            title: "Ready",
            subtitle: authSnapshot.detail
        )
    }

    private var microphoneStatus: SetupStatus {
        _ = permissionRefreshNonce
        switch AudioRecorder.microphonePermissionState() {
        case .granted:
            return SetupStatus(title: "Granted", subtitle: "Microphone access is ready.")
        case .undetermined:
            return SetupStatus(title: "Not requested yet", subtitle: "Press F5 once and macOS will ask for microphone access.", isReady: false)
        case .denied:
            return SetupStatus(
                title: "Needs permission",
                subtitle: "Microphone access was previously denied. Open Privacy & Security > Microphone to re-enable it.",
                isReady: false
            )
        }
    }

    private var accessibilityStatus: SetupStatus {
        _ = permissionRefreshNonce
        let guidance = AccessibilityPermission.repairGuidance()

        if AccessibilityPermission.isTrusted() {
            return SetupStatus(title: "Granted", subtitle: "Auto-paste is ready.")
        }

        return SetupStatus(
            title: "Optional but recommended",
            subtitle: guidance.subtitle,
            isReady: false
        )
    }

    private var accessibilityRepairActions: [PermissionRepairAction] {
        guard !AccessibilityPermission.isTrusted() else {
            return []
        }

        return AccessibilityPermission.repairActions()
    }

    private var microphoneRepairActions: [PermissionRepairAction] {
        AudioRecorder.repairActions(for: AudioRecorder.microphonePermissionState())
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeader
                        selectedSectionView
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                HStack {
                    Button("Open Config Folder", action: onOpenConfigFolder)
                    Spacer()
                    Button("Save Settings") {
                        onSave(config)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshNonce += 1
            authSnapshot = authManager.authSnapshot()
            browserBridgeSnapshot = authManager.browserBridgeSnapshot()
            refreshTextPolishStatus()
            refreshRecentHistory()
            refreshRecoveryHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatGPTAuthStateDidChange)) { _ in
            authSnapshot = authManager.authSnapshot()
            browserBridgeSnapshot = authManager.browserBridgeSnapshot()
            refreshTextPolishStatus()
        }
        .onAppear {
            refreshTextPolishStatus()
            refreshRecentHistory()
            refreshRecoveryHistory()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ChatType")
                    .font(.system(size: 24, weight: .semibold))
                Text("F5 dictation workflow")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                        Text(section.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.rawValue)
                .font(.system(size: 24, weight: .semibold))
            Text(sectionSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .account:
            return "Connect ChatGPT, verify permissions, and keep the first-run flow healthy."
        case .dictation:
            return "Configure the F5 recording route and ASR behavior."
        case .polish:
            return "Rewrite long transcripts into concise, agent-friendly plans after ASR."
        case .recovery:
            return "Copy or retry recent audio, ASR, and AI-polished results."
        case .terminology:
            return "Maximize glossary recall and preserve casing for product and technical terms."
        case .paste:
            return "Control paste behavior while keeping clipboard recovery conservative."
        case .advanced:
            return "Recovery routes and lower-level compatibility settings."
        }
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection {
        case .account:
            accountOverviewCard
        case .dictation:
            dictationCard
        case .polish:
            aiPolishCard
        case .recovery:
            recoveryHistoryCard
        case .terminology:
            settingsCard(title: "Terminology Dictionary") {
                terminologyDictionarySection
            }
        case .paste:
            settingsCard(title: "Paste & Clipboard") {
                Toggle("Restore clipboard after paste", isOn: $config.injection.preserveClipboard)
                Text("When no editable focus is detected, ChatType leaves the polished transcript in the clipboard for manual Cmd+V.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .advanced:
            advancedRecoveryCard
        }
    }

    private static func terminologyStatusMessage(for config: AppConfig) -> String? {
        let entries = config.transcription.terminology.entries
        guard !entries.isEmpty else {
            return nil
        }

        if let timestamp = config.transcription.terminology.lastImportedAt {
            return "Dictionary has \(entries.count) entries. Last dictionary import: \(timestamp)."
        }

        return "Dictionary has \(entries.count) entries."
    }

    private static func loadTextPolishUsage(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChatType", isDirectory: true)
    ) -> [TextPolishProviderID: TextPolishUsage] {
        let dataURL = directoryURL.appendingPathComponent("latency.jsonl")
        guard let contents = try? String(contentsOf: dataURL, encoding: .utf8) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var usage: [TextPolishProviderID: TextPolishUsage] = [:]

        for line in contents.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let sample = try? decoder.decode(LatencySample.self, from: data)
            else {
                continue
            }

            let attempted = sample.textPolishAttempted ?? (sample.polishMs > 0 || sample.textPolishProvider != nil)
            guard attempted else {
                continue
            }

            let provider = sample.textPolishProvider.flatMap(TextPolishProviderID.init(rawValue:)) ?? .chatGPTAuth
            var current = usage[provider] ?? TextPolishUsage()
            current.attempts += 1
            if sample.textPolishProvider != nil {
                current.succeeded += 1
                current.inputTokens += sample.estimatedPolishInputTokens
                current.outputTokens += sample.estimatedPolishOutputTokens
            } else {
                current.failed += 1
            }
            usage[provider] = current
        }

        return usage
    }

    private func refreshTextPolishStatus() {
        textPolishUsage = Self.loadTextPolishUsage()
    }

    private func refreshRecentHistory() {
        recentHistoryRecords = onLoadRecentHistory()
    }

    private func refreshRecoveryHistory() {
        recentRecoveryRecords = onLoadRecoveryHistory()
    }

    private var recentRecoveryItems: [RecoveryHistoryPreview] {
        RecoveryHistoryPreview.recentItems(
            from: recentRecoveryRecords,
            kind: selectedRecoveryKind,
            limit: 10
        )
    }

    private var recentDictationHistoryItems: [TranscriptionHistoryPreview] {
        TranscriptionHistoryPreview.recentItems(
            from: recentHistoryRecords,
            limit: 5,
            textSource: .dictation
        )
    }

    private var recentPolishHistoryItems: [TranscriptionHistoryPreview] {
        TranscriptionHistoryPreview.recentItems(
            from: recentHistoryRecords,
            limit: 5,
            textSource: .polish
        )
    }

    private var filteredTerminologyEntries: [(offset: Int, entry: TerminologyEntry)] {
        config.transcription.terminology.entries.enumerated().compactMap { offset, entry in
            let include: Bool
            switch terminologyFilter {
            case .all:
                include = true
            case .terms:
                include = entry.type == .term
            case .corrections:
                include = entry.type == .correction
            }
            return include ? (offset: offset, entry: entry) : nil
        }
    }

    private var accountOverviewCard: some View {
        settingsCard(title: "Account & Permissions") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    compactSetupTile(title: "ChatGPT", status: chatGPTAccountStatus)
                    compactSetupTile(title: "Microphone", status: microphoneStatus)
                    compactSetupTile(title: "Accessibility", status: accessibilityStatus)
                }

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(authSnapshot.userEmail ?? "Connect ChatGPT to start dictation.")
                            .font(.system(size: 12, weight: .medium))
                        Text("F5 starts and stops recording. Output pastes when an editable target is focused; otherwise it stays in the clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    chatGPTSetupActions
                }

                if microphoneStatus.isReady == false || accessibilityStatus.isReady == false {
                    Divider()
                    HStack(spacing: 10) {
                        ForEach(microphoneRepairActions + accessibilityRepairActions) { action in
                            repairActionButton(action)
                        }
                    }
                }
            }
        }
    }

    private var dictationCard: some View {
        settingsCard(title: "Dictation / ASR") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Hotkey")
                    Spacer()
                    Text("F5")
                        .monospaced()
                        .foregroundStyle(.secondary)
                }

                Toggle("Feedback sounds", isOn: $config.transcription.feedbackSoundsEnabled)
                Toggle("ASR prompt cleanup", isOn: $config.transcription.speechCleanupEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Default ASR route")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("ChatGPT Account")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Uses the ChatGPT backend transcribe API. This ASR response is already lightly polished by ChatGPT and is separate from the AI Polish rewrite tab.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                historySection(
                    title: "Recent Dictation History",
                    textSource: .dictation
                )
            }
        }
    }

    private var advancedRecoveryCard: some View {
        settingsCard(title: "Current Product Route") {
            VStack(alignment: .leading, spacing: 12) {
                Text("ChatType ships as a ChatGPT account dictation app. The normal path uses the ChatGPT backend for ASR and the ChatGPT-authenticated Responses endpoint for AI Polish.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    routeRow(
                        title: "Dictation",
                        value: "ChatGPT Account",
                        detail: config.transcription.chatGPTURL
                    )
                    routeRow(
                        title: "AI Polish",
                        value: "ChatGPT Auth",
                        detail: "\(config.transcription.textPolish.chatGPTResponseModel) via \(config.transcription.textPolish.chatGPTResponseURL)"
                    )
                }

                if config.transcription.provider == .openAICompatible {
                    Divider()
                    Text("Advanced transcription recovery is selected. It uses the configured OpenAI-compatible ASR environment variable, but ChatType no longer ships a provider-key fallback matrix or text-polish provider key UI.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func routeRow(title: String, value: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var aiPolishCard: some View {
        settingsCard(title: "AI Polish") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $config.transcription.textPolish.mode) {
                    Text("Auto").tag(TextPolishMode.automaticWhenKeyAvailable)
                    Text("Always rewrite").tag(TextPolishMode.always)
                    Text("Off").tag(TextPolishMode.disabled)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 16) {
                    Toggle("Show estimates", isOn: $config.transcription.textPolish.showCostEstimates)
                    if let textPolishMessage {
                        Text(textPolishMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(textPolishMessageIsError ? .red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Test Connection") {
                        testTextPolishSelection()
                    }
                    .buttonStyle(.bordered)
                }

                polishStatusSection
                historySection(
                    title: "Recent Polish History",
                    textSource: .polish
                )
            }
        }
    }

    private var recoveryHistoryCard: some View {
        settingsCard(title: "Recent Records") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Record type", selection: $selectedRecoveryKind) {
                    Text("原始语音").tag(RecoveryHistoryKind.audio)
                    Text("ASR 转录结果").tag(RecoveryHistoryKind.asr)
                    Text("AI polish 结果").tag(RecoveryHistoryKind.polish)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("最近 10 条")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        refreshRecoveryHistory()
                    }
                    .buttonStyle(.bordered)
                }

                if recentRecoveryItems.isEmpty {
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

    private func recoveryHistoryRow(_ item: RecoveryHistoryPreview) -> some View {
        let isCopied = copiedHistoryItemID == item.id

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.target)
                        .font(.system(size: 11, weight: .medium))
                    Text(item.outcome)
                        .font(.system(size: 10))
                        .foregroundStyle(item.outcome == "error" ? .red : .secondary)
                    Text(item.timestamp.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
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
                    retryRecoveryHistoryItem(item)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 12, height: 12)
                }
                .help("Retry")
                .accessibilityLabel("Retry")
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyRecoveryHistoryItem(_ item: RecoveryHistoryPreview) {
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

    private func retryRecoveryHistoryItem(_ item: RecoveryHistoryPreview) {
        guard let record = recentRecoveryRecords.first(where: { $0.id == item.recordID }) else {
            return
        }
        onRetryRecoveryRecord(record)
    }

    private var polishStatusSection: some View {
        let usage = textPolishUsage[.chatGPTAuth] ?? TextPolishUsage()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: authSnapshot.state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(authSnapshot.state == .ready ? .green : .orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("ChatGPT Auth rewrite")
                    .font(.system(size: 12, weight: .semibold))
                Text(authSnapshot.state == .ready ? "Ready with \(config.transcription.textPolish.chatGPTResponseModel)." : authSnapshot.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Usage: \(usage.attempts) attempts, \(usage.succeeded) succeeded, \(usage.failed) failed, \(usage.inputTokens) input tokens, \(usage.outputTokens) output tokens.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func historySection(
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

    private func recentHistoryRow(_ item: TranscriptionHistoryPreview) -> some View {
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

    private func copyRecentHistoryItem(_ item: TranscriptionHistoryPreview) {
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

    private func testTextPolishSelection() {
        let selected = TextPolishProviderSelector().selectProvider(
            config: config.transcription.textPolish,
            chatGPTAuthAvailable: authSnapshot.state == .ready
        )
        if let selected {
            let model = config.transcription.textPolish.chatGPTResponseModel
            textPolishMessage = "Ready: \(selected.id.title) / \(model)."
            textPolishMessageIsError = false
        } else {
            textPolishMessage = "ChatGPT Auth is not ready. Connect ChatGPT first."
            textPolishMessageIsError = true
        }
    }

    private var terminologyDictionarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Teach ChatType the words you use")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Preserve the spelling of a term, or replace a recurring transcription mistake.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: $config.transcription.terminology.enabled)
                    .toggleStyle(.switch)
            }

            terminologyImportRow
            terminologyEditor
            terminologyLibraryHeader
            terminologyToolbar

            terminologyList
        }
    }

    private var chatGPTAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT Account")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(authSnapshot.userEmail ?? authSnapshot.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(browserBridgeSnapshot.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    statusPill(for: authSnapshot.state)
                    browserBridgePill(for: browserBridgeSnapshot.state)
                }
            }

            HStack(spacing: 10) {
                Button(isConnectingBrowserLogin ? "Waiting for Browser" : "Use Browser Login") {
                    connectViaBrowser()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnectingBrowserLogin || config.transcription.provider == .openAICompatible)

                Button("Refresh Session") {
                    Task {
                        _ = try? await authManager.refreshAccessToken()
                        await MainActor.run {
                            authSnapshot = authManager.authSnapshot()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(config.transcription.provider == .openAICompatible)

                Button("Sign out") {
                    do {
                        try authManager.signOut()
                        authSnapshot = authManager.authSnapshot()
                    } catch {
                        terminologyImportMessage = error.localizedDescription
                        terminologyImportIsError = true
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func connectViaBrowser() {
        isConnectingBrowserLogin = true
        browserBridgeSnapshot = authManager.browserBridgeSnapshot()
        Task {
            do {
                _ = try await authManager.connectViaDefaultBrowser()
                await MainActor.run {
                    authSnapshot = authManager.authSnapshot()
                    browserBridgeSnapshot = authManager.browserBridgeSnapshot()
                    isConnectingBrowserLogin = false
                    terminologyImportMessage = "Browser login connected. ChatType saved the ChatGPT session locally."
                    terminologyImportIsError = false
                }
            } catch {
                await MainActor.run {
                    authSnapshot = authManager.authSnapshot()
                    browserBridgeSnapshot = authManager.browserBridgeSnapshot()
                    isConnectingBrowserLogin = false
                    terminologyImportMessage = error.localizedDescription
                    terminologyImportIsError = true
                }
            }
        }
    }

    private func statusPill(for state: ChatGPTAuthState) -> some View {
        let label: String
        let color: Color
        switch state {
        case .ready:
            label = "Signed In"
            color = .green
        case .signedOut:
            label = "Signed Out"
            color = .orange
        case .expired:
            label = "Expired"
            color = .orange
        case .unavailable:
            label = "Unavailable"
            color = .red
        }

        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
    }

    private func browserBridgePill(for state: BrowserBridgeState) -> some View {
        let label: String
        let color: Color
        switch state {
        case .available:
            label = "OAuth Ready"
            color = .secondary
        case .waiting:
            label = "Waiting"
            color = .orange
        case .connected:
            label = "Connected"
            color = .green
        case .failed:
            label = "Failed"
            color = .red
        }

        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
    }

    private var terminologySummaryRow: some View {
        let entries = config.transcription.terminology.entries
        let termCount = entries.filter { $0.type == .term }.count
        let correctionCount = entries.filter { $0.type == .correction }.count

        return HStack(spacing: 8) {
            terminologyCountBadge(title: "Terms", count: termCount, color: .accentColor)
            terminologyCountBadge(title: "Replacements", count: correctionCount, color: .orange)
        }
    }

    private func terminologyCountBadge(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(count)")
                .fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(Capsule())
    }

    private var terminologyToolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $terminologyFilter) {
                ForEach(TerminologyFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 390)
            .labelsHidden()
            .accessibilityLabel("Filter dictionary entries")

            Spacer()
        }
    }

    private var terminologyImportRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Import a dictionary", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))

                Text(terminologyImportMessage ?? "Add many terms at once from a local text or CSV file.")
                    .font(.system(size: 11))
                    .foregroundStyle(terminologyImportIsError ? .red : .secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                importTerminologyDictionary(
                    title: "Import Text Dictionary",
                    allowedContentTypes: [.plainText],
                    message: "Choose a plain text terminology dictionary."
                )
            } label: {
                Label("Text Dictionary…", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("import-text-dictionary")

            Button {
                importTerminologyDictionary(
                    title: "Import CSV Dictionary",
                    allowedContentTypes: [.commaSeparatedText],
                    message: "Choose a CSV terminology dictionary."
                )
            } label: {
                Label("CSV Dictionary…", systemImage: "tablecells")
            }
            .accessibilityIdentifier("import-csv-dictionary")
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }

    private var terminologyLibraryHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your dictionary")
                    .font(.system(size: 12, weight: .semibold))
                Text("Review, enable, edit, or remove dictionary entries.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            terminologySummaryRow
        }
        .padding(.top, 2)
    }

    private var terminologyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    editingTerminologyIndex == nil ? "Add a custom entry" : "Edit custom entry",
                    systemImage: editingTerminologyIndex == nil ? "plus.circle.fill" : "pencil.circle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

                Text(terminologyEditorHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Picker("Entry type", selection: terminologyTypeBinding) {
                Text("Term").tag(TerminologyEntryType.term)
                Text("Replacement").tag(TerminologyEntryType.correction)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityIdentifier("terminology-entry-type")

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editingTerminologyType == .term ? "Preferred spelling" : "Spoken or incorrect text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(
                        editingTerminologyType == .term ? "e.g. OpenClaw" : "e.g. opencloud",
                        text: $editingOriginal
                    )
                    .accessibilityIdentifier("terminology-original")
                }

                if editingTerminologyType == .correction {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replace with")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. OpenClaw", text: $editingReplacement)
                            .accessibilityIdentifier("terminology-replacement")
                    }
                }

                if editingTerminologyIndex != nil {
                    Button("Cancel") {
                        clearTerminologyEditor()
                    }
                }

                Button(terminologyEditorActionTitle) {
                    saveTerminologyEditor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveTerminologyEntry)
                .accessibilityIdentifier("terminology-save-entry")
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }

    private var terminologyEditorHelp: String {
        switch editingTerminologyType {
        case .term:
            return "Keep names and technical terms spelled exactly this way."
        case .correction:
            return "Automatically fix a phrase after transcription."
        }
    }

    private var terminologyEditorActionTitle: String {
        if editingTerminologyIndex != nil {
            return "Save Changes"
        }
        return editingTerminologyType == .term ? "Add Term" : "Add Replacement"
    }

    private var terminologyList: some View {
        Group {
            if filteredTerminologyEntries.isEmpty {
                Text("No dictionary entries for this filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(filteredTerminologyEntries.prefix(5)), id: \.offset) { index, entry in
                        terminologyEntryRow(index: index, entry: entry)
                    }

                    if filteredTerminologyEntries.count > 5 {
                        Text("Showing 5 of \(filteredTerminologyEntries.count). Use the filter or edit config.json for bulk changes.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func terminologyEntryRow(index: Int, entry: TerminologyEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.type == .correction ? "Replacement" : "Term")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(entry.type == .correction ? .orange : .accentColor)
                .frame(width: 82, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if entry.type == .correction {
                    Text("\(entry.original) -> \(entry.replacement ?? "")")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text(entry.original)
                        .font(.system(size: 12, weight: .medium))
                }
                Text("\(entry.source) · \(entry.isEnabled ? "enabled" : "disabled")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { config.transcription.terminology.entries[index].isEnabled },
                set: { config.transcription.terminology.entries[index].isEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button("Edit") {
                editTerminologyEntry(at: index)
            }
            .buttonStyle(.borderless)

            Button("Delete") {
                config.transcription.terminology.entries.remove(at: index)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func editTerminologyEntry(at index: Int) {
        let entry = config.transcription.terminology.entries[index]
        editingTerminologyIndex = index
        editingTerminologyType = entry.type
        editingOriginal = entry.original
        editingReplacement = entry.replacement ?? ""
    }

    private func saveTerminologyEditor() {
        let original = editingOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return
        }

        let replacement = editingTerminologyType == .correction
            ? editingReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let entry = TerminologyEntry(
            type: editingTerminologyType,
            original: original,
            replacement: replacement,
            aliases: [],
            isEnabled: true,
            source: "user",
            usageCount: 0,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        if let editingTerminologyIndex {
            config.transcription.terminology.entries[editingTerminologyIndex] = entry
        } else {
            config.transcription.terminology.entries.append(entry)
        }

        clearTerminologyEditor()
    }

    private func clearTerminologyEditor() {
        editingTerminologyIndex = nil
        editingTerminologyType = .term
        editingOriginal = ""
        editingReplacement = ""
    }

    private var canSaveTerminologyEntry: Bool {
        let original = editingOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return false
        }

        if editingTerminologyType == .correction {
            return !editingReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return true
    }

    private func importTerminologyDictionary(
        title: String,
        allowedContentTypes: [UTType],
        message: String
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes
        panel.message = message

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        switch onImportTerminologyDictionary(config, fileURL) {
        case .success(let updatedConfig):
            config = updatedConfig
            terminologyImportMessage = Self.terminologyStatusMessage(for: updatedConfig)
            terminologyImportIsError = false
            terminologyFilter = .all
        case .failure(let error):
            terminologyImportMessage = error.localizedDescription
            terminologyImportIsError = true
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func setupRow(title: String, status: SetupStatus) -> some View {
        setupRow(title: title, status: status) {
            EmptyView()
        }
    }

    private func compactSetupTile(title: String, status: SetupStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func setupRow<Actions: View>(
        title: String,
        status: SetupStatus,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isReady ? .green : .orange)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.title)
                    .font(.system(size: 12, weight: .medium))
                Text(status.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                actions()
            }
        }
    }

    private var chatGPTSetupActions: some View {
        HStack(spacing: 10) {
            if authSnapshot.state == .ready {
                Button("Use Browser Login") {
                    connectViaBrowser()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Use Browser Login") {
                    connectViaBrowser()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Refresh") {
                Task {
                    _ = try? await authManager.refreshAccessToken()
                    await MainActor.run {
                        authSnapshot = authManager.authSnapshot()
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(config.transcription.provider == .openAICompatible)

            if authSnapshot.state == .ready || authSnapshot.state == .expired {
                Button("Sign out") {
                    do {
                        try authManager.signOut()
                        authSnapshot = authManager.authSnapshot()
                    } catch {
                        terminologyImportMessage = error.localizedDescription
                        terminologyImportIsError = true
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 6)
    }

    private var terminologyTypeBinding: Binding<TerminologyEntryType> {
        Binding(
            get: { editingTerminologyType },
            set: { editingTerminologyType = $0 }
        )
    }

    @ViewBuilder
    private func permissionSetupSection(
        title: String,
        status: SetupStatus,
        detail: String?,
        actions: [PermissionRepairAction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            setupRow(title: title, status: status)

            if let detail, !detail.isEmpty, status.isReady == false {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        repairActionButton(action)
                    }
                }
            }
        }
    }

    @MainActor
    private func performRepairAction(_ action: PermissionRepairAction) {
        switch action.kind {
        case .guidedAccessibilityAccess:
            AccessibilityPermission.guideAccess()
        case .openSettings(let destination):
            _ = destination.open()
        case .refreshStatus:
            permissionRefreshNonce += 1
        }
    }

    @ViewBuilder
    private func repairActionButton(_ action: PermissionRepairAction) -> some View {
        switch action.prominence {
        case .primary:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.borderedProminent)
        case .secondary:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.bordered)
        case .utility:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct SetupStatus {
    let title: String
    let subtitle: String
    var isReady: Bool = true
}
