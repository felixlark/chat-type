import Foundation

struct ContactsCheckCase: Decodable, Sendable {
    let id: String
    let text: String
    let expected: [String]
}

struct ContactsCheckResult: Codable, Sendable {
    let label: String
    let expectedCount: Int
    let legacyHits: Int
    let layeredHits: Int
    let legacyCandidates: Int
    let layeredCandidates: Int
    let firstQueryIncludesIndexPreparation: Bool
    let legacyFirstQueryMs: Double
    let layeredFirstQueryMs: Double
    let legacyWarmMedianMs: Double
    let layeredWarmMedianMs: Double
}

struct ContactsReportSummary: Codable, Sendable {
    let schemaVersion: Int
    let capturedAt: Date
    let individualCards: Int
    let unifiedCards: Int
    let personCards: Int
    let organizationCards: Int
    let sameNameGroups: Int
    let sameNicknameGroups: Int
    let vocabularyEntries: Int
    let catalogWords: Int
    let roleCounts: [String: Int]
    let storedAppleTermsAbsentFromCurrentProjection: Int
    let nativeTermsAbsentFromAllCanonicalAndAliasKeys: Int
    let checkResults: [ContactsCheckResult]
    let reportPath: String
    let catalogPath: String
    let contactsModified: Bool
    let liveSelectorChanged: Bool
}

