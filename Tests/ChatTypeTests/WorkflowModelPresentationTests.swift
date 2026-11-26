import Testing
@testable import ChatType

@Test
func workflowModelPresentationListsPreviewRecognitionAndPolishInOrder() {
    var config = TranscriptionConfig()
    config.provider = .chatGPTManagedAuth
    config.livePreviewEnabled = true
    config.livePreviewProvider = .doubaoIME
    config.textPolish.provider = .doubaoIME
    config.textPolish.mode = .always

    let presentation = WorkflowModelPresentation(
        config: config,
        applePreviewAvailable: true
    )

    #expect(presentation.models == ["豆包实时", "ChatGPT 账户", "豆包整理"])
    #expect(presentation.summary == "豆包实时 + ChatGPT 账户 + 豆包整理")
}

@Test
func workflowModelPresentationUsesRecognizerAndPolishModelsWithoutPreview() {
    var config = TranscriptionConfig()
    config.provider = .openAICompatible
    config.openAIModel = "custom-asr"
    config.livePreviewEnabled = false
    config.textPolish.provider = .glmFlash
    config.textPolish.mode = .always

    let presentation = WorkflowModelPresentation(
        config: config,
        applePreviewAvailable: false
    )

    #expect(presentation.summary == "custom-asr + GLM-4.7-Flash")
}

@Test
func workflowModelPresentationOmitsDisabledPolish() {
    var config = TranscriptionConfig()
    config.provider = .doubaoIME
    config.livePreviewEnabled = false
    config.textPolish.provider = .doubaoIME
    config.textPolish.mode = .disabled

    let presentation = WorkflowModelPresentation(
        config: config,
        applePreviewAvailable: false
    )

    #expect(presentation.summary == "豆包")
}

@Test
func workflowModelPresentationNamesAutomaticApplePreviewOnlyWhenAvailable() {
    var config = TranscriptionConfig()
    config.provider = .chatGPTManagedAuth
    config.livePreviewEnabled = true
    config.livePreviewProvider = .automatic
    config.textPolish.mode = .disabled

    let available = WorkflowModelPresentation(
        config: config,
        applePreviewAvailable: true
    )
    let unavailable = WorkflowModelPresentation(
        config: config,
        applePreviewAvailable: false
    )

    #expect(available.summary == "Apple 本机预览 + ChatGPT 账户")
    #expect(unavailable.summary == "ChatGPT 账户")
}
