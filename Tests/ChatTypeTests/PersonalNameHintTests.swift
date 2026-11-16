import Foundation
import Testing
@testable import ChatType

// All names and organizations below are fictional test fixtures.

@Test func personalNamesRecallNearSoundsAndKeepHomophonesAsCandidates() {
    let entries = ["顾清禾", "顾青禾", "陶星澜", "周远舟", "金天"].map {
        TerminologyEntry(canonical: $0, aliases: [], source: "macos-contacts")
    }
    let result = PersonalNameHints.relatedTerms(in: "请联系顾清和、陶新蓝和舟远洲。", entries: entries)
    #expect(result.contains("顾清禾"))
    #expect(result.contains("顾青禾"))
    #expect(result.contains("陶星澜"))
    #expect(result.contains("周远舟"))
    #expect(PersonalNameHints.relatedTerms(in: "今天开会，下午先不要发布。", entries: entries).isEmpty)
    #expect(PersonalNameHints.relatedTerms(in: "联系金天。", entries: entries).contains("金天"))
    #expect(!PersonalNameHints.relatedTerms(in: "顾清和禾", entries: [entries[0]]).contains("金天"))
}

@Test func personalNameCacheRefreshesWhenCanonicalEntriesChange() {
    let old = [TerminologyEntry(canonical: "顾青禾", aliases: [], source: "user")]
    let new = [TerminologyEntry(canonical: "陶星澜", aliases: [], source: "user")]
    PersonalNameHints.prewarm(entries: old)
    #expect(PersonalNameHints.relatedTerms(in: "顾清和", entries: old) == ["顾青禾"])
    #expect(PersonalNameHints.relatedTerms(in: "陶新蓝", entries: new) == ["陶星澜"])
    #expect(PersonalNameHints.relatedTerms(in: "顾清和", entries: new).isEmpty)
}

@Test func relatedNamesEnterPolishBudgetBeforeUnrelatedDictionary() {
    let names = [TerminologyEntry(canonical: "陶星澜", aliases: [], source: "macos-contacts")]
    let unrelated = (0..<200).map { TerminologyEntry(canonical: "UnrelatedTerm\($0)", aliases: []) }
    let hints = ["pstack", "SmartShadow"] + PersonalNameHints.relatedTerms(in: "请联系陶新蓝", entries: names)
    var config = TextPolishConfig()
    config.glossaryBudgetCharacters = 60
    let messages = TextPolishPromptBuilder().buildMessages(transcript: "请联系陶新蓝", terminologyEntries: unrelated + names,
        config: config, priorityTerms: hints)
    #expect(messages[0].content.contains("- 陶星澜"))
    #expect(messages[0].content.contains("- pstack"))
    #expect(messages[1].content == "请联系陶新蓝")
}

@Test func userCorrectionTargetIsPrioritizedForASRAndWholeTextPolish() {
    var config = TranscriptionConfig()
    config.hintTerms = ["pstack"]
    config.terminology.entries = [
        TerminologyEntry(type: .correction, original: "周远洲", replacement: "周远舟", aliases: [], source: "user", usageCount: 0, createdAt: "test"),
        TerminologyEntry(canonical: "AUnrelatedTerm", aliases: [], source: "dictionary-import")
    ]
    #expect(config.prioritizedHintTerms == ["pstack", "周远舟"])
    #expect(config.promptHintTerms == ["pstack", "周远舟", "AUnrelatedTerm"])
}
