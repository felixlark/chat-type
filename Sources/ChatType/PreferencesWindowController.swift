import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        config: AppConfig,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Result<Void, any Error>,
        onImportAppleContactRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onImportWeixinRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onLoadRecentHistory: @escaping () -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping () -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false,
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        let view = PreferencesView(
            initialConfig: config,
            authManager: authManager,
            onSave: onSave,
            onImportAppleContactRemarks: onImportAppleContactRemarks,
            onImportWeixinRemarks: onImportWeixinRemarks,
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            onQuit: { NSApp.terminate(nil) }
        )
        window.minSize = NSSize(width: 940, height: 680)
        window.title = "ChatType Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentViewController = hostingController

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class CommandClosingWindow: NSWindow {
    private let onQuit: () -> Void

    init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
        onQuit: @escaping () -> Void
    ) {
        self.onQuit = onQuit
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let isCommandOnly = modifiers == .command
        let key = event.charactersIgnoringModifiers?.lowercased()

        if event.type == .keyDown, isCommandOnly, key == "q" {
            onQuit()
            return true
        }

        if event.type == .keyDown, isCommandOnly, key == "w" {
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
        case terminology = "Terminology"
        case recovery = "History"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .dictation:
                return "mic"
            case .recovery:
                return "clock.arrow.circlepath"
            case .terminology:
                return "text.book.closed"
            case .settings:
                return "gearshape"
            }
        }
    }

    @StateObject private var loginItem = LoginItemController()
    @State private var saveMessage = "Changes apply to the next recording after saving."
    @State private var saveIsError = false
    @State private var importingNames = false
    @State private var config: AppConfig
    @State private var permissionRefreshNonce: Int = 0
    @State private var terminologyImportMessage: String?
    @State private var terminologyImportIsError = false
    @State private var authSnapshot: ChatGPTAuthSnapshot
    @State private var browserBridgeSnapshot: BrowserBridgeSnapshot
    @State private var isConnectingBrowserLogin = false
    @State private var copiedDeviceCode: String?
    @State private var selectedSection: SettingsSection = .account
    @State private var textPolishUsage: [TextPolishProviderID: TextPolishUsage] = [:]
    @State private var unattributedPolishAttempts = 0
    @State private var qwenKeyInput = ""
    @State private var qwenKeySaved = false
    @State private var polishTestGeneration = UUID()
    @State private var glmKeyInput = ""
    @State private var glmKeySaved = false
    @State private var testingTextPolish = false
    private let qwenKeyStore: any QwenKeyStoring
    private let glmKeyStore: any GLMKeyStoring
    @State private var textPolishMessage: String?
    @State private var textPolishMessageIsError = false
    @State private var recentHistoryRecords: [TranscriptionHistoryRecord] = []
    @State private var recentRecoveryRecords: [RecoveryRecord] = []
    @State private var selectedRecoveryKind: RecoveryHistoryKind = .audio
    @State private var copiedHistoryItemID: String?

    let authManager: ChatGPTAuthManager
    let onSave: (AppConfig) -> Result<Void, any Error>
    let onImportAppleContactRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onImportWeixinRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onLoadRecentHistory: () -> [TranscriptionHistoryRecord]
    let onLoadRecoveryHistory: () -> [RecoveryRecord]
    let recoveryDirectoryURL: URL
    let onRetryRecoveryRecord: (RecoveryRecord) -> Void
    let onOpenConfigFolder: () -> Void

    init(
        initialConfig: AppConfig,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Result<Void, any Error>,
        onImportAppleContactRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onImportWeixinRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onLoadRecentHistory: @escaping () -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping () -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false,
        glmKeyStore: any GLMKeyStoring = KeychainGLMKeyStore(),
        qwenKeyStore: any QwenKeyStoring = KeychainQwenKeyStore()
    ) {
        self.qwenKeyStore = qwenKeyStore
        _qwenKeySaved = State(initialValue: qwenKeyStore.contains())
        self.glmKeyStore = glmKeyStore
        _glmKeySaved = State(initialValue: glmKeyStore.contains())
        _config = State(initialValue: initialConfig)
        _authSnapshot = State(initialValue: authManager.authSnapshot())
        _browserBridgeSnapshot = State(initialValue: authManager.browserBridgeSnapshot())
        _copiedDeviceCode = State(initialValue: nil)
        let polishUsage = Self.loadTextPolishUsage()
        _textPolishUsage = State(initialValue: polishUsage.usage)
        _unattributedPolishAttempts = State(initialValue: polishUsage.unattributed)
        _selectedSection = State(initialValue: focusRecoveryHistory ? .recovery : .account)
        self.authManager = authManager
        self.onSave = onSave
        self.onImportAppleContactRemarks = onImportAppleContactRemarks
        self.onImportWeixinRemarks = onImportWeixinRemarks
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
        if !config.transcription.needsChatGPT {
            return SetupStatus(
                title: "ChatGPT is optional for this route",
                subtitle: "Only a selected ChatGPT recognition or polish stage requires its account."
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
                .id(selectedSection)

                Divider()

                HStack {
                    Button("Open Config Folder", action: onOpenConfigFolder)
                    Spacer()
                    Text(saveMessage).font(.caption).foregroundStyle(saveIsError ? .red : .secondary)
                        .lineLimit(2)
                    Button("Save Settings") {
                        if config.transcription.textPolish.mode != .disabled {
                            if config.transcription.textPolish.provider == .qwenFlash && !qwenKeyStore.contains() {
                                selectedSection = .account
                                saveMessage = "Save the Qwen API key in Account, or turn AI Polish off."
                                saveIsError = true; return
                            }
                            if config.transcription.textPolish.provider == .glmFlash && !glmKeyStore.contains() {
                                selectedSection = .account
                                saveMessage = "Save the GLM API key in Account, or turn AI Polish off."
                                saveIsError = true; return
                            }
                        }
                        switch onSave(config) {
                        case .success: saveMessage = "Saved · applies to the next recording."; saveIsError = false
                        case .failure(let error): saveMessage = error.localizedDescription; saveIsError = true
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .onChange(of: config) { _ in
            saveMessage = "Unsaved changes · save to apply to the next recording."
            saveIsError = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshNonce += 1
            loginItem.refresh()
            authSnapshot = authManager.authSnapshot()
            browserBridgeSnapshot = authManager.browserBridgeSnapshot()
            refreshTextPolishStatus()
            refreshRecentHistory()
            refreshRecoveryHistory()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .chatGPTAuthStateDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
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
                Text("Speak. Make it clear.")
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
            Label("F5  start / stop", systemImage: "mic")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("ChatType")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text(selectedSection.rawValue)
            }.font(.caption).foregroundStyle(.secondary)
            Text(selectedSection.rawValue)
                .font(.system(size: 22, weight: .semibold))
            Text(sectionSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .account: return "Your accounts, services and models. Set up once, then press F5."
        case .dictation: return "From your voice to finished text. See what each step receives and sends."
        case .terminology: return "The words you use, spelled the way you intend."
        case .recovery: return "Review original recognition, finished text and saved audio."
        case .settings: return "Local preferences, login items and paste behavior."
        }
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection {
        case .account:
            accountOverviewCard
            transcriptionAccountCard
            aiPolishCard
        case .dictation:
            ProcessingFlowView(config: $config.transcription, injection: $config.injection, chatGPTReady: authSnapshot.state == .ready,
                glmReady: glmKeySaved, qwenReady: qwenKeySaved)
            dictationCard
        case .terminology:
            TerminologyEditor(terminology: $config.transcription.terminology,
                importContacts: onImportAppleContactRemarks, importWeChat: onImportWeixinRemarks, importing: $importingNames)
        case .recovery: recoveryHistoryCard
        case .settings: localSettingsCard
        }
    }

    private var transcriptionAccountCard: some View {
        settingsCard(title: "Audio transcription service") {
            Picker("Service", selection: $config.transcription.provider) {
                ForEach(TranscriptionProvider.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("transcription-service")
            if config.transcription.provider == .chatGPTManagedAuth {
                routeRow(title: "Model", value: "Selected by ChatGPT", detail: "The private transcription service does not expose a selectable model ID.")
                Text("Complete recordings go to chatgpt.com. Local Codex login supplies the ChatGPT session. This private backend can change or return a challenge; saved audio remains available in History.")
                    .foregroundStyle(.secondary)
            } else if config.transcription.provider == .doubaoIME {
                Text(config.transcription.provider.caption).foregroundStyle(.secondary)
                Text("不需要豆包账户登录。音频发送到 frontier-audio-ime-ws.doubao.com；先从 is.snssdk.com 取得配置。模型由服务端决定。已知识别与改口整理仍可能出错，请核对终稿。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("更新豆包识别配置") {
                    Task {
                        do { _ = try await DoubaoCredentials.shared.key(refresh: true); saveMessage = "豆包配置已保存到 Keychain；未上传音频。"; saveIsError = false }
                        catch { saveMessage = error.localizedDescription; saveIsError = true }
                    }
                }
            } else {
                TextField("Transcription endpoint", text: $config.transcription.openAITranscriptionURL)
                TextField("Audio model", text: $config.transcription.openAIModel)
                TextField("API key environment variable", text: $config.transcription.openAIAuthTokenEnv)
                Text("Advanced recovery uses your own API credentials and may incur usage charges. ChatGPT login credentials are never sent to this endpoint. No automatic provider switching.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localSettingsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard(title: "Startup") {
                Toggle("Launch ChatType at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .accessibilityIdentifier("launch-at-login")
                Text("Starts the installed menu-bar app when you sign in to this Mac. This switch takes effect immediately.")
                    .foregroundStyle(.secondary)
                if loginItem.status == .requiresApproval {
                    Text("Waiting for approval in macOS Login Items.").foregroundStyle(.orange)
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                }
                if let message = loginItem.message { Text(message).foregroundStyle(.red) }
            }
            settingsCard(title: "Paste & clipboard") {
                Toggle("仅复制到剪贴板", isOn: $config.injection.clipboardOnly)
            Toggle("Restore clipboard after paste", isOn: $config.injection.preserveClipboard)
                Text("With a focused editable target, finished text is pasted there. Otherwise it remains in the clipboard for Cmd+V.")
                    .foregroundStyle(.secondary)
                Toggle("Recording feedback sounds", isOn: $config.transcription.feedbackSoundsEnabled)
            }
            settingsCard(title: "Permissions") {
                setupRow(title: "Microphone", status: microphoneStatus)
                setupRow(title: "Accessibility", status: accessibilityStatus)
                ForEach(microphoneRepairActions + accessibilityRepairActions) { repairActionButton($0) }
            }
            settingsCard(title: "Local data") {
                Text("Configuration and vocabulary stay in ChatType’s local folder; credentials use macOS Keychain. History contains recognized text and recoverable recordings.")
                    .foregroundStyle(.secondary)
                Button("Open Local Data Folder", action: onOpenConfigFolder)
            }
        }
    }

    private static func loadTextPolishUsage(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChatType", isDirectory: true)
    ) -> (usage: [TextPolishProviderID: TextPolishUsage], unattributed: Int) {
        let dataURL = directoryURL.appendingPathComponent("latency.jsonl")
        guard let contents = try? String(contentsOf: dataURL, encoding: .utf8) else {
            return ([:], 0)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var usage: [TextPolishProviderID: TextPolishUsage] = [:]
        var unattributed = 0

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

            guard let provider = sample.textPolishProvider.flatMap(TextPolishProviderID.init(rawValue:)) else {
                unattributed += 1
                continue
            }
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

        return (usage, unattributed)
    }

    private func refreshTextPolishStatus() {
        let loaded = Self.loadTextPolishUsage()
        textPolishUsage = loaded.usage
        unattributedPolishAttempts = loaded.unattributed
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

    private var accountOverviewCard: some View {
        settingsCard(title: "ChatGPT account") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    compactSetupTile(title: "ChatGPT", status: chatGPTAccountStatus)
                    compactSetupTile(title: "Microphone", status: microphoneStatus)
                    compactSetupTile(title: "Accessibility", status: accessibilityStatus)
                }

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(authSnapshot.userEmail ?? "豆包无需 ChatGPT 登录；选择 ChatGPT 阶段时再连接。")
                            .font(.system(size: 12, weight: .medium))
                        Text("F5 starts and stops recording. Output pastes when an editable target is focused; otherwise it stays in the clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    chatGPTSetupActions
                }

                if let terminologyImportMessage {
                    Text(terminologyImportMessage).font(.caption).foregroundStyle(terminologyImportIsError ? .red : .secondary)
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
        settingsCard(title: "Writing preferences") {
            HStack {
                Button("豆包识别＋豆包整理") {
                    config.transcription.provider = .doubaoIME
                    config.transcription.textPolish.provider = .doubaoIME
                    config.transcription.textPolish.mode = .automaticWhenKeyAvailable
                }.accessibilityIdentifier("preset-doubao")
                Button("ChatGPT 识别＋ChatGPT 润色") {
                    config.transcription.provider = .chatGPTManagedAuth
                    config.transcription.textPolish.provider = .chatGPTAuth
                    config.transcription.textPolish.chatGPTAuthEnabled = true
                    config.transcription.textPolish.mode = .automaticWhenKeyAvailable
                }.accessibilityIdentifier("preset-chatgpt")
            }
            Text("组合只更改两个云端阶段；每阶段的选择仍可单独调整，保存后用于下一次录音。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Clean filler words and spoken corrections", isOn: $config.transcription.speechCleanupEnabled)
                .disabled(config.transcription.provider == .doubaoIME)
            if config.transcription.provider == .doubaoIME {
                Text("豆包识别的清理方式由服务端决定；本地术语对齐和纠错可在上方分别开关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Asks the audio transcription service to remove fillers and repetitions while preserving your intended meaning. F5 starts and stops; Escape cancels.").foregroundStyle(.secondary)
            Toggle("Polish the full transcript", isOn: Binding(
                get: { config.transcription.textPolish.isEnabled },
                set: { config.transcription.textPolish.setEnabled($0) }
            )).accessibilityIdentifier("polish-enabled")
            Text("Uses the service and model selected in Account. Input is the complete recognized text plus relevant terms. Audio stays in the transcription step. If polish fails, the completed stages are saved and processing remains incomplete; no text is pasted.")
                .foregroundStyle(.secondary)
            Button("Configure services & models") { selectedSection = .account }
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

    private var polishRouteDetail: String {
        switch config.transcription.textPolish.provider {
        case .doubaoIME: return "豆包文字整理 · ime.doubao.com（私有接口）"
        case .chatGPTAuth: return "\(config.transcription.textPolish.chatGPTResponseModel) via \(config.transcription.textPolish.chatGPTResponseURL)"
        case .glmFlash: return "glm-4.7-flash via open.bigmodel.cn"
        case .qwenFlash: return "qwen-flash via dashscope.aliyuncs.com (Beijing)"
        }
    }

    private var aiPolishCard: some View {
        settingsCard(title: "Text polish service") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Service", selection: Binding(get: { config.transcription.textPolish.provider }, set: { config.transcription.textPolish.selectProvider($0) })) {
                    ForEach(TextPolishProviderID.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .onChange(of: config.transcription.textPolish.provider) { _ in
                    if config.transcription.textPolish.provider == .chatGPTAuth { config.transcription.textPolish.chatGPTAuthEnabled = true }
                    polishTestGeneration = UUID()
                    testingTextPolish = false
                    textPolishMessage = nil
                    textPolishMessageIsError = false
                }
                if config.transcription.textPolish.provider == .qwenFlash {
                    HStack {
                        SecureField("Qwen API Key", text: $qwenKeyInput)
                            .accessibilityIdentifier("qwen-api-key")
                        Button("Save Key") { saveQwenKey() }
                        Text(qwenKeySaved ? "Key saved" : "Key not saved")
                            .font(.system(size: 11))
                    }
                    Text("Qwen Flash, Beijing: eligible free quota is used first, then usage billing. Full transcript and relevant glossary go to dashscope.aliyuncs.com; ASR follows the selected dictation route. Save Settings applies the provider to the next recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .glmFlash {
                    HStack {
                        SecureField("GLM API Key", text: $glmKeyInput)
                            .accessibilityIdentifier("glm-api-key")
                        Button("Save Key") { saveGLMKey() }
                        Text(glmKeySaved ? "Key saved" : "Key not saved")
                            .font(.system(size: 11))
                    }
                    Text("GLM-4.7-Flash uses your vendor account quota and current pricing. Full transcript and relevant glossary go to open.bigmodel.cn; ASR follows the selected dictation route. Save Settings applies the provider to the next recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .chatGPTAuth {
                    HStack {
                        Text("Text model").frame(width: 90, alignment: .leading)
                        TextField("Model ID", text: $config.transcription.textPolish.chatGPTResponseModel)
                            .accessibilityIdentifier("polish-model")
                    }
                    Text("Text model: only the text polish step uses this model. A larger model may improve rewriting and take longer; available models follow your ChatGPT account. Audio recognition uses its own server-selected model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(config.transcription.textPolish.provider == .doubaoIME
                    ? "输入：上一阶段的全文。输出：整理后的全文。本地词表不作为额外提示上传；不承诺云端热词生效。服务：ime.doubao.com。"
                    : "Input: aligned full transcript + relevant glossary. Output: rewritten text. Selected service: \(polishRouteDetail). Credentials stay in Keychain. A saved key has not been verified by a request.")
                    .font(.caption).foregroundStyle(.secondary)
                polishStatusSection
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
                .help("Recognize saved audio using current terminology and settings")
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

    private func saveQwenKey() {
        do {
            try qwenKeyStore.save(qwenKeyInput)
            qwenKeyInput = ""
            qwenKeySaved = qwenKeyStore.contains()
            textPolishMessage = "Qwen Key saved. Save Settings to apply the provider."
            textPolishMessageIsError = false
        } catch {
            textPolishMessage = error.localizedDescription
            textPolishMessageIsError = true
        }
    }

    private func saveGLMKey() {
        do {
            try glmKeyStore.save(glmKeyInput)
            glmKeyInput = ""
            glmKeySaved = glmKeyStore.contains()
            textPolishMessage = "GLM Key saved. Save Settings to apply the provider."
            textPolishMessageIsError = false
        } catch {
            textPolishMessage = error.localizedDescription
            textPolishMessageIsError = true
        }
    }

    private func testTextPolishSelection() {
        let selected = TextPolishProviderSelector().selectProvider(
            config: config.transcription.textPolish,
            chatGPTAuthAvailable: authSnapshot.state == .ready,
            glmKeyAvailable: glmKeyStore.contains(),
            qwenKeyAvailable: qwenKeyStore.contains()
        )
        guard let selected else {
            textPolishMessage = config.transcription.textPolish.provider == .qwenFlash ? "先保存 Qwen API Key，或检查 Mode。" : config.transcription.textPolish.provider == .glmFlash ? "先保存 GLM API Key，或检查 Mode。" : "ChatGPT Auth is not ready. Connect ChatGPT first."
            textPolishMessageIsError = true
            return
        }
        let generation = UUID()
        polishTestGeneration = generation
        testingTextPolish = true
        textPolishMessage = "Testing \(selected.id.title)…"
        textPolishMessageIsError = false
        let polisher = OpenAICompatibleTextPolisher(
            config: config.transcription.textPolish, chatGPTAuthProvider: authManager,
            chatGPTAuthAvailable: authSnapshot.state == .ready, glmKeyStore: glmKeyStore, qwenKeyStore: qwenKeyStore
        )
        Task { @MainActor in
            defer { if polishTestGeneration == generation { testingTextPolish = false } }
            do {
                _ = try await polisher.polish(text: "请保留 ChatType 与 F5，只整理这句话。", terminologyEntries: [], hintTerms: [])
                guard polishTestGeneration == generation else { return }
                textPolishMessage = "Connected: \(selected.id.title)."
                textPolishMessageIsError = false
            } catch {
                guard polishTestGeneration == generation else { return }
                textPolishMessage = error.localizedDescription
                textPolishMessageIsError = true
            }
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
                Button(browserLoginIsInProgress ? "Waiting for Authorization" : "Connect ChatGPT") {
                    connectViaBrowser()
                }
                .buttonStyle(.borderedProminent)
                .disabled(browserLoginIsInProgress)

                Button("Refresh Session") {
                    Task {
                        _ = try? await authManager.refreshAccessToken()
                        await MainActor.run {
                            authSnapshot = authManager.authSnapshot()
                        }
                    }
                }
                .buttonStyle(.bordered)

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

            if let userCode = browserBridgeSnapshot.userCode {
                deviceAuthorizationCard(userCode: userCode)
            }
        }
        .padding(.vertical, 4)
    }

    private func connectViaBrowser() {
        guard browserLoginIsInProgress == false else {
            return
        }

        isConnectingBrowserLogin = true
        browserBridgeSnapshot = authManager.browserBridgeSnapshot()

        Task { @MainActor in
            do {
                _ = try await authManager.connectViaDefaultBrowser()
                authSnapshot = authManager.authSnapshot()
                browserBridgeSnapshot = authManager.browserBridgeSnapshot()
                isConnectingBrowserLogin = false
                terminologyImportMessage = "ChatGPT connected. ChatType saved the session locally."
                terminologyImportIsError = false
            } catch {
                authSnapshot = authManager.authSnapshot()
                browserBridgeSnapshot = authManager.browserBridgeSnapshot()
                isConnectingBrowserLogin = false
                terminologyImportMessage = error.localizedDescription
                terminologyImportIsError = true
            }
        }
    }

    private var browserLoginIsInProgress: Bool {
        if case .waiting = browserBridgeSnapshot.state {
            return true
        }
        return isConnectingBrowserLogin
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
            label = "Device Login Ready"
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if authSnapshot.state == .ready {
                    Button(browserLoginIsInProgress ? "Waiting for Authorization" : "Connect ChatGPT") {
                        connectViaBrowser()
                    }
                    .buttonStyle(.bordered)
                    .disabled(browserLoginIsInProgress)
                } else {
                    Button(browserLoginIsInProgress ? "Waiting for Authorization" : "Connect ChatGPT") {
                        connectViaBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browserLoginIsInProgress)
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

            if let userCode = browserBridgeSnapshot.userCode {
                deviceAuthorizationCard(userCode: userCode)
            }
        }
        .padding(.top, 6)
    }

    private func deviceAuthorizationCard(userCode: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish sign-in in the OpenAI page", systemImage: "rectangle.and.hand.point.up.left")
                .font(.system(size: 13, weight: .semibold))

            Text("1. Copy this one-time code.")
                .font(.system(size: 12))

            HStack(spacing: 12) {
                Text(userCode)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Button(copiedDeviceCode == userCode ? "Copied" : "Copy Device Code") {
                    copyDeviceCode(userCode)
                }
                .buttonStyle(.borderedProminent)

                Button(chromeApplicationURL == nil ? "Open Login Page" : "Open in Chrome") {
                    openDeviceAuthorizationPage()
                }
                .buttonStyle(.bordered)
            }

            Text("2. Paste all 9 characters into the browser.  3. Click Continue.  4. Return here; ChatType will finish automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The code expires after 15 minutes. If it fails, click Connect ChatGPT again to generate a new code.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func copyDeviceCode(_ userCode: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
        copiedDeviceCode = userCode

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copiedDeviceCode == userCode {
                copiedDeviceCode = nil
            }
        }
    }

    private var chromeApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    private func openDeviceAuthorizationPage() {
        guard let chromeApplicationURL else {
            NSWorkspace.shared.open(BrowserAuthBridge.deviceVerificationURL)
            return
        }

        NSWorkspace.shared.open(
            [BrowserAuthBridge.deviceVerificationURL],
            withApplicationAt: chromeApplicationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

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
