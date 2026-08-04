@preconcurrency import Contacts
import Foundation
import SQLite3

struct TerminologyImportResult: Sendable, Equatable {
    let entries: [TerminologyEntry]
    let source: String
    let importedAt: String
}

enum AppleContactRemarkImportError: LocalizedError, Equatable {
    case accessDenied
    case noNicknames

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Allow ChatType to access Contacts before importing contact nicknames."
        case .noNicknames:
            return "No contact nicknames were found in Apple Contacts."
        }
    }
}

struct AppleContactRemarkImporter {
    func importEntries() async throws -> TerminologyImportResult {
        let store = CNContactStore()
        let granted: Bool

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = try await store.requestAccess(for: .contacts)
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }

        guard granted else {
            throw AppleContactRemarkImportError.accessDenied
        }

        var nicknames: [String] = []
        let request = CNContactFetchRequest(keysToFetch: [CNContactNicknameKey as CNKeyDescriptor])
        try store.enumerateContacts(with: request) { contact, _ in
            nicknames.append(contact.nickname)
        }

        let importedAt = ISO8601DateFormatter().string(from: Date())
        let entries = Self.entries(from: nicknames, importedAt: importedAt)
        guard !entries.isEmpty else {
            throw AppleContactRemarkImportError.noNicknames
        }

        return TerminologyImportResult(
            entries: entries,
            source: "apple-contacts-nickname",
            importedAt: importedAt
        )
    }

    static func entries(from nicknames: [String], importedAt: String) -> [TerminologyEntry] {
        uniqueTerms(from: nicknames).map {
            TerminologyEntry(
                type: .term,
                original: $0,
                replacement: nil,
                aliases: [],
                source: "apple-contacts-nickname",
                usageCount: 0,
                createdAt: importedAt
            )
        }
    }
}

enum WeixinRemarkImportError: LocalizedError, Equatable {
    case runtimeConfigMissing
    case invalidRuntimeConfig
    case decryptedContactDatabaseMissing
    case databaseReadFailed(String)
    case noRemarks

    var errorDescription: String? {
        switch self {
        case .runtimeConfigMissing:
            return "Smart Shadow's WeChat runtime is not configured on this Mac."
        case .invalidRuntimeConfig:
            return "Smart Shadow's WeChat runtime configuration is invalid."
        case .decryptedContactDatabaseMissing:
            return "Smart Shadow has not produced a decrypted WeChat contacts database yet."
        case .databaseReadFailed(let detail):
            return "Could not read Smart Shadow's decrypted WeChat contacts: \(detail)"
        case .noRemarks:
            return "No WeChat remark names were found in Smart Shadow's decrypted contacts."
        }
    }
}

struct WeixinRemarkDatabaseImporter: Sendable {
    private struct FileIdentity: Equatable {
        let size: UInt64
        let modifiedAt: Date
        let fileNumber: UInt64
    }

    private struct RuntimeConfig: Decodable {
        let decryptedDirectory: String

        enum CodingKeys: String, CodingKey {
            case decryptedDirectory = "decrypted_dir"
        }
    }

    private let configURLs: [URL]
    private let temporaryDirectory: URL

    init(configURLs: [URL]? = nil, temporaryDirectory: URL? = nil) {
        self.configURLs = configURLs ?? Self.defaultConfigURLs()
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
    }

