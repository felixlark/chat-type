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
    // Extra fields stay in the immutable sidecar even if an older journal
    // reader drops a new optional attempt field during a read/modify/write.
    private struct Archive: Codable {
        let transcription: TranscriptionConfig
        let injectionSnapshot: InjectionConfig?
        enum ExtraKeys: String, CodingKey { case injectionSnapshot }
        init(_ config: TranscriptionConfig, _ injection: InjectionConfig?) {
            transcription = config; injectionSnapshot = injection
        }
        init(from decoder: any Decoder) throws {
            transcription = try TranscriptionConfig(from: decoder)
            injectionSnapshot = try decoder.container(keyedBy: ExtraKeys.self).decodeIfPresent(InjectionConfig.self, forKey: .injectionSnapshot)
        }
        func encode(to encoder: any Encoder) throws {
            try transcription.encode(to: encoder)
            var c = encoder.container(keyedBy: ExtraKeys.self)
            try c.encodeIfPresent(injectionSnapshot, forKey: .injectionSnapshot)
        }
    }
    private final class Entry: NSObject {
        let snapshot: TranscriptionConfig
        let digest: String
        let injection: InjectionConfig?
        let fingerprint: Fingerprint
        var durable = false
        init(_ snapshot: TranscriptionConfig, _ hash: String, _ fingerprint: Fingerprint, injection: InjectionConfig? = nil) {
            self.snapshot = snapshot; self.digest = hash; self.fingerprint = fingerprint; self.injection = injection
        }
    }
    private let directory: URL
    private let fileManager: FileManager
    private let cache = NSCache<NSString, Entry>()
    // NSCache can be evicted when the menu-bar app is inactive. Active audit
    // attempts keep a strong owner until their terminal journal is durable.
    private var activeEntries: [UUID: Entry] = [:]
    private(set) var loads = 0
    private(set) var cacheHits = 0
    private(set) var activeHits = 0
    private(set) var invalidations = 0
    var activeCount: Int { activeEntries.count }
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
            let candidate = activeEntries[id] ?? cache.object(forKey: key)
            if let entry = candidate, entry.fingerprint == stamp {
                if activeEntries[id] != nil { activeHits += 1 } else { cacheHits += 1 }
                guard expected == nil || entry.digest == expected else { throw RecoverySnapshotError.missingOrDamaged }
                return entry
            }
            if candidate != nil {
                invalidations += 1
                activeEntries.removeValue(forKey: id)
                cache.removeObject(forKey: key)
            }
            let data = try Data(contentsOf: url)
            loads += 1
            let hash = Self.hash(data)
            guard expected == nil || hash == expected else { throw RecoverySnapshotError.missingOrDamaged }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            let snapshot = archive.transcription
            guard !Self.hasReference(snapshot) else { throw RecoverySnapshotError.invalidReference }
            let entry = Entry(snapshot, hash, stamp, injection: archive.injectionSnapshot)
            cache.setObject(entry, forKey: key, cost: data.count)
            return entry
        } catch { throw RecoverySnapshotError.missingOrDamaged }
    }

    private func referenceDigest(_ compact: TranscriptionConfig) throws -> String? {
        guard let marker = compact.terminology.lastImportedSource, marker.hasPrefix(Self.prefix) else { return nil }
        let digest = String(marker.dropFirst(Self.prefix.count))
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RecoverySnapshotError.invalidReference
        }
        return digest
    }

    func restore(_ compact: TranscriptionConfig, attemptID: UUID) throws -> TranscriptionConfig {
        guard let digest = try referenceDigest(compact) else { return compact }
        return try load(attemptID, expected: digest).snapshot
    }

    func compact(_ snapshot: TranscriptionConfig, attemptID: UUID, injection: InjectionConfig? = nil, retainUntilTerminal: Bool = false) throws -> TranscriptionConfig {
        guard !Self.hasReference(snapshot) else { throw RecoverySnapshotError.invalidReference }
        let url = directory.appendingPathComponent("\(attemptID.uuidString).json")
        let digest: String
        if fileManager.fileExists(atPath: url.path) {
            let old = try load(attemptID)
            guard old.snapshot == snapshot, injection == nil || old.injection == nil || injection == old.injection else { throw RecoverySnapshotError.changedSnapshot }
            try ensureDurable(old, at: url)
            if retainUntilTerminal { activeEntries[attemptID] = old }
            digest = old.digest
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Archive(snapshot, injection))
            digest = Self.hash(data)
            try data.write(to: url, options: .atomic)
            writes += 1; bytesWritten += data.count
            let entry = Entry(snapshot, digest, try fingerprint(url), injection: injection)
            try ensureDurable(entry, at: url)
            cache.setObject(entry, forKey: attemptID.uuidString as NSString, cost: data.count)
            if retainUntilTerminal { activeEntries[attemptID] = entry }
        }
        var compact = snapshot
        compact.terminology = .init()
        compact.terminology.lastImportedSource = Self.prefix + digest
        compact.hintTerms = []
        return compact
    }

    func restoreInjection(_ compact: TranscriptionConfig, attemptID: UUID) throws -> InjectionConfig? {
        guard let digest = try referenceDigest(compact) else { return nil }
        return try load(attemptID, expected: digest).injection
    }

    func release(_ attemptIDs: [UUID]) {
        for id in attemptIDs { activeEntries.removeValue(forKey: id) }
    }

    // Same eviction boundary as NSCache's automatic reclamation; testable
    // without depending on host memory pressure or changing journal data.
    func discardEvictableCache() { cache.removeAllObjects() }

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
