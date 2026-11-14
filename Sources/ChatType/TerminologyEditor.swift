import SwiftUI

struct VocabularyRow: Identifiable, Sendable {
    let id: Int
    let entry: TerminologyEntry
    let searchKey: String
}

struct VocabularyBrowser: Sendable {
    let rows: [VocabularyRow]
    let termCount: Int
    let correctionCount: Int
    let sources: [String]

    init(entries: [TerminologyEntry]) {
        rows = entries.enumerated().map {
            VocabularyRow(id: $0.offset, entry: $0.element,
                searchKey: ([$0.element.original, $0.element.replacement ?? ""] + $0.element.aliases)
                    .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
        termCount = entries.filter { $0.type == .term }.count
        correctionCount = entries.count - termCount
        sources = Set(entries.map { Self.sourceGroup($0.source) }).sorted()
    }

    func filtered(type: TerminologyEntryType, query: String, source: String) -> [VocabularyRow] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return rows.filter {
            $0.entry.type == type && (source.isEmpty || Self.sourceGroup($0.entry.source) == source)
                && (key.isEmpty || $0.searchKey.contains(key))
        }
    }

    static func sourceGroup(_ source: String) -> String {
        if ["smart-shadow-weixin-remark", "weixin-contacts", "weixin-remark-export"].contains(source) { return "wechat" }
        if ["apple-contacts-names", "apple-contacts-nickname", "macos-contacts"].contains(source) { return "contacts" }
        if source.hasPrefix("file:") { return "file" }
        return source
    }

    static func sourceTitle(_ source: String) -> String {
        switch sourceGroup(source) {
        case "user": return "Added by you"
        case "wechat": return "WeChat names"
        case "contacts": return "Contacts"
        case "macos-text-replacements": return "Recovered standard spelling"
        case "dictionary-import": return "Imported dictionary"
        case "auto-suggestion": return "Previously learned terms"
        case "file": return "Imported file"
        default: return source
        }
    }
}

/// Editor input lives here so typing never rebuilds account, history or the full settings tree.
struct TerminologyEditor: View {
    @Binding var terminology: TerminologyConfig
    let importContacts: () async -> Result<TerminologyImportResult, any Error>
    let importWeChat: () async -> Result<TerminologyImportResult, any Error>
    @State private var type: TerminologyEntryType = .term
    @State private var query = ""
    @State private var source = ""
    @State private var original = ""
    @State private var replacement = ""
    @State private var editingID: Int?
    @State private var browser = VocabularyBrowser(entries: [])
    @State private var rows: [VocabularyRow] = []
    @Binding var importing: Bool
    @State private var page = 0
    private let rowsPerPage = 50

