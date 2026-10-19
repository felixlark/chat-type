import Foundation
import Darwin

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
            displayText = "\(formattedDuration(record.audioDurationMs)) WAV"
        case .asr:
            guard let text = record.asrText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            copyText = text
            copyKind = .text
            displayText = collapsedPreview(text)
        case .polish:
            guard let text = record.polishText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            copyText = text
            copyKind = .text
            displayText = collapsedPreview(text)
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
            errorMessage: record.errorMessage,
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
        let records = try loadAllUnlocked()
        let ownedID = input.sourceAudioURL.deletingLastPathComponent().standardizedFileURL == audioDirectoryURL.standardizedFileURL
            ? UUID(uuidString: input.sourceAudioURL.deletingPathExtension().lastPathComponent) : nil
        let previous = records.first { $0.id == ownedID }
        let id = ownedID ?? UUID()
        let audioFileName = "\(id.uuidString).wav"
        let destinationURL = audioDirectoryURL.appendingPathComponent(audioFileName)
        if input.sourceAudioURL.standardizedFileURL != destinationURL.standardizedFileURL {
            try fileManager.copyItem(at: input.sourceAudioURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        }
        try Self.synchronize(destinationURL)
        try writeJournal(RecoveryRecord(
            id: id, timestamp: previous?.timestamp ?? input.timestamp,
            audioFileName: audioFileName, audioDurationMs: input.durationMs,
            asrText: input.asrText ?? previous?.asrText,
            polishText: input.polishText ?? previous?.polishText,
            appName: input.appName ?? previous?.appName,
            appBundleIdentifier: input.appBundleIdentifier ?? previous?.appBundleIdentifier,
            outcome: input.outcome, errorMessage: input.errorMessage
        ))
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
        var interrupted = records.filter { ["recording", "recorded", "processing"].contains($0.outcome) }
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
            try writeJournal(RecoveryRecord(id: record.id, timestamp: record.timestamp,
                audioFileName: record.audioFileName, audioDurationMs: duration,
                asrText: record.asrText, polishText: record.polishText, appName: record.appName,
                appBundleIdentifier: record.appBundleIdentifier, outcome: "interrupted",
                errorMessage: "录音或处理被中断；已保留原始音频，可复制或重试。"))
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
