import Foundation
import Testing
@testable import ChatType

@Test
func appleContactRemarkImporterBuildsUniqueTermsFromNicknames() {
    let entries = AppleContactRemarkImporter.entries(
        from: ["阿彪", " 阿彪 ", "Longbiao", ""],
        importedAt: "2026-08-01T00:00:00Z"
    )

    #expect(entries.map(\.original) == ["阿彪", "Longbiao"])
    #expect(entries.allSatisfy { $0.type == .term })
    #expect(entries.allSatisfy { $0.source == "apple-contacts-nickname" })
}

@Test
func weixinRemarkImporterReadsOnlyTheRemarkColumn() throws {
    let csv = """
    微信号,昵称,备注名
    longbiao,龙彪,陈老师
    team,研发群,"研发,核心群"
    duplicate,另一昵称,陈老师
    """

    let result = try WeixinRemarkCSVImporter().importEntries(
        from: Data(csv.utf8),
        sourceName: "weixin-contacts.csv"
    )

    #expect(result.source == "weixin-remark-export")
    #expect(result.entries.map(\.original) == ["陈老师", "研发,核心群"])
    #expect(result.entries.allSatisfy { $0.source == "weixin-remark-export" })
}

@Test
func weixinRemarkImporterAcceptsEnglishRemarkHeaderAndBOM() throws {
    let csv = "\u{feff}nickname,remark_name\nLongbiao,LB\n"

    let result = try WeixinRemarkCSVImporter().importEntries(
        from: Data(csv.utf8),
        sourceName: "contacts.csv"
    )

    #expect(result.entries.map(\.original) == ["LB"])
}

@Test
func weixinRemarkImporterRejectsArbitraryTextDictionary() {
    let csv = "term,notes\nChatType,app\n"

    #expect(throws: WeixinRemarkImportError.missingRemarkColumn) {
        try WeixinRemarkCSVImporter().importEntries(
            from: Data(csv.utf8),
            sourceName: "terms.csv"
        )
    }
}

@Test
func weixinRemarkImporterRejectsExportWithoutRemarks() {
    let csv = "微信号,备注名\nlongbiao,\n"

    #expect(throws: WeixinRemarkImportError.noRemarks) {
        try WeixinRemarkCSVImporter().importEntries(
            from: Data(csv.utf8),
            sourceName: "weixin-contacts.csv"
        )
    }
}