    private var pageRows: [VocabularyRow] { Array(rows.dropFirst(page * rowsPerPage).prefix(rowsPerPage)) }
    @State private var message: String?
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Library", selection: $type) {
                    Text("Terms · \(browser.termCount)").tag(TerminologyEntryType.term)
                    Text("Replacement · \(browser.correctionCount)").tag(TerminologyEntryType.correction)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 390)
                .accessibilityIdentifier("terminology-entry-type")
                Spacer()
                Menu(importing ? "Reading names…" : "Import names") {
                    Button("From Contacts") { startImport(weChat: false) }
                    Button("From WeChat") { startImport(weChat: true) }
                }
                .disabled(importing)
                .accessibilityIdentifier("import-names")
            }
            Text(type == .term
                ? "Standard spellings for names and technical words. English keeps your casing; Chinese terms guide recognition and relevant text alignment."
                : "Explicit text corrections after AI Polish: slips of the tongue, preferred wording and casing. Rules run once; English matches whole words. macOS keyboard shortcuts stay in macOS.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(type == .term ? "Standard spelling" : "Find this text").font(.caption)
                    TextField(type == .term ? "e.g. ChatType or 普适计算" : "e.g. chat type", text: $original)
                        .accessibilityIdentifier("terminology-original")
                }
                if type == .correction {
                    Image(systemName: "arrow.right").padding(.bottom, 5).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Replace with").font(.caption)
                        TextField("e.g. ChatType", text: $replacement)
                            .accessibilityIdentifier("terminology-replacement")
                    }
                }
                if editingID != nil { Button("Cancel") { clearEditor() } }
                Button(editingID == nil ? (type == .term ? "Add Term" : "Add Rule") : "Update") { saveEntry() }
                    .disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (type == .correction && replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("terminology-save-entry")
            }
            Divider()
            HStack {
                TextField("Search words, names or aliases", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("terminology-search")
                Picker("Source", selection: $source) {
                    Text("All sources").tag("")
                    ForEach(browser.sources, id: \.self) { Text(VocabularyBrowser.sourceTitle($0)).tag($0) }
                }.labelsHidden().frame(width: 180)
            }
            HStack {
                Text("\(rows.count) matching \(type == .term ? "terms" : "rules")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !rows.isEmpty {
                    Text("\(page * rowsPerPage + 1)–\(min((page + 1) * rowsPerPage, rows.count))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0).accessibilityLabel("Previous entries")
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled((page + 1) * rowsPerPage >= rows.count).accessibilityLabel("Next entries")
                }
                if importing { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.caption).foregroundStyle(error ? .red : .secondary).lineLimit(2) }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text(query.isEmpty ? (type == .term ? "Add a standard spelling to begin." : "Add a correction only when you need one.") : "No matching entries. Try another search.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 190)
            } else {
                List(pageRows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.entry.type == .term ? row.entry.original : "\(row.entry.original) → \(row.entry.replacement ?? "")")
                                .font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                            Text(VocabularyBrowser.sourceTitle(row.entry.source)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { edit(row) }.buttonStyle(.borderless)
                        Button("Delete") { delete(row) }.buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }
                .listStyle(.inset)
                .frame(minHeight: 280, idealHeight: 360, maxHeight: 420)
                .accessibilityIdentifier("terminology-list")
            }
            Text("The library is stored on this Mac; relevant terms, including names, may be sent as recognition hints or text-polish context to the services you select.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { rebuild() }
        .onChange(of: terminology.entries) { _ in clearEditor(); rebuild() }
        .onChange(of: type) { _ in clearEditor(); filter() }
        .onChange(of: query) { _ in filter() }
        .onChange(of: source) { _ in filter() }
    }

    private func rebuild() {
        browser = VocabularyBrowser(entries: terminology.entries)
        if !browser.sources.contains(source) { source = "" }
        filter()
    }
    private func filter() { page = 0; rows = browser.filtered(type: type, query: query, source: source) }
    private func clearEditor() { editingID = nil; original = ""; replacement = "" }
    private func edit(_ row: VocabularyRow) { editingID = row.id; original = row.entry.original; replacement = row.entry.replacement ?? "" }
    private func delete(_ row: VocabularyRow) {
        guard terminology.entries.indices.contains(row.id), terminology.entries[row.id] == row.entry else { return }
        terminology.entries.remove(at: row.id)
        message = "Entry removed."; error = false
    }
    private func saveEntry() {
        let wasEditing = editingID != nil
        let from = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = type == .correction ? replacement.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let duplicate = terminology.entries.indices.first {
            $0 != editingID && terminology.entries[$0].type == type
                && terminology.entries[$0].original.localizedCaseInsensitiveCompare(from) == .orderedSame
        }
        guard duplicate == nil else { message = "This entry already exists. Search for it to edit."; error = true; return }
        var entry = TerminologyEntry(type: type, original: from, replacement: to, aliases: [], source: "user",
            usageCount: 0, createdAt: ISO8601DateFormatter().string(from: Date()))
        if let id = editingID, terminology.entries.indices.contains(id) {
            entry.aliases = terminology.entries[id].aliases
            entry.createdAt = terminology.entries[id].createdAt
            terminology.entries[id] = entry
        } else { terminology.entries.insert(entry, at: 0) }
        clearEditor(); message = wasEditing ? "Entry updated." : "Entry added."; error = false
    }
    private func startImport(weChat: Bool) {
        importing = true; message = nil
        Task {
            let result = await (weChat ? importWeChat() : importContacts())
            importing = false
            switch result {
            case .success(let imported):
                // Merge with the current binding, preserving all edits made during the read.
                let sources: Set<String> = weChat
                    ? ["smart-shadow-weixin-remark", "weixin-contacts", "weixin-remark-export"]
                    : ["apple-contacts-nickname", "apple-contacts-names"]
                terminology.entries = AppCoordinator.refreshedTerminologyEntries(existing: terminology.entries,
                    incoming: imported.entries, replacingSources: sources)
                terminology.lastImportedSource = imported.source
                terminology.lastImportedAt = imported.importedAt
                type = .term; query = ""; source = VocabularyBrowser.sourceGroup(imported.source)
                message = "Read \(imported.entries.count) names."; error = false
            case .failure(let failure): message = failure.localizedDescription; error = true
            }
        }
    }
}
