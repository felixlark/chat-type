import Foundation

/// Selects related vocabulary for model prompts; never rewrites the transcript.
enum PersonalNameHints {
    private struct Name: Equatable, Sendable {
        let value: String
        let userPriority: Bool
    }
    private struct Candidate: Sendable {
        let name: Name
        let syllables: [String]
    }
    private struct Index: Sendable {
        let exact: [String: [Candidate]]
        let omitted: [String: [Candidate]]
    }
    private struct Match {
        let name: Name
        let soundDistance: Int
        let glyphDistance: Int
    }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var names: [Name] = []
        var index = Index(exact: [:], omitted: [:])
        func get(_ names: [Name]) -> Index {
            lock.withLock {
                if self.names == names { return index }
                var exact: [String: [Candidate]] = [:]
                var omitted: [String: [Candidate]] = [:]
                for name in names {
                    guard let sounds = PersonalNameHints.syllables(name.value), sounds.count == name.value.count else { continue }
                    let candidate = Candidate(name: name, syllables: sounds)
                    exact[sounds.joined(separator: "|"), default: []].append(candidate)
                    for i in sounds.indices {
                        omitted[PersonalNameHints.omissionKey(sounds, at: i), default: []].append(candidate)
                    }
                }
                self.names = names
                index = Index(exact: exact, omitted: omitted)
                return index
            }
        }
    }
    private static let cache = Cache()
    private static let personalSources: Set<String> = ["user", "macos-contacts", "apple-contacts-names",
        "apple-contacts-nickname", "smart-shadow-weixin-remark", "weixin-contacts",
        "weixin-remark-export", "macos-text-replacements"]

    static func prewarm(entries: [TerminologyEntry]) { _ = cache.get(names(in: entries)) }

    static func relatedTerms(in text: String, entries: [TerminologyEntry]) -> [String] {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: #"\p{Han}+"#) else { return [] }
        let runs = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !runs.isEmpty else { return [] }
        let index = cache.get(names(in: entries))
        var matches: [String: Match] = [:]
        for run in runs {
            guard let range = Range(run.range, in: text) else { continue }
            let characters = Array(text[range])
            guard let sounds = syllables(String(characters)), sounds.count == characters.count else { continue }
            for length in 2...4 where characters.count >= length {
                for start in 0...(characters.count - length) {
                    let glyphs = Array(characters[start..<(start + length)])
                    let query = Array(sounds[start..<(start + length)])
                    if length == 2 {
                        let prefix = String(characters[max(0, start - 6)..<start])
                        guard ["联系", "通知", "找", "叫", "问", "转告", "给", "发给", "收件人"].contains(where: { prefix.contains($0) }) else { continue }
                    }
                    var candidates = index.exact[query.joined(separator: "|"), default: []]
                    if length >= 3 {
                        for i in query.indices { candidates += index.omitted[omissionKey(query, at: i), default: []] }
                    }
                    for candidate in candidates {
                        let differing = query.indices.filter { query[$0] != candidate.syllables[$0] }
                        guard differing.count <= 1 else { continue }
                        let glyphDistance = zip(glyphs, candidate.name.value).filter { $0 != $1 }.count
                        let distance = differing.first.map { editDistance(query[$0], candidate.syllables[$0]) } ?? 0
                        guard distance <= 1 || (distance == 2 && glyphDistance <= 1) else { continue }
                        let found = Match(name: candidate.name, soundDistance: distance, glyphDistance: glyphDistance)
                        if let previous = matches[candidate.name.value], !precedes(found, previous) { continue }
                        matches[candidate.name.value] = found
                    }
                }
            }
        }
        return matches.values.sorted(by: precedes).prefix(12).map { $0.name.value }
    }

    private static func names(in entries: [TerminologyEntry]) -> [Name] {
        var values: [String: Bool] = [:]
        for entry in entries where personalSources.contains(entry.source) {
            let value = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...4).contains(value.count), value.unicodeScalars.allSatisfy(\.properties.isIdeographic) else { continue }
            values[value] = (values[value] ?? false) || entry.source == "user"
        }
        return values.map { Name(value: $0.key, userPriority: $0.value) }.sorted { $0.value < $1.value }
    }
    private static func syllables(_ text: String) -> [String]? {
        text.applyingTransform(.toLatin, reverse: false)?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private static func omissionKey(_ sounds: [String], at index: Int) -> String {
        "\(sounds.count):\(index):" + sounds.enumerated().filter { $0.offset != index }.map(\.element).joined(separator: "|")
    }
    private static func precedes(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.soundDistance != rhs.soundDistance { return lhs.soundDistance < rhs.soundDistance }
        if lhs.glyphDistance != rhs.glyphDistance { return lhs.glyphDistance < rhs.glyphDistance }
        if lhs.name.userPriority != rhs.name.userPriority { return lhs.name.userPriority }
        return lhs.name.value < rhs.name.value
    }
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (i, a) in lhs.enumerated() {
            var next = [i + 1]
            for (j, b) in right.enumerated() {
                next.append(min(next[j] + 1, previous[j + 1] + 1, previous[j] + (a == b ? 0 : 1)))
            }
            previous = next
        }
        return previous.last ?? 0
    }
}