    func importEntries() throws -> TerminologyImportResult {
        let config = try loadRuntimeConfig()
        let decryptedDirectory = URL(fileURLWithPath: config.decryptedDirectory, isDirectory: true)
        let databaseURL = [
            decryptedDirectory.appendingPathComponent("_monitor_cache/contact_contact.db"),
            decryptedDirectory.appendingPathComponent("contact/contact.db"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }

        guard let databaseURL else {
            throw WeixinRemarkImportError.decryptedContactDatabaseMissing
        }

        let remarks = try readRemarksFromStableSnapshot(of: databaseURL)
        let importedAt = ISO8601DateFormatter().string(from: Date())
        let entries = uniqueTerms(from: remarks).map {
            TerminologyEntry(
                type: .term,
                original: $0,
                replacement: nil,
                aliases: [],
                source: "smart-shadow-weixin-remark",
                usageCount: 0,
                createdAt: importedAt
            )
        }

        guard !entries.isEmpty else {
            throw WeixinRemarkImportError.noRemarks
        }

        return TerminologyImportResult(
            entries: entries,
            source: "smart-shadow-weixin-remark",
            importedAt: importedAt
        )
    }

    private func loadRuntimeConfig() throws -> RuntimeConfig {
        guard let configURL = configURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw WeixinRemarkImportError.runtimeConfigMissing
        }

        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(RuntimeConfig.self, from: data)
            guard !config.decryptedDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WeixinRemarkImportError.invalidRuntimeConfig
            }
            return config
        } catch let error as WeixinRemarkImportError {
            throw error
        } catch {
            throw WeixinRemarkImportError.invalidRuntimeConfig
        }
    }

    private func readRemarksFromStableSnapshot(of sourceURL: URL) throws -> [String] {
        var lastError: Error?

        for _ in 0..<3 {
            let snapshotDirectory = temporaryDirectory
                .appendingPathComponent("ChatType-WeixinRemarks-\(UUID().uuidString)", isDirectory: true)

            do {
                let beforeCopy = try fileIdentity(at: sourceURL)
                try FileManager.default.createDirectory(
                    at: snapshotDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
                defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

                let snapshotURL = snapshotDirectory.appendingPathComponent("contact.db")
                try FileManager.default.copyItem(at: sourceURL, to: snapshotURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: snapshotURL.path
                )

                guard beforeCopy == (try fileIdentity(at: sourceURL)) else {
                    continue
                }
                return try readRemarks(from: snapshotURL)
            } catch {
                lastError = error
            }
        }

        if let error = lastError as? WeixinRemarkImportError {
            throw error
        }
        if lastError != nil {
            throw WeixinRemarkImportError.databaseReadFailed(
                "SQLite could not create a private snapshot of the contacts database."
            )
        }
        throw WeixinRemarkImportError.databaseReadFailed(
            "The decrypted contacts changed while ChatType was reading them. Try again."
        )
    }

    private func fileIdentity(at url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else {
            throw WeixinRemarkImportError.databaseReadFailed(
                "SQLite could not inspect the contacts database."
            )
        }
        return FileIdentity(
            size: size.uint64Value,
            modifiedAt: modifiedAt,
            fileNumber: fileNumber.uint64Value
        )
    }

    private func readRemarks(from databaseURL: URL) throws -> [String] {
        var database: OpaquePointer?
        guard var components = URLComponents(url: databaseURL, resolvingAgainstBaseURL: false) else {
            throw WeixinRemarkImportError.databaseReadFailed("SQLite could not locate the contacts database.")
        }
        components.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1"),
        ]
        guard let databaseURI = components.string else {
            throw WeixinRemarkImportError.databaseReadFailed("SQLite could not locate the contacts database.")
        }
        let openResult = sqlite3_open_v2(
            databaseURI,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw WeixinRemarkImportError.databaseReadFailed("SQLite could not open the contacts database.")
        }
        defer { sqlite3_close(database) }

        let hasLocalType = tableHasColumn("local_type", database: database)
        let query = hasLocalType
            ? "SELECT remark FROM contact WHERE local_type != 3 AND trim(coalesce(remark, '')) != ''"
            : "SELECT remark FROM contact WHERE trim(coalesce(remark, '')) != ''"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WeixinRemarkImportError.databaseReadFailed(sqliteErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var remarks: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    remarks.append(String(cString: text))
                }
            case SQLITE_DONE:
                return remarks
            default:
                throw WeixinRemarkImportError.databaseReadFailed(sqliteErrorMessage(database))
            }
        }
    }

    private func tableHasColumn(_ column: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(contact)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else {
                continue
            }
            if String(cString: text) == column {
                return true
            }
        }
        return false
    }

    private func sqliteErrorMessage(_ database: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error."
        }
        return String(cString: message)
    }

    private static func defaultConfigURLs() -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SMART_SHADOW_WEIXIN_TOOLS_CONFIG"],
           !override.isEmpty
        {
            urls.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(
            home.appendingPathComponent("Projects/smart-shadow/var/weixin/tools/smart-shadow.json")
        )
        urls.append(
            home.appendingPathComponent("Projects/Development/smart-shadow/var/weixin/tools/smart-shadow.json")
        )
        return urls
    }
}

private func uniqueTerms(from values: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []

    for value in values {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            continue
        }
        let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard seen.insert(key).inserted else {
            continue
        }
        output.append(term)
    }

    return output
}
