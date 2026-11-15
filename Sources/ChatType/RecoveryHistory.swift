import Foundation
import Darwin
import CryptoKit
import OSLog

extension Notification.Name {
    static let recoveryRecordDidChange = Notification.Name("ChatTypeRecoveryRecordDidChange")
}

struct RecoveryWriteStats: Codable, Sendable, Equatable {
    var recordCalls = 0
    var recordMilliseconds: Double = 0
    var journalWrites = 0
    var journalBytes = 0
    var snapshotWrites = 0
    var snapshotBytes = 0
    var snapshotLoads = 0
    var snapshotCacheHits = 0
    var snapshotActiveHits = 0
    var snapshotInvalidations = 0
    var activeSnapshotCount = 0
}

struct RecoveryRecordInput: Sendable {
    let timestamp: Date
    let sourceAudioURL: URL
    let durationMs: Int
    let asrText: String?
    let polishText: String?
    let appName: String?
    let appBundleIdentifier: String?
    let outcome: String
    let errorMessage: String?
    var snapshot: TranscriptionConfig? = nil
    var attemptID: UUID? = nil
    var stages: DictationStageAudit? = nil
    var injectionSnapshot: InjectionConfig? = nil
    var parentRecordID: UUID? = nil
}

struct RecoveryRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let audioFileName: String
    let audioDurationMs: Int
    let asrText: String?
    let polishText: String?
    let appName: String?
    let appBundleIdentifier: String?
    let outcome: String
    let errorMessage: String?
    var snapshot: TranscriptionConfig? = nil
    var attempts: [DictationAttempt]? = nil
    var injectionSnapshot: InjectionConfig? = nil
    var audioSHA256: String? = nil
    var parentRecordID: UUID? = nil

    func audioURL(baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(audioFileName)
    }
}

enum RecoveryHistoryKind: String, CaseIterable, Identifiable, Sendable {
    case audio
    case asr
    case polish

    var id: String { rawValue }
}

enum RecoveryCopyKind: Sendable, Equatable {
    case audioFile
    case text
}

struct RecoveryHistoryPreview: Sendable, Equatable, Identifiable {
    let id: String
    let recordID: UUID
    let kind: RecoveryHistoryKind
    let timestamp: Date
    let text: String
    let copyText: String
    let copyKind: RecoveryCopyKind
    let target: String
    let outcome: String
    let errorMessage: String?
    let audioFileName: String
    let audioDurationMs: Int

