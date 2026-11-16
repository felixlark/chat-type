import Foundation
import Testing
@testable import ChatType

@Test func alignmentVocabularyReusesArraysAndInvalidatesEditsWithoutChangingOldSnapshots() {
    let cache = AlignmentVocabularyCache()
    var entries = [TerminologyEntry(canonical: "taskd", aliases: ["task d"]),
        TerminologyEntry(type: .correction, original: "Shade", replacement: "Shade", aliases: [],
            source: "user", usageCount: 0, createdAt: "test"),
        TerminologyEntry(type: .correction, original: "typo", replacement: "fixed", aliases: [],
            source: "user", usageCount: 0, createdAt: "test")]
    let old = cache.vocabulary(for: entries)
    let same = cache.vocabulary(for: entries)
    for enabled in [false, true] {
        let expected = entries.filter { $0.type == .term }
            + (enabled ? entries.filter { $0.type == .correction && $0.original == $0.replacement } : [])
        #expect(old.entries(correctionsEnabled: enabled) == expected)
        #expect(VocabularyIndex.identity(old.entries(correctionsEnabled: enabled))
            == VocabularyIndex.identity(same.entries(correctionsEnabled: enabled)))
        let normalizer = TerminologyNormalizer()
        #expect(normalizer.normalize(text: "请检查 task d 与 Shade。", importedEntries: expected, hintTerms: [])
            == normalizer.normalize(text: "请检查 task d 与 Shade。",
                importedEntries: same.entries(correctionsEnabled: enabled), hintTerms: []))
    }
    entries[0].original = "contextd"
    let edited = cache.vocabulary(for: entries)
    #expect(edited.storageIdentity != old.storageIdentity)
    #expect(edited.terms.first?.original == "contextd")
    #expect(old.terms.first?.original == "taskd")
    #expect(cache.vocabulary(for: old.sourceEntries).terms == old.terms)
    #expect(cache.vocabulary(for: []).entries(correctionsEnabled: true).isEmpty)
}

@Test func alignmentVocabularyConcurrentSnapshotReadsStayCoherent() async {
    let cache = AlignmentVocabularyCache()
    let snapshots = (0..<4).map { [TerminologyEntry(canonical: "Snapshot\($0)", aliases: [])] }
    await withTaskGroup(of: Bool.self) { group in
        for i in 0..<40 {
            let entries = snapshots[i % snapshots.count]
            group.addTask { cache.vocabulary(for: entries).entries(correctionsEnabled: i.isMultiple(of: 2)) == entries }
        }
        for await coherent in group { #expect(coherent) }
    }
}

@Test func cachedVocabularyPreserves109PromptsAcrossBudgetsAndUnicode() {
    var popular = TerminologyEntry(canonical: "Zeta", aliases: ["zeta alias"])
    popular.usageCount = 10
    let entries = [popular,
        TerminologyEntry(canonical: "pstack", aliases: ["peacteg"]),
        TerminologyEntry(canonical: "SmartShadow", aliases: ["smar shade"]),
        TerminologyEntry(canonical: "café", aliases: ["cafe"]),
        TerminologyEntry(canonical: "cafe\u{301}", aliases: []),
        TerminologyEntry(canonical: "___", aliases: ["---"]),
        TerminologyEntry(canonical: "👨‍👩‍👧", aliases: ["family emoji"]),
        TerminologyEntry(canonical: "林锦钗", aliases: [], source: "user"),
        TerminologyEntry(type: .correction, original: "林龙标", replacement: "林龙彪", aliases: [], source: "user", usageCount: 0, createdAt: "test")]
    let contexts = ["", "请用 peacteg 评审 smar shade。", "cafe 和 café", "family emoji", "林锦猜先不要发布", "___"]
    let priorities = [[], ["pstack", "SmartShadow"], ["New.Term", "NewTerm", "___"]]
    var caseCount = 0
    for hints in priorities {
        var config = TranscriptionConfig()
        config.hintTerms = hints
        config.terminology.entries = entries
        let reference = Reference109Vocabulary(hintTerms: hints, activeDictionaryEntries: entries)
        #expect(config.prioritizedHintTerms == reference.prioritizedHintTerms)
        #expect(config.promptHintTerms == reference.promptHintTerms)
        #expect(TranscriptionPromptBuilder().buildPrompt(hintTerms: config.promptHintTerms)
            .utf8.elementsEqual(TranscriptionPromptBuilder().buildPrompt(hintTerms: reference.promptHintTerms).utf8))
        for budget in [0, 12, 24, 60, 240, 1200] {
            for text in contexts {
                var polish = TextPolishConfig()
                polish.glossaryBudgetCharacters = budget
                let historical = Reference109PolishPromptBuilder().buildMessages(transcript: text,
                    terminologyEntries: entries + hints.map { TerminologyEntry(canonical: $0, aliases: []) },
                    config: polish, priorityTerms: hints)
                // The owner changed the language contract on 2026-11-11; glossary behavior stays frozen.
                let expected = historical.map { message in
                    TextPolishMessage(role: message.role, content: message.content.replacingOccurrences(
                        of: "Goal: return directly usable Chinese or mixed Chinese/English text; output only the final text.",
                        with: "Goal: return directly usable text in the transcript's original language; output only the final text. Keep English in English. For mixed-language dictation, preserve the original language of each passage instead of translating it."))
                }
                let actual = TextPolishPromptBuilder().buildMessages(transcript: text,
                    terminologyEntries: entries, config: polish, priorityTerms: hints)
                #expect(actual == expected, "case \(caseCount), budget \(budget)")
                #expect(actual.count == expected.count)
                for (message, old) in zip(actual, expected) {
                    #expect(message.role.utf8.elementsEqual(old.role.utf8))
                    #expect(message.content.utf8.elementsEqual(old.content.utf8), "UTF-8 case \(caseCount), budget \(budget)")
                }
                caseCount += 1
            }
        }
    }
    #expect(caseCount == 108)
}

