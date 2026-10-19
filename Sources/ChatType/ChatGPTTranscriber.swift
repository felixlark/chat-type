import Foundation

private enum TranscriptionUploadLimit {
    static let maxBytes = 25_000_000
    static let label = "25 MB"
}

enum TranscriptionError: LocalizedError {
    case invalidAudio
    case payloadTooLarge
    case transcriptionFailed(String)
    case invalidResponse
    case missingAuthTokenEnv(String)
    case retryableCloudflareChallenge(attempts: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "录音文件无效。"
        case .payloadTooLarge:
            return "录音文件超过 \(TranscriptionUploadLimit.label)，已超过 ChatGPT/OpenAI 转写上传上限，当前不发送。"
        case .transcriptionFailed(let message):
            return "ChatGPT 转写失败：\(message)"
        case .invalidResponse:
            return "ChatGPT 转写返回了空文本。"
        case .missingAuthTokenEnv(let envName):
            return "缺少转写 API key，请设置环境变量 \(envName)。"
        case .retryableCloudflareChallenge(let attempts):
            return "ChatGPT 私有转写接口连续 \(attempts) 次返回 Cloudflare 403 challenge；这不是 ChatType 会话过期。录音已保留，可以点击 Retry 再试一次。"
        }
    }
}

private struct TranscriptionHTTPError: LocalizedError {
    let providerLabel: String
    let statusCode: Int
    let message: String
    let contentType: String?
    let server: String?
    let bodyPrefix: String?

    var isAuthFailure: Bool {
        statusCode == 401 || statusCode == 403
    }

    var shouldRefreshAuthToken: Bool {
        isAuthFailure && !isCloudflareChallenge
    }

    var canRetryWithoutPrompt: Bool {
        statusCode == 400 || statusCode == 422
    }

    var isCloudflareChallenge: Bool {
        guard statusCode == 403 else {
            return false
        }

        let lowerContentType = contentType?.lowercased() ?? ""
        let lowerServer = server?.lowercased() ?? ""
        let lowerBodyPrefix = bodyPrefix?.lowercased() ?? ""
        return lowerServer.contains("cloudflare")
            || lowerContentType.contains("text/html")
            || lowerBodyPrefix.contains("<html")
            || lowerBodyPrefix.contains("cloudflare")
    }

    var errorDescription: String? {
        if isCloudflareChallenge {
            return "\(providerLabel) 转写失败：私有转写接口返回 Cloudflare 403 challenge；这不是 ChatType 会话过期。"
        }

        return "\(providerLabel) 转写失败：\(message)"
    }
}

struct TranscriptionMetrics: Sendable, Equatable {
    let provider: TranscriptionProvider
    let audioDurationMs: Int
    let audioBytes: Int
    let authMs: Int
    let transcribeMs: Int
    let promptIncluded: Bool
}

struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let metrics: TranscriptionMetrics
}

final class BridgePromptCapabilityStore: @unchecked Sendable {
    static let shared = BridgePromptCapabilityStore()

    private let lock = NSLock()
    private var supportsPrompt: Bool?

    func value() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return supportsPrompt
    }

    func mark(_ value: Bool) {
        lock.lock()
        supportsPrompt = value
        lock.unlock()
    }
}

