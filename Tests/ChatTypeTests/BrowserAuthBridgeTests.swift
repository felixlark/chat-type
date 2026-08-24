import Foundation
import Testing
@testable import ChatType

@Test
func deviceAuthorizationUsesOfficialCodexEndpointsAndSavesReturnedSession() async throws {
    let loader = DeviceAuthStub()
    let openedURL = URLRecorder()
    let sleepRecorder = SleepRecorder()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bridge = BrowserAuthBridge(
        timeoutSeconds: 10,
        now: { now },
        opener: { openedURL.record($0) },
        dataLoader: { request in try loader.load(request) },
        sleeper: { nanoseconds in sleepRecorder.record(nanoseconds) }
    )

    let session = try await bridge.captureSession(now: now)
    let requests = loader.recordedRequests()

    #expect(openedURL.value() == URL(string: "https://auth.openai.com/codex/device"))
    #expect(session.accessToken == "device-access-token")
    #expect(session.refreshToken == "device-refresh-token")
    #expect(session.idToken == "device-id-token")
    #expect(session.accessTokenExpiresAt == now.addingTimeInterval(3_600))
    #expect(bridge.snapshot() == BrowserBridgeSnapshot(
        state: .connected,
        detail: "ChatType connected to ChatGPT via OpenAI device authorization."
    ))
    #expect(sleepRecorder.values() == [1_000_000_000])
    #expect(requests.map { $0.url?.path } == [
        "/api/accounts/deviceauth/usercode",
        "/api/accounts/deviceauth/token",
        "/api/accounts/deviceauth/token",
        "/oauth/token",
    ])
    #expect(String(data: try #require(requests[0].httpBody), encoding: .utf8) ==
        #"{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann"}"#)
    let pollData = try #require(requests[1].httpBody)
    let pollBody = try #require(JSONSerialization.jsonObject(with: pollData) as? [String: String])
    #expect(pollBody == ["device_auth_id": "device-auth-id", "user_code": "ABCD-EFGH"])
    let tokenBody = String(data: try #require(requests[3].httpBody), encoding: .utf8) ?? ""
    #expect(tokenBody.contains("grant_type=authorization_code"))
    #expect(tokenBody.contains("code=device-authorization-code"))
    #expect(tokenBody.contains("code_verifier=device-code-verifier"))
    #expect(tokenBody.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
}

@Test
func deviceAuthorizationKeepsWaitingForStandardHTTP400PendingResponse() async throws {
    let loader = DeviceAuthStub(pendingStatus: 400)
    let bridge = BrowserAuthBridge(
        timeoutSeconds: 10,
        opener: { _ in },
        dataLoader: { request in try loader.load(request) },
        sleeper: { _ in }
    )

    let session = try await bridge.captureSession()

    #expect(session.accessToken == "device-access-token")
    #expect(loader.recordedRequests().filter { $0.url?.path == "/api/accounts/deviceauth/token" }.count == 2)
}

