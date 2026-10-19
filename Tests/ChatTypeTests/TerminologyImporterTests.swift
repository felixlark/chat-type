import Foundation
import SQLite3
import Testing
@testable import ChatType

@Test
func appleContactRemarkImporterBuildsUniqueTermsFromNicknames() {
    let entries = AppleContactRemarkImporter.entries(
        from: [
            "阿彪",
            " 阿彪 ",
            "刘鑫财 漳州龙轴组织部 部长",
            "郑计阮-厦大车队总经理",
            "厦门金联云投资有限合伙企业",
            "Alice Smith",
            "Longbiao",
            "",
        ],
        importedAt: "2026-08-01T00:00:00Z"
    )

    #expect(entries.map(\.original) == [
        "阿彪",
        "刘鑫财",
        "漳州龙轴组织部",
        "郑计阮",
        "厦大车队",
        "厦门金联云投资有限合伙企业",
        "Alice Smith",
        "Longbiao",
    ])
    #expect(entries.allSatisfy { $0.type == .term })
    #expect(entries.allSatisfy { $0.source == "apple-contacts-nickname" })
}

@Test
func weixinRemarkImporterReadsOnlyRemarksFromSmartShadowDatabase() throws {
    let fixture = try WeixinDatabaseFixture(rows: [
        ("wxid_one", "昵称一", "李俊波，厦门市政府二办三处", 1),
        ("wxid_two", "昵称二", " 研发群 ", 1),
        ("wxid_duplicate", "昵称三", "李俊波", 1),
        ("wxid_group_member", "群成员", "不应导入", 3),
        ("wxid_empty", "只有昵称", "", 1),
    ])
    defer { fixture.remove() }
    try fixture.makeDatabaseDirectoryReadOnly()

    let result = try WeixinRemarkDatabaseImporter(
        configURLs: [fixture.configURL],
        temporaryDirectory: fixture.snapshotRootURL
    ).importEntries()

    #expect(result.source == "smart-shadow-weixin-remark")
    #expect(result.entries.map(\.original) == ["李俊波", "厦门市政府二办三处", "研发群"])
    #expect(result.entries.allSatisfy { $0.source == "smart-shadow-weixin-remark" })
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotRootURL.path).isEmpty)
}

@Test
func contactNameSplittingRequiresAnExplicitSeparatorAndPlausibleChineseName() {
    let entries = AppleContactRemarkImporter.entries(
        from: [
            "曾文淇-芗城区住建局",
            "吴成联 厦门金联云投资有限合伙企业",
            "陈晋辉 福建龙轴集团 董事长",
            "厦门金联云投资有限合伙企业",
            "Alice Smith",
        ],
        importedAt: "2026-08-01T00:00:00Z"
    )

    #expect(entries.map(\.original) == [
        "曾文淇",
        "芗城区住建局",
        "吴成联",
        "厦门金联云投资有限合伙企业",
        "陈晋辉",
        "福建龙轴集团",
        "Alice Smith",
    ])
}

@Test
func weixinRemarkImporterReportsMissingRuntimeConfig() {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("smart-shadow.json")

    #expect(throws: WeixinRemarkImportError.runtimeConfigMissing) {
        try WeixinRemarkDatabaseImporter(configURLs: [missingURL]).importEntries()
    }
}

@Test
func weixinImporterFindsTheCurrentDocumentsSmartShadowCheckout() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    let urls = WeixinRemarkDatabaseImporter.standardConfigURLs(homeDirectory: home)

    #expect(urls.first?.path == "/Users/test/Documents/Development/smart-shadow/var/weixin/tools/smart-shadow.json")
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
    let previousImport = terminologyTerm("刘鑫财 漳州龙轴组织部 部长", source: "apple-contacts-nickname")
    let user = terminologyTerm("ChatType", source: "user")
    let incoming = [
        terminologyTerm("刘鑫财", source: "apple-contacts-nickname"),
        terminologyTerm("漳州龙轴组织部", source: "apple-contacts-nickname"),
    ]

    let refreshed = AppCoordinator.refreshedTerminologyEntries(
        existing: [previousImport, user],
        incoming: incoming,
        replacingSources: ["apple-contacts-nickname"]
    )

    #expect(refreshed.map(\.original) == ["ChatType", "刘鑫财", "漳州龙轴组织部"])
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

private struct WeixinDatabaseFixture {
    let rootURL: URL
    let configURL: URL
    let databaseDirectory: URL
    let snapshotRootURL: URL

    init(rows: [(String, String, String, Int32)]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatType-WeixinImporter-\(UUID().uuidString)", isDirectory: true)
        databaseDirectory = rootURL
            .appendingPathComponent("decrypted/_monitor_cache", isDirectory: true)
        snapshotRootURL = rootURL.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotRootURL, withIntermediateDirectories: true)
        let databaseURL = databaseDirectory.appendingPathComponent("contact_contact.db")

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(
            database,
            "CREATE TABLE contact (username TEXT, nick_name TEXT, remark TEXT, local_type INTEGER)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO contact (username, nick_name, remark, local_type) VALUES (?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.0, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.1, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.2, -1, sqliteTransient)
            sqlite3_bind_int(statement, 4, row.3)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        configURL = rootURL.appendingPathComponent("smart-shadow.json")
        let config = ["decrypted_dir": rootURL.appendingPathComponent("decrypted").path]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: configURL)
    }

    func makeDatabaseDirectoryReadOnly() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))],
            ofItemAtPath: databaseDirectory.path
        )
    }

    func remove() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: databaseDirectory.path
        )
        try? FileManager.default.removeItem(at: rootURL)
    }
}
