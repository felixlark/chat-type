import Darwin
import Foundation
import Testing
@testable import ChatType

private final class SocketProbe: @unchecked Sendable {
    let lock = NSLock()
    var received = false
    func mark() { lock.withLock { received = true } }
    var ready: Bool { lock.withLock { received } }
}

@Test(arguments: [false, true]) @MainActor
func cancellingStalledEditorSocketAllowsNextTransaction(throughSession: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("e.sock").path
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { Darwin.close(listener); try? FileManager.default.removeItem(at: root) }
    var address = sockaddr_un(); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(listener, SOMAXCONN) == 0)
    let probe = SocketProbe()
    let server = Task.detached {
        let first = Darwin.accept(listener, nil, nil)
        guard first >= 0 else { return }
        defer { Darwin.close(first) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = Darwin.recv(first, &buffer, buffer.count, 0)
        probe.mark() // Deliberately keep the first connection open without a reply.
        let second = Darwin.accept(listener, nil, nil)
        guard second >= 0 else { return }
        defer { Darwin.close(second) }
        _ = Darwin.recv(second, &buffer, buffer.count, 0)
        let reply = Data("{\"protocol\":1,\"build\":136,\"status\":\"ready\"}\n".utf8)
        reply.withUnsafeBytes { _ = Darwin.send(second, $0.baseAddress, $0.count, 0) }
        _ = Darwin.shutdown(second, SHUT_WR)
    }
    let stalled = EditorSocketTransaction()
    let bridge = SublimeEditorBridge(path: path)
    let editor = SublimeEditorSession(bridge: bridge)
    let first: Task<EditorBridgeResponse, Error>
    if throughSession { first = Task { try await editor.geometry() } }
    else { first = Task.detached { try stalled.exchange(path: path, request: EditorBridgeRequest(session: UUID().uuidString, operation: "health")) } }
    while !probe.ready { await Task.yield() }
    if throughSession { first.cancel() } else { stalled.cancel() }
    do { _ = try await first.value; Issue.record("Cancelled socket must not return a successful response") }
    catch { #expect(error is CancellationError) }
    let second: EditorBridgeResponse
    if throughSession { second = try await bridge.enqueue(session: UUID().uuidString, operation: "health").value }
    else { second = try await Task.detached { try EditorSocketTransaction().exchange(path: path,
        request: EditorBridgeRequest(session: UUID().uuidString, operation: "health")) }.value }
    #expect(second.status == "ready")
    await server.value
}
