import Foundation
import Testing
@testable import ChatType

@Test
func inMemorySessionStoreRoundTripsSession() throws {
    let store = InMemoryChatGPTSessionStore()
    let session = ChatGPTSession(
        accessToken: "token-1",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
        userEmail: "user@example.com",
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    try store.save(session)

    #expect(try store.load() == session)
}

@Test
func sessionTokenIsUsableBeforeExpiry() {
    let session = ChatGPTSession(
        accessToken: "token-1",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
        userEmail: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(session.tokenIsUsable(now: Date(timeIntervalSince1970: 1_500)) == true)
    #expect(session.tokenIsUsable(now: Date(timeIntervalSince1970: 2_500)) == false)
}

@Test
func sessionExtractsChatGPTAccountIDFromOAuthJWTWithoutPersistingAnotherSecret() throws {
    let payload = try JSONSerialization.data(withJSONObject: [
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "account-123",
        ],
    ])
    let encodedPayload = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let session = ChatGPTSession(
        accessToken: "header.\(encodedPayload).signature",
        accessTokenExpiresAt: nil,
        userEmail: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(session.chatGPTAccountID == "account-123")
}
