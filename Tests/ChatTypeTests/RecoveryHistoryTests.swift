import Foundation
import Testing
@testable import ChatType

@Test
func recoveryStoreRecordsAudioAsrAndPolishCopyItems() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceAudioURL = root.appendingPathComponent("source.wav")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("wav-data".utf8).write(to: sourceAudioURL)

    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery", isDirectory: true))
    try store.record(
        RecoveryRecordInput(
            timestamp: Date(timeIntervalSince1970: 1_234),
            sourceAudioURL: sourceAudioURL,
            durationMs: 65_000,
            asrText: " raw transcript ",
            polishText: " polished transcript ",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            outcome: "pasted",
            errorMessage: nil
        )
    )

    let records = try store.loadRecent(limit: 10)
    #expect(records.count == 1)

    let record = try #require(records.first)
    #expect(FileManager.default.fileExists(atPath: record.audioURL(baseDirectory: store.directoryURL).path))

    let audioItem = try #require(RecoveryHistoryPreview.recentItems(from: records, kind: .audio, limit: 10).first)
    #expect(audioItem.copyKind == .audioFile)
    #expect(audioItem.text == "01:05 WAV")
    #expect(audioItem.target == "Notes")

    let asrItem = try #require(RecoveryHistoryPreview.recentItems(from: records, kind: .asr, limit: 10).first)
    #expect(asrItem.copyKind == .text)
    #expect(asrItem.copyText == "raw transcript")

    let polishItem = try #require(RecoveryHistoryPreview.recentItems(from: records, kind: .polish, limit: 10).first)
    #expect(polishItem.copyKind == .text)
    #expect(polishItem.copyText == "polished transcript")
}

@Test
func recoveryStoreDisplayLimitNeverPrunesOldAudio() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceAudioURL = root.appendingPathComponent("source.wav")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("wav-data".utf8).write(to: sourceAudioURL)

    let store = RecoveryStore(
        directoryURL: root.appendingPathComponent("Recovery", isDirectory: true),
        retainedLimit: 2
    )

    for index in 0..<3 {
        try store.record(
            RecoveryRecordInput(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                sourceAudioURL: sourceAudioURL,
                durationMs: 1_000,
                asrText: "asr \(index)",
                polishText: "polish \(index)",
                appName: nil,
                appBundleIdentifier: nil,
                outcome: "clipboard",
                errorMessage: nil
            )
        )
    }

    let records = try store.loadRecent(limit: 10)
    #expect(records.map(\.asrText) == ["asr 0", "asr 1", "asr 2"])
    #expect(try store.loadRecent(limit: 2).map(\.asrText) == ["asr 1", "asr 2"])

    let audioDirectory = store.directoryURL.appendingPathComponent("Audio", isDirectory: true)
    let audioFiles = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
    #expect(audioFiles.map(\.lastPathComponent).sorted() == records.map(\.audioFileName).sorted())
}

@Test
func recoveryPreviewSkipsMissingTextForTextKinds() {
    let record = RecoveryRecord(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 42),
        audioFileName: "sample.wav",
        audioDurationMs: 3_000,
        asrText: "   ",
        polishText: nil,
        appName: nil,
        appBundleIdentifier: nil,
        outcome: "error",
        errorMessage: "Network failed"
    )

    #expect(RecoveryHistoryPreview.recentItems(from: [record], kind: .audio, limit: 10).count == 1)
    #expect(RecoveryHistoryPreview.recentItems(from: [record], kind: .asr, limit: 10).isEmpty)
    #expect(RecoveryHistoryPreview.recentItems(from: [record], kind: .polish, limit: 10).isEmpty)
}

@Test
func recordingReservationIsPrivateAndVisibleBeforeAudioExists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root)
    let url = try store.beginRecording()
    #expect(FileManager.default.fileExists(atPath: url.path))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let records = try RecoveryStore(directoryURL: root).loadRecent(limit: 10)
    #expect(records.count == 1)
    #expect(records.first?.outcome == "recording")
    #expect(records.first?.audioURL(baseDirectory: root) == url)
}

@Test
func finishedAndCancelledRecordingUpdatesOriginalWithoutCopyOrPruning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root)
    let url = try store.beginRecording()
    let bytes = Data("original samples".utf8)
    try bytes.write(to: url)
    try store.finishRecording(RecordedAudio(fileURL: url, durationMs: 4_000), outcome: "cancelled")
    let records = try store.loadRecent(limit: 10)
    #expect(records.count == 1)
    #expect(records.first?.outcome == "cancelled")
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Audio").path).count == 1)
}

@Test
func restartRecoversUnfinalizedWAVAndKeepsAllPCMBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root)
    let url = try store.beginRecording()
    var wav = Data()
    func appendUInt32(_ value: UInt32) { var v = value.littleEndian; wav.append(withUnsafeBytes(of: &v) { Data($0) }) }
    func appendUInt16(_ value: UInt16) { var v = value.littleEndian; wav.append(withUnsafeBytes(of: &v) { Data($0) }) }
    wav.append(Data("RIFF".utf8)); appendUInt32(0); wav.append(Data("WAVEfmt ".utf8))
    appendUInt32(16); appendUInt16(1); appendUInt16(1); appendUInt32(24_000)
    appendUInt32(48_000); appendUInt16(2); appendUInt16(16)
    wav.append(Data("data".utf8)); appendUInt32(0)
    let samples = Data(repeating: 17, count: 48_000)
    wav.append(samples)
    try wav.write(to: url)
    let restarted = RecoveryStore(directoryURL: root)
    try restarted.recoverInterruptedRecordings()
    let records = try restarted.loadRecent(limit: 10)
    #expect(records.first?.outcome == "interrupted")
    #expect(records.first?.audioDurationMs == 1_000)
    let recovered = try Data(contentsOf: url)
    #expect(recovered.suffix(samples.count) == samples)
    #expect(try InterruptedWAVRecovery.repair(url: url) == 1_000)
    try restarted.recoverInterruptedRecordings()
    #expect(try restarted.loadRecent(limit: 10).count == 1)
}

@Test
func reservationFailsWhenArchiveCannotBeCreated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a directory".utf8).write(to: root)
    #expect(throws: (any Error).self) { try RecoveryStore(directoryURL: root).beginRecording() }
}
