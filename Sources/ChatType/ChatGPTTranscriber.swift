import Foundation

private enum TranscriptionUploadLimit {
    static let maxBytes = 25_000_000
    static let label = "25 MB"
}

enum TranscriptionError: LocalizedError {
    case invalidAudio
    case payloadTooLarge
    case noUsableAudioSignal
    case interruptedAudioInput(capturedSignalSeconds: Int, silentTailSeconds: Int)
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
        case .noUsableAudioSignal:
            return "录音中没有检测到有效麦克风信号；为避免输出空白或不完整转写，ChatType 未发送这份录音并已将其保留。请检查输入设备后重新录制。"
        case .interruptedAudioInput(let capturedSignalSeconds, let silentTailSeconds):
            return "麦克风输入在约 \(capturedSignalSeconds) 秒后中断，随后约 \(silentTailSeconds) 秒只有数字静音；为避免输出不完整转写，ChatType 未发送这份录音并已将其保留。请检查输入设备后重新录制。"
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
    var retryAfterSeconds: Int? = nil

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

        let wait = retryAfterSeconds.map { "；请等待 \($0) 秒后点击 Retry" } ?? ""
        return "\(providerLabel) 转写失败：\(message)\(wait)"
    }
}

struct TranscriptionMetrics: Sendable, Equatable {
    let provider: TranscriptionProvider
    let audioDurationMs: Int
    let audioBytes: Int
    let authMs: Int
    let transcribeMs: Int
    let promptIncluded: Bool
    var encodingMs: Int = 0
    var uploadedBytes: Int = 0
    var uploadFormat: String = "wav"
    var protocolRequestID: String? = nil
    var protocolSessions: [DoubaoSessionAttempt]? = nil
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
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> Int? {
        guard let value else { return nil }
        if let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(now))))
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let http = error as? TranscriptionHTTPError {
            return http.statusCode == 429 || (500...599).contains(http.statusCode)
        }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(url.code)
        }
        if case TranscriptionError.invalidResponse = error { return true }
        return false
    }

    let usesLocalSpeechForFiles: Bool
    let uploadMode: AudioUploadMode
    let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        authManager: any ChatGPTAuthProviding,
        config: TranscriptionConfig,
        promptBuilder: TranscriptionPromptBuilder = .init(),
        bridgePromptCapability: BridgePromptCapabilityStore = .shared,
        cloudflareChallengeMaxAttempts: Int = 3,
        uploadMode: AudioUploadMode = .automatic,
        usesLocalSpeechForFiles: Bool = false,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.authManager = authManager
        self.config = config
        self.promptBuilder = promptBuilder
        self.bridgePromptCapability = bridgePromptCapability
        self.cloudflareChallengeMaxAttempts = max(1, cloudflareChallengeMaxAttempts)
        self.usesLocalSpeechForFiles = usesLocalSpeechForFiles
        self.uploadMode = uploadMode
        self.dataLoader = dataLoader
    }

    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        var audio = audio
        if audio.localTranscript == nil, usesLocalSpeechForFiles, config.provider == .chatGPTManagedAuth {
            if #available(macOS 26.0, *) {
                let url = audio.fileURL
                audio.localTranscript = Task { try await LocalSpeechRecorder.transcribeFile(url, hintTerms: config.hintTerms) }
            }
        }
        if let local = audio.localTranscript {
            let started = DispatchTime.now().uptimeNanoseconds
            let text = try await withTaskCancellationHandler {
                try await local.value
            } onCancel: { local.cancel() }
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.invalidResponse
            }
            let bytes = (try? Data(contentsOf: audio.fileURL).count) ?? 0
            return TranscriptionResult(text: text, metrics: TranscriptionMetrics(
                provider: config.provider, audioDurationMs: audio.durationMs, audioBytes: bytes,
                authMs: 0, transcribeMs: elapsedMilliseconds(since: started), promptIncluded: false,
                uploadedBytes: 0, uploadFormat: "local-speech"))
        }
        let data = try Data(contentsOf: audio.fileURL)
        guard !data.isEmpty else {
            throw TranscriptionError.invalidAudio
        }
        guard data.count <= TranscriptionUploadLimit.maxBytes else {
            throw TranscriptionError.payloadTooLarge
        }

        switch PCMRecordingIntegrityAnalyzer().analyze(wavData: data) {
        case .noUsableSignal:
            throw TranscriptionError.noUsableAudioSignal
        case .interruptedInput(let capturedSignalSeconds, let silentTailSeconds):
            if audio.isPartialReplay { break }
            throw TranscriptionError.interruptedAudioInput(
                capturedSignalSeconds: capturedSignalSeconds,
                silentTailSeconds: silentTailSeconds
            )
        case nil:
            break
        }

        let vocabularyStarted = ProcessingTiming.now()
        let terms = (config.prioritizedHintTerms, config.promptHintTerms)
        ProcessingTrace.current?.recordStage("asrVocabulary", since: vocabularyStarted)
        let namesStarted = ProcessingTiming.now()
        let relatedNames = PersonalNameHints.relatedTerms(in: audio.previewText, entries: config.activeDictionaryEntries)
        ProcessingTrace.current?.recordStage("nameLookup", since: namesStarted)
        let promptStarted = ProcessingTiming.now()
        let prompt = promptBuilder.buildPrompt(
            hintTerms: terms.0 + relatedNames + terms.1,
            speechCleanupEnabled: config.speechCleanupEnabled
        )
        ProcessingTrace.current?.recordStage("asrPromptBuild", since: promptStarted)
        switch config.provider {
        case .doubaoIME:
            // Handled before the account-specific preparation above.
            throw TranscriptionError.invalidResponse
        case .chatGPTManagedAuth:
            let encodingStarted = DispatchTime.now().uptimeNanoseconds
            let payload = try AudioUploadPreparation().prepare(audio: audio, original: data, mode: uploadMode)
            let encodingMs = elapsedMilliseconds(since: encodingStarted)
            let authStarted = DispatchTime.now().uptimeNanoseconds
            var token = try await authManager.bestAvailableAccessToken()
            var accountID = authManager.chatGPTAccountID()
            var authMs = elapsedMilliseconds(since: authStarted)
            let transcribeStarted = DispatchTime.now().uptimeNanoseconds
            let response: (text: String, promptIncluded: Bool)
            do {
                response = try await transcribeViaChatGPTBridgeWithCloudflareRetries(
                    audioData: payload,
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
                    audioData: payload,
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
                    promptIncluded: response.promptIncluded,
                    encodingMs: encodingMs,
                    uploadedBytes: payload.data.count,
                    uploadFormat: payload.filename
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
        audioData: AudioUploadPayload,
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
        audioData: AudioUploadPayload,
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
        } catch let error as TranscriptionHTTPError where error.canRetryWithoutPrompt {
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
        audioData: AudioUploadPayload,
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
            audioData: audioData.data,
            filename: audioData.filename,
            mimeType: audioData.mimeType,
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
                bodyPrefix: String(data: responseData.prefix(512), encoding: .utf8),
                retryAfterSeconds: Self.retryAfterSeconds(httpResponse.value(forHTTPHeaderField: "Retry-After"))
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

    private func makeMultipartBody(boundary: String, audioData: Data, filename: String = "voice.wav", mimeType: String = "audio/wav", extraFields: [String: String]) -> Data {
        var body = Data()
        for (name, value) in extraFields.sorted(by: { $0.key < $1.key }) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: \(mimeType)\r\n\r\n".utf8)
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

/// Keep the account transcriber injectable and account-only. Provider routing is
/// explicit, so its test transport can never accidentally invoke a real socket.
struct SelectedRouteTranscriber: Transcriber {
    let account: ChatGPTTranscriber
    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        if account.config.provider == .doubaoIME {
            return try await DoubaoTranscriber(maximumSessionAttempts: account.cloudflareChallengeMaxAttempts).transcribe(audio)
        }
        return try await account.transcribe(audio)
    }
}

extension ChatGPTTranscriber {
    var selectedRoute: SelectedRouteTranscriber { SelectedRouteTranscriber(account: self) }
}

extension ChatGPTTranscriber: Transcriber {}
