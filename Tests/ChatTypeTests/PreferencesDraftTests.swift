import Testing
import Foundation
@testable import ChatType

@Test @MainActor func preferencesDraftAppliesOnlyAtAnExplicitActionAndRetainsFailures() {
    let original = AppConfig(), draft = PreferencesDraft(config: AppConfig())
    var writes = 0
    draft.config.transcription.provider = .chatGPTManagedAuth
    draft.config.transcription.textPolish.provider = .chatGPTAuth
    #expect(writes == 0 && draft.hasChanges)
    _ = draft.apply { _ in writes += 1; return .failure(CocoaError(.fileWriteUnknown)) }
    #expect(draft.hasChanges && draft.isError && writes == 1)
    _ = draft.apply { config in
        #expect(config.transcription.provider == .chatGPTManagedAuth)
        writes += 1; return .success(())
    }
    #expect(!draft.hasChanges && !draft.isError && writes == 2)
    _ = draft.apply { _ in writes += 1; return .success(()) }
    #expect(writes == 2)
    #expect(original.transcription.provider == .doubaoIME)
}


@Test(arguments: [TextPolishProviderID.qwenFlash, .glmFlash]) @MainActor
func missingPolishKeyRejectsDirtyAndAlreadySavedFlowBeforeSaving(provider: TextPolishProviderID) {
    var original = AppConfig(); original.transcription.textPolish.provider = provider
    var writes = 0, checks = 0
    let draft = PreferencesDraft(config: original, hasPolishCredential: { requested in
        #expect(requested == provider); checks += 1; return false
    })
    // An unchanged saved selection must also be checked (the key may have been removed).
    #expect(!draft.hasChanges)
    if case .success = draft.apply(using: { _ in writes += 1; return .success(()) }) { Issue.record("Missing key accepted") }
    draft.config.transcription.provider = .chatGPTManagedAuth
    if case .success = draft.apply(using: { _ in writes += 1; return .success(()) }) { Issue.record("Dirty missing key accepted") }
    #expect(writes == 0 && checks == 2 && draft.hasChanges && draft.isError)
    draft.config.transcription.textPolish.setEnabled(false)
    _ = draft.apply { _ in writes += 1; return .success(()) }
    #expect(writes == 1 && !draft.hasChanges)
}