struct ChatGPTTranscriber: Sendable {
    let authManager: any ChatGPTAuthProviding
    let config: TranscriptionConfig
    let promptBuilder: TranscriptionPromptBuilder
    let bridgePromptCapability: BridgePromptCapabilityStore
    let cloudflareChallengeMaxAttempts: Int
    let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        authManager: any ChatGPTAuthProviding,
        config: TranscriptionConfig,
        promptBuilder: TranscriptionPromptBuilder = .init(),
        bridgePromptCapability: BridgePromptCapabilityStore = .shared,
        cloudflareChallengeMaxAttempts: Int = 3,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.authManager = authManager
        self.config = config
        self.promptBuilder = promptBuilder
        self.bridgePromptCapability = bridgePromptCapability
        self.cloudflareChallengeMaxAttempts = max(1, cloudflareChallengeMaxAttempts)
        self.dataLoader = dataLoader
    }

    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        let data = try Data(contentsOf: audio.fileURL)
        guard !data.isEmpty else {
            throw TranscriptionError.invalidAudio
        }
        guard data.count <= TranscriptionUploadLimit.maxBytes else {
            throw TranscriptionError.payloadTooLarge
        }

        let prompt = promptBuilder.buildPrompt(
            hintTerms: config.promptHintTerms,
            speechCleanupEnabled: config.speechCleanupEnabled
        )

        switch config.provider {
        case .chatGPTManagedAuth:
            let authStarted = DispatchTime.now().uptimeNanoseconds
            var token = try await authManager.bestAvailableAccessToken()
            var accountID = authManager.chatGPTAccountID()
            var authMs = elapsedMilliseconds(since: authStarted)
            let transcribeStarted = DispatchTime.now().uptimeNanoseconds
            let response: (text: String, promptIncluded: Bool)
            do {
                response = try await transcribeViaChatGPTBridgeWithCloudflareRetries(
                    audioData: data,
                    token: token,
                    accountID: accountID,
                    prompt: prompt
                )
            } catch let error as TranscriptionHTTPError where error.shouldRefreshAuthToken {
                let refreshStarted = DispatchTime.now().uptimeNanoseconds
                token = try await authManager.refreshAccessToken()
                accountID = authManager.chatGPTAccountID()
                authMs += elapsedMilliseconds(since: refreshStarted)
                response = try await transcribeViaChatGPTBridgeWithCloudflareRetries(
                    audioData: data,
                    token: token,
                    accountID: accountID,
                    prompt: prompt
                )
            }
            let transcribeMs = elapsedMilliseconds(since: transcribeStarted)
            return TranscriptionResult(
                text: response.text,
                metrics: TranscriptionMetrics(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: audio.durationMs,
                    audioBytes: data.count,
                    authMs: authMs,
                    transcribeMs: transcribeMs,
                    promptIncluded: response.promptIncluded
                )
            )
        case .openAICompatible:
            let transcribeStarted = DispatchTime.now().uptimeNanoseconds
            let text = try await transcribeViaOpenAICompatible(
                audioData: data,
                prompt: prompt
            )
            let transcribeMs = elapsedMilliseconds(since: transcribeStarted)
            return TranscriptionResult(
                text: text,
                metrics: TranscriptionMetrics(
                    provider: .openAICompatible,
                    audioDurationMs: audio.durationMs,
                    audioBytes: data.count,
                    authMs: 0,
                    transcribeMs: transcribeMs,
                    promptIncluded: true
                )
            )
        }
    }

    private func transcribeViaChatGPTBridgeWithCloudflareRetries(
        audioData: Data,
        token: String,
        accountID: String?,
        prompt: String
    ) async throws -> (text: String, promptIncluded: Bool) {
        for attempt in 1...cloudflareChallengeMaxAttempts {
            do {
                return try await transcribeViaChatGPTBridge(
                    audioData: audioData,
                    token: token,
                    accountID: accountID,
                    prompt: prompt
                )
            } catch let error as TranscriptionHTTPError where error.isCloudflareChallenge {
                if attempt == cloudflareChallengeMaxAttempts {
                    throw TranscriptionError.retryableCloudflareChallenge(
                        attempts: cloudflareChallengeMaxAttempts
                    )
                }
                continue
            }
        }

        throw TranscriptionError.retryableCloudflareChallenge(
            attempts: cloudflareChallengeMaxAttempts
        )
    }

    private func transcribeViaChatGPTBridge(
        audioData: Data,
        token: String,
        accountID: String?,
        prompt: String
    ) async throws -> (text: String, promptIncluded: Bool) {
        let capability = bridgePromptCapability.value()
        if capability == false {
            let text = try await executeTranscriptionRequest(
                makeChatGPTBridgeRequest(
                    audioData: audioData,
                    token: token,
                    accountID: accountID,
                    prompt: nil
                ),
                providerLabel: "ChatGPT"
            )
            return (text, false)
        }

        do {
            let text = try await executeTranscriptionRequest(
                makeChatGPTBridgeRequest(
                audioData: audioData,
                token: token,
                accountID: accountID,
                prompt: prompt
                ),
                providerLabel: "ChatGPT"
            )
            bridgePromptCapability.mark(true)
            return (text, true)
        } catch let error as TranscriptionHTTPError where error.shouldRefreshAuthToken || error.isCloudflareChallenge {
            throw error
        } catch let error as TranscriptionHTTPError where !error.canRetryWithoutPrompt {
            throw error
        } catch {
            let fallbackText = try await executeTranscriptionRequest(
                makeChatGPTBridgeRequest(
                    audioData: audioData,
                    token: token,
                    accountID: accountID,
                    prompt: nil
                ),
                providerLabel: "ChatGPT"
            )
            bridgePromptCapability.mark(false)
            return (fallbackText, false)
        }
    }

    private func makeChatGPTBridgeRequest(
        audioData: Data,
        token: String,
        accountID: String?,
        prompt: String?
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: config.chatGPTURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID, accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("ChatType/0.5 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(makeBoundary())", forHTTPHeaderField: "Content-Type")
        let boundary = request.value(forHTTPHeaderField: "Content-Type")!.split(separator: "=").last.map(String.init) ?? makeBoundary()
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            extraFields: prompt.map { ["prompt": $0] } ?? [:]
        )
        return request
    }

    private func transcribeViaOpenAICompatible(audioData: Data, prompt: String) async throws -> String {
        guard let token = openAICompatibleAuthToken() else {
            throw TranscriptionError.missingAuthTokenEnv(config.openAIAuthTokenEnv)
        }

        let boundary = makeBoundary()
        var request = URLRequest(url: URL(string: config.openAITranscriptionURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            extraFields: [
                "model": config.openAIModel,
                "prompt": prompt,
            ]
        )

        return try await executeTranscriptionRequest(request, providerLabel: "OpenAI-compatible")
    }

    private func openAICompatibleAuthToken() -> String? {
        let token = ProcessInfo.processInfo.environment[config.openAIAuthTokenEnv] ?? ""
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedToken.isEmpty ? nil : trimmedToken
    }

    private func executeTranscriptionRequest(_ request: URLRequest, providerLabel: String) async throws -> String {
        let (responseData, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.transcriptionFailed("\(providerLabel) missing HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let providerMessage = decodeProviderMessage(from: responseData) ?? "status \(httpResponse.statusCode)"
            throw TranscriptionHTTPError(
                providerLabel: providerLabel,
                statusCode: httpResponse.statusCode,
                message: providerMessage,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                server: httpResponse.value(forHTTPHeaderField: "Server"),
                bodyPrefix: String(data: responseData.prefix(512), encoding: .utf8)
            )
        }

        let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        if let text = object?["text"] as? String, !text.isEmpty {
            return text
        }
        if let text = object?["transcript"] as? String, !text.isEmpty {
            return text
        }

        throw TranscriptionError.invalidResponse
    }

    private func makeBoundary() -> String {
        "ChatType-\(UUID().uuidString)"
    }

    private func makeMultipartBody(boundary: String, audioData: Data, extraFields: [String: String]) -> Data {
        var body = Data()
        for (name, value) in extraFields.sorted(by: { $0.key < $1.key }) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private func decodeProviderMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}

extension ChatGPTTranscriber: Transcriber {}
