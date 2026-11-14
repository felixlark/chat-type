@preconcurrency import Contacts
import Foundation
import AppKit

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
            return "Allow ChatType to access Contacts before importing contact names."
        case .noNicknames:
            return "No contact names were found in Apple Contacts."
        }
    }
}

struct AppleContactRemarkImporter {
    func importEntries() async throws -> TerminologyImportResult {
        let store = CNContactStore()
        let granted: Bool

        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            granted = true
        } else if status == .notDetermined {
            granted = try await store.requestAccess(for: .contacts)
        } else {
            granted = false
        }

        guard granted else {
            throw AppleContactRemarkImportError.accessDenied
        }

        var names: [String] = []
        let request = CNContactFetchRequest(keysToFetch: [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
        ])
        try store.enumerateContacts(with: request) { contact, _ in
            names.append(contentsOf: Self.nameValues(from: contact))
        }

        let importedAt = ISO8601DateFormatter().string(from: Date())
        let entries = Self.entries(from: names, importedAt: importedAt, source: "apple-contacts-names")
        guard !entries.isEmpty else {
            throw AppleContactRemarkImportError.noNicknames
        }

        return TerminologyImportResult(
            entries: entries,
            source: "apple-contacts-names",
            importedAt: importedAt
        )
    }

    static func nameValues(from contact: CNContact) -> [String] {
        [CNContactFormatter.string(from: contact, style: .fullName) ?? "", contact.nickname]
    }

    static func entries(from nicknames: [String], importedAt: String, source: String = "apple-contacts-nickname") -> [TerminologyEntry] {
        TerminologyPolicy.contactTerms(from: nicknames).map {
            TerminologyEntry(
                type: .term,
                original: $0,
                replacement: nil,
                aliases: [],
                source: source,
                usageCount: 0,
                createdAt: importedAt
            )
        }
    }
}

enum WeixinRemarkImportError: LocalizedError, Equatable {
    case runtimeMissing
    case providerFailed(Int, String)
    case invalidResponse
    case noNames

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "WeChat name reader is unavailable. Restore the installed wechat-decrypt runtime and source, then try again."
        case .providerFailed(let status, let kind): return "WeChat name reader failed (exit \(status), \(kind)). Check wechat-decrypt and its existing permissions, then retry."
        case .invalidResponse: return "The WeChat reader returned an incomplete response. No names were changed. Retry after checking wechat-decrypt."
        case .noNames: return "The WeChat reader returned no personal names. No existing names were changed."
        }
    }
}

/// Calls the same supported read tool as the connected WeChat service. Never opens its databases.
struct WeixinNameImporter: Sendable {
    let home: URL
    let helper: URL?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, helper: URL? = nil) {
        self.home = home
        self.helper = helper ?? Bundle.main.resourceURL?.appendingPathComponent("wechat_names.py")
    }

    func importEntries() throws -> TerminologyImportResult {
        let python = home.appendingPathComponent("Library/Application Support/wechat-decrypt/runtime/bin/python3")
        let provider = home.appendingPathComponent("Projects/wechat-decrypt/mcp_server.py")
        guard let helper, FileManager.default.fileExists(atPath: helper.path),
              FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: provider.path) else {
            throw WeixinRemarkImportError.runtimeMissing
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.arguments = ["-I", helper.path, provider.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let kind = failure?["failure"] as? String ?? "process failure"
            let safeKinds = ["PermissionError", "FileNotFoundError", "RuntimeError", "ValueError", "ModuleNotFoundError", "ImportError", "process failure"]
            throw WeixinRemarkImportError.providerFailed(Int(process.terminationStatus), safeKinds.contains(kind) ? kind : "reader error")
        }
        return try Self.result(from: data)
    }

    static func result(from data: Data) throws -> TerminologyImportResult {
        struct Response: Decodable { let names: [String]; let complete: Bool }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.complete else {
            throw WeixinRemarkImportError.invalidResponse
        }
        let date = ISO8601DateFormatter().string(from: Date())
        let entries = AppleContactRemarkImporter.entries(from: response.names, importedAt: date,
            source: "smart-shadow-weixin-remark")
        guard !entries.isEmpty else { throw WeixinRemarkImportError.noNames }
        return TerminologyImportResult(entries: entries, source: "smart-shadow-weixin-remark", importedAt: date)
    }
}
