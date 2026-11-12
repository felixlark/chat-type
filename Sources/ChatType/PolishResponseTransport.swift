import Foundation

final class PolishRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Both credential-bearing fixed endpoints reject every redirect.
enum PolishResponseTransport {
    private static let session = URLSession(configuration: .ephemeral, delegate: PolishRedirectPolicy(), delegateQueue: nil)

    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let http = response as? HTTPURLResponse
        if let trace = ProcessingTrace.current, let call = ProcessingTrace.polishCall, let attempt = ProcessingTrace.httpAttempt {
            trace.headers(call: call, attempt: attempt, status: http?.statusCode, mimeType: response.mimeType)
        }
        let isSSE = http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
        guard isSSE, let status = http?.statusCode, (200..<300).contains(status) else {
            var data = Data()
            var timingObserver = PolishStreamTimingObserver()
            let observesTiming = ProcessingTrace.current != nil && http.map { (200..<300).contains($0.statusCode) } == true
            for try await byte in bytes {
                data.append(byte)
                if observesTiming { timingObserver.consume(byte) }
            }
            if observesTiming { timingObserver.finishLine() }
            return (data, response)
        }
        var body = Data()
        var completion = ChatCompletionPolishStream()
        let isChatCompletion = ["open.bigmodel.cn", "dashscope.aliyuncs.com"].contains(request.url?.host ?? "")
        for try await line in bytes.lines {
            try Task.checkCancellation()
            body.append(contentsOf: (line + "\n").utf8)
            ProcessingTrace.observeStreamLine(line)
            if isChatCompletion {
                if try completion.consume(line) { return (body, response) }
            } else {
                if isCompletedEvent(line) { return (body, response) }
                if line.hasPrefix("data: "), line.contains("\"response.failed\"") || line.contains("\"response.incomplete\"") {
                    throw TextPolishError.requestFailed("AI Polish returned an incomplete response.")
                }
            }
        }
        throw TextPolishError.requestFailed("AI Polish stream ended before completion.")
    }

    static func isCompletedEvent(_ line: String) -> Bool {
        guard line.hasPrefix("data: "),
              let data = String(line.dropFirst(6)).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return event["type"] as? String == "response.completed"
    }
}

struct ChatCompletionPolishStream {
    private(set) var text = ""

    mutating func consume(_ line: String) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["error"] == nil,
              let choices = event["choices"] as? [[String: Any]],
              let choice = choices.first else { throw TextPolishError.invalidResponse }
        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
            text += content
        }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextPolishError.invalidResponse
            }
            return true
        }
        return false
    }
}
