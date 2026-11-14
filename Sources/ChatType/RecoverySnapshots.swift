import CryptoKit
import Darwin
import Foundation

enum RecoverySnapshotError: LocalizedError {
    case invalidReference, missingOrDamaged, changedSnapshot
    var errorDescription: String? {
        switch self {
        case .invalidReference: "录音的完整配置引用无效；原声与原记录已保留。"
        case .missingOrDamaged: "录音的完整配置快照缺失或损坏；未替换后端或继续处理。"
        case .changedSnapshot: "同一次处理的配置快照发生变化；原快照与原声仍保留。"
        }
    }
}

/// Called under RecoveryStore's lock. Immutable snapshots are written once per
/// attempt. The provenance marker uses a field understood by build128, so its
/// read/modify/write path cannot discard the reference. It is never a hint term.
final class RecoverySnapshots {
    static let prefix = "ChatType snapshot SHA256:"
    private struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private final class Entry: NSObject {
        let snapshot: TranscriptionConfig
        let digest: String
        let fingerprint: Fingerprint
        var durable = false
        init(_ snapshot: TranscriptionConfig, _ hash: String, _ fingerprint: Fingerprint) {
            self.snapshot = snapshot; self.digest = hash; self.fingerprint = fingerprint
        }
    }
    private let directory: URL
    private let fileManager: FileManager
    private let cache = NSCache<NSString, Entry>()
    private let synchronizeSnapshot: (URL) throws -> Void
    private(set) var writes = 0
    private(set) var bytesWritten = 0

    init(directory: URL, fileManager: FileManager, synchronizeSnapshot: ((URL) throws -> Void)? = nil) {
        self.directory = directory; self.fileManager = fileManager
        self.synchronizeSnapshot = synchronizeSnapshot ?? Self.synchronizeSnapshotFile
    }

    static func hasReference(_ snapshot: TranscriptionConfig) -> Bool {
        snapshot.terminology.lastImportedSource?.hasPrefix(prefix) == true
    }

    private func fingerprint(_ url: URL) throws -> Fingerprint {
        let a = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
              let inode = a[.systemFileNumber] as? NSNumber else { throw RecoverySnapshotError.missingOrDamaged }
        return Fingerprint(size: size.uint64Value, modified: date, inode: inode.uint64Value)
    }

    private func load(_ id: UUID, expected: String? = nil) throws -> Entry {
        let key = id.uuidString as NSString
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        do {
            let stamp = try fingerprint(url)
            if let entry = cache.object(forKey: key), entry.fingerprint == stamp {
                guard expected == nil || entry.digest == expected else { throw RecoverySnapshotError.missingOrDamaged }
                return entry
            }
            let data = try Data(contentsOf: url)
            let hash = Self.hash(data)
            guard expected == nil || hash == expected else { throw RecoverySnapshotError.missingOrDamaged }
            let snapshot = try JSONDecoder().decode(TranscriptionConfig.self, from: data)
            guard !Self.hasReference(snapshot) else { throw RecoverySnapshotError.invalidReference }
            let entry = Entry(snapshot, hash, stamp)
            cache.setObject(entry, forKey: key, cost: data.count)
            return entry
        } catch { throw RecoverySnapshotError.missingOrDamaged }
    }

    func restore(_ compact: TranscriptionConfig, attemptID: UUID) throws -> TranscriptionConfig {
        guard let marker = compact.terminology.lastImportedSource, marker.hasPrefix(Self.prefix) else { return compact }
        let expected = String(marker.dropFirst(Self.prefix.count))
        guard expected.count == 64, expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecoverySnapshotError.invalidReference
        }
        return try load(attemptID, expected: expected).snapshot
    }

    func compact(_ snapshot: TranscriptionConfig, attemptID: UUID) throws -> TranscriptionConfig {
        guard !Self.hasReference(snapshot) else { throw RecoverySnapshotError.invalidReference }
        let url = directory.appendingPathComponent("\(attemptID.uuidString).json")
        let digest: String
        if fileManager.fileExists(atPath: url.path) {
            let old = try load(attemptID)
            guard old.snapshot == snapshot else { throw RecoverySnapshotError.changedSnapshot }
            try ensureDurable(old, at: url)
            digest = old.digest
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            digest = Self.hash(data)
            try data.write(to: url, options: .atomic)
            writes += 1; bytesWritten += data.count
            let entry = Entry(snapshot, digest, try fingerprint(url))
            try ensureDurable(entry, at: url)
            cache.setObject(entry, forKey: attemptID.uuidString as NSString, cost: data.count)
        }
        var compact = snapshot
        compact.terminology = .init()
        compact.terminology.lastImportedSource = Self.prefix + digest
        compact.hintTerms = []
        return compact
    }

    private func ensureDurable(_ entry: Entry, at url: URL) throws {
        guard !entry.durable else { return }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronizeSnapshot(url)
        entry.durable = true
    }

    private static func synchronizeSnapshotFile(_ url: URL) throws {
        try RecoveryStore.synchronize(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
        try synchronizeDirectory(url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
