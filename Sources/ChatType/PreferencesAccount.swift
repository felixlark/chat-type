import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    var accountOverviewCard: some View {
        settingsCard(
            title: "服务",
            subtitle: "每项服务标明实时预览、识别和润色能力；绿色表示当前可用或凭据已保存，红色表示仍需配置。权限统一在 Settings 管理。"
        ) {
            providerRow(
                "ChatGPT Account",
                status: chatGPTAccountStatus.title,
                ready: providers.value.checked ? chatGPTAccountStatus.isReady : nil,
                capabilities: [.recognition, .polish],
                detail: "识别完整录音 · 润色使用账户会话 · \(authSnapshot.userEmail ?? authSnapshot.detail)",
                accessory: {
                    if authSnapshot.state == .ready || authSnapshot.state == .expired {
                        chatGPTAccountMenu
                    }
                }
            )
            if !chatGPTAccountStatus.isReady {
                chatGPTSetupActions
            }
            Divider()
            providerRow(
                "Doubao IME",
                status: !providers.value.checked ? "检查中…" : providers.value.doubaoInstalled ? "已安装" : "未安装",
                ready: providers.value.checked ? providers.value.doubaoInstalled : nil,
                capabilities: [.livePreview, .recognition, .polish],
                detail: "实时预览/完整识别/文字整理由服务端选模型；安装状态不代表云端已验证。"
            )
            Divider()
            providerRow(
                "Apple SpeechAnalyzer",
                status: LocalSpeechPreviewAvailability.isAvailable ? "可用" : "不可用",
                ready: LocalSpeechPreviewAvailability.isAvailable,
                capabilities: [.livePreview],
                detail: "本机预览，仅配合 ChatGPT 识别；不生成最终转写。"
            )
            Divider()
            providerRow(
                "GLM",
                status: providers.value.checked ? (glmKeySaved ? "已保存" : "需要填写") : "检查中…",
                ready: providers.value.checked ? glmKeySaved : nil,
                capabilities: [.polish],
                detail: "GLM-4.7-Flash · 智谱额度与计费；保存密钥不等于请求已验证。",
                accessory: {
                    ServiceKeyButton(
                        title: "GLM",
                        text: $glmKeyInput,
                        saved: glmKeySaved,
                        save: saveGLMKey
                    )
                }
            )
            Divider()
            providerRow(
                "Qwen",
                status: providers.value.checked ? (qwenKeySaved ? "已保存" : "需要填写") : "检查中…",
                ready: providers.value.checked ? qwenKeySaved : nil,
                capabilities: [.polish],
                detail: "Qwen Flash · 北京地域；免费额度后按量计费。保存密钥不等于请求已验证。",
                accessory: {
                    ServiceKeyButton(
                        title: "Qwen",
                        text: $qwenKeyInput,
                        saved: qwenKeySaved,
                        save: saveQwenKey
                    )
                }
            )
            Divider()
            providerRow(
                "DeepSeek · Markpipe",
                status: providers.value.checked ? (markpipeKeySaved ? "已保存" : "需要填写") : "检查中…",
                ready: providers.value.checked ? markpipeKeySaved : nil,
                capabilities: [.recognition, .polish],
                detail: "DeepSeek ASR + DeepSeek Flash · api.markpipe.app；识别与润色共用这一把 Markpipe key。保存密钥不等于请求已验证。",
                accessory: {
                    ServiceKeyButton(
                        title: "Markpipe",
                        text: $markpipeKeyInput,
                        saved: markpipeKeySaved,
                        save: saveMarkpipeKey
                    )
                }
            )
            if let terminologyImportMessage {
                Text(terminologyImportMessage).font(SettingsTypography.detail).foregroundStyle(terminologyImportIsError ? .red : .secondary)
            }
            if let textPolishMessage {
                Text(textPolishMessage).font(SettingsTypography.detail).foregroundStyle(textPolishMessageIsError ? .red : .secondary)
            }
            Button("刷新服务状态") { providers.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(providers.isLoading)
        }
    }

    var chatGPTAccountMenu: some View {
        Menu {
            Button("刷新会话") {
                Task {
                    _ = try? await authManager.refreshAccessToken()
                    await MainActor.run {
                        authSnapshot = authManager.authSnapshot()
                    }
                }
            }
            Divider()
            Button("退出登录", role: .destructive) {
                do {
                    try authManager.signOut()
                    authSnapshot = authManager.authSnapshot()
                } catch {
                    terminologyImportMessage = error.localizedDescription
                    terminologyImportIsError = true
                }
            }
        } label: {
            Label("账户操作", systemImage: "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 6)
                .frame(height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("刷新 ChatGPT 会话或退出登录")
    }

    func providerRow<Accessory: View>(
        _ title: String,
        status: String,
        ready: Bool?,
        capabilities: [ServiceCapability],
        detail: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        let tone: SettingsStatusTone = ready == true ? .ready : ready == false ? .error : .neutral
        return HStack(alignment: .top, spacing: 12) {
            SettingsIconBadge(symbol: providerSymbol(title), tone: tone, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(SettingsTypography.rowTitle)
                    HStack(spacing: 4) {
                        ForEach(capabilities) { capability in
                            Text(capability.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                    accessory()
                    SettingsStatusPill(text: localizedProviderStatus(status), tone: tone)
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("provider-" + title)
    }

    private func providerSymbol(_ title: String) -> String {
        if title.hasPrefix("ChatGPT") { return "bubble.left.and.bubble.right" }
        if title.hasPrefix("Doubao") { return "waveform" }
        if title.hasPrefix("Apple") { return "waveform.badge.mic" }
        if title.hasPrefix("GLM") || title.hasPrefix("Qwen") || title.hasPrefix("DeepSeek") { return "key" }
        return "terminal"
    }

    private func localizedProviderStatus(_ status: String) -> String {
        switch status {
        case "Ready": return "已连接"
        case "Needs attention": return "需要处理"
        case "Not connected": return "未连接"
        case "Checking…": return "检查中…"
        case "检查中…": return "检查中…"
        case "Installed": return "已安装"
        case "Not installed": return "未安装"
        case "Key saved": return "密钥已保存"
        case "Key not saved": return "需要填写"
        case "Available on this macOS": return "此 macOS 可用"
        case "Requires macOS 26": return "需要 macOS 26"
        case "Advanced recovery": return "高级恢复"
        default: return status
        }
    }

    func routeRow(title: String, value: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(SettingsTypography.bodyEmphasis)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(SettingsTypography.value)
                Text(detail)
                    .font(SettingsTypography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var polishRouteDetail: String {
        switch config.transcription.textPolish.provider {
        case .doubaoIME: return "豆包文字整理 · ime.doubao.com（私有接口）"
        case .chatGPTAuth: return "\(config.transcription.textPolish.chatGPTResponseModel) via \(config.transcription.textPolish.chatGPTResponseURL)"
        case .glmFlash: return "glm-4.7-flash via open.bigmodel.cn"
        case .qwenFlash: return "qwen-flash via dashscope.aliyuncs.com (Beijing)"
        case .deepSeekFlash: return "deepseek-flash via api.markpipe.app"
        }
    }

    func saveQwenKey() {
        do {
            try qwenKeyStore.save(qwenKeyInput)
            qwenKeyInput = ""
            qwenKeySaved = true
            providers.refresh()
            textPolishMessage = "Qwen Key 已保存；F5 新录音或按当前流程重跑时应用所选服务。"
            textPolishMessageIsError = false
        } catch {
            textPolishMessage = error.localizedDescription
            textPolishMessageIsError = true
        }
    }

    func saveGLMKey() {
        do {
            try glmKeyStore.save(glmKeyInput)
            glmKeyInput = ""
            glmKeySaved = true
            providers.refresh()
            textPolishMessage = "GLM Key 已保存；F5 新录音或按当前流程重跑时应用所选服务。"
            textPolishMessageIsError = false
        } catch {
            textPolishMessage = error.localizedDescription
            textPolishMessageIsError = true
        }
    }

    func saveMarkpipeKey() {
        do {
            try markpipeKeyStore.save(markpipeKeyInput)
            markpipeKeyInput = ""
            markpipeKeySaved = true
            providers.refresh()
            textPolishMessage = "Markpipe Key 已保存；DeepSeek 识别与润色会在 F5 新录音或重跑时使用它。"
            textPolishMessageIsError = false
        } catch {
            textPolishMessage = error.localizedDescription
            textPolishMessageIsError = true
        }
    }

    func testTextPolishSelection() {
        let selected = TextPolishProviderSelector().selectProvider(
            config: config.transcription.textPolish,
            chatGPTAuthAvailable: authSnapshot.state == .ready,
            glmKeyAvailable: glmKeySaved,
            qwenKeyAvailable: qwenKeySaved,
            markpipeKeyAvailable: markpipeKeySaved
        )
        guard let selected else {
            textPolishMessage = config.transcription.textPolish.provider == .qwenFlash ? "先保存 Qwen API Key，或检查 Mode。" : config.transcription.textPolish.provider == .glmFlash ? "先保存 GLM API Key，或检查 Mode。" : config.transcription.textPolish.provider == .deepSeekFlash ? "先保存 Markpipe API Key，或检查 Mode。" : "ChatGPT Auth is not ready. Connect ChatGPT first."
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
            chatGPTAuthAvailable: authSnapshot.state == .ready, glmKeyStore: glmKeyStore, qwenKeyStore: qwenKeyStore,
            markpipeKeyStore: markpipeKeyStore
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

    var chatGPTAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChatGPT Account")
                        .font(SettingsTypography.bodyEmphasis)
                        .foregroundStyle(.secondary)
                    Text(authSnapshot.userEmail ?? authSnapshot.detail)
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                    Text(browserBridgeSnapshot.detail)
                        .font(SettingsTypography.detail)
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

    func connectViaBrowser() {
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

    var browserLoginIsInProgress: Bool {
        if case .waiting = browserBridgeSnapshot.state {
            return true
        }
        return isConnectingBrowserLogin
    }

    func statusPill(for state: ChatGPTAuthState) -> some View {
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
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
    }

    func browserBridgePill(for state: BrowserBridgeState) -> some View {
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
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
    }

    var chatGPTSetupActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if authSnapshot.state == .ready {
                    Button(browserLoginIsInProgress ? "等待授权" : "连接 ChatGPT") {
                        connectViaBrowser()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(browserLoginIsInProgress)
                } else {
                    Button(browserLoginIsInProgress ? "等待授权" : "连接 ChatGPT") {
                        connectViaBrowser()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(browserLoginIsInProgress)
                }

                Button("刷新") {
                    Task {
                        _ = try? await authManager.refreshAccessToken()
                        await MainActor.run {
                            authSnapshot = authManager.authSnapshot()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if authSnapshot.state == .ready || authSnapshot.state == .expired {
                    Button("退出登录") {
                        do {
                            try authManager.signOut()
                            authSnapshot = authManager.authSnapshot()
                        } catch {
                            terminologyImportMessage = error.localizedDescription
                            terminologyImportIsError = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            if let userCode = browserBridgeSnapshot.userCode {
                deviceAuthorizationCard(userCode: userCode)
            }
        }
        .padding(.top, 6)
    }

    func deviceAuthorizationCard(userCode: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("在 OpenAI 页面完成登录", systemImage: "rectangle.and.hand.point.up.left")
                .font(.system(size: 13, weight: .semibold))

            Text("1. 复制一次性验证码。")
                .font(SettingsTypography.body)

            HStack(spacing: 12) {
                Text(userCode)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Button(copiedDeviceCode == userCode ? "已复制" : "复制验证码") {
                    copyDeviceCode(userCode)
                }
                .buttonStyle(.borderedProminent)

                Button(chromeApplicationURL == nil ? "打开登录页" : "在 Chrome 中打开") {
                    openDeviceAuthorizationPage()
                }
                .buttonStyle(.bordered)
            }

            Text("2. 将 9 个字符粘贴到浏览器。3. 点击继续。4. 回到这里，ChatType 会自动完成。")
                .font(SettingsTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("验证码 15 分钟后过期。失败时再次点击“连接 ChatGPT”生成新验证码。")
                .font(SettingsTypography.detail)
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

    func copyDeviceCode(_ userCode: String) {
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

    var chromeApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    func openDeviceAuthorizationPage() {
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

}

private struct ServiceKeyButton: View {
    let title: String
    @Binding var text: String
    let saved: Bool
    let save: () -> Void
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: saved ? "key.fill" : "key")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(saved ? Color.secondary : Color.red)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(saved ? "更换 \(title) API Key" : "填写 \(title) API Key")
        .accessibilityLabel(saved ? "更换 \(title) API Key" : "填写 \(title) API Key")
        .accessibilityIdentifier("manage-\(title.lowercased())-key")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(title) API Key")
                    .font(.system(size: 14, weight: .semibold))
                SecureField("\(title) API Key", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(SettingsTypography.control)
                    .controlSize(.large)
                HStack {
                    Text("只保存到 macOS Keychain。")
                        .font(SettingsTypography.detail)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") {
                        save()
                        showing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}