@Test
func chatGPTAuthManagerDoesNotStartBrowserBridgeWhenStoredSessionIsUsable() async throws {
    let session = makeChatGPTSession(token: "stored-token", expiresAt: Date(timeIntervalSince1970: 1_800_003_600))
    let store = InMemoryChatGPTSessionStore(session: session)
    let bridge = RecordingBrowserAuthBridge(session: makeChatGPTSession(token: "browser-token"))
    let manager = ChatGPTAuthManager(
        store: store,
        browserAuthBridge: bridge,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let connected = try await manager.connectViaDefaultBrowser()

    #expect(connected.accessToken == "stored-token")
    #expect(bridge.captureCount == 0)
}

@Test
func chatGPTAuthManagerSavesOAuthSession() async throws {
    let store = InMemoryChatGPTSessionStore()
    let browserSession = makeChatGPTSession(token: "browser-token", refreshToken: "refresh-token", userEmail: "browser@example.com")
    let bridge = RecordingBrowserAuthBridge(session: browserSession)
    let manager = ChatGPTAuthManager(
        store: store,
        browserAuthBridge: bridge,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let connected = try await manager.connectViaDefaultBrowser()
    let accessToken = try await manager.bestAvailableAccessToken()

    #expect(connected == browserSession)
    #expect(accessToken == "browser-token")
    #expect(try store.load() == browserSession)
    #expect(bridge.captureCount == 1)
}

@Test
func chatGPTAuthManagerRefreshesOAuthSessionWithRefreshToken() async throws {
    let expiredSession = makeChatGPTSession(
        token: "expired-token",
        expiresAt: Date(timeIntervalSince1970: 1_799_999_000),
        refreshToken: "refresh-token"
    )
    let refreshedSession = makeChatGPTSession(
        token: "refreshed-token",
        expiresAt: Date(timeIntervalSince1970: 1_800_003_600),
        refreshToken: "refresh-token-2"
    )
    let store = InMemoryChatGPTSessionStore(session: expiredSession)
    let bridge = RecordingBrowserAuthBridge(session: makeChatGPTSession(token: "browser-token"), refreshedSession: refreshedSession)
    let manager = ChatGPTAuthManager(
        store: store,
        browserAuthBridge: bridge,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )

    let accessToken = try await manager.refreshAccessToken()

    #expect(accessToken == "refreshed-token")
    #expect(try store.load() == refreshedSession)
    #expect(bridge.refreshTokens == ["refresh-token"])
}

private final class RecordingBrowserAuthBridge: BrowserAuthBridging, @unchecked Sendable {
    private let session: ChatGPTSession
    private let refreshedSession: ChatGPTSession
    private(set) var captureCount = 0
    private(set) var refreshTokens: [String] = []

    init(session: ChatGPTSession, refreshedSession: ChatGPTSession? = nil) {
        self.session = session
        self.refreshedSession = refreshedSession ?? session
    }

    func snapshot() -> BrowserBridgeSnapshot {
        .available
    }

    func captureSession(now: Date) async throws -> ChatGPTSession {
        captureCount += 1
        return session
    }

    func refreshSession(refreshToken: String, now: Date) async throws -> ChatGPTSession {
        refreshTokens.append(refreshToken)
        return refreshedSession
    }
}

private final class DeviceAuthStub: @unchecked Sendable {
    private let lock = NSLock()
    private let pendingStatus: Int
    private var requests: [URLRequest] = []

    init(pendingStatus: Int = 404) {
        self.pendingStatus = pendingStatus
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        let index = requests.count
        requests.append(request)
        lock.unlock()

        switch index {
        case 0:
            return response(
                for: request,
                status: 200,
                body: #"{"device_auth_id":"device-auth-id","user_code":"ABCD-EFGH","interval":"1"}"#
            )
        case 1:
            return response(
                for: request,
                status: pendingStatus,
                body: #"{"error":{"message":"Device authorization is pending.","code":"deviceauth_authorization_pending"}}"#
            )
        case 2:
            return response(
                for: request,
                status: 200,
                body: #"{"authorization_code":"device-authorization-code","code_challenge":"device-code-challenge","code_verifier":"device-code-verifier"}"#
            )
        case 3:
            return response(
                for: request,
                status: 200,
                body: #"{"access_token":"device-access-token","refresh_token":"device-refresh-token","id_token":"device-id-token","expires_in":3600}"#
            )
        default:
            Issue.record("Unexpected request at index \(index)")
            return response(for: request, status: 500, body: "{}")
        }
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func response(for request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func record(_ url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
    }

    func value() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        lock.lock()
        recordedValues.append(nanoseconds)
        lock.unlock()
    }

    func values() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}

private func makeChatGPTSession(
    token: String,
    expiresAt: Date? = Date(timeIntervalSince1970: 1_800_003_600),
    refreshToken: String? = nil,
    userEmail: String? = nil
) -> ChatGPTSession {
    ChatGPTSession(
        accessToken: token,
        accessTokenExpiresAt: expiresAt,
        refreshToken: refreshToken,
        idToken: nil,
        userEmail: userEmail,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}
