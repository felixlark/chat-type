import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    var accountOverviewCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard(title: "Providers") {
                providerRow("ChatGPT", status: chatGPTAccountStatus.title,
                    ready: providers.value.checked ? authSnapshot.state == .ready : nil,
                    detail: authSnapshot.userEmail ?? authSnapshot.detail)
                chatGPTSetupActions
                Divider()
                providerRow("Doubao IME", status: !providers.value.checked ? "Checking…" : providers.value.doubaoInstalled ? "Installed" : "Not installed",
                    ready: providers.value.checked ? providers.value.doubaoInstalled : nil,
                    detail: "豆包输入法安装检测 · 可用于识别与文字整理。安装状态不代表云端请求已验证；ChatType 使用自身配置。")
                Divider()
                providerRow("Apple SpeechAnalyzer", status: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Available on this macOS" : "Requires macOS 26",
                    ready: nil,
                    detail: "本机实时预览 · 选择 ChatGPT 识别路线时使用；模型在录音准备时检测。终稿仍由所选识别服务生成。")
                Divider()
                providerRow("GLM", status: providers.value.checked ? (glmKeySaved ? "Key saved" : "Key not saved") : "Checking…",
                    ready: providers.value.checked ? glmKeySaved : nil,
                    detail: "文字润色 · GLM-4.7-Flash · 密钥保存状态，尚未验证请求。")
                HStack {
                    SecureField("GLM API Key", text: $glmKeyInput).accessibilityIdentifier("glm-api-key")
                    Button("Save GLM Key") { saveGLMKey() }.disabled(glmKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                providerRow("Qwen", status: providers.value.checked ? (qwenKeySaved ? "Key saved" : "Key not saved") : "Checking…",
                    ready: providers.value.checked ? qwenKeySaved : nil,
                    detail: "文字润色 · Qwen Flash · 密钥保存状态，尚未验证请求。")
                HStack {
                    SecureField("Qwen API Key", text: $qwenKeyInput).accessibilityIdentifier("qwen-api-key")
                    Button("Save Qwen Key") { saveQwenKey() }.disabled(qwenKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                providerRow("OpenAI-Compatible", status: "Advanced recovery", ready: nil,
                    detail: "使用独立端点与 API Key，可能按量收费；在 Workflow 的 Recognize 阶段配置，未验证可用性。")
                if let terminologyImportMessage {
                    Text(terminologyImportMessage).font(.caption).foregroundStyle(terminologyImportIsError ? .red : .secondary)
                }
                if let textPolishMessage {
                    Text(textPolishMessage).font(.caption).foregroundStyle(textPolishMessageIsError ? .red : .secondary)
                }
                Button("Refresh Provider Status") { providers.refresh() }.disabled(providers.isLoading)
            }
            settingsCard(title: "Permissions") {
                HStack(spacing: 10) {
                    compactSetupTile(title: "Microphone", status: microphoneStatus)
                    compactSetupTile(title: "Accessibility", status: accessibilityStatus)
                }
                ForEach(microphoneRepairActions + accessibilityRepairActions) { repairActionButton($0) }
            }
        }
    }

    func providerRow(_ title: String, status: String, ready: Bool?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(ready == true ? Color.green : ready == false ? Color.orange : Color.secondary)
                .frame(width: 8, height: 8).padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Text(status).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("provider-" + title)
    }

    func routeRow(title: String, value: String, detail: String) -> some View {
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

    var polishRouteDetail: String {
        switch config.transcription.textPolish.provider {
        case .doubaoIME: return "豆包文字整理 · ime.doubao.com（私有接口）"
        case .chatGPTAuth: return "\(config.transcription.textPolish.chatGPTResponseModel) via \(config.transcription.textPolish.chatGPTResponseURL)"
        case .glmFlash: return "glm-4.7-flash via open.bigmodel.cn"
        case .qwenFlash: return "qwen-flash via dashscope.aliyuncs.com (Beijing)"
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

    func testTextPolishSelection() {
        let selected = TextPolishProviderSelector().selectProvider(
            config: config.transcription.textPolish,
            chatGPTAuthAvailable: authSnapshot.state == .ready,
            glmKeyAvailable: glmKeySaved,
            qwenKeyAvailable: qwenKeySaved
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

    var chatGPTAccountSection: some View {
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
            .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: 11, weight: .semibold))
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

    func deviceAuthorizationCard(userCode: String) -> some View {
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
