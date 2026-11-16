import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    var transcriptionAccountCard: some View {
        settingsCard(title: "Audio transcription service") {
            Picker("Service", selection: $draft.config.transcription.provider) {
                ForEach(TranscriptionProvider.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("stage-asr-provider")
            Toggle("Clean filler words and spoken corrections", isOn: $draft.config.transcription.speechCleanupEnabled)
                .disabled(config.transcription.provider == .doubaoIME)
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
                TextField("Transcription endpoint", text: $draft.config.transcription.openAITranscriptionURL)
                TextField("Audio model", text: $draft.config.transcription.openAIModel)
                TextField("API key environment variable", text: $draft.config.transcription.openAIAuthTokenEnv)
                Text("Advanced recovery uses your own API credentials and may incur usage charges. ChatGPT login credentials are never sent to this endpoint. No automatic provider switching.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var localSettingsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard(title: "激活快捷键") {
                HStack {
                    Text(ActivationShortcut(config.transcription).title)
                        .font(.body.weight(.medium))
                        .accessibilityIdentifier("activation-shortcut-value")
                    if draft.shortcutHasChanges { Text("待保存").foregroundStyle(.secondary) }
                    Spacer()
                    Button(draft.isRecordingShortcut ? "取消录入" : "录入快捷键") {
                        if draft.isRecordingShortcut { draft.endShortcutCapture() }
                        else { draft.beginShortcutCapture() }
                    }.accessibilityIdentifier("record-activation-shortcut")
                }
                if draft.isRecordingShortcut {
                    Text("请按下快捷键；Esc 取消。")
                        .foregroundStyle(.secondary)
                        .background(ShortcutRecorder(onCapture: { draft.endShortcutCapture($0) }, onCancel: { draft.endShortcutCapture() }))
                }
                Text("按一次开始，再按一次停止。支持普通按键和 Command、Option、Control、Shift 组合；保存设置后生效。录入期间暂停激活。当前生效：\(draft.activeShortcut.title)。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if config.transcription.hotkeyKeyCode == 79 {
                    Text("本机键盘映射可能将实体 F5 输出为 F18；这里显示应用实际接收的按键。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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

    func terminologyEditor(_ type: TerminologyEntryType) -> some View {
        TerminologyEditor(terminology: $draft.config.transcription.terminology,
            importContacts: onImportAppleContactRemarks, importWeChat: onImportWeixinRemarks,
            entryType: type, importing: $importingNames)
    }

    var aiPolishCard: some View {
        settingsCard(title: "Text polish service") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用全文润色", isOn: Binding(get: { config.transcription.textPolish.isEnabled }, set: { config.transcription.textPolish.setEnabled($0) }))
                    .accessibilityIdentifier("stage-polish-enabled")
                Picker("Service", selection: Binding(get: { config.transcription.textPolish.provider }, set: { config.transcription.textPolish.selectProvider($0) })) {
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
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Qwen Flash, Beijing: eligible free quota is used first, then usage billing. Full transcript and relevant glossary go to dashscope.aliyuncs.com; ASR follows the selected dictation route. F5 新录音或按当前流程重跑时应用这些选择。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .glmFlash {
                    Text("凭据在 Account 中管理。密钥已保存不代表请求已经验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("GLM-4.7-Flash uses your vendor account quota and current pricing. Full transcript and relevant glossary go to open.bigmodel.cn; ASR follows the selected dictation route. F5 新录音或按当前流程重跑时应用这些选择。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if config.transcription.textPolish.provider == .chatGPTAuth {
                    HStack {
                        Text("Text model").frame(width: 90, alignment: .leading)
                        TextField("Model ID", text: $draft.config.transcription.textPolish.chatGPTResponseModel)
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
                    .onAppear { refreshTextPolishStatus() }
                if let error = usage.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

}
