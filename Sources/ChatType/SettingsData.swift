import Foundation
import Combine

/// Disk and Keychain reads never execute on the UI executor. An overlapping
/// refresh is a pending read, not a dropped request or another concurrent scan.
@MainActor
final class SettingsResource<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    private let load: @Sendable () throws -> Value
    private var task: Task<Void, Never>?
    private var pending = false
    private var generation = UUID()
    private var overlays: [(Value) -> Value] = []

    init(_ initial: Value, load: @escaping @Sendable () throws -> Value) {
        value = initial
        self.load = load
    }

    func refresh() {
        refresh(using: load)
    }

    func refresh(using loader: @escaping @Sendable () throws -> Value) {
        guard task == nil else { pending = true; return }
        let id = UUID()
        generation = id
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            repeat {
                pending = false
                overlays = []
                let result = await Task.detached(priority: .utility) { Result { try loader() } }.value
                guard generation == id, !Task.isCancelled else { return }
                switch result {
                case .success(let loaded):
                    value = overlays.reduce(loaded) { $1($0) }
                    error = nil
                case .failure(let failure):
                    // Keep the last successful result, including live updates.
                    error = failure.localizedDescription
                }
                hasLoaded = true
            } while pending
            overlays = []
            isLoading = false
            task = nil
        }
    }

    func refreshIfIdle(using loader: @escaping @Sendable () throws -> Value) {
        guard task == nil else { return }
        refresh(using: loader)
    }

    /// A recording notification or successful credential save wins over a read
    /// that started before it. A subsequent refresh reads the durable result.
    func update(_ transform: @escaping (Value) -> Value) {
        value = transform(value)
        hasLoaded = true
        if isLoading { overlays.append(transform) }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        pending = false
        overlays = []
        isLoading = false
    }
}

struct SettingsProviderEnvironment: Sendable {
    var auth = ChatGPTAuthSnapshot(state: .unavailable, detail: "Checking saved session…", userEmail: nil)
    var browser = BrowserBridgeSnapshot(state: .available, detail: "Checking device login…")
    var qwenKeySaved = false
    var glmKeySaved = false
    var doubaoInstalled = false
    var checked = false

    static func doubaoIsInstalled(roots: [URL] = [
        URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true)
    ]) -> Bool {
        roots.contains { root in
            let url = root.appendingPathComponent("DoubaoIme.app", isDirectory: true)
            guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return plist["CFBundleIdentifier"] as? String == "com.bytedance.inputmethod.doubaoime"
        }
    }
}

struct TextPolishUsage: Equatable, Sendable {
    var attempts = 0
    var succeeded = 0
    var failed = 0
    var inputTokens = 0
    var outputTokens = 0

    var summary: String {
        guard attempts > 0 else { return "0 attempts / 0 tokens" }
        return "\(attempts) attempts / \(succeeded) succeeded / \(failed) failed / \(inputTokens + outputTokens) tokens"
    }
}

struct SettingsPolishUsage: Sendable {
    var usage: [TextPolishProviderID: TextPolishUsage] = [:]
    var unattributed = 0

    static func read(directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ChatType", isDirectory: true)) throws -> Self {
        let url = directoryURL.appendingPathComponent("latency.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result = Self()
        for line in contents.split(separator: "\n") {
            guard let sample = try? decoder.decode(LatencySample.self, from: Data(line.utf8)),
                  sample.textPolishAttempted ?? (sample.polishMs > 0 || sample.textPolishProvider != nil) else { continue }
            guard let provider = sample.textPolishProvider.flatMap(TextPolishProviderID.init(rawValue:)) else {
                result.unattributed += 1
                continue
            }
            var current = result.usage[provider] ?? TextPolishUsage()
            current.attempts += 1
            if sample.textPolishProvider != nil {
                current.succeeded += 1
                current.inputTokens += sample.estimatedPolishInputTokens
                current.outputTokens += sample.estimatedPolishOutputTokens
            } else { current.failed += 1 }
            result.usage[provider] = current
        }
        return result
    }
}
