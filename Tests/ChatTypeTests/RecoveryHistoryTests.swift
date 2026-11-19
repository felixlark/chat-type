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
func recoveryHistoryPagesKeepTenRowsAndExposeNavigation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("wav".utf8).write(to: source)
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery", isDirectory: true))
    for index in 0..<21 {
        try store.record(RecoveryRecordInput(timestamp: Date(timeIntervalSince1970: TimeInterval(index)), sourceAudioURL: source,
            durationMs: 1_000, asrText: "asr \(index)", polishText: nil, appName: nil, appBundleIdentifier: nil,
            outcome: "clipboard", errorMessage: nil))
    }
    let first = try store.loadPage(offset: 0, limit: 10)
    let second = try store.loadPage(offset: 10, limit: 10)
    let last = try store.loadPage(offset: 20, limit: 10)
    #expect(first.records.count == 10 && first.hasNext && !first.hasPrevious)
    #expect(second.records.count == 10 && second.hasNext && second.hasPrevious)
    #expect(last.records.count == 1 && !last.hasNext && last.hasPrevious)
    #expect(Set(first.records.map(\.id)).isDisjoint(with: second.records.map(\.id)))
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

@Test
func diagnosticAttemptPreservesPrimaryVoiceStateAndSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("wav".utf8).write(to: source)
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery", isDirectory: true))
    let fullAttemptID = UUID()
    let diagnosticAttemptID = UUID()
    let config = TranscriptionConfig()

    try store.record(RecoveryRecordInput(
        timestamp: Date(timeIntervalSince1970: 10),
        sourceAudioURL: source,
        durationMs: 3_000,
        asrText: "primary asr",
        polishText: "primary polish",
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "pasted",
        errorMessage: nil,
        snapshot: config,
        attemptID: fullAttemptID,
        stages: DictationStageAudit(
            asrText: "primary asr",
            polishInput: "primary asr",
            polishOutput: "primary polish",
            finalText: "primary final"
        )
    ))
    let firstRecord = try #require(try store.loadRecent(limit: 1).first)
    let ownedAudioURL = firstRecord.audioURL(baseDirectory: store.directoryURL)

    try store.record(RecoveryRecordInput(
        timestamp: Date(timeIntervalSince1970: 20),
        sourceAudioURL: ownedAudioURL,
        durationMs: 3_000,
        asrText: "diagnostic asr",
        polishText: nil,
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "asrComplete",
        errorMessage: nil,
        snapshot: config,
        attemptID: diagnosticAttemptID,
        stages: DictationStageAudit(asrText: "diagnostic asr"),
        attemptKind: .asrOnly
    ))

    let record = try #require(try store.loadRecent(limit: 1).first)
    #expect(record.outcome == "pasted")
    #expect(record.asrText == "primary asr")
    #expect(record.polishText == "primary polish")
    #expect(record.attempts?.count == 2)
    #expect(record.attempts?.last?.kind == .asrOnly)

    let index = try store.loadHistoryIndex()
    let summary = try #require(index.records.first)
    #expect(summary.outcome == "pasted")
    #expect(summary.primaryAttemptID == fullAttemptID)
    #expect(summary.attemptCount == 2)
    #expect(summary.stageStates.count == HistoryStagePosition.allCases.count)

    let diagnostic = HistoryRecordPresentation(
        record: record,
        selectedAttemptID: diagnosticAttemptID,
        audioAvailable: true
    )
    #expect(diagnostic.status.label == "仅转写完成")
    #expect(diagnostic.selectedAttempt?.resolvedKind == .asrOnly)
    #expect(diagnostic.stages.first(where: { $0.position == .alignment })?.state == .skipped)
    #expect(diagnostic.stages.first(where: { $0.position == .polish })?.state == .skipped)
    #expect(diagnostic.stages.first(where: { $0.position == .correction })?.state == .skipped)
    #expect(diagnostic.stages.first(where: { $0.position == .output })?.state == .skipped)
    #expect(diagnostic.artifacts.first(where: { $0.kind == .aligned })?.note == "仅转写尝试")
    #expect(diagnostic.artifacts.first(where: { $0.kind == .output })?.note == "仅诊断")
    #expect(diagnostic.artifacts.count == 3)
}

@Test
func legacyRecordPresentationKeepsOldPolishLabelAndOmitsFakeStages() {
    let record = RecoveryRecord(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 1),
        audioFileName: "old.wav",
        audioDurationMs: 2_000,
        asrText: "old asr",
        polishText: "old polish",
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "pasted",
        errorMessage: nil
    )
    let presentation = HistoryRecordPresentation(record: record, selectedAttemptID: nil, audioAvailable: true)
    #expect(presentation.legacy)
    #expect(presentation.stages.isEmpty)
    #expect(presentation.artifacts.count == 3)
    #expect(presentation.artifacts.first(where: { $0.kind == .aligned })?.note == "旧记录未保存对齐文本")
    #expect(presentation.artifacts.first(where: { $0.kind == .output })?.note == "旧版润色文本")
}

