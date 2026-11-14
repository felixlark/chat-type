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
