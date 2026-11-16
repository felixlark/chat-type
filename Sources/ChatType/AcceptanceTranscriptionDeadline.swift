import Foundation
import OSLog

/// Explicit installed-app acceptance only. The failure still comes from real URLSession I/O.
final class AcceptanceTranscriptionDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private let logger = Logger(subsystem: "me.longbiaochen.chattype", category: "AcceptanceTransport")

    static func requested(arguments: [String]) -> Bool {
        arguments.contains("--acceptance-transcription-timeout-once")
    }

    func prepare(_ request: URLRequest) -> URLRequest {
        guard let url = request.url, url.scheme == "https", url.host == "chatgpt.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.path == "/backend-api/transcribe", url.query == nil, url.fragment == nil,
              request.httpMethod == "POST" else { return request }
        let consume = lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
        guard consume else { return request }
        var limited = request
        limited.timeoutInterval = 0.001
        logger.notice("Controlled acceptance: first audited transcription POST deadline=1ms; real URLSession, no synthesized error")
        return limited
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: prepare(request)) }
        catch let error as URLError {
            logger.notice("Real URLSession acceptance transport error: code=\(error.errorCode, privacy: .public)")
            throw error
        }
    }

    func pipeline(_ config: TranscriptionConfig, _ auth: any ChatGPTAuthProviding,
                  _ policy: TranscriptionAttemptPolicy) -> any DictationPreparing {
        DictationServiceFactory.make(
            config: config, auth: auth, policy: policy,
            dataLoader: { request in try await self.load(request) }
        )
    }
}