@Test
func failedAttemptPresentationExposesNoFakeTextArtifacts() throws {
    let recordID = UUID()
    let attemptID = UUID()
    let record = RecoveryRecord(
        id: recordID,
        timestamp: Date(timeIntervalSince1970: 2),
        audioFileName: "\(recordID.uuidString).wav",
        audioDurationMs: 1_000,
        asrText: nil,
        polishText: nil,
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "error",
        errorMessage: "ASR failed",
        attempts: [
            DictationAttempt(
                id: attemptID,
                startedAt: Date(timeIntervalSince1970: 2),
                snapshot: TranscriptionConfig(),
                stages: DictationStageAudit(error: "ASR failed"),
                outcome: "error"
            )
        ]
    )
    let presentation = HistoryRecordPresentation(
        record: record,
        selectedAttemptID: attemptID,
        audioAvailable: true
    )
    #expect(presentation.status.label == "处理失败")
    #expect(presentation.artifacts.allSatisfy { $0.text == nil })
    #expect(presentation.stages.first(where: { $0.position == .asr })?.state == .failed)
    #expect(presentation.stages.first(where: { $0.position == .alignment })?.state == .unavailable)
    #expect(presentation.stages.first(where: { $0.position == .polish })?.state == .failed)
}

@Test
func outputFailureAfterFinalizationDoesNotMarkEarlierStagesFailed() throws {
    let recordID = UUID()
    let attemptID = UUID()
    let record = RecoveryRecord(
        id: recordID,
        timestamp: Date(timeIntervalSince1970: 3),
        audioFileName: "\(recordID.uuidString).wav",
        audioDurationMs: 1_000,
        asrText: "raw",
        polishText: "polished",
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "error",
        errorMessage: "inject failed",
        attempts: [
            DictationAttempt(
                id: attemptID,
                startedAt: Date(timeIntervalSince1970: 3),
                snapshot: TranscriptionConfig(),
                stages: DictationStageAudit(
                    asrText: "raw",
                    polishInput: "raw",
                    polishOutput: "polished",
                    finalText: "polished",
                    error: "inject failed"
                ),
                outcome: "error"
            )
        ]
    )
    let presentation = HistoryRecordPresentation(
        record: record,
        selectedAttemptID: attemptID,
        audioAvailable: true
    )
    #expect(presentation.stages.first(where: { $0.position == .polish })?.state == .complete)
    #expect(presentation.stages.first(where: { $0.position == .correction })?.state == .complete)
    #expect(presentation.stages.first(where: { $0.position == .output })?.state == .failed)
    #expect(presentation.artifacts.first(where: { $0.kind == .output })?.text == "polished")
}

@Test
func historyTextChangeSummaryNamesChangedWords() {
    let summary = HistoryTextChangeAnalyzer.summarize(
        from: "请把陈晓的稿子发给张三",
        to: "请把林澈的稿子发给张三"
    )
    #expect(summary.count == 1)
    #expect(summary.uniqueTermCount == 1)
    #expect(summary.shortDetail.contains("陈晓 → 林澈"))
}

@Test
func historyTextChangeSummaryIgnoresPunctuationOnlyChanges() {
    let summary = HistoryTextChangeAnalyzer.summarize(
        from: "今天下雨 我不出门",
        to: "今天下雨，我不出门。"
    )
    #expect(summary.count == 0)
    #expect(summary.shortDetail == "无词级变化")
}

@Test
func legacyIndexOnlyRecordRemainsOpenableFromHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    let id = UUID()
    let record = RecoveryRecord(
        id: id,
        timestamp: Date(timeIntervalSince1970: 4),
        audioFileName: "\(id.uuidString).wav",
        audioDurationMs: 2_000,
        asrText: "legacy asr",
        polishText: "legacy polish",
        appName: "Notes",
        appBundleIdentifier: "com.apple.Notes",
        outcome: "pasted",
        errorMessage: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try (encoder.encode(record) + Data([0x0A]))
        .write(to: recovery.appendingPathComponent("recovery-history.jsonl"))

    let store = RecoveryStore(directoryURL: recovery)
    #expect(try store.loadHistoryIndex().records.contains { $0.id == id })
    let loaded = try #require(try store.loadRecord(id: id))
    #expect(loaded.asrText == "legacy asr")
    #expect(loaded.polishText == "legacy polish")
}
