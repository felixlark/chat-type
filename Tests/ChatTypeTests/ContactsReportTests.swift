import Foundation
import Testing
@testable import ChatType

private func reportFixture() -> ContactsSnapshot {
    let sources = [ContactSource(id: "source-a", label: "C1", name: "Account <private>", type: 3, isDefault: true, cardCount: 3)]
    let cards = [LocalContactCard(id: "a", fullName: "林小明", givenName: "小明", familyName: "林", nickname: "小林", organization: "示例机构", sourceIDs: ["source-a"]),
        LocalContactCard(id: "b", fullName: "林小明", givenName: "小明", familyName: "林", nickname: "小林", sourceIDs: ["source-a"]),
        LocalContactCard(id: "c", fullName: "示例机构", organization: "示例机构", isOrganization: true, sourceIDs: ["source-a"])]
    return ContactsSnapshot(capturedAt: Date(timeIntervalSince1970: 0), sources: sources, individual: cards,
        unified: cards, candidateLinks: ["a": ["a"], "b": ["b"]])
}

@Test func localNameCatalogRetainsRolesMultiplePeopleAndLegacyWords() {
    let old = [TerminologyEntry(canonical: "示例机构", aliases: ["示例公司"], source: "apple-contacts-names"),
        TerminologyEntry(canonical: "待核旧词", aliases: ["旧别名"], source: "smart-shadow-weixin-remark"),
        TerminologyEntry(type: .correction, original: "林小名", replacement: "林小明", aliases: [], source: "user", usageCount: 0, createdAt: "test")]
    let catalog = LocalNameCatalog.build(snapshot: reportFixture(), vocabulary: old)
    let person = catalog.entries.first { $0.forms.contains("林小明") }!
    #expect(person.contactIDs == ["a", "b"])
    #expect(person.sources.contains("user"))
    #expect(person.sources.contains("apple-native:source-a"))
    #expect(person.roles.contains(.name))
    #expect(person.userPriority)
    #expect(!catalog.hintEntries.contains { $0.canonical == "示例机构" || $0.canonical == "示例公司" })
    #expect(catalog.hintEntries.contains { $0.canonical == "待核旧词" })
    #expect(catalog.hintEntries.contains { $0.canonical == "旧别名" })
    #expect(old[2].original == "林小名")
    #expect(ContactsReportGroups.groups(reportFixture().unified, nickname: false).count == 1)
}

@Test func contactsReportEscapesPrivateFieldsAndPublishesOwnerOnlyFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let malicious = "<img src='https://invalid.example/private'>"
    let vocabulary = [TerminologyEntry(canonical: malicious, aliases: [], source: "user")]
    let report = try ContactsReport.generate(snapshot: reportFixture(), vocabulary: vocabulary, root: root)
    let html = try String(contentsOfFile: report.reportPath, encoding: .utf8)
    #expect(html.contains("default-src 'none'"))
    #expect(html.contains("Account &lt;private&gt;"))
    #expect(!html.contains("<script"))
    #expect(report.sameNameGroups == 1)
    #expect(report.sameNicknameGroups == 1)
    #expect(!report.liveSelectorChanged)
    let directory = URL(fileURLWithPath: report.reportPath).deletingLastPathComponent()
    let wordPage = try String(contentsOf: directory.appendingPathComponent("unclassified.html"), encoding: .utf8)
    #expect(wordPage.contains("&lt;img src=&#39;https://invalid.example/private&#39;&gt;"))
    #expect(!wordPage.contains("<img"))
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    let metadata = try String(contentsOf: directory.appendingPathComponent("summary.json"), encoding: .utf8)
    #expect(!metadata.contains("林小明"))
    #expect(!metadata.contains("Account"))
    #expect(!metadata.contains("source-a"))
}

@Test func contactsReportFailureRetainsPreviousGenerationAndRemovesPending() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ContactsReport.generate(snapshot: reportFixture(), vocabulary: [], root: root)
    let original = try Data(contentsOf: URL(fileURLWithPath: first.reportPath))
    do {
        _ = try ContactsReport.generate(snapshot: reportFixture(), vocabulary: [], root: root,
            validateBeforePublish: { throw ContactsReportError.changedDuringRead })
        Issue.record("Changing snapshot should abort publication")
    } catch ContactsReportError.changedDuringRead { }
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.reportPath)) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
}

