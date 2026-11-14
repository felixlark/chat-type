import Foundation
import Testing
@testable import ChatType

@Test func textCorrectionIsLiteralWholeWordAndNonRecursive() {
    let entries = [rule("alpha", "beta"), rule("beta", "gamma"), rule("chat type", "ChatType"), rule("研发步", "研发部")]
    let result = TerminologyNormalizer().applyCorrections(text: "alpha beta alphabet chat type 研发步", entries: entries)
    #expect(result.text == "beta gamma alphabet ChatType 研发部")
    #expect(result.exactReplacementCount == 4)
    #expect(TerminologyNormalizer().applyCorrections(text: "a l p h a", entries: entries).text == "a l p h a")
}

@Test func textCorrectionProtectsCodePathsLinksAndMatchesLongest() {
    let entries = [rule("type", "Type"), rule("chat type", "ChatType"), rule("alpha", "Beta")]
    let text = "chat type `alpha` /alpha/test https://example.com/alpha alpha"
    #expect(TerminologyNormalizer().applyCorrections(text: text, entries: entries).text
        == "ChatType `alpha` /alpha/test https://example.com/alpha Beta")
}

@Test func textCorrectionPreservesSpecifiedCasing() {
    #expect(TerminologyNormalizer().applyCorrections(text: "openai OpenAI OPENAI openaix", entries: [rule("openai", "OpenAI")]).text == "OpenAI OpenAI OpenAI openaix")
}

@Test func vocabularySearchHandlesLargeBilingualLibraryWithoutChangingEntries() {
    let entries = (0..<17_503).map { TerminologyEntry(canonical: "Word\($0)", aliases: []) }
        + [TerminologyEntry(canonical: "普适计算", aliases: ["ubiquitous computing"], source: "user"), rule("chat type", "ChatType")]
    let browser = VocabularyBrowser(entries: entries)
    #expect(browser.termCount == 17_504)
    #expect(browser.correctionCount == 1)
    #expect(browser.filtered(type: .term, query: "COMPUTING", source: "").map(\.entry.original) == ["普适计算"])
    #expect(browser.filtered(type: .correction, query: "ChatType", source: "user").count == 1)
    #expect(browser.filtered(type: .term, query: "", source: "user").count == 1)
}

@Test @MainActor func importedNamesMergeIntoCurrentDraftPreservingEdits() {
    var current = AppConfig()
    current.transcription.textPolish.chatGPTResponseModel = "selected-during-import"
    current.transcription.terminology.entries = [TerminologyEntry(canonical: "EditedWhileReading", aliases: [], source: "user")]
    let incoming = [TerminologyEntry(canonical: "NewName", aliases: [], source: "smart-shadow-weixin-remark")]
    current.transcription.terminology.entries = AppCoordinator.refreshedTerminologyEntries(
        existing: current.transcription.terminology.entries, incoming: incoming, replacingSources: ["smart-shadow-weixin-remark"])
    #expect(current.transcription.textPolish.chatGPTResponseModel == "selected-during-import")
    #expect(current.transcription.terminology.entries.map(\.original) == ["EditedWhileReading", "NewName"])
}

@Test func processingFlowFollowsSelectedRouteAndPolishAvailability() {
    var config = TranscriptionConfig()
    config.provider = .openAICompatible
    config.openAIModel = "test-audio-model"
    config.openAITranscriptionURL = "https://recovery.example/v1/audio/transcriptions"
    config.textPolish.provider = .qwenFlash
    var stages = ProcessingStage.stages(config: config, localPreviewSupported: true, chatGPTReady: true, glmReady: false, qwenReady: false)
    #expect(stages[1].service == "test-audio-model · recovery.example")
    #expect(stages[0].service == "This Mac · audio recorder")
    #expect(stages[3].service.hasPrefix("Skipped"))
    #expect(stages[3].input.contains("text only"))
    config.textPolish.mode = .disabled
    stages = ProcessingStage.stages(config: config, localPreviewSupported: true, chatGPTReady: true, glmReady: true, qwenReady: true)
    #expect(stages[3].service.hasPrefix("Off"))
}

@Test func configurationMigrationBacksUpOriginalBytesAndIsIdempotent() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ConfigStore(homeDirectoryURL: home)
    try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
    let original = Data(#"{"transcription":{"terminology":{"entries":[{"type":"correction","original":"wubi","replacement":"普适计算","source":"macos-text-replacements"}]}}}"#.utf8)
    try original.write(to: store.configURL)
    let config = try store.load()
    let backup = store.directoryURL.appendingPathComponent("config-before-keyboard-shortcut-migration.json")
    #expect(try Data(contentsOf: backup) == original)
    #expect(config.transcription.terminology.entries.first?.original == "普适计算")
    #expect(config.transcription.terminology.entries.first?.type == .term)
    _ = try store.load()
    #expect(try Data(contentsOf: backup) == original)
    #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

private func rule(_ from: String, _ to: String) -> TerminologyEntry {
    TerminologyEntry(type: .correction, original: from, replacement: to, aliases: [], source: "user", usageCount: 0, createdAt: "test")
}

@Test func configurationMigrationFailureLeavesOriginalUnchanged() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = ConfigStore(homeDirectoryURL: home)
    let backup = store.directoryURL.appendingPathComponent("config-before-keyboard-shortcut-migration.json")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let original = Data(#"{"transcription":{"terminology":{"entries":[{"type":"correction","original":"wb","replacement":"普适计算","source":"macos-text-replacements"}]}}}"#.utf8)
    try original.write(to: store.configURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.configURL) == original)
}

@Test func vocabularySourcesGroupRelatedImportsAndHideInternalPaths() {
    let entries = [TerminologyEntry(canonical: "NameA", aliases: [], source: "apple-contacts-names"),
        TerminologyEntry(canonical: "NameB", aliases: [], source: "macos-contacts"),
        TerminologyEntry(canonical: "NameC", aliases: [], source: "file: /private/example.txt")]
    let browser = VocabularyBrowser(entries: entries)
    #expect(browser.sources == ["contacts", "file"])
    #expect(browser.filtered(type: .term, query: "", source: "contacts").count == 2)
    #expect(VocabularyBrowser.sourceTitle("file: /private/example.txt") == "Imported file")
}

@Test func importedChineseFragmentsStayStableAcrossSaveAndReload() {
    let imported = AppleContactRemarkImporter.entries(from: ["张明 厦大-实验室", "Alice Smith", "李四-研发部"], importedAt: "test", source: "smart-shadow-weixin-remark")
    let saved = TerminologyPolicy.sanitizedEntries(imported)
    let reloaded = TerminologyPolicy.sanitizedEntries(saved)
    #expect(saved == reloaded)
    #expect(saved.map(\.original) == ["张明", "厦大", "实验室", "Alice Smith", "李四", "研发部"])
}
