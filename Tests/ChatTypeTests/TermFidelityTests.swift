import Foundation
import Testing
@testable import ChatType

@Test func recognizedProtocolAcronymSurvivesLongerFuzzyCandidate() {
    let result = TerminologyNormalizer().normalize(text: "消息推送到 MCP server。",
        importedEntries: [TerminologyEntry(canonical: "MCP", aliases: []),
                          TerminologyEntry(canonical: "AppServer", aliases: [])], hintTerms: [])
    #expect(result.text == "消息推送到 MCP server。", "Observed: \(result.text)")
    #expect(result.fuzzyReplacementCount == 0)
}

@Test func correctlySpelledProviderSurvivesUnrelatedProverTerm() {
    let result = TerminologyNormalizer().normalize(text: "配置 Provider。",
        importedEntries: [TerminologyEntry(canonical: "Prover", aliases: [])], hintTerms: [])
    #expect(result.text == "配置 Provider。", "Observed: \(result.text)")
    #expect(result.fuzzyReplacementCount == 0)
}

@Test func unavailableEnglishVocabularyKeepsWordsAndExplicitAliases() {
    let normalizer = TerminologyNormalizer(isKnownEnglishWord: { _ in nil })
    let result = normalizer.normalize(text: "Provider 和 pea stack。",
        importedEntries: [TerminologyEntry(canonical: "Prover", aliases: []),
            TerminologyEntry(canonical: "pstack", aliases: ["pea stack"])], hintTerms: [])
    #expect(result.text == "Provider 和 pstack。")
}

@Test func knownWordBesideUnknownMisspellingStillAllowsTermRepair() {
    let normalizer = TerminologyNormalizer(isKnownEnglishWord: { $0.lowercased() == "type" })
    let result = normalizer.normalize(text: "Type Wísper。",
        importedEntries: [TerminologyEntry(canonical: "TypeWhisper", aliases: ["Type Whisper"])], hintTerms: [])
    #expect(result.text == "TypeWhisper。")
}
