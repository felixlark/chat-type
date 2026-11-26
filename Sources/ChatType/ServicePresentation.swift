import Foundation

enum ServiceCapability: String, CaseIterable, Identifiable, Sendable {
    case livePreview = "实时预览"
    case recognition = "识别"
    case polish = "润色"

    var id: String { rawValue }
}

extension TranscriptionProvider {
    var capabilities: [ServiceCapability] {
        switch self {
        case .doubaoIME:
            return [.livePreview, .recognition]
        case .chatGPTManagedAuth:
            return [.recognition]
        case .openAICompatible:
            return [.recognition]
        }
    }

    func modelLabel(config: TranscriptionConfig) -> String {
        switch self {
        case .doubaoIME:
            return "豆包"
        case .chatGPTManagedAuth:
            return "ChatGPT 账户"
        case .openAICompatible:
            let model = config.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "模型未填写" : model
        }
    }
}

extension TextPolishProviderID {
    var capabilities: [ServiceCapability] { [.polish] }

    func modelLabel(config: TextPolishConfig) -> String {
        switch self {
        case .doubaoIME:
            return "豆包整理"
        case .chatGPTAuth:
            let model = config.chatGPTResponseModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "ChatGPT 账户 · 模型未填写" : model
        case .glmFlash:
            return "GLM-4.7-Flash"
        case .qwenFlash:
            return "Qwen Flash"
        }
    }
}

struct WorkflowModelPresentation: Equatable, Sendable {
    let models: [String]

    init(config: TranscriptionConfig, applePreviewAvailable: Bool) {
        var models: [String] = []
        if config.livePreviewEnabled,
           let preview = config.livePreviewProvider.resolvedSource(
               for: config.provider,
               applePreviewAvailable: applePreviewAvailable
           ) {
            switch preview {
            case .doubaoIME:
                models.append("豆包实时")
            case .appleSpeech:
                models.append("Apple 本机预览")
            }
        }

        models.append(config.provider.modelLabel(config: config))
        if config.textPolish.isEnabled {
            models.append(config.textPolish.provider.modelLabel(config: config.textPolish))
        }
        self.models = models
    }

    var summary: String {
        models.joined(separator: " + ")
    }
}