@Test func cachedASRPromptsPreserveExact600CharacterBoundary() {
    for prefixLength in [591, 592, 593, 594, 595, 596, 597, 598, 599, 600, 601] {
        var config = TranscriptionConfig()
        config.hintTerms = [String(repeating: "甲", count: prefixLength), "cafe\u{301}"]
        config.terminology.entries = [TerminologyEntry(canonical: "café", aliases: []),
            TerminologyEntry(canonical: "SmartShadow", aliases: [])]
        let old = Reference109Vocabulary(hintTerms: config.hintTerms, activeDictionaryEntries: config.activeDictionaryEntries)
        let actual = TranscriptionPromptBuilder().buildPrompt(hintTerms: config.promptHintTerms)
        let expected = TranscriptionPromptBuilder().buildPrompt(hintTerms: old.promptHintTerms)
        #expect(actual.utf8.elementsEqual(expected.utf8), "prefix \(prefixLength)")
        #expect(actual.contains("- cafe\u{301}") == (prefixLength + 2 + 4 <= 600))
        #expect(actual.contains("- SmartShadow") == false)
    }
}

@Test func vocabularyCacheInvalidatesSameCountEditsAndKeepsOldSnapshots() {
    let cache = VocabularyIndexCache()
    var original = [TerminologyEntry(canonical: "OldName", aliases: ["old alias"])]
    let old = cache.index(for: original)
    #expect(cache.index(for: original) === old)
    original[0].original = "NewName"
    original[0].aliases = ["new alias"]
    let new = cache.index(for: original)
    #expect(new !== old)
    #expect(old.glossary(transcript: "old alias", priorities: [], budget: 240) == ["OldName aliases: old alias"])
    #expect(new.glossary(transcript: "new alias", priorities: [], budget: 240) == ["NewName aliases: new alias"])
    #expect(cache.index(for: old.sourceEntries).asrHints(priorities: []) == ["OldName"])
    #expect(cache.index(for: original).asrHints(priorities: []) == ["NewName"])
    #expect(new.asrHints(priorities: ["PriorityA"]).first == "PriorityA")
    #expect(new.asrHints(priorities: ["PriorityB"]).first == "PriorityB")
    #expect(cache.index(for: original, locale: Locale(identifier: "tr_TR")) !== new)
}

@Test func vocabularyPrewarmAndForegroundReadsPublishCompleteMatchingSnapshots() async {
    let cache = VocabularyIndexCache()
    let snapshots = (0..<4).map { i in [TerminologyEntry(canonical: "Snapshot\(i)", aliases: [])] }
    await withTaskGroup(of: Bool.self) { group in
        for i in 0..<80 {
            let entries = snapshots[i % snapshots.count]
            group.addTask {
                let index = cache.index(for: entries)
                return index.asrHints(priorities: []) == entries.map(\.original)
                    && index.glossary(transcript: entries[0].original, priorities: [], budget: 240) == entries.map(\.original)
            }
        }
        for await correct in group { #expect(correct) }
    }
}
