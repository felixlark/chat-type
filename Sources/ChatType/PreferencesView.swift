import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

struct PreferencesView: View {
    enum SettingsSection: String, CaseIterable, Identifiable {
        case account = "Account"
        case workflow = "Workflow"
        case recovery = "History"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .workflow:
                return "mic"
            case .recovery:
                return "clock.arrow.circlepath"
            case .settings:
                return "gearshape"
            }
        }
    }

    @StateObject var loginItem = LoginItemController()
    @ObservedObject var draft: PreferencesDraft
    var saveMessage: String { get { draft.message } nonmutating set { draft.message = newValue } }
    var saveIsError: Bool { get { draft.isError } nonmutating set { draft.isError = newValue } }
    @State var importingNames = false
    var config: AppConfig { get { draft.config } nonmutating set { draft.config = newValue } }
    @State var permissionRefreshNonce: Int = 0
    @State var terminologyImportMessage: String?
    @State var terminologyImportIsError = false
    @StateObject var providers: SettingsResource<SettingsProviderEnvironment>
    @StateObject var usage: SettingsResource<SettingsPolishUsage>
    @StateObject var history: SettingsResource<[TranscriptionHistoryRecord]>
    @StateObject var recovery: SettingsResource<[RecoveryRecord]>
    var authSnapshot: ChatGPTAuthSnapshot {
        get { providers.value.auth }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.auth = value; return copy } }
    }
    var browserBridgeSnapshot: BrowserBridgeSnapshot {
        get { providers.value.browser }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.browser = value; return copy } }
    }
    @State var isConnectingBrowserLogin = false
    @State var copiedDeviceCode: String?
    @State var selectedSection: SettingsSection = .account
    var textPolishUsage: [TextPolishProviderID: TextPolishUsage] { usage.value.usage }
    var unattributedPolishAttempts: Int { usage.value.unattributed }
    @State var qwenKeyInput = ""
    var qwenKeySaved: Bool {
        get { providers.value.qwenKeySaved }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.qwenKeySaved = value; return copy } }
    }
    @State var polishTestGeneration = UUID()
    @State var glmKeyInput = ""
    var glmKeySaved: Bool {
        get { providers.value.glmKeySaved }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.glmKeySaved = value; return copy } }
    }
    @State var testingTextPolish = false
    let qwenKeyStore: any QwenKeyStoring
    let glmKeyStore: any GLMKeyStoring
    @State var textPolishMessage: String?
    @State var textPolishMessageIsError = false
    var recentHistoryRecords: [TranscriptionHistoryRecord] { history.value }
    var recentRecoveryRecords: [RecoveryRecord] { recovery.value }
    @State var selectedRecoveryKind: RecoveryHistoryKind = .audio
    @State var copiedHistoryItemID: String?

    let authManager: ChatGPTAuthManager
    let onSave: (AppConfig) -> Result<Void, any Error>
    let onImportAppleContactRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onImportWeixinRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onLoadRecentHistory: @Sendable () throws -> [TranscriptionHistoryRecord]
    let onLoadRecoveryHistory: @Sendable () throws -> [RecoveryRecord]
    let recoveryDirectoryURL: URL
    let onRetryRecoveryRecord: (RecoveryRecord) -> Void
    let onReprocessRecoveryRecord: (RecoveryRecord) -> Void
    let onOpenConfigFolder: () -> Void

    init(
        initialConfig: AppConfig,
        draft: PreferencesDraft? = nil,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Result<Void, any Error>,
        onImportAppleContactRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onImportWeixinRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onLoadRecentHistory: @escaping @Sendable () throws -> [TranscriptionHistoryRecord],
        onLoadRecoveryHistory: @escaping @Sendable () throws -> [RecoveryRecord],
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onReprocessRecoveryRecord: @escaping (RecoveryRecord) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false,
        glmKeyStore: any GLMKeyStoring = KeychainGLMKeyStore(),
        qwenKeyStore: any QwenKeyStoring = KeychainQwenKeyStore()
    ) {
        self.qwenKeyStore = qwenKeyStore
        self.glmKeyStore = glmKeyStore
        _draft = ObservedObject(wrappedValue: draft ?? PreferencesDraft(config: initialConfig))
        _providers = StateObject(wrappedValue: SettingsResource(SettingsProviderEnvironment()) {
            SettingsProviderEnvironment(auth: authManager.authSnapshot(), browser: authManager.browserBridgeSnapshot(),
                qwenKeySaved: qwenKeyStore.contains(), glmKeySaved: glmKeyStore.contains(),
                doubaoInstalled: SettingsProviderEnvironment.doubaoIsInstalled(), checked: true)
        })
        _usage = StateObject(wrappedValue: SettingsResource(SettingsPolishUsage()) { try SettingsPolishUsage.read() })
        _history = StateObject(wrappedValue: SettingsResource([]) { try onLoadRecentHistory() })
        _recovery = StateObject(wrappedValue: SettingsResource([]) { try onLoadRecoveryHistory() })
        _copiedDeviceCode = State(initialValue: nil)
        _selectedSection = State(initialValue: focusRecoveryHistory ? .recovery : .account)
        self.authManager = authManager
        self.onSave = onSave
        self.onImportAppleContactRemarks = onImportAppleContactRemarks
        self.onImportWeixinRemarks = onImportWeixinRemarks
        self.onLoadRecentHistory = onLoadRecentHistory
        self.onLoadRecoveryHistory = onLoadRecoveryHistory
        self.recoveryDirectoryURL = recoveryDirectoryURL
        self.onRetryRecoveryRecord = onRetryRecoveryRecord
        self.onReprocessRecoveryRecord = onReprocessRecoveryRecord
        self.onOpenConfigFolder = onOpenConfigFolder
    }

    var runtimeIssues: [RuntimePreflightIssue] {
        RuntimePreflight.issues(
            for: config,
            environment: ProcessInfo.processInfo.environment,
            authSnapshotProvider: { authSnapshot }
        )
    }

    var chatGPTAccountStatus: SetupStatus {
        guard providers.value.checked else { return SetupStatus(title: "Checking…", subtitle: "Reading saved account status.", isReady: false) }
        guard authSnapshot.state == .ready else {
            return SetupStatus(title: authSnapshot.state == .signedOut ? "Not connected" : "Needs attention", subtitle: authSnapshot.detail, isReady: false)
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

    var microphoneStatus: SetupStatus {
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

    var accessibilityStatus: SetupStatus {
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

    var accessibilityRepairActions: [PermissionRepairAction] {
        guard !AccessibilityPermission.isTrusted() else {
            return []
        }

        return AccessibilityPermission.repairActions()
    }

    var microphoneRepairActions: [PermissionRepairAction] {
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
                        _ = draft.apply(using: onSave)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .onChange(of: config) { _ in
            saveMessage = "尚未应用 · F5 新录音或按当前流程重跑时会应用；正在处理的录音保持原路线。"
            saveIsError = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshNonce += 1
            loginItem.refresh()
            providers.refresh()
            if selectedSection == .recovery { refreshRecentHistory(); refreshRecoveryHistory() }

        }
        .onReceive(NotificationCenter.default.publisher(for: .recoveryRecordDidChange).receive(on: RunLoop.main)) { update in
            guard update.userInfo?["directory"] as? String == recoveryDirectoryURL.path,
                  let record = update.object as? RecoveryRecord else { return }
            // Update the touched row directly: no synchronous scan/decode of
            // the entire original-audio archive on the UI or processing path.
            recovery.update { records in
                var updated = records.filter { $0.id != record.id }
                updated.append(record)
                return Array(updated.sorted { $0.timestamp < $1.timestamp }.suffix(10))
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .chatGPTAuthStateDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            providers.refresh()
        }
        .onAppear { providers.refresh(); refreshVisibleSection() }
        .onChange(of: selectedSection) { _ in refreshVisibleSection() }
        .onDisappear { providers.cancel(); usage.cancel(); history.cancel(); recovery.cancel() }
    }

    var sidebar: some View {
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

    var sectionHeader: some View {
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

    var sectionSubtitle: String {
        switch selectedSection {
        case .account: return "查看各个服务的账户、安装与密钥状态；在 Workflow 中组合处理流程。"
        case .workflow: return "From your voice to finished text. See what each step receives and sends."
        case .recovery: return "Review original recognition, finished text and saved audio."
        case .settings: return "Local preferences, login items and paste behavior."
        }
    }

    @ViewBuilder
    var selectedSectionView: some View {
        switch selectedSection {
        case .account:
            accountOverviewCard
        case .workflow:
            ProcessingFlowView(config: $draft.config.transcription, injection: $draft.config.injection, chatGPTReady: authSnapshot.state == .ready,
                glmReady: glmKeySaved, qwenReady: qwenKeySaved,
                recognitionOptions: transcriptionAccountCard, polishOptions: aiPolishCard,
                termsOptions: terminologyEditor(.term), correctionOptions: terminologyEditor(.correction))
        case .recovery: recoveryHistoryCard
        case .settings: localSettingsCard
        }
    }

}

struct SetupStatus {
    let title: String
    let subtitle: String
    var isReady: Bool = true
}
