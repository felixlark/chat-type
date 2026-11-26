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
    @StateObject var historyWorkspace: HistoryWorkspaceModel
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
    @State var markpipeKeyInput = ""
    var markpipeKeySaved: Bool {
        get { providers.value.markpipeKeySaved }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.markpipeKeySaved = value; return copy } }
    }
    @State var glmKeyInput = ""
    var glmKeySaved: Bool {
        get { providers.value.glmKeySaved }
        nonmutating set { let value = newValue; providers.update { var copy = $0; copy.glmKeySaved = value; return copy } }
    }
    @State var testingTextPolish = false
    let qwenKeyStore: any QwenKeyStoring
    let glmKeyStore: any GLMKeyStoring
    let markpipeKeyStore: any MarkpipeKeyStoring
    @State var textPolishMessage: String?
    @State var textPolishMessageIsError = false
    let authManager: ChatGPTAuthManager
    let onSave: (AppConfig) -> Result<Void, any Error>
    let onImportAppleContactRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onImportWeixinRemarks: () async -> Result<TerminologyImportResult, any Error>
    let onLoadHistoryIndex: @Sendable () throws -> RecoveryHistoryIndex
    let onLoadHistoryRecord: @Sendable (UUID) throws -> RecoveryRecord?
    let recoveryDirectoryURL: URL
    let onRetryRecoveryRecord: (RecoveryRecord, UUID?) -> Void
    let onReprocessRecoveryRecord: (RecoveryRecord, UUID?) -> Void
    let onOpenConfigFolder: () -> Void

    init(
        initialConfig: AppConfig,
        draft: PreferencesDraft? = nil,
        authManager: ChatGPTAuthManager,
        onSave: @escaping (AppConfig) -> Result<Void, any Error>,
        onImportAppleContactRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onImportWeixinRemarks: @escaping () async -> Result<TerminologyImportResult, any Error>,
        onLoadHistoryIndex: @escaping @Sendable () throws -> RecoveryHistoryIndex,
        onLoadHistoryRecord: @escaping @Sendable (UUID) throws -> RecoveryRecord?,
        recoveryDirectoryURL: URL,
        onRetryRecoveryRecord: @escaping (RecoveryRecord, UUID?) -> Void,
        onReprocessRecoveryRecord: @escaping (RecoveryRecord, UUID?) -> Void,
        onOpenConfigFolder: @escaping () -> Void,
        focusRecoveryHistory: Bool = false,
        glmKeyStore: any GLMKeyStoring = KeychainGLMKeyStore(),
        qwenKeyStore: any QwenKeyStoring = KeychainQwenKeyStore(),
        markpipeKeyStore: any MarkpipeKeyStoring = KeychainMarkpipeKeyStore()
    ) {
        self.qwenKeyStore = qwenKeyStore
        self.glmKeyStore = glmKeyStore
        self.markpipeKeyStore = markpipeKeyStore
        _draft = ObservedObject(wrappedValue: draft ?? PreferencesDraft(config: initialConfig))
        _providers = StateObject(wrappedValue: SettingsResource(SettingsProviderEnvironment()) {
            SettingsProviderEnvironment(auth: authManager.authSnapshot(), browser: authManager.browserBridgeSnapshot(),
                qwenKeySaved: qwenKeyStore.contains(), glmKeySaved: glmKeyStore.contains(),
                markpipeKeySaved: markpipeKeyStore.contains(),
                doubaoInstalled: SettingsProviderEnvironment.doubaoIsInstalled(), checked: true)
        })
        _usage = StateObject(wrappedValue: SettingsResource(SettingsPolishUsage()) { try SettingsPolishUsage.read() })
        _historyWorkspace = StateObject(wrappedValue: HistoryWorkspaceModel(
            recoveryDirectoryURL: recoveryDirectoryURL,
            onLoadIndex: onLoadHistoryIndex,
            onLoadRecord: onLoadHistoryRecord
        ))
        _copiedDeviceCode = State(initialValue: nil)
        _selectedSection = State(initialValue: focusRecoveryHistory ? .recovery : .account)
        self.authManager = authManager
        self.onSave = onSave
        self.onImportAppleContactRemarks = onImportAppleContactRemarks
        self.onImportWeixinRemarks = onImportWeixinRemarks
        self.onLoadHistoryIndex = onLoadHistoryIndex
        self.onLoadHistoryRecord = onLoadHistoryRecord
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
        guard providers.value.checked else { return SetupStatus(title: "检查中…", subtitle: "正在读取已保存的账户状态。", isReady: false) }
        guard authSnapshot.state == .ready else {
            return SetupStatus(title: authSnapshot.state == .signedOut ? "未连接" : "需要处理", subtitle: authSnapshot.detail, isReady: false)
        }

        if let issue = runtimeIssues.first(where: {
            switch $0 {
            case .chatGPTLoginRequired, .chatGPTSessionExpired, .chatGPTSessionUnavailable:
                return true
            default:
                return false
            }
        }) {
            return SetupStatus(title: "需要处理", subtitle: issue.message, isReady: false)
        }

        return SetupStatus(
            title: "已连接",
            subtitle: authSnapshot.detail
        )
    }

    var microphoneStatus: SetupStatus {
        _ = permissionRefreshNonce
        switch AudioRecorder.microphonePermissionState() {
        case .granted:
            return SetupStatus(title: "已授权", subtitle: "麦克风权限已就绪。")
        case .undetermined:
            return SetupStatus(title: "尚未请求", subtitle: "按一次 \(draft.activeShortcut.title)，macOS 会请求麦克风权限。", isReady: false)
        case .denied:
            return SetupStatus(
                title: "需要权限",
                subtitle: "麦克风权限曾被拒绝。请在系统设置 > 隐私与安全性 > 麦克风中重新启用。",
                isReady: false
            )
        }
    }

    var accessibilityStatus: SetupStatus {
        _ = permissionRefreshNonce
        let guidance = AccessibilityPermission.repairGuidance()

        if AccessibilityPermission.isTrusted() {
            return SetupStatus(title: "已授权", subtitle: "自动粘贴已就绪。")
        }

        return SetupStatus(
            title: "可选但建议开启",
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
                if selectedSection == .recovery {
                    HistoryWorkspaceView(
                        model: historyWorkspace,
                        recoveryDirectoryURL: recoveryDirectoryURL,
                        onRetryRecoveryRecord: onRetryRecoveryRecord,
                        onReprocessRecoveryRecord: onReprocessRecoveryRecord
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                            sectionHeader
                            selectedSectionView
                        }
                        .padding(SettingsLayout.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(selectedSection)
                }

                Divider()

                HStack {
                    Button("打开配置文件夹", action: onOpenConfigFolder)
                        .buttonStyle(.bordered)
                        .font(SettingsTypography.body)
                        .controlSize(.large)
                        .frame(minWidth: 120)
                    Spacer()
                    Text(saveMessage)
                        .font(SettingsTypography.detail)
                        .foregroundStyle(saveIsError ? .red : .secondary)
                        .lineLimit(2)
                    Button("保存设置") {
                        _ = draft.apply(using: onSave)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(SettingsTypography.bodyEmphasis)
                    .controlSize(.large)
                    .frame(minWidth: 96)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.isRecordingShortcut)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(minHeight: 58)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1200, minHeight: 680)
        .onChange(of: config) { _ in
            saveMessage = "尚未应用 · 保存设置后使用新快捷键；新录音或按当前流程重跑时应用流程选择。"
            saveIsError = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshNonce += 1
            loginItem.refresh()
            providers.refresh()

        }
        .onReceive(NotificationCenter.default.publisher(for: .recoveryRecordDidChange).receive(on: RunLoop.main)) { update in
            guard update.userInfo?["directory"] as? String == recoveryDirectoryURL.path,
                  let record = update.object as? RecoveryRecord else { return }
            historyWorkspace.recordDidChange(record, directory: recoveryDirectoryURL.path)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .chatGPTAuthStateDidChange)
                .receive(on: RunLoop.main)
        ) { _ in
            providers.refresh()
        }
        .onAppear { providers.refresh(); if selectedSection == .recovery { historyWorkspace.activate() } }
        .onChange(of: selectedSection) { section in
            draft.endShortcutCapture()
            if section == .recovery { historyWorkspace.activate() }
        }
        .onDisappear { draft.endShortcutCapture(); providers.cancel(); usage.cancel(); historyWorkspace.cancel() }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ChatType")
                    .font(.system(size: 26, weight: .semibold))
                Text("Speak. Make it clear.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 20)
                        Text(section.rawValue)
                        Spacer()
                    }
                    .font(SettingsTypography.nav)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
            Label("\(draft.activeShortcut.title) 开始 / 停止", systemImage: "mic")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(width: SettingsLayout.sidebarWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("ChatType")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text(selectedSection.rawValue)
            }
            .font(SettingsTypography.caption)
            .foregroundStyle(.secondary)
            Text(selectedSection.rawValue)
                .font(SettingsTypography.pageTitle)
            Text(sectionSubtitle)
                .font(SettingsTypography.pageSubtitle)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    var sectionSubtitle: String {
        switch selectedSection {
        case .account: return "查看每项服务能做什么、是否可用，以及凭据是否已保存。"
        case .workflow: return "看清每一步用什么、输入什么、输出什么。"
        case .recovery: return "原声、转写、对齐、润色与校正，一屏查看。"
        case .settings: return "快捷键、启动项、权限和本地数据。"
        }
    }

    @ViewBuilder
    var selectedSectionView: some View {
        switch selectedSection {
        case .account:
            accountOverviewCard
        case .workflow:
            ProcessingFlowView(config: $draft.config.transcription, injection: $draft.config.injection, chatGPTReady: authSnapshot.state == .ready,
                glmReady: glmKeySaved, qwenReady: qwenKeySaved, deepSeekReady: markpipeKeySaved,
                recognitionOptions: transcriptionAccountCard, polishOptions: aiPolishCard,
                termsOptions: terminologyEditor(.term), correctionOptions: terminologyEditor(.correction))
        case .recovery: EmptyView()
        case .settings: localSettingsCard
        }
    }

}

struct SetupStatus {
    let title: String
    let subtitle: String
    var isReady: Bool = true
}
