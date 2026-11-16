import Foundation
import Darwin

struct EditorBridgeResponse: Codable, Sendable {
    let `protocol`: Int
    let build: Int
    let status: String
    var finalApplied: Bool? = nil
    var matched: Bool? = nil
    var viewID: Int? = nil
    var visible: Bool? = nil
    var caretX: Double? = nil
    var caretY: Double? = nil
    var lineHeight: Double? = nil
    var viewportX: Double? = nil
    var viewportY: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var fontName: String? = nil
    var fontSize: Double? = nil
    var foreground: String? = nil
    var background: String? = nil
}

struct EditorBridgeRequest: Encodable, Sendable {
    let `protocol` = 1
    let session: String
    let operation: String
    var text: String? = nil
}

enum EditorDeliveryError: LocalizedError {
    case unavailable
    case outputUnknown
    var errorDescription: String? {
        switch self {
        case .unavailable: return "原编辑器的输入连接不可用；录音与终稿仍保留。"
        case .outputUnknown: return "原输入框可能已收到终稿，但输出状态未能确认。请先核对原文档，避免重复重跑；录音与终稿已保留。"
        }
    }
}

/// Cancellation shuts down the owned descriptor; the worker alone closes it,
/// preventing descriptor reuse races while interrupting a stalled read.
final class EditorSocketTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func exchange(path: String, request: EditorBridgeRequest) throws -> EditorBridgeResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EditorDeliveryError.unavailable }
        defer {
            lock.withLock { descriptor = -1 }
            Darwin.close(fd)
        }
        try lock.withLock {
            if cancelled { throw CancellationError() }
            descriptor = fd
        }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        // macOS sys/un.h defines the Unix-domain address capacity (sun_path).
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw EditorDeliveryError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw EditorDeliveryError.unavailable }
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw EditorDeliveryError.unavailable }
                sent += count
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw EditorDeliveryError.unavailable }
            response.append(contentsOf: buffer.prefix(count))
        }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        let decoded = try JSONDecoder().decode(EditorBridgeResponse.self, from: response)
        guard decoded.protocol == 1, decoded.build == 136 else { throw EditorDeliveryError.unavailable }
        return decoded
    }
}

@MainActor
final class SublimeEditorBridge {
    static let shared = SublimeEditorBridge()
    private let path: String
    private var tail: Task<EditorBridgeResponse, Error>?
    private var tasks: [UUID: (String, Task<EditorBridgeResponse, Error>)] = [:]

    init(path: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ChatType/EditorBridge/sublime.sock").path) { self.path = path }

    func enqueue(session: String, operation: String, text: String? = nil) -> Task<EditorBridgeResponse, Error> {
        let previous = tail
        let id = UUID()
        let transaction = EditorSocketTransaction()
        let request = EditorBridgeRequest(session: session, operation: operation, text: text)
        let path = self.path
        let task = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await Task.detached { try transaction.exchange(path: path, request: request) }.value
            } onCancel: { transaction.cancel() }
        }
        tasks[id] = (session, task)
        tail = task
        return task
    }

    func cancelPending(session: String) {
        for entry in tasks.values where entry.0 == session { entry.1.cancel() }
    }
}

@MainActor
protocol PinnedEditorSession: AnyObject {
    func prepare() async throws -> EditorBridgeResponse
    func geometry() async throws -> EditorBridgeResponse
    func commit(_ text: String) async throws -> Bool
    func cancelPending()
    func close()
}

@MainActor
final class SublimeEditorSession: PinnedEditorSession {
    private let id = UUID().uuidString
    private let bridge: SublimeEditorBridge
    init(bridge: SublimeEditorBridge = .shared) { self.bridge = bridge }
    func prepare() async throws -> EditorBridgeResponse {
        let response = try await bridge.enqueue(session: id, operation: "begin").value
        guard response.status == "active" else { throw EditorDeliveryError.unavailable }
        return response
    }
    func geometry() async throws -> EditorBridgeResponse {
        try await bridge.enqueue(session: id, operation: "geometry").value
    }
    func commit(_ text: String) async throws -> Bool {
        let response: EditorBridgeResponse
        do { response = try await bridge.enqueue(session: id, operation: "commit", text: text).value }
        catch {
            // A missing receipt can follow a successful mutation. Reconcile the
            // same pin; never send another commit or clipboard copy here.
            guard let reconciled = try? await bridge.enqueue(session: id, operation: "status").value,
                  reconciled.status == "committed", reconciled.matched == true else {
                throw EditorDeliveryError.outputUnknown
            }
            return true
        }
        if response.status == "committed", response.matched == true { return true }
        if response.status == "outputUnknown" || response.finalApplied == true { throw EditorDeliveryError.outputUnknown }
        return false
    }
    func cancelPending() { bridge.cancelPending(session: id) }
    func close() { cancelPending(); _ = bridge.enqueue(session: id, operation: "close") }
}
