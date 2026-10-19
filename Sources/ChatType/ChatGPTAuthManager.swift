import AppKit
import Foundation

extension Notification.Name {
    static let chatGPTAuthStateDidChange = Notification.Name("ChatTypeChatGPTAuthStateDidChange")
}

enum ChatGPTAuthError: LocalizedError {
    case loginRequired
    case sessionExpired
    case sessionUnavailable
    case accessTokenMissing
    case refreshFailed(String)
    case browserLoginFailed(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            return "请先在 ChatType 设置中连接 ChatGPT。"
        case .sessionExpired:
            return "ChatType 保存的 ChatGPT 会话已过期，请重新登录。"
        case .sessionUnavailable:
            return "ChatType 当前无法读取可用的 ChatGPT 会话。"
        case .accessTokenMissing:
            return "ChatType 已登录，但当前没有可用的 ChatGPT access token。"
        case .refreshFailed(let message):
            return "ChatType 刷新 ChatGPT 会话失败：\(message)"
        case .browserLoginFailed(let message):
            return "ChatType 登录失败：\(message)"
        }
    }
}

enum ChatGPTAuthState: Sendable, Equatable {
    case signedOut
    case ready
    case expired
    case unavailable
}

struct ChatGPTAuthSnapshot: Sendable, Equatable {
    let state: ChatGPTAuthState
    let detail: String
    let userEmail: String?
}

protocol ChatGPTAuthProviding: Sendable {
    func authSnapshot() -> ChatGPTAuthSnapshot
    func chatGPTAccountID() -> String?
    func bestAvailableAccessToken() async throws -> String
    func refreshAccessToken() async throws -> String
    func prewarmSession() async
    func signOut() throws
}

final class ChatGPTAuthManager: ChatGPTAuthProviding, @unchecked Sendable {
    private let store: any ChatGPTSessionPersisting
    private let browserAuthBridge: any BrowserAuthBridging
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedSession: ChatGPTSession?

    init(
        store: any ChatGPTSessionPersisting = KeychainChatGPTSessionStore(),
        browserAuthBridge: any BrowserAuthBridging = BrowserAuthBridge(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.browserAuthBridge = browserAuthBridge
        self.now = now
        cachedSession = try? store.load()
    }

    func authSnapshot() -> ChatGPTAuthSnapshot {
        do {
            guard let session = try loadSession() else {
                return ChatGPTAuthSnapshot(
                    state: .signedOut,
                    detail: "Connect ChatGPT in ChatType Settings before recording.",
                    userEmail: nil
                )
            }
            if session.tokenIsUsable(now: now()) {
                return ChatGPTAuthSnapshot(
                    state: .ready,
                    detail: "ChatType has its own ChatGPT session and can transcribe without Codex.",
                    userEmail: session.userEmail
                )
            }
            return ChatGPTAuthSnapshot(
                state: .expired,
                detail: "ChatType has a saved ChatGPT session, but it needs refresh or sign-in again.",
                userEmail: session.userEmail
            )
        } catch {
            return ChatGPTAuthSnapshot(
                state: .unavailable,
                detail: error.localizedDescription,
                userEmail: nil
            )
        }
    }

    func chatGPTAccountID() -> String? {
        try? loadSession()?.chatGPTAccountID
    }

    func bestAvailableAccessToken() async throws -> String {
        if let session = try loadSession(), session.tokenIsUsable(now: now()) {
            return session.accessToken
        }
        return try await refreshAccessToken()
    }

    func refreshAccessToken() async throws -> String {
        guard let session = try loadSession() else {
            throw ChatGPTAuthError.loginRequired
        }
        guard let refreshToken = session.refreshToken, refreshToken.isEmpty == false else {
            throw ChatGPTAuthError.sessionExpired
        }

        do {
            var refreshed = try await browserAuthBridge.refreshSession(
                refreshToken: refreshToken,
                now: now()
            )
            if refreshed.refreshToken == nil {
                refreshed.refreshToken = refreshToken
            }
            try saveSession(refreshed)
            return refreshed.accessToken
        } catch let error as ChatGPTAuthError {
            if case .loginRequired = error {
                try? signOut()
            }
            throw error
        } catch {
            throw ChatGPTAuthError.refreshFailed(error.localizedDescription)
        }
    }

    func connectViaDefaultBrowser() async throws -> ChatGPTSession {
        if let session = try loadSession(), session.tokenIsUsable(now: now()) {
            return session
        }

        do {
            let session = try await browserAuthBridge.captureSession(now: now())
            try saveSession(session)
            return session
        } catch {
            throw ChatGPTAuthError.browserLoginFailed(error.localizedDescription)
        }
    }

    func browserBridgeSnapshot() -> BrowserBridgeSnapshot {
        browserAuthBridge.snapshot()
    }

    func prewarmSession() async {
        _ = try? await bestAvailableAccessToken()
    }

    func signOut() throws {
        try store.delete()
        lock.lock()
        cachedSession = nil
        lock.unlock()
        NotificationCenter.default.post(name: .chatGPTAuthStateDidChange, object: nil)
    }

    private func loadSession() throws -> ChatGPTSession? {
        lock.lock()
        if let cachedSession {
            lock.unlock()
            return cachedSession
        }
        lock.unlock()

        let session = try store.load()
        lock.lock()
        cachedSession = session
        lock.unlock()
        return session
    }

    private func saveSession(_ session: ChatGPTSession) throws {
        try store.save(session)
        lock.lock()
        cachedSession = session
        lock.unlock()
        NotificationCenter.default.post(name: .chatGPTAuthStateDidChange, object: nil)
    }
}