@Test func readonlyVocabularyDecodePreservesReplacementAndSource() throws {
    let data = Data(#"{"transcription":{"terminology":{"entries":[{"type":"correction","original":"林小名","replacement":"林小明","source":"user"}]}}}"#.utf8)
    let vocabulary = try JSONDecoder().decode(LocalVocabularyFile.self, from: data)
    #expect(vocabulary.entries[0].original == "林小名")
    #expect(vocabulary.entries[0].canonical == "林小明")
    #expect(vocabulary.entries[0].source == "user")
}

private struct ReportFixtureProvider: ContactsSnapshotProviding {
    func capture() throws -> ContactsSnapshot { reportFixture() }
}

@Test func contactsReportCommandUsesReadonlyConfigAndInjectedNativeBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config.json")
    let bytes = Data(#"{"transcription":{"terminology":{"entries":[]}},"unrecognized":{"keep":"exact"}}"#.utf8)
    try bytes.write(to: config)
    let summary = try ContactsReportCommand.run(arguments: [], provider: ReportFixtureProvider(),
        configURL: config, root: root.appendingPathComponent("reports"))
    #expect(try Data(contentsOf: config) == bytes)
    #expect(summary.individualCards == 3)
    #expect(summary.personCards == 2)
    #expect(!summary.contactsModified)
}

@Test func contactsReportRetainsEachRawCardSourceAssociation() throws {
    let sourceA = ContactSource(id: "s-a", label: "C1", name: "First account", type: 3, isDefault: true, cardCount: 1)
    let sourceB = ContactSource(id: "s-b", label: "C2", name: "Second account", type: 3, isDefault: false, cardCount: 2)
    let raw = [LocalContactCard(id: "raw-a", fullName: "林小明", sourceIDs: ["s-a"]),
               LocalContactCard(id: "raw-b", fullName: "林小明", sourceIDs: ["s-b"]),
               LocalContactCard(id: "raw-c", fullName: "林小明", sourceIDs: ["s-b"])]
    let unified = [LocalContactCard(id: "unified-a", fullName: "林小明"), LocalContactCard(id: "unified-b", fullName: "林小明")]
    let snapshot = ContactsSnapshot(capturedAt: Date(), sources: [sourceA, sourceB], individual: raw,
        unified: unified, candidateLinks: ["unified-a": ["raw-a", "raw-b"], "unified-b": ["raw-c"]])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try ContactsReport.generate(snapshot: snapshot, vocabulary: [], root: root)
    let html = try String(contentsOfFile: report.reportPath, encoding: .utf8)
    #expect(html.contains("<td>unified-a</td><td>raw-a</td><td>C1 · First account</td>"))
    #expect(html.contains("<td>unified-a</td><td>raw-b</td><td>C2 · Second account</td>"))
    #expect(html.contains("<td>unified-b</td><td>raw-c</td><td>C2 · Second account</td>"))
}

@Test func contactsOfflineComparisonCoversSuccessKnownFailureAndNegative() {
    let vocabulary = [TerminologyEntry(canonical: "林小明", aliases: [], source: "user")]
    let catalog = LocalNameCatalog.build(snapshot: reportFixture(), vocabulary: vocabulary)
    let cases = [ContactsCheckCase(id: "success", text: "请联系林小明", expected: ["林小明"]),
                 ContactsCheckCase(id: "unrelated-name", text: "请联系张四海", expected: ["林小明"]),
                 ContactsCheckCase(id: "negative", text: "预算五十元，周六开会。", expected: [])]
    let results = ContactsReport.check(cases, vocabulary: vocabulary, catalog: catalog)
    #expect(results.map(\.label) == ["Q1", "Q2", "Q3"])
    #expect(results[0].legacyHits == 1 && results[0].layeredHits == 1)
    #expect(results[1].legacyHits == 0 && results[1].layeredHits == 0)
    #expect(results[2].legacyCandidates == 0 && results[2].layeredCandidates == 0)
    #expect(results[0].firstQueryIncludesIndexPreparation)
    #expect(!results[1].firstQueryIncludesIndexPreparation)
    #expect(ContactsReport.check([], vocabulary: vocabulary, catalog: catalog).isEmpty)
}
