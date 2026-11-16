import Foundation
import Testing
@testable import ChatType

@Test(arguments: TranscriptionProvider.allCases)
func acceptanceAndNormalPipelinesUseTheSameSelectedRouteAndSwitches(provider: TranscriptionProvider) throws {
    var config = TranscriptionConfig()
    config.provider = provider
    config.textPolish.setEnabled(false)
    config.terminologyAlignmentEnabled = false
    config.correctionRulesEnabled = false
    let auth = FakeChatGPTAuthManager()
    let normal = DictationServiceFactory.make(config: config, auth: auth, policy: .manualRetry)
    let acceptance = try #require(AcceptanceTranscriptionDeadline().pipeline(config, auth, .manualRetry) as? DictationPipeline)
    for pipeline in [normal, acceptance] {
        let selected = try #require(pipeline.transcriber as? SelectedRouteTranscriber)
        #expect(selected.account.config.provider == provider)
        #expect(selected.account.cloudflareChallengeMaxAttempts == 1)
        #expect(pipeline.textPolisher == nil)
        #expect(!pipeline.alignmentEnabled)
        #expect(!pipeline.correctionsEnabled)
        #expect(pipeline.importedEntries == config.activeDictionaryEntries)
        #expect(pipeline.hintTerms == config.prioritizedHintTerms)
    }
    #expect(auth.bestCallCount == 0)
    #expect(auth.refreshCallCount == 0)
}
