import Foundation
import Testing
@testable import ChatType

@Test
func acceptanceDeadlineIsExplicitAndOnlyConsumesTheAuditedPOST() {
    #expect(!AcceptanceTranscriptionDeadline.requested(arguments: ["ChatType"]))
    #expect(AcceptanceTranscriptionDeadline.requested(arguments: ["ChatType", "--acceptance-transcription-timeout-once"]))
    let deadline = AcceptanceTranscriptionDeadline()
    for endpoint in ["http://chatgpt.com/backend-api/transcribe", "https://example.com/backend-api/transcribe",
                     "https://chatgpt.com/backend-api/transcribe?other=1", "https://chatgpt.com/other"] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        #expect(deadline.prepare(request).timeoutInterval == request.timeoutInterval)
    }
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
    #expect(deadline.prepare(request).timeoutInterval == request.timeoutInterval)
    request.httpMethod = "POST"
    #expect(deadline.prepare(request).timeoutInterval == 0.001)
    #expect(deadline.prepare(request).timeoutInterval == request.timeoutInterval)
}

@Test
func acceptanceDeadlineIsConsumedExactlyOnceUnderConcurrency() {
    let deadline = AcceptanceTranscriptionDeadline()
    final class Count: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func increment() { lock.withLock { value += 1 } }
    }
    let count = Count()
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
        request.httpMethod = "POST"
        if deadline.prepare(request).timeoutInterval == 0.001 { count.increment() }
    }
    #expect(count.value == 1)
}
