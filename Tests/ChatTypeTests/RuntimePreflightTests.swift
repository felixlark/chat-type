import Foundation
import Testing
@testable import ChatType

@Test
func preflightRequiresChatGPTLoginForChatTypeDefaults() {
    let issues = RuntimePreflight.issues(
        for: legacyAccountConfig(),
        environment: [:],
        authSnapshotProvider: {
            ChatGPTAuthSnapshot(state: .signedOut, detail: "", userEmail: nil)
        }
    )

    #expect(issues == [.chatGPTLoginRequired])
}

@Test
func preflightFlagsExpiredChatGPTSession() {
    let issues = RuntimePreflight.issues(
        for: legacyAccountConfig(),
        environment: [:],
        authSnapshotProvider: {
            ChatGPTAuthSnapshot(state: .expired, detail: "expired", userEmail: "user@example.com")
        }
    )

    #expect(issues == [.chatGPTSessionExpired])
}

@Test
func preflightRequiresOpenAIKeyInRecoveryMode() {
    var config = legacyAccountConfig()
    config.transcription.provider = .openAICompatible

    let issues = RuntimePreflight.issues(for: config, environment: [:])

    #expect(issues == [.missingTranscriptionAuthToken("OPENAI_API_KEY")])
}

@Test
func legacyCleanupConfigDoesNotAddDesktopHostRequirementToRecoveryMode() {
    var config = legacyAccountConfig()
    config.transcription.provider = .openAICompatible
    config.transcription.textPolish.mode = .disabled

    let issues = RuntimePreflight.issues(
        for: config,
        environment: ["OPENAI_API_KEY": "test-key"],
        authSnapshotProvider: {
            ChatGPTAuthSnapshot(state: .signedOut, detail: "", userEmail: nil)
        }
    )

    #expect(issues.isEmpty)
}
