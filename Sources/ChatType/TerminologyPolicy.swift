import Foundation

enum TerminologyPolicy {
    private static let contactSources: Set<String> = [
        "apple-contacts-nickname",
        "macos-contacts",
        "smart-shadow-weixin-remark",
        "weixin-contacts",
        "weixin-remark-export",
    ]

    private static let nameSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "-–—－,，、;；/／|｜")
    )
    private static let affiliationSeparators = CharacterSet.newlines.union(
        CharacterSet(charactersIn: ",，、;；/／|｜")
    )
    private static let trimSeparators = nameSeparators.union(.punctuationCharacters)

    private static let positionTitles = [
        "常务副总经理", "正高级工程师", "党委副书记", "党组副书记", "常务副校长",
        "副董事长", "高级工程师", "副总经理", "副秘书长", "总工程师", "技术负责人",
        "党委书记", "党组书记", "执行董事", "副理事长", "副总裁", "副总监",
        "副局长", "副处长", "副科长", "副部长", "副主任", "副所长", "副院长",
        "副校长", "副书记", "副教授", "副市长", "董事长", "总经理", "常务副总",
        "秘书长", "理事长", "副会长", "负责人", "创始人", "总裁", "总监",
        "局长", "处长", "科长", "部长", "主任", "所长", "院长", "校长",
        "书记", "教授", "市长", "工程师", "会计师", "会长", "副总", "顾问",
        "律师", "医生", "老师", "师傅", "博士", "董事", "监事", "秘书",
    ].sorted { $0.count > $1.count }

    static func sanitizedEntries(_ entries: [TerminologyEntry]) -> [TerminologyEntry] {
        var output: [TerminologyEntry] = []
        var indexByKey: [String: Int] = [:]

        for entry in entries {
            guard !isRetiredBulkSource(entry.source) else {
                continue
            }

            let normalizedEntries: [TerminologyEntry]
            if entry.type == .term, contactSources.contains(entry.source) {
                normalizedEntries = contactTerms(from: [entry.original]).map { term in
                    var normalized = entry
                    normalized.original = term
                    return normalized
                }
            } else {
                normalizedEntries = [entry]
            }

            for normalized in normalizedEntries {
                let key = entryKey(normalized)
                if let existingIndex = indexByKey[key] {
                    if normalized.source == "user", output[existingIndex].source != "user" {
                        output[existingIndex] = normalized
                    }
                    continue
                }
                indexByKey[key] = output.count
                output.append(normalized)
            }
        }

        return output
    }

    static func contactTerms(from values: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        for value in values {
            for term in normalizedContactTerms(from: value) {
                let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard seen.insert(key).inserted else {
                    continue
                }
                output.append(term)
            }
        }

        return output
    }

    private static func isRetiredBulkSource(_ source: String) -> Bool {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "jieba"
            || normalized.hasPrefix("jieba:")
            || normalized == "thuocl"
            || normalized.hasPrefix("thuocl:")
    }

    private static func normalizedContactTerms(from value: String) -> [String] {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return []
        }

        if let separator = term.rangeOfCharacter(from: nameSeparators) {
            let possibleName = String(term[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(term[separator.upperBound...])
                .trimmingCharacters(in: nameSeparators)
            if isPlausibleChineseName(possibleName), !remainder.isEmpty {
                return [possibleName] + normalizedAffiliations(from: remainder)
            }
        }

        return normalizedAffiliations(from: term)
    }

    private static func normalizedAffiliations(from value: String) -> [String] {
        value.components(separatedBy: affiliationSeparators).compactMap { segment in
            strippingTrailingPositions(from: segment)
        }
    }

    private static func strippingTrailingPositions(from value: String) -> String? {
        var current = value.trimmingCharacters(in: trimSeparators)
        guard !current.isEmpty else {
            return nil
        }

        while let title = positionTitles.first(where: { current.hasSuffix($0) }) {
            var base = String(current.dropLast(title.count)).trimmingCharacters(in: trimSeparators)
            guard base.count >= 2 else {
                return nil
            }
            if (title == "局长" || title == "副局长"), base.hasSuffix("公安") {
                base.append("局")
            }
            current = base
        }

        return current.isEmpty ? nil : current
    }

    private static func isPlausibleChineseName(_ value: String) -> Bool {
        guard (2...4).contains(value.count),
              !positionTitles.contains(where: { value.hasSuffix($0) })
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy(\.properties.isIdeographic)
    }

    private static func entryKey(_ entry: TerminologyEntry) -> String {
        [
            entry.type.rawValue,
            entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            (entry.replacement ?? "").folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ),
        ].joined(separator: "|")
    }
}
