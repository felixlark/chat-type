import Foundation
import Testing
@testable import ChatType

private final class SettingsReadGate: @unchecked Sendable {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func read() throws -> Int {
        let current = lock.withLock { reads += 1; return reads }
        if current == 1 { release.wait() }
        return current
    }
}

@MainActor private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "Async settings read did not settle")
}

@Test @MainActor func settingsReadsStayOffMainCoalesceAndPreserveLiveUpdates() async {
    let gate = SettingsReadGate()
    let resource = SettingsResource(0) {
        #expect(!Thread.isMainThread)
        return try gate.read()
    }
    #expect(gate.count == 0) // constructing a settings window performs no IO
    resource.refresh()
    await settle { gate.count == 1 }
    #expect(resource.isLoading && resource.value == 0) // UI executor is still free
    resource.update { _ in 90 } // a notification or a successfully saved key
    #expect(resource.value == 90)
    gate.release.signal()
    await settle { !resource.isLoading }
    #expect(resource.value == 90) // old read must not overwrite a live update

    let otherGate = SettingsReadGate()
    let coalesced = SettingsResource(0) { try otherGate.read() }
    coalesced.refresh()
    await settle { otherGate.count == 1 }
    coalesced.refresh()
    coalesced.refresh()
    otherGate.release.signal()
    await settle { !coalesced.isLoading }
    #expect(otherGate.count == 2 && coalesced.value == 2)
}

@Test @MainActor func cancelledSettingsReadCannotOverwriteReopenedResource() async {
    let gate = SettingsReadGate()
    let resource = SettingsResource(0) { try gate.read() }
    resource.refresh()
    await settle { gate.count == 1 }
    resource.cancel()
    resource.refresh()
    await settle { !resource.isLoading }
    #expect(resource.value == 2)
    gate.release.signal()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(resource.value == 2 && !resource.isLoading)
}

@Test @MainActor func failedSettingsRefreshRetainsPreviousDataAndShowsError() async {
    let resource = SettingsResource(["previous result"]) { () throws -> [String] in
        throw CocoaError(.fileReadCorruptFile)
    }
    resource.refresh()
    await settle { !resource.isLoading }
    #expect(resource.value == ["previous result"])
    #expect(resource.error != nil)
}

@Test func doubaoInstallationChecksSystemAndUserRootsAndBundleIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("system"), user = root.appendingPathComponent("user")
    #expect(!SettingsProviderEnvironment.doubaoIsInstalled(roots: [system, user]))
    let contents = user.appendingPathComponent("DoubaoIme.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = contents.appendingPathComponent("Info.plist")
    func write(_ id: String) throws {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: plist)
    }
    try write("com.example.different")
    #expect(!SettingsProviderEnvironment.doubaoIsInstalled(roots: [system, user]))
    // A new root avoids Foundation Bundle's intentional metadata caching.
    let installed = root.appendingPathComponent("installed")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try write("com.bytedance.inputmethod.doubaoime")
    try FileManager.default.copyItem(at: user.appendingPathComponent("DoubaoIme.app"), to: installed.appendingPathComponent("DoubaoIme.app"))
    #expect(SettingsProviderEnvironment.doubaoIsInstalled(roots: [system, installed]))
}
