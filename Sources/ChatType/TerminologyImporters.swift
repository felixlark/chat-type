@preconcurrency import Contacts
import Foundation

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
    case unreadableCSV(String)
    case missingRemarkColumn
    case noRemarks

    var errorDescription: String? {
        switch self {
        case .unreadableCSV(let source):
            return "Could not read the WeChat contacts CSV: \(source)."
        case .missingRemarkColumn:
            return "The WeChat contacts CSV must contain a 备注名 column."
        case .noRemarks:
            return "No WeChat remark names were found in this export."
        }
    }
}

struct WeixinRemarkCSVImporter {
    func importEntries(from data: Data, sourceName: String) throws -> TerminologyImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw WeixinRemarkImportError.unreadableCSV(sourceName)
        }

        let rows = text
            .split(whereSeparator: \.isNewline)
            .map { csvFields(from: String($0)) }
            .filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

        guard let headers = rows.first else {
            throw WeixinRemarkImportError.noRemarks
        }

        let acceptedHeaders: Set<String> = ["备注名", "微信备注名", "remark", "remarkname"]
        guard let remarkIndex = headers.firstIndex(where: { acceptedHeaders.contains(normalizedHeader($0)) }) else {
            throw WeixinRemarkImportError.missingRemarkColumn
        }

        let remarks = rows.dropFirst().compactMap { row -> String? in
            guard row.indices.contains(remarkIndex) else {
                return nil
            }
            return row[remarkIndex]
        }
        let importedAt = ISO8601DateFormatter().string(from: Date())
        let entries = uniqueTerms(from: remarks).map {
            TerminologyEntry(
                type: .term,
                original: $0,
                replacement: nil,
                aliases: [],
                source: "weixin-remark-export",
                usageCount: 0,
                createdAt: importedAt
            )
        }

        guard !entries.isEmpty else {
            throw WeixinRemarkImportError.noRemarks
        }

        return TerminologyImportResult(
            entries: entries,
            source: "weixin-remark-export",
            importedAt: importedAt
        )
    }

    private func normalizedHeader(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func csvFields(from row: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = row.startIndex

        while index < row.endIndex {
            let character = row[index]
            if character == "\"" {
                let next = row.index(after: index)
                if isQuoted, next < row.endIndex, row[next] == "\"" {
                    field.append("\"")
                    index = row.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
            index = row.index(after: index)
        }

        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
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
