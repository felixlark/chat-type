import Foundation

struct PolishHTTPAttemptTiming: Codable, Sendable, Equatable {
    let ordinal: Int
    var headersMs: Double?
    var firstContentDeltaMs: Double?
    var lastContentDeltaMs: Double?
    var protocolCompletedMs: Double?
    var finishedMs: Double?
    var statusCode: Int?
    var responseMimeType: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedInputTokens: Int?
    var reasoningTokens: Int?
    var responseModel: String?
    var outcome: String?
}

struct PolishCallTiming: Codable, Sendable, Equatable {
    let ordinal: Int
    var promptBuildMs: Double?
    var credentialsMs: Double?
    var httpAttempts: [PolishHTTPAttemptTiming] = []
}

struct ProcessingTimingSnapshot: Codable, Sendable, Equatable {
    let traceID: String
    let stagesMs: [String: Double]
    let polishCalls: [PolishCallTiming]
    let pipelineReadyMs: Double?
}

/// Task-scoped observations only. No text, vocabulary, credentials or URLs are recorded.
final class ProcessingTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let traceID = UUID().uuidString
    private let started = DispatchTime.now().uptimeNanoseconds
    private var stages: [String: Double] = [:]
    private var calls: [PolishCallTiming] = []
    private var attemptStarts: [String: UInt64] = [:]

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func milliseconds(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    func recordStage(_ name: String, since start: UInt64) {
        let ms = Self.milliseconds(since: start)
        lock.withLock { stages[name, default: 0] += ms }
    }
    func beginPolishCall() -> Int {
        lock.withLock {
            calls.append(PolishCallTiming(ordinal: calls.count + 1))
            return calls.count
        }
    }
    func recordPrompt(call: Int, since start: UInt64) {
        let ms = Self.milliseconds(since: start)
        lock.withLock { calls[call - 1].promptBuildMs = ms }
    }
    func recordCredentials(call: Int, since start: UInt64) {
        let ms = Self.milliseconds(since: start)
        lock.withLock { calls[call - 1].credentialsMs = (calls[call - 1].credentialsMs ?? 0) + ms }
    }
    func beginHTTP(call: Int) -> Int {
        lock.withLock {
            let ordinal = calls[call - 1].httpAttempts.count + 1
            calls[call - 1].httpAttempts.append(PolishHTTPAttemptTiming(ordinal: ordinal))
            attemptStarts["\(call):\(ordinal)"] = Self.now()
            return ordinal
        }
    }
    private func update(call: Int, attempt: Int, _ update: (inout PolishHTTPAttemptTiming, Double) -> Void) {
        lock.withLock {
            guard let start = attemptStarts["\(call):\(attempt)"] else { return }
            update(&calls[call - 1].httpAttempts[attempt - 1], Self.milliseconds(since: start))
        }
    }
    func headers(call: Int, attempt: Int, status: Int?, mimeType: String? = nil) {
        update(call: call, attempt: attempt) { row, ms in
            row.headersMs = ms
            row.statusCode = status
            row.responseMimeType = mimeType
        }
    }
    func contentDelta(call: Int, attempt: Int) {
        update(call: call, attempt: attempt) { row, ms in
            if row.firstContentDeltaMs == nil { row.firstContentDeltaMs = ms }
            row.lastContentDeltaMs = ms
        }
    }
    func completed(call: Int, attempt: Int, usage: [String: Any]?, model: String? = nil) {
        update(call: call, attempt: attempt) { row, ms in
            row.protocolCompletedMs = ms
            row.inputTokens = usage?["input_tokens"] as? Int ?? usage?["prompt_tokens"] as? Int
            row.outputTokens = usage?["output_tokens"] as? Int ?? usage?["completion_tokens"] as? Int
            let details = usage?["input_tokens_details"] as? [String: Any] ?? usage?["prompt_tokens_details"] as? [String: Any]
            row.cachedInputTokens = details?["cached_tokens"] as? Int
            let outputDetails = usage?["output_tokens_details"] as? [String: Any] ?? usage?["completion_tokens_details"] as? [String: Any]
            row.reasoningTokens = outputDetails?["reasoning_tokens"] as? Int
            row.responseModel = model
        }
    }
    func finished(call: Int, attempt: Int, status: Int?, outcome: String) {
        update(call: call, attempt: attempt) { row, ms in
            row.finishedMs = ms
            if let status { row.statusCode = status }
            row.outcome = outcome
        }
    }
    func snapshot(ready: Bool = false) -> ProcessingTimingSnapshot {
        lock.withLock {
            ProcessingTimingSnapshot(traceID: traceID, stagesMs: stages,
                polishCalls: calls, pipelineReadyMs: ready ? Self.milliseconds(since: started) : nil)
        }
    }
}

enum ProcessingTrace {
    @TaskLocal static var current: ProcessingTiming?
    @TaskLocal static var polishCall: Int?
    @TaskLocal static var httpAttempt: Int?

    static func observeStreamLine(_ line: String) {
        guard let trace = current, let call = polishCall, let attempt = httpAttempt,
              line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["type"] as? String == "response.output_text.delta", let delta = object["delta"] as? String, !delta.isEmpty {
            trace.contentDelta(call: call, attempt: attempt)
        }
        if let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty { trace.contentDelta(call: call, attempt: attempt) }
        if object["type"] as? String == "response.completed" {
            let response = object["response"] as? [String: Any]
            trace.completed(call: call, attempt: attempt, usage: response?["usage"] as? [String: Any], model: response?["model"] as? String)
        } else if let choices = object["choices"] as? [[String: Any]], choices.first?["finish_reason"] as? String == "stop" {
            trace.completed(call: call, attempt: attempt, usage: object["usage"] as? [String: Any])
        }
    }

    static func load(_ request: URLRequest, using loader: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        guard let trace = current, let call = polishCall else { return try await loader(request) }
        let attempt = trace.beginHTTP(call: call)
        return try await $httpAttempt.withValue(attempt) {
            do {
                let result = try await loader(request)
                trace.finished(call: call, attempt: attempt, status: (result.1 as? HTTPURLResponse)?.statusCode, outcome: "response")
                return result
            } catch {
                trace.finished(call: call, attempt: attempt, status: nil, outcome: error is CancellationError ? "cancelled" : "error")
                throw error
            }
        }
    }
}

/// Observes SSE timing even when the server omits a stream Content-Type.
/// The transport still returns the original response bytes unchanged.
struct PolishStreamTimingObserver {
    private var line = Data()

    mutating func consume(_ byte: UInt8) {
        if byte == 0x0A {
            finishLine()
        } else {
            line.append(byte)
        }
    }

    mutating func finishLine() {
        if line.starts(with: [0x64, 0x61, 0x74, 0x61, 0x3A]), let text = String(data: line, encoding: .utf8) {
            ProcessingTrace.observeStreamLine(text)
        }
        line.removeAll(keepingCapacity: true)
    }
}
