import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    var transcriptionAccountCard: some View {
        settingsCard(
            title: "识别服务",
            subtitle: "选择完整录音送往哪个识别服务；实时预览只作为过程提示，最终输出仍由这里的选择生成。"
        ) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DeepSeek API 全流程")
                        .font(SettingsTypography.bodyEmphasis)
                    Text("识别和润色都使用 DeepSeek API，共用一把 key。")
                        .font(SettingsTypography.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择") {
                    draft.config.transcription.provider = .deepSeek
                    draft.config.transcription.livePreviewProvider = .automatic
                    draft.config.transcription.textPolish.selectProvider(.deepSeekFlash)
                    draft.config.transcription.textPolish.setEnabled(true)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(config.transcription.provider == .deepSeek
                    && config.transcription.textPolish.isEnabled
                    && config.transcription.textPolish.provider == .deepSeekFlash)
                .accessibilityIdentifier("select-deepseek-workflow")
            }
            Picker("服务", selection: $draft.config.transcription.provider) {
                ForEach(TranscriptionProvider.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("stage-asr-provider")
            Toggle("清理口头语和改口", isOn: $draft.config.transcription.speechCleanupEnabled)
                .disabled(config.transcription.provider == .doubaoIME || config.transcription.provider == .deepSeek)
            if config.transcription.provider == .chatGPTManagedAuth {
                routeRow(title: "模型", value: "由 ChatGPT 选择", detail: "私有转写服务不暴露可选择的模型 ID。")
                Text("Complete recordings go to chatgpt.com. Local Codex login supplies the ChatGPT session. This private backend can change or return a challenge; saved audio remains available in History.")
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
            } else if config.transcription.provider == .doubaoIME {
                Text(config.transcription.provider.caption)
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
                Text("不需要豆包账户登录。音频发送到 frontier-audio-ime-ws.doubao.com；先从 is.snssdk.com 取得配置。模型由服务端决定。已知识别与改口整理仍可能出错，请核对最终输出。")
                    .font(SettingsTypography.detail).foregroundStyle(.secondary)
                Button("更新豆包识别配置") {
                    Task {
                        do { _ = try await DoubaoCredentials.shared.key(refresh: true); saveMessage = "豆包配置已保存到 Keychain；未上传音频。"; saveIsError = false }
                        catch { saveMessage = error.localizedDescription; saveIsError = true }
                    }
                }
            } else if config.transcription.provider == .deepSeek {
                Text(config.transcription.provider.caption)
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
                Text("整段 WAV 发往 DeepSeek API。语音识别不接收提示词或热词字段；本地术语对齐仍会执行。识别和润色共用 Account 中保存的 DeepSeek API key，失败时不会自动切换。")
                    .font(SettingsTypography.detail).foregroundStyle(.secondary)
            } else {
                LabeledContent("转写端点") {
                    TextField("https://…", text: $draft.config.transcription.openAITranscriptionURL)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("音频模型") {
                    TextField("模型 ID", text: $draft.config.transcription.openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("API Key 环境变量") {
                    TextField("变量名", text: $draft.config.transcription.openAIAuthTokenEnv)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
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
                subtitle: "按一次开始，再按一次停止；录入时暂停激活，保存后生效。"
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
                    .controlSize(.large)
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
                if config.transcription.hotkeyKeyCode == 79 {
                    Text("本机实体 F5 映射为 F18；这里显示应用实际接收的按键。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                }
            }

            settingsCard(
                title: "启动与权限",
                subtitle: "登录项、麦克风和辅助功能都在这里管理。"
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
                        .controlSize(.large)
                }
                if let message = loginItem.message {
                    Text(message).font(SettingsTypography.detail).foregroundStyle(.red)
                }
                Divider()
                compactSetupTile(title: "麦克风", status: microphoneStatus)
                Divider()
                compactSetupTile(title: "辅助功能", status: accessibilityStatus)
                HStack(spacing: 10) {
                    ForEach(microphoneRepairActions + accessibilityRepairActions) { repairActionButton($0) }
                }
            }

            settingsCard(
                title: "本地数据",
                subtitle: "配置与词库保存在本机；凭据使用 macOS Keychain。"
            ) {
                LabeledContent("保存位置") {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("~/Library/Application Support/ChatType")
                                .font(SettingsTypography.bodyEmphasis)
                                .textSelection(.enabled)
                            Text("History 包含识别文本和可恢复的原始录音。")
                                .font(SettingsTypography.detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .multilineTextAlignment(.trailing)
                    Button("打开本地数据文件夹", action: onOpenConfigFolder)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
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
                if config.transcription.textPolish.provider == .deepSeekFlash {
                    Text("凭据在 Account 中管理。DeepSeek Flash 与 DeepSeek API ASR 共用 DeepSeek API key；密钥已保存不代表请求已经验证。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                    Text("Full transcript and relevant glossary go to the DeepSeek API for DeepSeek Flash. ASR follows the selected dictation route. F5 新录音或按当前流程重跑时应用这些选择。")
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .chatGPTAuth {
                    LabeledContent("文本模型") {
                        TextField("模型 ID", text: $draft.config.transcription.textPolish.chatGPTResponseModel)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("polish-model")
                    }
                    Text("仅润色阶段使用这个模型。ChatType 通过 chatgpt.com 的账户后端和现有 ChatGPT 登录发送文本，不调用 OpenAI Platform API，也不使用按量 API Key。实际额度与频率限制由 ChatGPT 账户决定；界面中的 token 数为本地估算，不是账单。")
                        .font(SettingsTypography.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