    static func recentItems(
        from records: [RecoveryRecord],
        kind: RecoveryHistoryKind,
        limit: Int
    ) -> [RecoveryHistoryPreview] {
        records
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { record in
                makePreview(from: record, kind: kind)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func makePreview(
        from record: RecoveryRecord,
        kind: RecoveryHistoryKind
    ) -> RecoveryHistoryPreview? {
        let copyText: String
        let displayText: String
        let copyKind: RecoveryCopyKind

        switch kind {
        case .audio:
            copyText = ""
            copyKind = .audioFile
            displayText = (record.attempts?.last?.stages.partialAudio == true || record.outcome == "interrupted" ? "已保存片段 · " : "") + "\(formattedDuration(record.audioDurationMs)) WAV"
        case .asr:
            guard let text = record.asrText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            copyText = text
            copyKind = .text
            displayText = (record.attempts?.last?.stages.partialAudio == true
                || (record.outcome == "error" && record.attempts?.last?.stages.asrText == nil) ? "部分转写 · " : "") + collapsedPreview(text)
        case .polish:
            let protected = record.attempts?.last?.stages.polishProtectionReason != nil
            let accepted = protected ? (record.attempts?.last?.stages.finalText ?? record.attempts?.last?.stages.polishInput) : record.polishText
            guard let text = accepted?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            copyText = text
            copyKind = .text
            displayText = (protected ? "已保留原文 · " : (record.outcome == "error" || record.attempts?.last?.stages.partialAudio == true ? "部分整理 · " : "")) + collapsedPreview(text)
        }

        return RecoveryHistoryPreview(
            id: "\(kind.rawValue)-\(record.id.uuidString)",
            recordID: record.id,
            kind: kind,
            timestamp: record.timestamp,
            text: displayText,
            copyText: copyText,
            copyKind: copyKind,
            target: record.appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? record.appName ?? "Unknown target"
                : "Unknown target",
            outcome: record.outcome,
            errorMessage: record.errorMessage ?? record.attempts?.last?.stages.polishProtectionReason,
            audioFileName: record.audioFileName,
            audioDurationMs: record.audioDurationMs
        )
    }

    private static func collapsedPreview(_ text: String, maxCharacters: Int = 120) -> String {
        let collapsed = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxCharacters else {
            return collapsed
        }

        return String(collapsed.prefix(maxCharacters)) + "..."
    }

    private static func formattedDuration(_ durationMs: Int) -> String {
        let seconds = max(0, durationMs) / 1_000
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

protocol RecoveryRecording: Sendable {
    var directoryURL: URL { get }
    func record(_ input: RecoveryRecordInput) throws
    func loadRecent(limit: Int) throws -> [RecoveryRecord]
}

/// Audio is retained independently of the recent-history display limit.
/// A synced per-record journal exists before the microphone starts.
final class RecoveryStore: RecoveryRecording, @unchecked Sendable {
    private let fileManager: FileManager
    let directoryURL: URL
    private let lock = NSLock()
    private let snapshots: RecoverySnapshots
    private var writeStats = RecoveryWriteStats()
    private var unreadableJournals = 0
    private let logger = Logger(subsystem: "me.longbiaochen.chattype", category: "Recovery")

    init(fileManager: FileManager = .default, directoryURL: URL? = nil, retainedLimit: Int = 10,
         snapshotSynchronizer: ((URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChatType/Recovery", isDirectory: true)
        snapshots = RecoverySnapshots(directory: self.directoryURL.appendingPathComponent("Snapshots", isDirectory: true),
                                      fileManager: fileManager, synchronizeSnapshot: snapshotSynchronizer)
        // Kept for source compatibility; retention is now independent of display limits.
        _ = retainedLimit
    }

    func beginRecording() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectories()
        let id = UUID()
        let url = audioDirectoryURL.appendingPathComponent("\(id.uuidString).wav")
        guard fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try Self.synchronize(url)
        try synchronizeDirectory(audioDirectoryURL)
        let record = RecoveryRecord(id: id, timestamp: Date(), audioFileName: url.lastPathComponent,
                                    audioDurationMs: 0, asrText: nil, polishText: nil, appName: nil,
                                    appBundleIdentifier: nil, outcome: "recording", errorMessage: nil)
        try writeJournal(record)
        return url
    }

    func finishRecording(_ audio: RecordedAudio, outcome: String) throws {
        try Self.synchronize(audio.fileURL)
        try record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                                      durationMs: audio.durationMs, asrText: nil, polishText: nil,
                                      appName: nil, appBundleIdentifier: nil,
                                      outcome: outcome, errorMessage: nil))
    }

    static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func record(_ input: RecoveryRecordInput) throws {
        let started = ProcessingTiming.now()
        lock.lock()
        defer {
            writeStats.recordCalls += 1
            writeStats.recordMilliseconds += ProcessingTiming.milliseconds(since: started)
            lock.unlock()
        }
        try prepareDirectories()
        let ownedID = input.sourceAudioURL.deletingLastPathComponent().standardizedFileURL == audioDirectoryURL.standardizedFileURL
            ? UUID(uuidString: input.sourceAudioURL.deletingPathExtension().lastPathComponent) : nil
        let previous: RecoveryRecord?
        if let ownedID, fileManager.fileExists(atPath: journalDirectoryURL.appendingPathComponent("\(ownedID.uuidString).json").path) {
            previous = try readJournal(journalDirectoryURL.appendingPathComponent("\(ownedID.uuidString).json"), expectedID: ownedID)
        } else { previous = try loadAllUnlocked().first { $0.id == ownedID } }
        let id = ownedID ?? UUID()
        let audioFileName = "\(id.uuidString).wav"
        let destinationURL = audioDirectoryURL.appendingPathComponent(audioFileName)
        if input.sourceAudioURL.standardizedFileURL != destinationURL.standardizedFileURL {
            try fileManager.copyItem(at: input.sourceAudioURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        }
        try Self.synchronize(destinationURL)
        var attempts = previous?.attempts ?? []
        if let attemptID = input.attemptID, let snapshot = input.snapshot {
            let position = attempts.firstIndex { $0.id == attemptID }
            let old = position.map { attempts[$0] }
            let attempt = DictationAttempt(id: attemptID, startedAt: old?.startedAt ?? input.timestamp,
                snapshot: snapshot, stages: (old?.stages ?? .init()).merging(input.stages ?? .init()), outcome: input.outcome,
                injectionSnapshot: old?.injectionSnapshot ?? input.injectionSnapshot)
            if let position { attempts[position] = attempt } else { attempts.append(attempt) }
        }
        if input.attemptID == nil, input.outcome == "cancelled", let last = attempts.indices.last {
            attempts[last].outcome = "cancelled"
        }
        let sameAttempt = input.attemptID == nil || previous?.attempts?.last?.id == input.attemptID
        var audioSHA = previous?.audioSHA256
        if input.outcome != "recording", audioSHA == nil || !sameAttempt {
            let actual = try Self.checksum(destinationURL)
            guard audioSHA == nil || audioSHA == actual else {
                throw RecorderError.recordingStorageFailed("音频校验值已改变；未继续处理。")
            }
            audioSHA = actual
        }
        try writeJournal(RecoveryRecord(
            id: id, timestamp: previous?.timestamp ?? input.timestamp,
            audioFileName: audioFileName, audioDurationMs: input.durationMs,
            asrText: input.asrText ?? (sameAttempt ? previous?.asrText : nil),
            polishText: input.polishText ?? (sameAttempt ? previous?.polishText : nil),
            appName: input.appName ?? previous?.appName,
            appBundleIdentifier: input.appBundleIdentifier ?? previous?.appBundleIdentifier,
            outcome: input.outcome, errorMessage: input.errorMessage,
            snapshot: input.snapshot ?? previous?.snapshot, attempts: attempts.isEmpty ? nil : attempts,
            injectionSnapshot: input.injectionSnapshot ?? previous?.injectionSnapshot,
            audioSHA256: audioSHA, parentRecordID: input.parentRecordID ?? previous?.parentRecordID
        ))
    }

    /// Persist network sub-attempts while recording/processing. Preserve the
    /// current terminal outcome if cancellation races a receiver callback.
    func recordASRSessions(audioURL: URL, attemptID: UUID, sessions: [DoubaoSessionAttempt]) throws {
        lock.lock(); defer { lock.unlock() }
        let id = audioURL.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: id) != nil,
              audioURL.deletingLastPathComponent().standardizedFileURL == audioDirectoryURL.standardizedFileURL else {
            throw RecorderError.recordingStorageFailed("识别会话没有对应的原声归档。")
        }
        let url = journalDirectoryURL.appendingPathComponent("\(id).json")
        var record = try readJournal(url, expectedID: UUID(uuidString: id))
        guard let position = record.attempts?.firstIndex(where: { $0.id == attemptID }) else {
            throw RecorderError.recordingStorageFailed("识别会话没有对应的处理记录。")
        }
        record.attempts?[position].stages.asrSessions = sessions
        try writeJournal(record)
    }

    private static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Import external audio once, before processing, so every attempt keeps one
    /// owned audio identity. Original files are never removed.
    func adopt(_ audio: RecordedAudio) throws -> RecordedAudio {
        if audio.fileURL.deletingLastPathComponent().standardizedFileURL == audioDirectoryURL.standardizedFileURL {
            return audio
        }
        let destination = try beginRecording()
        let source = try FileHandle(forReadingFrom: audio.fileURL)
        let target = try FileHandle(forWritingTo: destination)
        defer { try? source.close(); try? target.close() }
        while let bytes = try source.read(upToCount: 65_536), !bytes.isEmpty { try target.write(contentsOf: bytes) }
        try target.synchronize()
        var owned = audio
        owned = RecordedAudio(fileURL: destination, durationMs: audio.durationMs,
            localTranscript: audio.localTranscript, previewText: audio.previewText, cloudTranscript: audio.cloudTranscript,
            isPartialReplay: audio.isPartialReplay)
        try finishRecording(owned, outcome: "recorded")
        return owned
    }

    func loadRecent(limit: Int = 10) throws -> [RecoveryRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        // Select by journal metadata first. Restoring every historic vocabulary
        // snapshot merely to display ten rows caused multi-second Settings hangs.
        let candidates = try loadAllUnlocked(hydrateSnapshots: false).sorted { $0.timestamp > $1.timestamp }
        var recent: [RecoveryRecord] = []
        for record in candidates {
            if let restored = try? hydrate(record) { recent.append(restored) }
            else { unreadableJournals += 1 }
            if recent.count == limit { break }
        }
        return recent.reversed()
    }

    /// Called once on normal launch, never while a recorder owns an open WAV.
    func recoverInterruptedRecordings() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectories()
        let records = try loadAllUnlocked()
        // A present but damaged journal is authoritative. Never mistake its WAV
        // for an orphan or overwrite the original audit with a synthetic record.
        let journalIDs = try Set(fileManager.contentsOfDirectory(at: journalDirectoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        let ids = Set(records.map(\.id)).union(journalIDs)
        var interrupted = records.filter { ["recording", "recorded", "processing", "readyToInject"].contains($0.outcome) }
        // A crash between file creation and journal creation must not hide the audio.
        for url in try fileManager.contentsOfDirectory(at: audioDirectoryURL, includingPropertiesForKeys: [.creationDateKey])
            where url.pathExtension == "wav" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            interrupted.append(RecoveryRecord(id: id, timestamp: date, audioFileName: url.lastPathComponent,
                audioDurationMs: 0, asrText: nil, polishText: nil, appName: nil, appBundleIdentifier: nil,
                outcome: "recording", errorMessage: nil))
        }
        for record in interrupted {
            let url = record.audioURL(baseDirectory: directoryURL)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let duration = try InterruptedWAVRecovery.repair(url: url) ?? record.audioDurationMs
            let unknownOutput = record.outcome == "readyToInject"
            var attempts = record.attempts
            if let last = attempts?.indices.last { attempts?[last].outcome = unknownOutput ? "outputUnknown" : "interrupted" }
            try writeJournal(RecoveryRecord(id: record.id, timestamp: record.timestamp,
                audioFileName: record.audioFileName, audioDurationMs: duration,
                asrText: record.asrText, polishText: record.polishText, appName: record.appName,
                appBundleIdentifier: record.appBundleIdentifier, outcome: unknownOutput ? "outputUnknown" : "interrupted",
                errorMessage: unknownOutput ? "上次输出状态未知；请先核对目标，避免重复输出。" : "录音或处理被中断；已保留原始音频，可复制或重试。",
                snapshot: record.snapshot, attempts: attempts, injectionSnapshot: record.injectionSnapshot,
                audioSHA256: try Self.checksum(url), parentRecordID: record.parentRecordID))
        }
    }

    private func prepareDirectories() throws {
        for url in [directoryURL, audioDirectoryURL, journalDirectoryURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func loadAllUnlocked(hydrateSnapshots: Bool = true) throws -> [RecoveryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [UUID: RecoveryRecord] = [:]
        // Read the old index without pruning or rewriting the user's existing archive.
        let indexURL = directoryURL.appendingPathComponent("recovery-history.jsonl")
        if fileManager.fileExists(atPath: indexURL.path) {
            for line in try String(contentsOf: indexURL, encoding: .utf8).split(separator: "\n") {
                if let record = try? decoder.decode(RecoveryRecord.self, from: Data(line.utf8)) {
                    records[record.id] = record
                }
            }
        }
        var unreadable = 0
        if fileManager.fileExists(atPath: journalDirectoryURL.path) {
            for url in try fileManager.contentsOfDirectory(at: journalDirectoryURL, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                // Suppress even a same-ID legacy index entry when the newer
                // authoritative journal cannot be decoded or hydrated.
                records.removeValue(forKey: id)
                if let record = try? readJournal(url, expectedID: id, hydrateSnapshots: hydrateSnapshots) {
                    records[record.id] = record
                } else { unreadable += 1 }
            }
        }
        if unreadable != unreadableJournals {
            unreadableJournals = unreadable
            if unreadable > 0 { logger.error("\(unreadable, privacy: .public) recovery journal(s) could not be read; original files retained, no fallback or orphan replacement.") }
        }
        return Array(records.values)
    }

    private func readJournal(_ url: URL, expectedID: UUID?, hydrateSnapshots: Bool = true) throws -> RecoveryRecord {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(RecoveryRecord.self, from: Data(contentsOf: url))
        guard record.id == expectedID else { throw RecoverySnapshotError.invalidReference }
        return hydrateSnapshots ? try hydrate(record) : record
    }

    private func hydrate(_ input: RecoveryRecord) throws -> RecoveryRecord {
        var record = input
        let storedAttempts = record.attempts ?? []
        if let top = record.snapshot, RecoverySnapshots.hasReference(top) {
            guard let owner = storedAttempts.last(where: { $0.snapshot.terminology.lastImportedSource == top.terminology.lastImportedSource }) else {
                throw RecoverySnapshotError.invalidReference
            }
            record.snapshot = try snapshots.restore(top, attemptID: owner.id)
        }
        record.attempts = try record.attempts?.map { attempt in
            var a = attempt
            if a.injectionSnapshot == nil { a.injectionSnapshot = try snapshots.restoreInjection(a.snapshot, attemptID: a.id) }
            a.snapshot = try snapshots.restore(a.snapshot, attemptID: a.id)
            return a
        }
        return record
    }

    private func writeJournal(_ record: RecoveryRecord) throws {
        var compact = record
        let active = ["recording", "recorded", "processing", "readyToInject"].contains(record.outcome)
        compact.attempts = try record.attempts?.map { attempt in
            var a = attempt; a.snapshot = try snapshots.compact(a.snapshot, attemptID: a.id, injection: a.injectionSnapshot, retainUntilTerminal: true); return a
        }
        if let top = record.snapshot, let owner = record.attempts?.lastIndex(where: { $0.snapshot == top }) {
            compact.snapshot = compact.attempts?[owner].snapshot
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = journalDirectoryURL.appendingPathComponent("\(record.id.uuidString).json")
        let data = try encoder.encode(compact)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.synchronize(url)
        try synchronizeDirectory(journalDirectoryURL)
        writeStats.journalWrites += 1; writeStats.journalBytes += data.count
        if !active { snapshots.release(record.attempts?.map(\.id) ?? []) }
        let directory = directoryURL.path
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .recoveryRecordDidChange, object: record, userInfo: ["directory": directory])
        }
    }

    func persistenceStats() -> RecoveryWriteStats {
        lock.lock(); defer { lock.unlock() }
        var s = writeStats; s.snapshotWrites = snapshots.writes; s.snapshotBytes = snapshots.bytesWritten
        s.snapshotLoads = snapshots.loads; s.snapshotCacheHits = snapshots.cacheHits
        s.snapshotActiveHits = snapshots.activeHits; s.snapshotInvalidations = snapshots.invalidations
        s.activeSnapshotCount = snapshots.activeCount
        return s
    }

    func discardEvictableSnapshotCache() {
        lock.lock(); defer { lock.unlock() }; snapshots.discardEvictableCache()
    }

    var unreadableJournalCount: Int { lock.lock(); defer { lock.unlock() }; return unreadableJournals }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private var audioDirectoryURL: URL { directoryURL.appendingPathComponent("Audio", isDirectory: true) }
    private var journalDirectoryURL: URL { directoryURL.appendingPathComponent("Records", isDirectory: true) }
}
