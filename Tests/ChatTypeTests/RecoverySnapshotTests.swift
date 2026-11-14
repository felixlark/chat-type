import Foundation
import Testing
@testable import ChatType

private func snapshotWithTerms() -> TranscriptionConfig {
    var s = TranscriptionConfig()
    s.provider = .doubaoIME; s.textPolish.provider = .chatGPTAuth
    s.textPolish.chatGPTResponseModel = "gpt-6.1-terra"
    s.hintTerms = ["保留的提示词"]
    s.terminology.lastImportedSource = "test-source"
    s.terminology.entries = (0..<300).map {
        TerminologyEntry(type: .term, original: "测试词条\($0)", replacement: nil,
                         aliases: ["别名\($0)"], source: "test", usageCount: 0, createdAt: "2026-11-14")
    }
    return s
}
private func saveSnapshotAttempt(_ store: ChatType.RecoveryStore, _ url: URL, _ id: UUID,
                                 _ snapshot: TranscriptionConfig, outcome: String = "processing") throws {
    try store.record(ChatType.RecoveryRecordInput(timestamp: Date(), sourceAudioURL: url, durationMs: 100,
        asrText: "原识别", polishText: nil, appName: nil, appBundleIdentifier: nil,
        outcome: outcome, errorMessage: nil, snapshot: snapshot, attemptID: id,
        stages: .init(asrText: "原识别", polishInput: "原整理输入")))
}

@Test func repeatedStagesWriteOneFullSnapshotAndSmallDurableJournals() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatType.RecoveryStore(directoryURL: root)
    let url = try store.beginRecording(); let original = Data("retained audio".utf8); try original.write(to: url)
    let id = UUID(), snapshot = snapshotWithTerms()
    try saveSnapshotAttempt(store, url, id, snapshot)
    for _ in 0..<6 { try saveSnapshotAttempt(store, url, id, snapshot) }
    let stats = store.persistenceStats()
    #expect(stats.snapshotWrites == 1)
    #expect(stats.snapshotBytes > 30_000)
    #expect(stats.journalBytes < 30_000)
    let journal = root.appendingPathComponent("Records/\(url.deletingPathExtension().lastPathComponent).json")
    #expect(try Data(contentsOf: journal).count < 5000)
    let record = try #require(ChatType.RecoveryStore(directoryURL: root).loadRecent().first)
    #expect(record.snapshot == snapshot)
    #expect(record.attempts?.last?.snapshot == snapshot)
    #expect(record.attempts?.last?.stages.polishInput == "原整理输入")
    #expect(try Data(contentsOf: url) == original)
    #expect(try JSONDecoder().decode(ChatType.RecoveryRecord.self, from: JSONEncoder().encode(record)) == record)
    let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Snapshots/\(id.uuidString).json").path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func missingOrCorruptSnapshotCannotBeRebuiltFromOldIndexOrOverwriteJournal() throws {
    for missing in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatType.RecoveryStore(directoryURL: root)
        let url = try store.beginRecording(); let original = Data("retained original".utf8); try original.write(to: url)
        let id = UUID(); try saveSnapshotAttempt(store, url, id, snapshotWithTerms(), outcome: "readyToInject")
        let loaded = try #require(store.loadRecent().first)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var index = try encoder.encode(loaded); index.append(10)
        try index.write(to: root.appendingPathComponent("recovery-history.jsonl"))
        let journal = root.appendingPathComponent("Records/\(loaded.id.uuidString).json")
        let before = try Data(contentsOf: journal)
        let sidecar = root.appendingPathComponent("Snapshots/\(id.uuidString).json")
        if missing { try FileManager.default.removeItem(at: sidecar) }
        else { try Data("corrupted snapshot".utf8).write(to: sidecar) }
        let cold = ChatType.RecoveryStore(directoryURL: root)
        try cold.recoverInterruptedRecordings()
        #expect(try cold.loadRecent().isEmpty)
        #expect(cold.unreadableJournalCount == 1)
        #expect(try Data(contentsOf: journal) == before)
        #expect(try Data(contentsOf: url) == original)
        #expect(throws: (any Error).self) { try saveSnapshotAttempt(cold, url, id, snapshotWithTerms()) }
        #expect(try Data(contentsOf: journal) == before)
    }
}

@Test func build128ActualRecordAndColdRecoveryPreserveFullSnapshotReferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatType.RecoveryStore(directoryURL: root)
    let url = try store.beginRecording()
    try doubaoSnapshotWAV().write(to: url)
    let snapshot = snapshotWithTerms(), id = UUID()
    try saveSnapshotAttempt(store, url, id, snapshot, outcome: "processing")
    let old = LegacyRecovery128.RecoveryStore(directoryURL: root)
    let oldRecord = try #require(old.loadRecent().first)
    let slim = try #require(oldRecord.snapshot)
    #expect(slim.terminology.entries.isEmpty)
    #expect(slim.terminology.lastImportedSource?.hasPrefix(RecoverySnapshots.prefix) == true)
    #expect(slim.provider == snapshot.provider && slim.textPolish == snapshot.textPolish)
    // Execute exactly build128's reconstruction, not a new-format DTO roundtrip.
    try old.record(LegacyRecovery128.RecoveryRecordInput(timestamp: Date(), sourceAudioURL: url,
        durationMs: 100, asrText: "原识别", polishText: "终稿", appName: nil, appBundleIdentifier: nil,
        outcome: "readyToInject", errorMessage: nil, snapshot: slim, attemptID: id,
        stages: .init(asrText: "原识别", polishInput: "原整理输入", polishOutput: "终稿")))
    try old.recoverInterruptedRecordings()
    let restored = try #require(ChatType.RecoveryStore(directoryURL: root).loadRecent().first)
    #expect(restored.outcome == "outputUnknown")
    #expect(restored.snapshot == snapshot)
    #expect(restored.attempts?.last?.snapshot == snapshot)
    #expect(restored.attempts?.last?.stages.polishOutput == "终稿")
    #expect(restored.attempts?.last?.id == id)
    #expect(try Data(contentsOf: url) == doubaoSnapshotWAV())
}

