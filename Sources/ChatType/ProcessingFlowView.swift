import SwiftUI

struct ProcessingStage: Identifiable, Equatable {
    let id: Int
    let title: String
    let icon: String
    let input: String
    let service: String
    let output: String
    let detail: String

    static func stages(config: TranscriptionConfig, localPreviewSupported: Bool,
                       chatGPTReady: Bool, glmReady: Bool, qwenReady: Bool, clipboardOnly: Bool = false) -> [Self] {
        let managed = config.provider == .chatGPTManagedAuth
        let selected = TextPolishProviderSelector().selectProvider(config: config.textPolish,
            chatGPTAuthAvailable: chatGPTReady, glmKeyAvailable: glmReady, qwenKeyAvailable: qwenReady)
        let polishService: String
        switch config.textPolish.provider {
        case .doubaoIME: polishService = "Doubao IME · ime.doubao.com · server-selected model"
        case .chatGPTAuth: polishService = "ChatGPT · \(config.textPolish.chatGPTResponseModel) · chatgpt.com"
        case .glmFlash: polishService = "GLM-4.7-Flash · open.bigmodel.cn"
        case .qwenFlash: polishService = "Qwen Flash · dashscope.aliyuncs.com"
        }
        let polishState = !config.textPolish.isEnabled ? "Off — aligned text passes through"
            : selected == nil ? "Needs account or key — processing cannot complete" : polishService
        let doubao = config.provider == .doubaoIME
        let preview = config.livePreviewEnabled && (doubao || (localPreviewSupported && managed))
        return [
            Self(id: 0, title: "录音", icon: "mic", input: "Microphone audio after F5",
                 service: preview && managed ? "This Mac · Apple SpeechAnalyzer (when preparation succeeds)" : "This Mac · audio recorder",
                 output: preview ? "Complete audio recording + live draft preview" : "Complete audio recording",
                 detail: "F5 stops and submits the recording. Escape or × cancels. Live preview is provisional; the complete audio supplies final recognition."),
            Self(id: 1, title: "识别", icon: "waveform", input: "Complete audio recording + recognition hints",
                 service: doubao ? "Doubao IME · frontier-audio-ime-ws.doubao.com · server-selected model" : managed ? "ChatGPT account · chatgpt.com · server-selected model" : "\(config.openAIModel) · \(URL(string: config.openAITranscriptionURL)?.host ?? "configured endpoint")",
                 output: "Initial ASR text (automatic speech recognition)",
                 detail: doubao ? "Audio goes to Doubao IME. The private protocol may change; configuration credentials stay in Keychain. No account Cookie or ChatGPT token is used. Pricing and long-term availability are unconfirmed." : managed ? "Audio goes to the original ChatGPT account. This is a private backend; its model ID is not exposed. The preview is not supplied as a second audio input. Challenges retain audio for manual retry."
                    : "Audio goes to your chosen compatible endpoint using its own API key. Its model affects recognition quality, languages and latency; provider usage charges may apply."),
            Self(id: 2, title: "对齐", icon: "text.book.closed", input: "Recognized text + local Terms",
                 service: config.terminologyAlignmentEnabled ? "This Mac · terminology alignment" : "Off · recognized text passes through", output: "Aligned full transcript",
                 detail: "Standard spellings preserve names and English casing. Relevant Chinese terms and personal-name hints help matching. Keyboard input codes are excluded."),
            Self(id: 3, title: "润色", icon: "wand.and.stars", input: config.textPolish.provider == .doubaoIME ? "Aligned full transcript · text only" : "Aligned full transcript + relevant glossary · text only",
                 service: polishState, output: !config.textPolish.isEnabled ? "Aligned transcript" : selected == nil ? "No output until the selected account or key is ready" : "Rewritten full transcript",
                 detail: "The polish model receives text only. Changing it affects rewriting quality, wording and wait time, independently of audio recognition. On failure or truncation, processing remains incomplete and no text is pasted; audio and available stage text are saved for an explicit retry. No automatic switch to another provider."),
            Self(id: 4, title: "修正", icon: "text.badge.checkmark", input: "Polished text, or aligned text when polish is off",
                 service: config.correctionRulesEnabled ? "This Mac · Replacement rules" : "Off · explicit corrections skipped", output: "Final text with your explicit corrections",
                 detail: "Rules run once, longest match first. English matches whole words, Chinese matches exact text; output keeps your chosen casing. Replacement output is not recursively replaced. Code, paths and links are protected."),
            Self(id: 5, title: "输出", icon: "doc.on.clipboard", input: "Final text", service: clipboardOnly ? "This Mac · clipboard only" : "This Mac · focused editable target / clipboard",
                 output: clipboardOnly ? "Clipboard ready for Cmd+V" : "Pasted text, or clipboard ready for Cmd+V",
                 detail: clipboardOnly ? "Only copies after required stage records have been saved. It does not paste into any app." : "Without an editable target, text stays in the clipboard. History keeps recognition and finished results for review or recovery.")
        ]
    }
}

