import Foundation

enum DictationServiceFactory {
    static func make(
        config: TranscriptionConfig,
        auth: any ChatGPTAuthProviding,
        policy: TranscriptionAttemptPolicy,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) -> DictationPipeline {
        DictationPipeline(
            transcriber: ChatGPTTranscriber(
                authManager: auth,
                config: config,
                cloudflareChallengeMaxAttempts: policy.cloudflareChallengeMaxAttempts,
                dataLoader: dataLoader
            ).selectedRoute,
            normalizer: TerminologyNormalizer(),
            importedEntries: config.activeDictionaryEntries,
            hintTerms: config.prioritizedHintTerms,
            textPolisher: config.textPolish.isEnabled ? OpenAICompatibleTextPolisher(
                config: config.textPolish,
                chatGPTAuthProvider: auth,
                chatGPTAuthAvailable: config.needsChatGPT && auth.authSnapshot().state == .ready
            ) : nil,
            alignmentEnabled: config.terminologyAlignmentEnabled,
            correctionsEnabled: config.correctionRulesEnabled
        )
    }
}
