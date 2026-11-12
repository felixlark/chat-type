import Foundation

enum LocalWordRole: String, Codable, CaseIterable, Sendable {
    case name, nickname, organization, term, unclassified
    var title: String {
        switch self {
        case .name: "姓名"
        case .nickname: "昵称"
        case .organization: "机构"
        case .term: "通用词"
        case .unclassified: "待核"
        }
    }
}

struct LocalNameCatalog: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var forms: Set<String> = []
        var roles: Set<LocalWordRole> = []
        var sources: Set<String> = []
        var contactIDs: Set<String> = []
        var userPriority = false
    }
    let schemaVersion: Int
    let capturedAt: Date
    let entries: [Entry]

    static let legacyNameSources: Set<String> = ["user", "macos-contacts", "apple-contacts-names",
        "apple-contacts-nickname", "smart-shadow-weixin-remark", "weixin-contacts",
        "weixin-remark-export", "macos-text-replacements"]

    static func build(snapshot: ContactsSnapshot, vocabulary: [TerminologyEntry]) -> LocalNameCatalog {
        var words: [String: Entry] = [:]
        func add(_ value: String, role: LocalWordRole, source: String, contact: String? = nil, user: Bool = false) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = ContactsReportGroups.key(trimmed)
            words[key, default: Entry()].forms.insert(trimmed)
            words[key, default: Entry()].roles.insert(role)
            words[key, default: Entry()].sources.insert(source)
            if let contact { words[key, default: Entry()].contactIDs.insert(contact) }
            if user { words[key, default: Entry()].userPriority = true }
        }
        for card in snapshot.individual {
            let provenance = card.sourceIDs.isEmpty ? ["apple-native:unknown"] : card.sourceIDs.map { "apple-native:\($0)" }
            for source in provenance {
                let structured = !(card.givenName + card.middleName + card.familyName).isEmpty
                let nameRole: LocalWordRole = card.isOrganization ? .organization : structured ? .name : .unclassified
                add(card.fullName, role: nameRole, source: source, contact: card.id)
                add(card.nickname, role: card.isOrganization ? .organization : .nickname, source: source, contact: card.id)
                add(card.organization, role: .organization, source: source, contact: card.id)
                for value in [card.fullName, card.nickname] {
                    for term in TerminologyPolicy.contactTerms(from: [value]) where term != value {
                        let role: LocalWordRole = card.isOrganization || ContactsReportGroups.key(term) == ContactsReportGroups.key(card.organization)
                            ? .organization : .unclassified
                        add(term, role: role, source: source, contact: card.id)
                    }
                }
            }
        }
        for term in vocabulary {
            let role: LocalWordRole = legacyNameSources.contains(term.source) ? .unclassified : .term
            let current = words[ContactsReportGroups.key(term.canonical)]
            let resolved = current?.roles.contains(.organization) == true
                && current?.roles.contains(.name) == false && current?.roles.contains(.nickname) == false
                && ["macos-contacts", "apple-contacts-names", "apple-contacts-nickname"].contains(term.source)
            add(term.canonical, role: resolved ? .organization : role, source: term.source, user: term.source == "user")
            for alias in term.aliases { add(alias, role: resolved ? .organization : role, source: term.source, user: term.source == "user") }
        }
        return LocalNameCatalog(schemaVersion: 1, capturedAt: snapshot.capturedAt,
            entries: words.sorted { $0.key < $1.key }.map(\.value))
    }

    /// Offline comparison only. Live dictation keeps its existing vocabulary and selector.
    var hintEntries: [TerminologyEntry] {
        entries.filter { !$0.roles.isDisjoint(with: [.name, .nickname, .unclassified]) }.flatMap { entry in
            entry.forms.sorted().map { TerminologyEntry(canonical: $0, aliases: [],
                source: entry.userPriority ? "user" : "macos-contacts") }
        }
    }
}

struct LocalVocabularyFile: Decodable {
    struct Transcription: Decodable {
        struct Terms: Decodable {
            let entries: [TerminologyEntry]?
            let importedEntries: [TerminologyEntry]?
        }
        let terminology: Terms
    }
    let transcription: Transcription
    var entries: [TerminologyEntry] {
        let terms = transcription.terminology
        return terms.entries?.isEmpty == false ? terms.entries! : terms.importedEntries ?? []
    }
}
