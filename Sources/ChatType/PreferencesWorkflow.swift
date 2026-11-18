import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    var transcriptionAccountCard: some View {
        settingsCard(
            title: "识别服务",
            subtitle: "选择完整录音送往哪个识别服务；实时预览只作为过程提示，终稿仍由这里的选择生成。"
        ) {
            Picker("服务", selection: $draft.config.transcription.provider) {
                ForEach(TranscriptionProvider.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("stage-asr-provider")
            Toggle("清理口头语和改口", isOn: $draft.config.transcription.speechCleanupEnabled)
                .disabled(config.transcription.provider == .doubaoIME)
            if config.transcription.provider == .chatGPTManagedAuth {
                routeRow(title: "模型", value: "由 ChatGPT 选择", detail: "私有转写服务不暴露可选择的模型 ID。")
                Text("Complete recordings go to chatgpt.com. Local Codex login supplies the ChatGPT session. This private backend can change or return a challenge; saved audio remains available in History.")
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
            } else if config.transcription.provider == .doubaoIME {
                Text(config.transcription.provider.caption)
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
                Text("不需要豆包账户登录。音频发送到 frontier-audio-ime-ws.doubao.com；先从 is.snssdk.com 取得配置。模型由服务端决定。已知识别与改口整理仍可能出错，请核对终稿。")
                    .font(SettingsTypography.detail).foregroundStyle(.secondary)
                Button("更新豆包识别配置") {
                    Task {
                        do { _ = try await DoubaoCredentials.shared.key(refresh: true); saveMessage = "豆包配置已保存到 Keychain；未上传音频。"; saveIsError = false }
                        catch { saveMessage = error.localizedDescription; saveIsError = true }
                    }
                }
            } else {
                TextField("转写端点", text: $draft.config.transcription.openAITranscriptionURL)
                TextField("音频模型", text: $draft.config.transcription.openAIModel)
                TextField("API Key 环境变量", text: $draft.config.transcription.openAIAuthTokenEnv)
                Text("Advanced recovery uses your own API credentials and may incur usage charges. ChatGPT login credentials are never sent to this endpoint. No automatic provider switching.")
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var localSettingsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard(
                title: "激活快捷键",
                subtitle: "按一次开始录音，再按一次停止。录入期间暂停激活，保存后生效。"
            ) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前生效")
                            .font(SettingsTypography.detail)
                            .foregroundStyle(.secondary)
                        Text(draft.shortcutHasChanges ? "待保存 · \(ActivationShortcut(config.transcription).title)" : ActivationShortcut(config.transcription).title)
                            .font(SettingsTypography.monoValue)
                            .accessibilityIdentifier("activation-shortcut-value")
                    }
                    Spacer()
                    Button(draft.isRecordingShortcut ? "取消录入" : "录入快捷键") {
                        if draft.isRecordingShortcut { draft.endShortcutCapture() }
                        else { draft.beginShortcutCapture() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(draft.isRecordingShortcut ? Color(nsColor: .secondaryLabelColor) : Color.accentColor)
                    .font(SettingsTypography.bodyEmphasis)
                    .accessibilityIdentifier("record-activation-shortcut")
                }
                if draft.isRecordingShortcut {
                    Text("请按下快捷键；Esc 取消。")
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                        .background(ShortcutRecorder(onCapture: { draft.endShortcutCapture($0) }, onCancel: { draft.endShortcutCapture() }))
                }
                Text("支持普通按键和 Command、Option、Control、Shift 组合。当前生效：\(draft.activeShortcut.title)。")
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if config.transcription.hotkeyKeyCode == 79 {
                    Text("本机键盘映射可能将实体 F5 输出为 F18；这里显示应用实际接收的按键。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                settingsCard(
                    title: "启动",
                    subtitle: "登录这台 Mac 时自动启动菜单栏应用。"
                ) {
                    Toggle("登录时启动 ChatType", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .accessibilityIdentifier("launch-at-login")
                    Text("切换后立即生效。")
                        .font(SettingsTypography.detail)
                        .foregroundStyle(.secondary)
                    if loginItem.status == .requiresApproval {
                        Text("等待 macOS 登录项批准。").font(SettingsTypography.body).foregroundStyle(.orange)
                        Button("打开登录项") { loginItem.openSystemSettings() }
                            .buttonStyle(.bordered)
                    }
                    if let message = loginItem.message {
                        Text(message).font(SettingsTypography.detail).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                settingsCard(
                    title: "权限",
                    subtitle: "麦克风用于录音，辅助功能用于自动粘贴。"
                ) {
                    setupRow(title: "麦克风", status: microphoneStatus)
                    setupRow(title: "辅助功能", status: accessibilityStatus)
                    ForEach(microphoneRepairActions + accessibilityRepairActions) { repairActionButton($0) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            settingsCard(
                title: "本地数据",
                subtitle: "配置与词库保存在本机；凭据使用 macOS Keychain。"
            ) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("~/Library/Application Support/ChatType")
                            .font(SettingsTypography.bodyEmphasis)
                            .textSelection(.enabled)
                        Text("History 包含识别文本和可恢复的原始录音。")
                            .font(SettingsTypography.detail)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开本地数据文件夹", action: onOpenConfigFolder)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    func terminologyEditor(_ type: TerminologyEntryType) -> some View {
        TerminologyEditor(terminology: $draft.config.transcription.terminology,
            importContacts: onImportAppleContactRemarks, importWeChat: onImportWeixinRemarks,
            entryType: type, importing: $importingNames)
    }

    var aiPolishCard: some View {
        settingsCard(
            title: "润色服务",
            subtitle: "只向所选服务发送文本；识别与润色可以独立选择，失败时不会自动切换。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用全文润色", isOn: Binding(get: { config.transcription.textPolish.isEnabled }, set: { config.transcription.textPolish.setEnabled($0) }))
                    .accessibilityIdentifier("stage-polish-enabled")
                Picker("服务", selection: Binding(get: { config.transcription.textPolish.provider }, set: { config.transcription.textPolish.selectProvider($0) })) {
                    ForEach(TextPolishProviderID.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .accessibilityIdentifier("stage-polish-provider")
                .onChange(of: config.transcription.textPolish.provider) { _ in
                    if config.transcription.textPolish.provider == .chatGPTAuth { config.transcription.textPolish.chatGPTAuthEnabled = true }
                    polishTestGeneration = UUID()
                    testingTextPolish = false
                    textPolishMessage = nil
                    textPolishMessageIsError = false
                }
                if config.transcription.textPolish.provider == .qwenFlash {
                    Text("凭据在 Account 中管理。密钥已保存不代表请求已经验证。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                    Text("Qwen Flash, Beijing: eligible free quota is used first, then usage billing. Full transcript and relevant glossary go to dashscope.aliyuncs.com; ASR follows the selected dictation route. F5 新录音或按当前流程重跑时应用这些选择。")
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .glmFlash {
                    Text("凭据在 Account 中管理。密钥已保存不代表请求已经验证。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                    Text("GLM-4.7-Flash uses your vendor account quota and current pricing. Full transcript and relevant glossary go to open.bigmodel.cn; ASR follows the selected dictation route. F5 新录音或按当前流程重跑时应用这些选择。")
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .chatGPTAuth {
                    HStack {
                        Text("文本模型").frame(width: 90, alignment: .leading)
                        TextField("模型 ID", text: $draft.config.transcription.textPolish.chatGPTResponseModel)
                            .accessibilityIdentifier("polish-model")
                    }
                    Text("Text model: only the text polish step uses this model. A larger model may improve rewriting and take longer; available models follow your ChatGPT account. Audio recognition uses its own server-selected model.")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                }
                Text(config.transcription.textPolish.provider == .doubaoIME
                    ? "输入：上一阶段的全文。输出：整理后的全文。本地词表不作为额外提示上传；不承诺云端热词生效。服务：ime.doubao.com。"
                    : "Input: aligned full transcript + relevant glossary. Output: rewritten text. Selected service: \(polishRouteDetail). Credentials stay in Keychain. A saved key has not been verified by a request.")
                    .font(SettingsTypography.detail).foregroundStyle(.secondary)
                polishStatusSection
                    .onAppear { refreshTextPolishStatus() }
                if let error = usage.error { Text(error).font(SettingsTypography.detail).foregroundStyle(.red) }
            }
        }
    }

}
