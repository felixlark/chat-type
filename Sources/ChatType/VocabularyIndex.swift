import Foundation

/// Immutable derived data. The retained source array also enforces Swift CoW on edits.
final class VocabularyIndex: Sendable {
    struct Entry: Sendable {
        let canonical: String
        let canonicalKey: String
        let matchKeys: [String]
        let line: String
        let lineKey: String
        let characterCount: Int

        init(_ entry: TerminologyEntry, locale: Locale) {
            canonical = entry.canonical
            canonicalKey = VocabularyIndex.looseKey(entry.canonical, locale: locale)
            matchKeys = ([entry.canonical] + entry.aliases).map { VocabularyIndex.looseKey($0, locale: locale) }
            let aliases = entry.aliases.isEmpty ? "" : " aliases: \(entry.aliases.joined(separator: ", "))"
            line = "\(entry.canonical)\(aliases)"
            lineKey = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            characterCount = line.count
        }
    }

    let sourceEntries: [TerminologyEntry]
    let storageIdentity: UInt
    let locale: Locale
    let entries: [Entry]
    let userChineseTerms: [String]
    private let orderedASRTerms: [(text: String, key: String)]
    private let firstByCanonical: [String: Int]

    init(entries source: [TerminologyEntry], locale: Locale = .current) {
        sourceEntries = source
        storageIdentity = Self.identity(source)
        self.locale = locale
        entries = source.map { Entry($0, locale: locale) }
        var first: [String: Int] = [:]
        for (i, entry) in entries.enumerated() where first[entry.canonicalKey] == nil { first[entry.canonicalKey] = i }
        firstByCanonical = first
        userChineseTerms = source.filter { $0.source == "user" }.map(\.canonical).filter {
            (2...4).contains($0.count) && $0.unicodeScalars.allSatisfy(\.properties.isIdeographic)
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let sortable = source.enumerated().filter { $0.element.type == .term }.map {
            (offset: $0.offset, entry: $0.element,
             folded: $0.element.canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posix))
        }.sorted {
            if $0.entry.usageCount != $1.entry.usageCount { return $0.entry.usageCount > $1.entry.usageCount }
            return $0.folded == $1.folded ? $0.offset < $1.offset : $0.folded < $1.folded
        }
        orderedASRTerms = sortable.map { ($0.entry.original, $0.folded) }
    }

    func asrHints(priorities: [String]) -> [String] {
        var seen = Set<String>()
        let posix = Locale(identifier: "en_US_POSIX")
        var output = priorities.filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posix)).inserted
        }
        for term in orderedASRTerms where seen.insert(term.key).inserted { output.append(term.text) }
        return output
    }

    func glossary(transcript: String, priorities: [String], budget: Int) -> [String] {
        let priorityKeys = Set(priorities.map { Self.looseKey($0, locale: locale) })
        let gate = EntryKeyMatchGate(textKey: Self.looseKey(transcript, locale: locale))
        let preferred = priorities.map { term in
            firstByCanonical[Self.looseKey(term, locale: locale)].map { entries[$0] }
                ?? Entry(TerminologyEntry(canonical: term, aliases: []), locale: locale)
        }
        var output: [String] = []
        var seen = Set<String>()
        var count = 0
        for entry in preferred + entries {
            let priority = priorityKeys.contains(entry.canonicalKey)
            guard priority || entry.matchKeys.contains(where: { gate.matchesNonEmptyKey($0) }) else { continue }
            guard seen.insert(priority ? entry.canonicalKey : entry.lineKey).inserted else { continue }
            let next = count + entry.characterCount
            guard next <= budget else { break }
            output.append(entry.line)
            count = next
        }
        return output
    }

    static func looseKey(_ text: String, locale: Locale) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let scalars = folded.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "." && $0 != "_" && $0 != "-"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func identity(_ entries: [TerminologyEntry]) -> UInt {
        entries.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0 }
    }
}

final class VocabularyIndexCache: @unchecked Sendable {
    static let shared = VocabularyIndexCache()
    private let lock = NSLock()
    private var cached: VocabularyIndex?

    func index(for entries: [TerminologyEntry], locale: Locale = .current) -> VocabularyIndex {
        lock.withLock {
            let identity = VocabularyIndex.identity(entries)
            if let cached, cached.storageIdentity == identity,
               cached.sourceEntries.count == entries.count, cached.locale.identifier == locale.identifier { return cached }
            let index = VocabularyIndex(entries: entries, locale: locale)
            cached = index
            return index
        }
    }
}
