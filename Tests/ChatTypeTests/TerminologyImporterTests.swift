import Foundation
@preconcurrency import Contacts
import Testing
@testable import ChatType

// All names and organizations below are fictional test fixtures.

@Test
func appleContactRemarkImporterBuildsUniqueTermsFromNicknames() {
    let entries = AppleContactRemarkImporter.entries(
        from: [
            "小轩",
            " 小轩 ",
            "周明轩 云城示例组织部 部长",
            "吴语桐-示例车队总经理",
            "云城示例投资有限合伙企业",
            "Alice Smith",
            "Alex Example",
            "",
        ],
        importedAt: "2026-08-01T00:00:00Z"
    )

    #expect(entries.map(\.original) == [
        "小轩",
        "周明轩",
        "云城示例组织部",
        "吴语桐",
        "示例车队",
        "云城示例投资有限合伙企业",
        "Alice Smith",
        "Alex Example",
    ])
    #expect(entries.allSatisfy { $0.type == .term })
    #expect(entries.allSatisfy { $0.source == "apple-contacts-nickname" })
}

@Test
func weixinNameImporterAcceptsCompleteToolNamesAndDeduplicates() throws {
    let data = Data(#"{"complete":true,"names":["李明-研发部","李明","Alice Smith"]}"#.utf8)
    let result = try WeixinNameImporter.result(from: data)
    #expect(result.entries.map(\.original) == ["李明", "研发部", "Alice Smith"])
    #expect(result.entries.allSatisfy { $0.type == .term && $0.source == "smart-shadow-weixin-remark" })
}

@Test
func weixinNameImporterRejectsIncompleteAndEmptyResults() {
    #expect(throws: WeixinRemarkImportError.invalidResponse) {
        try WeixinNameImporter.result(from: Data(#"{"complete":false,"names":["李明"]}"#.utf8))
    }
    #expect(throws: WeixinRemarkImportError.noNames) {
        try WeixinNameImporter.result(from: Data(#"{"complete":true,"names":[]}"#.utf8))
    }
}

@Test
func contactNameSplittingRequiresAnExplicitSeparatorAndPlausibleChineseName() {
    let entries = AppleContactRemarkImporter.entries(
        from: [
            "李景宁-示例区住建局",
            "陈雨溪 云城示例投资有限合伙企业",
            "苏星辰 云城示例集团 董事长",
            "云城示例投资有限合伙企业",
            "Alice Smith",
        ],
        importedAt: "2026-08-01T00:00:00Z"
    )

    #expect(entries.map(\.original) == [
        "李景宁",
        "示例区住建局",
        "陈雨溪",
        "云城示例投资有限合伙企业",
        "苏星辰",
        "云城示例集团",
        "Alice Smith",
    ])
}

@Test
func weixinNameImporterReportsMissingRuntime() {
    #expect(throws: WeixinRemarkImportError.runtimeMissing) {
        try WeixinNameImporter(home: URL(fileURLWithPath: "/missing"), helper: URL(fileURLWithPath: "/missing/helper.py")).importEntries()
    }
}

@Test
@MainActor
func weixinRemarkRefreshReplacesLegacySourcesAndPreservesUserTerms() {
    let legacy = terminologyTerm("旧微信昵称", source: "weixin-contacts")
    let previousImport = terminologyTerm("旧微信备注", source: "weixin-remark-export")
    let user = terminologyTerm("ChatType", source: "user")
    let incoming = terminologyTerm("新微信备注", source: "smart-shadow-weixin-remark")

    let refreshed = AppCoordinator.refreshedTerminologyEntries(
        existing: [legacy, previousImport, user],
        incoming: [incoming],
        replacingSources: ["weixin-contacts", "weixin-remark-export", "smart-shadow-weixin-remark"]
    )

    #expect(refreshed.map(\.original) == ["ChatType", "新微信备注"])
}

@Test
@MainActor
func appleContactNameRefreshReplacesPreviousCombinedEntries() {
    let previousImport = terminologyTerm("周明轩 云城示例组织部 部长", source: "apple-contacts-nickname")
    let user = terminologyTerm("ChatType", source: "user")
    let incoming = [
        terminologyTerm("周明轩", source: "apple-contacts-nickname"),
        terminologyTerm("云城示例组织部", source: "apple-contacts-nickname"),
    ]

    let refreshed = AppCoordinator.refreshedTerminologyEntries(
        existing: [previousImport, user],
        incoming: incoming,
        replacingSources: ["apple-contacts-nickname"]
    )

    #expect(refreshed.map(\.original) == ["ChatType", "周明轩", "云城示例组织部"])
}

private func terminologyTerm(_ value: String, source: String) -> TerminologyEntry {
    TerminologyEntry(
        type: .term,
        original: value,
        replacement: nil,
        aliases: [],
        source: source,
        usageCount: 0,
        createdAt: "2026-08-04T00:00:00Z"
    )
}

@Test func contactImportIncludesFullNameWithoutNickname() {
    let contact = CNMutableContact()
    contact.familyName = "顾"
    contact.givenName = "清禾"
    let values = AppleContactRemarkImporter.nameValues(from: contact)
    let entries = AppleContactRemarkImporter.entries(from: values, importedAt: "test", source: "apple-contacts-names")
    #expect(entries.map(\.original).contains("顾清禾"))
    contact.nickname = "小顾"
    #expect(AppleContactRemarkImporter.nameValues(from: contact).contains("小顾"))
}

@Test func keyboardShortcutsMigrateToStandardSpellingsWithoutAliases() {
    let old = TerminologyEntry(type: .correction, original: "wubi", replacement: "普适计算", aliases: ["wb"],
        source: "macos-text-replacements", usageCount: 0, createdAt: "test")
    let migrated = TerminologyPolicy.sanitizedEntries([old])
    #expect(migrated.count == 1)
    #expect(migrated.first?.type == .term)
    #expect(migrated.first?.original == "普适计算")
    #expect(migrated.first?.aliases.isEmpty == true)
    #expect(migrated.first?.replacement == nil)
    #expect(TerminologyPolicy.sanitizedEntries(migrated) == migrated)
}
