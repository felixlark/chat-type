import Foundation
import Testing
@testable import ChatType

@Test
func latencyRecorderAppendsJsonlSamples() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recorder = LatencyRecorder(directoryURL: root)

    try recorder.record(
        .init(
            timestamp: Date(timeIntervalSince1970: 1_234),
            audioDurationMs: 3_000,
            audioBytes: 42_000,
            provider: "chatGPTManagedAuth",
            textPolishProvider: "chatGPTAuth",
            authMs: 120,
            transcribeMs: 850,
            normalizationMs: 2,
            polishMs: 300,
            textPolishAttempted: true,
            estimatedPolishInputTokens: 1_200,
            estimatedPolishOutputTokens: 400,
            injectMs: 40,
            totalProcessingMs: 1_012,
            resultStatus: "pasted",
            errorCategory: nil,
            uploadedAudioBytes: 7_000,
            uploadEncodingMs: 15,
            uploadAudioFormat: "voice.m4a"
        )
    )

    let contents = try String(contentsOf: root.appendingPathComponent("latency.jsonl"), encoding: .utf8)
    #expect(contents.contains("\"uploadedAudioBytes\":7000"))
    #expect(contents.contains("\"uploadAudioFormat\":\"voice.m4a\""))
    #expect(contents.contains("\"provider\":\"chatGPTManagedAuth\""))
    #expect(contents.contains("\"textPolishProvider\":\"chatGPTAuth\""))
    #expect(contents.contains("\"textPolishAttempted\":true"))
    #expect(contents.contains("\"transcribeMs\":850"))
    #expect(contents.contains("\"estimatedPolishInputTokens\":1200"))
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])
    for field in ["uploadedAudioBytes", "uploadEncodingMs", "uploadAudioFormat"] { legacy.removeValue(forKey: field) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(LatencySample.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.uploadedAudioBytes == nil)
    #expect(decoded.audioBytes == 42_000)
}

@Test func processingTimingSeparatesPolishCallsHTTPRetriesAndUnknownFields() async throws {
    let trace = ProcessingTiming()
    let first = trace.beginPolishCall()
    let http1 = trace.beginHTTP(call: first)
    trace.headers(call: first, attempt: http1, status: 401)
    trace.finished(call: first, attempt: http1, status: 401, outcome: "response")
    let http2 = trace.beginHTTP(call: first)
    await ProcessingTrace.$current.withValue(trace) {
        await ProcessingTrace.$polishCall.withValue(first) {
            await ProcessingTrace.$httpAttempt.withValue(http2) {
                ProcessingTrace.observeStreamLine(#"data: {"type":"response.reasoning_summary_text.delta","delta":"reasoning"}"#)
                #expect(trace.snapshot().polishCalls[0].httpAttempts[1].firstContentDeltaMs == nil)
                ProcessingTrace.observeStreamLine(#"data: {"type":"response.output_text.delta","delta":"synthetic"}"#)
                ProcessingTrace.observeStreamLine(#"data: {"type":"response.completed","response":{"usage":{"input_tokens":50,"output_tokens":0,"input_tokens_details":{"cached_tokens":0}}}}"#)
            }
        }
    }
    trace.finished(call: first, attempt: http2, status: 200, outcome: "response")
    let second = trace.beginPolishCall()
    let next = trace.beginHTTP(call: second)
    trace.finished(call: second, attempt: next, status: nil, outcome: "error")
    let result = trace.snapshot(ready: true)
    #expect(result.polishCalls.map(\.ordinal) == [1, 2])
    #expect(result.polishCalls[0].httpAttempts.map(\.ordinal) == [1, 2])
    #expect(result.polishCalls[0].httpAttempts[1].firstContentDeltaMs != nil)
    #expect(result.polishCalls[0].httpAttempts[1].outputTokens == 0)
    #expect(result.polishCalls[0].httpAttempts[1].cachedInputTokens == 0)
    #expect(result.polishCalls[1].httpAttempts[0].headersMs == nil)
    #expect(result.polishCalls[1].httpAttempts[0].outputTokens == nil)
    #expect(result.pipelineReadyMs != nil)
    let json = try JSONEncoder().encode(result)
    #expect(!String(decoding: json, as: UTF8.self).contains("synthetic"))
    #expect(try JSONDecoder().decode(ProcessingTimingSnapshot.self, from: json) == result)
}

@Test func processingTimingObservesByteStreamWithoutContentType() {
    let trace = ProcessingTiming()
    let call = trace.beginPolishCall()
    let attempt = trace.beginHTTP(call: call)
    ProcessingTrace.$current.withValue(trace) {
        ProcessingTrace.$polishCall.withValue(call) {
            ProcessingTrace.$httpAttempt.withValue(attempt) {
                var observer = PolishStreamTimingObserver()
                let reasoning = #"data: {"type":"response.reasoning_summary_text.delta","delta":"reasoning"}"# + "\r\n\r\n"
                reasoning.utf8.forEach { observer.consume($0) }
                #expect(trace.snapshot().polishCalls[0].httpAttempts[0].firstContentDeltaMs == nil)
                let text = #"data: {"type":"response.output_text.delta","delta":"合成文本"}"# + "\n\n"
                text.utf8.forEach { observer.consume($0) }
                #expect(trace.snapshot().polishCalls[0].httpAttempts[0].firstContentDeltaMs != nil)
                let completed = #"data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":4}}}"#
                completed.utf8.forEach { observer.consume($0) }
                #expect(trace.snapshot().polishCalls[0].httpAttempts[0].protocolCompletedMs == nil)
                observer.finishLine()
            }
        }
    }
    let result = trace.snapshot().polishCalls[0].httpAttempts[0]
    #expect(result.headersMs == nil)
    #expect(result.responseMimeType == nil)
    #expect(result.protocolCompletedMs != nil)
    #expect(result.outputTokens == 4)
}
