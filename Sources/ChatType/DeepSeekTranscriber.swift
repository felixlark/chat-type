import Foundation

enum MarkpipeDeepSeekRoute {
    static let asrURL = URL(string: "https://api.markpipe.app/v1/tools/asr")!
    static let chatCompletionsURL = URL(string: "https://api.markpipe.app/v1/chat/completions")!
    static let polishModel = "deepseek-flash"
    // DeepSeek ASR accepts at most 8 MiB and 120 seconds per complete recording.
    // https://api-docs.deepseek.com/guides/asr/
    static let maximumAudioBytes = 8 * 1024 * 1024
    static let maximumAudioDurationMs = 120_000
}

enum DeepSeekHTTP {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PolishRedirectPolicy(), delegateQueue: nil)
    }()

    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum DeepSeekTranscriptionError: LocalizedError, Sendable {
    case missingKey
    case invalidAudio
    case payloadTooLarge
    case recordingTooLong
    case noUsableAudioSignal
    case interruptedAudioInput(capturedSignalSeconds: Int, silentTailSeconds: Int)
    case cloudflareChallenge(status: Int)
    case requestFailed(status: Int)
    case invalidResponse

    var isRetryable: Bool {
        switch self {
        case .requestFailed(let status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResponse:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "请先在 Account 保存 Markpipe API Key。"
        case .invalidAudio:
            return "录音文件无效，DeepSeek 未发送。"
        case .payloadTooLarge:
            return "录音超过 DeepSeek ASR 的 8 MB 上限，当前不发送。"
        case .recordingTooLong:
            return "录音超过 DeepSeek ASR 的 120 秒上限，当前不发送。"
        case .noUsableAudioSignal:
            return "录音中没有检测到有效麦克风信号；为避免输出空白或不完整转写，ChatType 未发送这份录音并已将其保留。请检查输入设备后重新录制。"
        case .interruptedAudioInput(let capturedSignalSeconds, let silentTailSeconds):
            return "麦克风输入在约 \(capturedSignalSeconds) 秒后中断，随后约 \(silentTailSeconds) 秒只有数字静音；为避免输出不完整转写，ChatType 未发送这份录音并已将其保留。请检查输入设备后重新录制。"
        case .cloudflareChallenge(let status):
            return "DeepSeek 转写失败：Markpipe 返回 Cloudflare \(status) challenge；这不是 API Key 失效。录音已保留，可以稍后手动重试。"
        case .requestFailed(let status):
            switch status {
            case 401, 403:
                return "DeepSeek 转写失败：Markpipe 鉴权失败（HTTP \(status)），请检查 API Key。"
            case 429:
                return "DeepSeek 转写失败：Markpipe 请求过多（HTTP 429），请稍后重试。"
            case 503, 504, 520...526:
                return "DeepSeek 转写失败：Markpipe 或 DeepSeek 服务暂时不可用（HTTP \(status)）。"
            default:
                return "DeepSeek 转写失败：Markpipe 返回 HTTP \(status)。"
            }
        case .invalidResponse:
            return "DeepSeek 转写返回了空文本或无法识别的响应。"
        }
    }
}

struct DeepSeekTranscriber: Transcriber {
    var keyStore: any MarkpipeKeyStoring = KeychainMarkpipeKeyStore()
    var dataLoader: DeepSeekHTTP.Loader = DeepSeekHTTP.load

    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? DeepSeekTranscriptionError {
            return error.isRetryable
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(error.code)
        }
        return false
    }

    func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
        let credentialStarted = DispatchTime.now().uptimeNanoseconds
        guard let key = try keyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw DeepSeekTranscriptionError.missingKey
        }
        let authMs = elapsedMilliseconds(since: credentialStarted)

        let data = try Data(contentsOf: audio.fileURL)
        guard !data.isEmpty else { throw DeepSeekTranscriptionError.invalidAudio }
        guard data.count <= MarkpipeDeepSeekRoute.maximumAudioBytes else {
            throw DeepSeekTranscriptionError.payloadTooLarge
        }
        guard audio.durationMs <= MarkpipeDeepSeekRoute.maximumAudioDurationMs else {
            throw DeepSeekTranscriptionError.recordingTooLong
        }
        switch PCMRecordingIntegrityAnalyzer().analyze(wavData: data) {
        case .noUsableSignal:
            throw DeepSeekTranscriptionError.noUsableAudioSignal
        case .interruptedInput(let capturedSignalSeconds, let silentTailSeconds):
            if !audio.isPartialReplay {
                throw DeepSeekTranscriptionError.interruptedAudioInput(
                    capturedSignalSeconds: capturedSignalSeconds,
                    silentTailSeconds: silentTailSeconds
                )
            }
        case nil:
            break
        }

        let boundary = "ChatType-\(UUID().uuidString)"
        var request = URLRequest(url: MarkpipeDeepSeekRoute.asrURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ChatType/macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, audioData: data)

        let transcribeStarted = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()
        let (responseData, response) = try await dataLoader(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403, isCloudflareChallenge(http, data: responseData) {
                throw DeepSeekTranscriptionError.cloudflareChallenge(status: http.statusCode)
            }
            throw DeepSeekTranscriptionError.requestFailed(status: http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekTranscriptionError.invalidResponse
        }

        return TranscriptionResult(
            text: text,
            metrics: TranscriptionMetrics(
                provider: .deepSeek,
                audioDurationMs: audio.durationMs,
                audioBytes: data.count,
                authMs: authMs,
                transcribeMs: elapsedMilliseconds(since: transcribeStarted),
                promptIncluded: false,
                uploadedBytes: data.count,
                uploadFormat: "wav",
                protocolRequestID: object["request_id"] as? String
            )
        )
    }

    private func multipartBody(boundary: String, audioData: Data) -> Data {
        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(audioData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func isCloudflareChallenge(_ response: HTTPURLResponse, data: Data) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let server = response.value(forHTTPHeaderField: "Server")?.lowercased() ?? ""
        let body = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return server.contains("cloudflare")
            || contentType.contains("text/html")
            || body.contains("<html")
            || body.contains("cloudflare")
    }
}