private func doubaoSnapshotWAV() -> Data {
    var data = StreamingEvaluationCLI.header(pcmBytes: 640)
    data.append(Data(repeating: 1, count: 640)); return data
}

@Test func snapshotCacheRechecksChangedFilesAndRejectsChangingAnAttempt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatType.RecoveryStore(directoryURL: root)
    let url = try store.beginRecording(); try Data("audio".utf8).write(to: url)
    let id = UUID(); let s = snapshotWithTerms(); try saveSnapshotAttempt(store, url, id, s)
    _ = try store.loadRecent()
    var changed = s; changed.provider = .chatGPTManagedAuth
    #expect(throws: (any Error).self) { try saveSnapshotAttempt(store, url, id, changed) }
    #expect(try store.loadRecent().first?.snapshot == s)
    let sidecar = root.appendingPathComponent("Snapshots/\(id.uuidString).json")
    try Data("damaged".utf8).write(to: sidecar)
    #expect(try store.loadRecent().isEmpty)
}

@Test func archiveWriteAmplificationComparedWithActualBuild128Store() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = snapshotWithTerms()
    if let path = ProcessInfo.processInfo.environment["CHATTYPE_AUDIT_BENCHMARK_CONFIG"] {
        snapshot = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path))).transcription
    }
    let modernRoot = root.appendingPathComponent("modern"), oldRoot = root.appendingPathComponent("legacy")
    let modern = ChatType.RecoveryStore(directoryURL: modernRoot)
    let legacy = LegacyRecovery128.RecoveryStore(directoryURL: oldRoot)
    let modernURL = try modern.beginRecording(), oldURL = try legacy.beginRecording()
    let audio = Data("retained baseline PCM fixture".utf8)
    try audio.write(to: modernURL); try audio.write(to: oldURL)
    let id = UUID()
    let oldStart = ProcessingTiming.now()
    var oldJournalBytes = 0
    for _ in 0..<8 {
        try legacy.record(LegacyRecovery128.RecoveryRecordInput(timestamp: Date(), sourceAudioURL: oldURL,
            durationMs: 100, asrText: "固定识别", polishText: nil, appName: nil, appBundleIdentifier: nil,
            outcome: "processing", errorMessage: nil, snapshot: snapshot, attemptID: id,
            stages: .init(asrText: "固定识别", polishInput: "固定输入")))
        oldJournalBytes += try Data(contentsOf: oldRoot.appendingPathComponent("Records/\(oldURL.deletingPathExtension().lastPathComponent).json")).count
    }
    let oldMs = ProcessingTiming.milliseconds(since: oldStart)
    let newStart = ProcessingTiming.now()
    for _ in 0..<8 { try saveSnapshotAttempt(modern, modernURL, id, snapshot) }
    let newMs = ProcessingTiming.milliseconds(since: newStart)
    let stats = modern.persistenceStats()
    #expect(stats.snapshotWrites == 1)
    #expect(stats.snapshotBytes + stats.journalBytes < oldJournalBytes / 2)
    #expect(try ChatType.RecoveryStore(directoryURL: modernRoot).loadRecent().first?.snapshot == snapshot)
    print("AUDIT_WRITE_COMPARISON legacyMs=\(oldMs) modernMs=\(newMs) legacyJournalBytes=\(oldJournalBytes) modernJournalBytes=\(stats.journalBytes) snapshotBytes=\(stats.snapshotBytes) snapshotWrites=\(stats.snapshotWrites)")
}

@Test func failedSnapshotDurabilityMustBeRetriedBeforePublishingReference() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var synchronizations = 0
    let store = ChatType.RecoveryStore(directoryURL: root, snapshotSynchronizer: { url in
        synchronizations += 1
        if synchronizations < 3 { throw CocoaError(.fileWriteUnknown) }
        try ChatType.RecoveryStore.synchronize(url)
        try RecoverySnapshots.synchronizeDirectory(url.deletingLastPathComponent())
        try RecoverySnapshots.synchronizeDirectory(root)
    })
    let audio = try store.beginRecording(); try Data("raw retained".utf8).write(to: audio)
    let journal = root.appendingPathComponent("Records/\(audio.deletingPathExtension().lastPathComponent).json")
    let originalJournal = try Data(contentsOf: journal)
    let id = UUID(); let snapshot = snapshotWithTerms()
    for _ in 0..<2 {
        #expect(throws: (any Error).self) { try saveSnapshotAttempt(store, audio, id, snapshot) }
        #expect(try Data(contentsOf: journal) == originalJournal)
    }
    #expect(synchronizations == 2)
    try saveSnapshotAttempt(store, audio, id, snapshot)
    #expect(synchronizations == 3)
    try saveSnapshotAttempt(store, audio, id, snapshot)
    #expect(synchronizations == 3)
    #expect(try ChatType.RecoveryStore(directoryURL: root).loadRecent().first?.snapshot == snapshot)
}
