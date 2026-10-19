import Foundation
@testable import ChatType

final class FakeChatGPTAuthManager: ChatGPTAuthProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var bestTokens: [Result<String, Error>]
    private var refreshTokens: [Result<String, Error>]
    private(set) var bestCallCount = 0
    private(set) var refreshCallCount = 0
    private let snapshotValue: ChatGPTAuthSnapshot
    private let accountIDValue: String?

    init(
        bestTokens: [Result<String, Error>] = [.success("desktop-token")],
        refreshTokens: [Result<String, Error>] = [.success("desktop-token")],
        accountID: String? = nil,
        snapshot: ChatGPTAuthSnapshot = ChatGPTAuthSnapshot(
            state: .ready,
            detail: "ready",
            userEmail: "user@example.com"
        )
    ) {
        self.bestTokens = bestTokens
        self.refreshTokens = refreshTokens
        accountIDValue = accountID
        snapshotValue = snapshot
    }

    func authSnapshot() -> ChatGPTAuthSnapshot {
        snapshotValue
    }

    func chatGPTAccountID() -> String? {
        accountIDValue
    }

    func bestAvailableAccessToken() async throws -> String {
        try next(from: &bestTokens, counter: \.bestCallCount)
    }

    func refreshAccessToken() async throws -> String {
        try next(from: &refreshTokens, counter: \.refreshCallCount)
    }

    func prewarmSession() async {}

    func signOut() throws {}

    private func next(
        from queue: inout [Result<String, Error>],
        counter: ReferenceWritableKeyPath<FakeChatGPTAuthManager, Int>
    ) throws -> String {
        lock.lock()
        self[keyPath: counter] += 1
        let result = queue.isEmpty ? .success("desktop-token") : queue.removeFirst()
        lock.unlock()
        return try result.get()
    }
}