enum ContactsReport {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(escape(title))</title>
        <style>body{font:16px/1.6 system-ui;margin:2rem auto;max-width:1200px;padding:0 1rem;color:#222}table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border:1px solid #ddd;padding:.4rem;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:#eee}code{font-size:.8em}details{margin:1rem 0}.note{background:#f5f5f5;padding:1rem}a{color:#1462a5}</style></head>
        <body><h1>\(escape(title))</h1>\(body)</body></html>
        """
    }

    static func table(_ headings: [String], _ rows: [[String]]) -> String {
        "<table><thead><tr>" + headings.map { "<th>\(escape($0))</th>" }.joined()
            + "</tr></thead><tbody>" + rows.map { row in
                "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
            }.joined() + "</tbody></table>"
    }

    static func check(_ cases: [ContactsCheckCase], vocabulary: [TerminologyEntry], catalog: LocalNameCatalog) -> [ContactsCheckResult] {
        guard !cases.isEmpty else { return [] }
        func measure(_ pool: [TerminologyEntry]) -> [(Int, Int, Double, Double)] {
            let cold = cases.map { item -> (Int, Int, Double) in
                let start = ProcessingTiming.now()
                let found = PersonalNameHints.relatedTerms(in: item.text, entries: pool)
                return (item.expected.filter { found.contains($0) }.count, found.count, ProcessingTiming.milliseconds(since: start))
            }
            PersonalNameHints.prewarm(entries: pool)
            return cases.enumerated().map { offset, item in
                let times = (0..<5).map { _ -> Double in
                    let start = ProcessingTiming.now()
                    _ = PersonalNameHints.relatedTerms(in: item.text, entries: pool)
                    return ProcessingTiming.milliseconds(since: start)
                }
                return (cold[offset].0, cold[offset].1, cold[offset].2, times.sorted()[2])
            }
        }
        let original = measure(vocabulary)
        let layered = measure(catalog.hintEntries)
        return cases.indices.map { i in
            ContactsCheckResult(label: "Q\(i + 1)", expectedCount: cases[i].expected.count,
                legacyHits: original[i].0, layeredHits: layered[i].0,
                legacyCandidates: original[i].1, layeredCandidates: layered[i].1,
                firstQueryIncludesIndexPreparation: i == 0,
                legacyFirstQueryMs: original[i].2, layeredFirstQueryMs: layered[i].2,
                legacyWarmMedianMs: original[i].3, layeredWarmMedianMs: layered[i].3)
        }
    }

    static func generate(snapshot: ContactsSnapshot, vocabulary: [TerminologyEntry], cases: [ContactsCheckCase] = [],
                         root: URL, write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                         validateBeforePublish: () throws -> Void = {}) throws -> ContactsReportSummary {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let generation = "Report-" + UUID().uuidString
        let final = root.appendingPathComponent(generation, isDirectory: true)
        let pending = root.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: pending) }
        func save(_ data: Data, _ name: String) throws {
            let file = pending.appendingPathComponent(name)
            try write(data, file)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let catalog = LocalNameCatalog.build(snapshot: snapshot, vocabulary: vocabulary)
        let nameGroups = ContactsReportGroups.groups(snapshot.unified, nickname: false)
        let nicknameGroups = ContactsReportGroups.groups(snapshot.unified, nickname: true)
        let projection = Set(TerminologyPolicy.contactTerms(from: snapshot.unified.flatMap { [$0.fullName, $0.nickname] }).map(importKey))
        let oldApple = Set(vocabulary.filter { $0.type == .term && ["macos-contacts", "apple-contacts-names", "apple-contacts-nickname"].contains($0.source) }.map { importKey($0.canonical) })
        let allKeys = Set(vocabulary.flatMap { [$0.canonical] + $0.aliases }.map(importKey))
        let absent = vocabulary.filter { $0.type == .term && ["macos-contacts", "apple-contacts-names", "apple-contacts-nickname"].contains($0.source) && !projection.contains(importKey($0.canonical)) }
        let checks = check(cases, vocabulary: vocabulary, catalog: catalog)
        let summary = ContactsReportSummary(schemaVersion: 1, capturedAt: snapshot.capturedAt,
            individualCards: snapshot.individual.count, unifiedCards: snapshot.unified.count,
            personCards: snapshot.unified.filter { !$0.isOrganization }.count,
            organizationCards: snapshot.unified.filter(\.isOrganization).count,
            sameNameGroups: nameGroups.count, sameNicknameGroups: nicknameGroups.count,
            vocabularyEntries: vocabulary.count, catalogWords: catalog.entries.count,
            roleCounts: Dictionary(uniqueKeysWithValues: LocalWordRole.allCases.map { role in
                (role.rawValue, catalog.entries.filter { $0.roles.contains(role) }.count)
            }), storedAppleTermsAbsentFromCurrentProjection: oldApple.subtracting(projection).count,
            nativeTermsAbsentFromAllCanonicalAndAliasKeys: projection.subtracting(allKeys).count,
            checkResults: checks, reportPath: final.appendingPathComponent("index.html").path,
            catalogPath: final.appendingPathComponent("name-catalog.json").path,
            contactsModified: false, liveSelectorChanged: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try save(encoder.encode(catalog), "name-catalog.json")
        let sourceNames = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, "\($0.label) · \($0.name)") })
        let rawByID = Dictionary(uniqueKeysWithValues: snapshot.individual.map { ($0.id, $0) })
        func groupHTML(_ groups: [[LocalContactCard]], nickname: Bool) -> String {
            table(["候选组", nickname ? "昵称" : "姓名", "显示姓名", "类型", "统一卡片标识", "原始卡片标识", "该原卡来源"], groups.enumerated().flatMap { offset, cards in
                cards.flatMap { card -> [[String]] in
                    let linked = snapshot.candidateLinks[card.id, default: []].sorted()
                    return (linked.isEmpty ? [""] : linked).map { rawID in
                        let sourceIDs = rawByID[rawID]?.sourceIDs ?? []
                        let sources = sourceIDs.isEmpty ? "来源关联未知" : sourceIDs.sorted().map { sourceNames[$0] ?? "未知" }.joined(separator: "；")
                        return ["G\(offset + 1)", nickname ? card.nickname : card.fullName, card.fullName,
                            card.isOrganization ? "组织" : "个人", card.id, rawID.isEmpty ? "关联未知" : rawID, sources]
                    }
                }
            })
        }
        var body = "<p class=\"note\">本机只读报告。联系人原卡片、词库和真实转写路径保持原样。同名和同昵称均为候选，身份尚待核验。本报告未读取电话、邮箱、地址、备注或照片。</p>"
        body += "<p>采集时间：\(escape(ISO8601DateFormatter().string(from: snapshot.capturedAt)))</p>"
        body += table(["口径", "数量"], [["原始卡片", "\(summary.individualCards)"], ["关联后显示卡片", "\(summary.unifiedCards)"],
            ["个人 / 组织卡片", "\(summary.personCards) / \(summary.organizationCards)"], ["同名 / 同昵称候选组", "\(nameGroups.count) / \(nicknameGroups.count)"],
            ["原词库词项 / 本机清单字形", "\(vocabulary.count) / \(catalog.entries.count)"], ["当前原生词项未被全词库字形或别名覆盖", "\(summary.nativeTermsAbsentFromAllCanonicalAndAliasKeys)" ]])
        body += "<h2>来源账户</h2>" + table(["标签", "本机账户名称", "类型", "默认", "原始卡片"], snapshot.sources.map {
            [$0.label, $0.name, $0.type == 1 ? "本机" : "同步来源（类型\($0.type)）", $0.isDefault ? "是" : "否", "\($0.cardCount)"]
        })
        body += "<h2>字形角色</h2><p>角色允许重叠；同一字形可关联多个人和来源。新清单仅供本机对照。</p><ul>"
        for role in LocalWordRole.allCases {
            body += "<li><a href=\"\(role.rawValue).html\">\(role.title)：\(summary.roleCounts[role.rawValue, default: 0])项</a></li>"
            let rows = catalog.entries.filter { $0.roles.contains(role) }.map { entry in
                [entry.forms.sorted().joined(separator: "；"), entry.roles.map(\.title).sorted().joined(separator: "；"),
                 entry.sources.sorted().map { value in
                    value.hasPrefix("apple-native:") ? sourceNames[String(value.dropFirst(13))] ?? "Apple来源未知" : value
                 }.joined(separator: "；"), entry.contactIDs.sorted().joined(separator: "；")]
            }
            try save(Data(page(title: role.title + "字形清单", body: "<p><a href=\"index.html\">返回报告</a> · 本机只读，未接入真实转写</p>" + table(["原字形", "角色", "来源", "原始卡片标识"], rows)).utf8), role.rawValue + ".html")
        }
        body += "</ul><h2>同名候选</h2>" + groupHTML(nameGroups, nickname: false)
        body += "<h2>同昵称候选</h2>" + groupHTML(nicknameGroups, nickname: true)
        body += "<h2>旧Apple来源核验</h2><p>以下\(absent.count)项在当前姓名/昵称派生清单中缺席，可能为历史别名、机构或字段变更。原词保留。</p>"
        body += table(["原字形", "已有来源"], absent.map { [$0.canonical, $0.source] })
        if !cases.isEmpty {
            body += "<h2>离线姓名检索对照</h2><p>当前匹配规则保持；每组先查询一次，再预热索引并测5轮。只有各组首个查询包含冷索引构建，后续首查询已共享同一索引。中位数仅为本地检索耗时。</p>"
            body += table(["样本", "本机原文", "预期字形", "原池命中", "分层命中", "原池预热中位ms", "分层预热中位ms"], cases.indices.map { i in
                let r = checks[i]
                return [cases[i].id, cases[i].text, cases[i].expected.joined(separator: "；"), "\(r.legacyHits)/\(r.expectedCount)", "\(r.layeredHits)/\(r.expectedCount)", String(format: "%.2f", r.legacyWarmMedianMs), String(format: "%.2f", r.layeredWarmMedianMs)]
            })
        }
        try save(Data(page(title: "ChatType 本机通讯录候选报告", body: body).utf8), "index.html")
        try save(encoder.encode(summary), "summary.json")
        try validateBeforePublish()
        try fm.moveItem(at: pending, to: final)
        return summary
    }

    private static func importKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum ContactsReportCommand {
    static func run(arguments: [String], provider: any ContactsSnapshotProviding = NativeContactsSnapshotProvider(),
                    configURL: URL = ConfigStore().configURL,
                    root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChatType/ContactsReports", isDirectory: true)) throws -> ContactsReportSummary {
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--check-cases") else {
            throw ContactsReportError.invalidArguments
        }
        let original = try Data(contentsOf: configURL)
        let entries = try JSONDecoder().decode(LocalVocabularyFile.self, from: original).entries
        let cases = arguments.isEmpty ? [] : try JSONDecoder().decode([ContactsCheckCase].self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        guard Set(cases.map(\.id)).count == cases.count,
              cases.allSatisfy({ !$0.id.isEmpty && $0.expected.allSatisfy { !$0.isEmpty } }) else {
            throw ContactsReportError.invalidCases
        }
        let snapshot = try provider.capture()
        return try ContactsReport.generate(snapshot: snapshot, vocabulary: entries, cases: cases, root: root,
            validateBeforePublish: {
                guard try Data(contentsOf: configURL) == original else { throw ContactsReportError.changedDuringRead }
            })
    }
}