struct ProcessingFlowView<RecognitionOptions: View, PolishOptions: View, TermsOptions: View, CorrectionOptions: View>: View {
    @Binding var config: TranscriptionConfig
    @Binding var injection: InjectionConfig
    let chatGPTReady: Bool
    let glmReady: Bool
    let qwenReady: Bool
    let recognitionOptions: RecognitionOptions
    let polishOptions: PolishOptions
    let termsOptions: TermsOptions
    let correctionOptions: CorrectionOptions
    @State private var selected = 1

    private var stages: [ProcessingStage] {
        ProcessingStage.stages(config: config, localPreviewSupported: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
            chatGPTReady: chatGPTReady, glmReady: glmReady, qwenReady: qwenReady, clipboardOnly: injection.clipboardOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stageMap

            let stage = stages[selected]
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stage.title)
                            .font(.system(size: 21, weight: .semibold))
                        Text("第 \(selected + 1) 步，共 \(stages.count) 步")
                            .font(SettingsTypography.detail)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                stageOptions
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("输入", stage.input)
                    detailRow("运行于", stage.service)
                    detailRow("输出", stage.output)
                }
                Text(stage.detail)
                    .font(SettingsTypography.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
        .font(SettingsTypography.body)
        .padding(.vertical, 2)
    }

    private var stageMap: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("处理流程")
                        .font(SettingsTypography.sectionTitle)
                    Text("F5 新录音或“按当前流程重跑”会应用当前选择；已开始的任务保持原路线。")
                        .font(SettingsTypography.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(stages.count) 个步骤")
                    .font(SettingsTypography.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(stages) { stage in
                    Button {
                        selected = stage.id
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: stage.icon)
                                .font(.system(size: 20, weight: .medium))
                            Text(stage.title)
                                .font(.system(size: 13, weight: selected == stage.id ? .semibold : .medium))
                        }
                        .foregroundStyle(selected == stage.id ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selected == stage.id ? Color.accentColor.opacity(0.11) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Processing step: \(stage.title)")

                    if stage.id != stages.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .accessibilityIdentifier("processing-flow")
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
        )
    }

    @ViewBuilder private var stageOptions: some View {
        switch selected {
        case 0:
            Toggle("边录边识别 / 实时预览", isOn: $config.livePreviewEnabled)
                .accessibilityIdentifier("stage-live-preview")
            Toggle("录音开始/结束提示音", isOn: $config.feedbackSoundsEnabled)
            Text("关闭后仍保存完整录音，停录后才识别。原始语音始终在本机保留。")
                .font(SettingsTypography.detail).foregroundStyle(.secondary)
        case 1:
            recognitionOptions
        case 2:
            Toggle("使用本地词库对齐标准写法", isOn: $config.terminologyAlignmentEnabled)
                .accessibilityIdentifier("stage-terminology")
            termsOptions
        case 3:
            polishOptions
        case 4:
            Toggle("应用本地替换规则", isOn: $config.correctionRulesEnabled)
                .accessibilityIdentifier("stage-corrections")
            correctionOptions
        default:
            Toggle("仅复制到剪贴板，不自动粘贴", isOn: $injection.clipboardOnly)
                .accessibilityIdentifier("stage-clipboard-only")
            Toggle("粘贴后恢复剪贴板", isOn: $injection.preserveClipboard)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(SettingsTypography.detail)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(SettingsTypography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
