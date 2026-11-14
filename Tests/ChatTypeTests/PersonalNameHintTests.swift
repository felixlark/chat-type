import Foundation
import Testing
@testable import ChatType

@Test func personalNamesRecallNearSoundsAndKeepHomophonesAsCandidates() {
    let entries = ["林卓玟", "林卓闻", "林锦钗", "林龙彪", "金天"].map {
        TerminologyEntry(canonical: $0, aliases: [], source: "macos-contacts")
    }
    let result = PersonalNameHints.relatedTerms(in: "请联系林卓文、林锦猜和临龙标。", entries: entries)
    #expect(result.contains("林卓玟"))
    #expect(result.contains("林卓闻"))
    #expect(result.contains("林锦钗"))
    #expect(result.contains("林龙彪"))
    #expect(PersonalNameHints.relatedTerms(in: "今天开会，下午先不要发布。", entries: entries).isEmpty)
    #expect(PersonalNameHints.relatedTerms(in: "联系金天。", entries: entries).contains("金天"))
    #expect(!PersonalNameHints.relatedTerms(in: "林卓文玟", entries: [entries[0]]).contains("金天"))
}

@Test func personalNameCacheRefreshesWhenCanonicalEntriesChange() {
    let old = [TerminologyEntry(canonical: "林卓闻", aliases: [], source: "user")]
    let new = [TerminologyEntry(canonical: "林锦钗", aliases: [], source: "user")]
    PersonalNameHints.prewarm(entries: old)
    #expect(PersonalNameHints.relatedTerms(in: "林卓文", entries: old) == ["林卓闻"])
    #expect(PersonalNameHints.relatedTerms(in: "林锦猜", entries: new) == ["林锦钗"])
    #expect(PersonalNameHints.relatedTerms(in: "林卓文", entries: new).isEmpty)
}

@Test func relatedNamesEnterPolishBudgetBeforeUnrelatedDictionary() {
    let names = [TerminologyEntry(canonical: "林锦钗", aliases: [], source: "macos-contacts")]
    let unrelated = (0..<200).map { TerminologyEntry(canonical: "UnrelatedTerm\($0)", aliases: []) }
    let hints = ["pstack", "SmartShadow"] + PersonalNameHints.relatedTerms(in: "请联系林锦猜", entries: names)
    var config = TextPolishConfig()
    config.glossaryBudgetCharacters = 60
    let messages = TextPolishPromptBuilder().buildMessages(transcript: "请联系林锦猜", terminologyEntries: unrelated + names,
        config: config, priorityTerms: hints)
    #expect(messages[0].content.contains("- 林锦钗"))
    #expect(messages[0].content.contains("- pstack"))
    #expect(messages[1].content == "请联系林锦猜")
}

@Test func userCorrectionTargetIsPrioritizedForASRAndWholeTextPolish() {
    var config = TranscriptionConfig()
    config.hintTerms = ["pstack"]
    config.terminology.entries = [
        TerminologyEntry(type: .correction, original: "林龙标", replacement: "林龙彪", aliases: [], source: "user", usageCount: 0, createdAt: "test"),
        TerminologyEntry(canonical: "AUnrelatedTerm", aliases: [], source: "dictionary-import")
    ]
    #expect(config.prioritizedHintTerms == ["pstack", "林龙彪"])
    #expect(config.promptHintTerms == ["pstack", "林龙彪", "AUnrelatedTerm"])
}
