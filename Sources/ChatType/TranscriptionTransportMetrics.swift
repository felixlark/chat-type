import Foundation

/// Per-transcription instrumentation; retains timing only, never headers or credentials.
final class TranscriptionTransportMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transactions: [[String: Int]] = []

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let rows = metrics.transactionMetrics.map { metric in
            func ms(_ start: Date?, _ end: Date?) -> Int {
                guard let start, let end else { return 0 }
                return max(0, Int(end.timeIntervalSince(start) * 1000))
            }
            return ["uploadMs": ms(metric.requestStartDate, metric.requestEndDate),
                    "waitMs": ms(metric.requestEndDate, metric.responseStartDate),
                    "receiveMs": ms(metric.responseStartDate, metric.responseEndDate),
                    "connectMs": ms(metric.connectStartDate, metric.connectEndDate)]
        }
        lock.lock()
        transactions.append(contentsOf: rows)
        lock.unlock()
    }

    func snapshot() -> [[String: Int]] {
        lock.lock()
        defer { lock.unlock() }
        return transactions
    }
}
