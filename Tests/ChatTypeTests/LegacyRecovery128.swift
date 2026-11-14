// Frozen build128 compatibility fixture from 13ac75f. Do not modernize.
// Execute its actual record and cold-recovery paths against the new archive.
import Foundation
import Darwin
import CryptoKit
import OSLog
@testable import ChatType

enum LegacyRecovery128 {
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

    init(fileManager: FileManager = .default, directoryURL: URL? = nil, retainedLimit: Int = 10) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChatType/Recovery", isDirectory: true)
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
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectories()
        let ownedID = input.sourceAudioURL.deletingLastPathComponent().standardizedFileURL == audioDirectoryURL.standardizedFileURL
            ? UUID(uuidString: input.sourceAudioURL.deletingPathExtension().lastPathComponent) : nil
        let previous: RecoveryRecord?
        if let ownedID, fileManager.fileExists(atPath: journalDirectoryURL.appendingPathComponent("\(ownedID.uuidString).json").path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            previous = try decoder.decode(RecoveryRecord.self,
                from: Data(contentsOf: journalDirectoryURL.appendingPathComponent("\(ownedID.uuidString).json")))
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
                snapshot: snapshot, stages: (old?.stages ?? .init()).merging(input.stages ?? .init()), outcome: input.outcome)
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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let url = journalDirectoryURL.appendingPathComponent("\(id).json")
        var record = try decoder.decode(RecoveryRecord.self, from: Data(contentsOf: url))
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
        return Array(try loadAllUnlocked().sorted { $0.timestamp < $1.timestamp }.suffix(max(0, limit)))
    }

    /// Called once on normal launch, never while a recorder owns an open WAV.
    func recoverInterruptedRecordings() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectories()
        let records = try loadAllUnlocked()
        let ids = Set(records.map(\.id))
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

    private func loadAllUnlocked() throws -> [RecoveryRecord] {
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
        if fileManager.fileExists(atPath: journalDirectoryURL.path) {
            for url in try fileManager.contentsOfDirectory(at: journalDirectoryURL, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                // An unreadable journal must not cause unrelated recordings to be removed.
                if let data = try? Data(contentsOf: url), let record = try? decoder.decode(RecoveryRecord.self, from: data) {
                    records[record.id] = record
                }
            }
        }
        return Array(records.values)
    }

    private func writeJournal(_ record: RecoveryRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = journalDirectoryURL.appendingPathComponent("\(record.id.uuidString).json")
        try encoder.encode(record).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.synchronize(url)
        try synchronizeDirectory(journalDirectoryURL)
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private var audioDirectoryURL: URL { directoryURL.appendingPathComponent("Audio", isDirectory: true) }
    private var journalDirectoryURL: URL { directoryURL.appendingPathComponent("Records", isDirectory: true) }
}

}
