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
                       chatGPTReady: Bool, glmReady: Bool, qwenReady: Bool) -> [Self] {
        let managed = config.provider == .chatGPTManagedAuth
        let selected = TextPolishProviderSelector().selectProvider(config: config.textPolish,
            chatGPTAuthAvailable: chatGPTReady, glmKeyAvailable: glmReady, qwenKeyAvailable: qwenReady)
        let polishService: String
        switch config.textPolish.provider {
        case .chatGPTAuth: polishService = "ChatGPT · \(config.textPolish.chatGPTResponseModel) · chatgpt.com"
        case .glmFlash: polishService = "GLM-4.7-Flash · open.bigmodel.cn"
        case .qwenFlash: polishService = "Qwen Flash · dashscope.aliyuncs.com"
        }
        let polishState = config.textPolish.mode == .disabled ? "Off — aligned text passes through"
            : selected == nil ? "Skipped — selected account or key unavailable" : polishService
        let preview = localPreviewSupported && managed
        return [
            Self(id: 0, title: "Voice", icon: "mic", input: "Microphone audio after F5",
                 service: preview ? "This Mac · Apple SpeechAnalyzer (when preparation succeeds)" : "This Mac · audio recorder",
                 output: preview ? "Complete audio recording + live draft preview" : "Complete audio recording",
                 detail: "F5 stops and submits the recording. Escape or × cancels. Live preview is provisional; the complete audio supplies final recognition."),
            Self(id: 1, title: "Recognize", icon: "waveform", input: "Complete audio recording + recognition hints",
                 service: managed ? "ChatGPT account · chatgpt.com · server-selected model" : "\(config.openAIModel) · \(URL(string: config.openAITranscriptionURL)?.host ?? "configured endpoint")",
                 output: "Initial ASR text (automatic speech recognition)",
                 detail: managed ? "Audio goes to the original ChatGPT account. This is a private backend; its model ID is not exposed. The preview is not supplied as a second audio input. Challenges retain audio for manual retry."
                    : "Audio goes to your chosen compatible endpoint using its own API key. Its model affects recognition quality, languages and latency; provider usage charges may apply."),
            Self(id: 2, title: "Align", icon: "text.book.closed", input: "Recognized text + local Terms",
                 service: "This Mac · terminology alignment", output: "Aligned full transcript",
                 detail: "Standard spellings preserve names and English casing. Relevant Chinese terms and personal-name hints help matching. Keyboard input codes are excluded."),
            Self(id: 3, title: "Polish", icon: "wand.and.stars", input: "Aligned full transcript + relevant glossary · text only",
                 service: polishState, output: selected == nil ? "Aligned transcript" : "Rewritten full transcript",
                 detail: "The polish model receives text only. Changing it affects rewriting quality, wording and wait time, independently of audio recognition. On failure or truncation, ChatType preserves the aligned transcript. No automatic switch to another provider."),
            Self(id: 4, title: "Correct", icon: "text.badge.checkmark", input: "Polished text, or aligned text when polish is unavailable",
                 service: "This Mac · Replacement rules", output: "Final text with your explicit corrections",
                 detail: "Rules run once, longest match first. English matches whole words, Chinese matches exact text; output keeps your chosen casing. Replacement output is not recursively replaced. Code, paths and links are protected."),
            Self(id: 5, title: "Paste", icon: "doc.on.clipboard", input: "Final text", service: "This Mac · focused editable target / clipboard",
                 output: "Pasted text, or clipboard ready for Cmd+V",
                 detail: "Without an editable target, text stays in the clipboard. History keeps recognition and finished results for review or recovery.")
        ]
    }
}

struct ProcessingFlowView: View {
    let config: TranscriptionConfig
    let chatGPTReady: Bool
    let glmReady: Bool
    let qwenReady: Bool
    @State private var selected = 1

    private var stages: [ProcessingStage] {
        ProcessingStage.stages(config: config, localPreviewSupported: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
            chatGPTReady: chatGPTReady, glmReady: glmReady, qwenReady: qwenReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 4) {
                ForEach(stages) { stage in
                    Button { selected = stage.id } label: {
                        VStack(spacing: 7) {
                            Image(systemName: stage.icon).font(.system(size: 17))
                            Text(stage.title).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(selected == stage.id ? Color.accentColor.opacity(0.12) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Processing step: \(stage.title)")
                    if stage.id != stages.last?.id {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityIdentifier("processing-flow")
            Text("Route for the settings shown here · save changes to use it for the next recording.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            let stage = stages[selected]
            VStack(alignment: .leading, spacing: 12) {
                Text(stage.title).font(.headline)
                detailRow("Input", stage.input)
                detailRow("Runs on", stage.service)
                detailRow("Output", stage.output)
                Text(stage.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.textSelection(.enabled)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }
}
