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

/// An array position is only valid while the captured entry still occupies it.
/// Async filtering, imports and deletion can all invalidate an old visible row.
struct VocabularyEdit {
    let index: Int
    let original: TerminologyEntry

    init?(row: VocabularyRow, entries: [TerminologyEntry]) {
        guard entries.indices.contains(row.id), entries[row.id] == row.entry else { return nil }
        index = row.id
        original = row.entry
    }

    func replace(with entry: TerminologyEntry, in entries: inout [TerminologyEntry]) -> Bool {
        guard entries.indices.contains(index), entries[index] == original else { return false }
        entries[index] = entry
        return true
    }
}

/// Editor input lives here so typing never rebuilds account, history or the full settings tree.
struct TerminologyEditor: View {
    @Binding var terminology: TerminologyConfig
    let importContacts: () async -> Result<TerminologyImportResult, any Error>
    let importWeChat: () async -> Result<TerminologyImportResult, any Error>
    let entryType: TerminologyEntryType
    private var type: TerminologyEntryType { entryType }
    @State private var indexing = false
    @State private var query = ""
    @State private var source = ""
    @State private var original = ""
    @State private var replacement = ""
    @State private var editing: VocabularyEdit?
    private var editingID: Int? { editing?.index }
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
                Text(type == .term ? "Custom phrases · \(browser.termCount)" : "Replacement · \(browser.correctionCount)")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if type == .term { Menu(importing ? "Reading names…" : "Import names") {
                    Button("From Contacts") { startImport(weChat: false) }
                    Button("From WeChat") { startImport(weChat: true) }
                }
                .disabled(importing)
                .accessibilityIdentifier("import-names").fixedSize() }
            }
            Text(type == .term
                ? "Standard spellings for names and technical words. English keeps your casing; Chinese terms guide recognition and relevant text alignment."
                : "Explicit text corrections after AI Polish: slips of the tongue, preferred wording and casing. Rules run once; English matches whole words. macOS keyboard shortcuts stay in macOS.")
                .font(SettingsTypography.body).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(type == .term ? "Standard spelling" : "Find this text").font(SettingsTypography.detail)
                    TextField(type == .term ? "e.g. ChatType or 普适计算" : "e.g. chat type", text: $original)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.control)
                        .accessibilityIdentifier("terminology-original")
                }
                if type == .correction {
                    Image(systemName: "arrow.right").padding(.bottom, 5).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Replace with").font(SettingsTypography.detail)
                        TextField("e.g. ChatType", text: $replacement)
                            .textFieldStyle(.roundedBorder)
                            .font(SettingsTypography.control)
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
                    .font(SettingsTypography.control)
                    .accessibilityIdentifier("terminology-search")
                Picker("来源", selection: $source) {
                    Text("全部来源").tag("")
                    ForEach(browser.sources, id: \.self) { Text(VocabularyBrowser.sourceTitle($0)).tag($0) }
                }.labelsHidden().frame(width: 210)
            }
            HStack {
                Text("\(rows.count) matching \(type == .term ? "terms" : "rules")").font(SettingsTypography.detail).foregroundStyle(.secondary)
                Spacer()
                if !rows.isEmpty {
                    Text("\(page * rowsPerPage + 1)–\(min((page + 1) * rowsPerPage, rows.count))")
                        .font(SettingsTypography.detail).monospacedDigit().foregroundStyle(.secondary)
                    Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0).accessibilityLabel("Previous entries")
                        .font(.system(size: 12, weight: .semibold))
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled((page + 1) * rowsPerPage >= rows.count).accessibilityLabel("Next entries")
                        .font(.system(size: 12, weight: .semibold))
                }
                if importing || indexing { ProgressView().controlSize(.small) }
                if let message { Text(message).font(SettingsTypography.detail).foregroundStyle(error ? .red : .secondary).lineLimit(2) }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text(query.isEmpty ? (type == .term ? "Add a standard spelling to begin." : "Add a correction only when you need one.") : "No matching entries. Try another search.")
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(pageRows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.entry.type == .term ? row.entry.original : "\(row.entry.original) → \(row.entry.replacement ?? "")")
                                .font(.system(size: 13.5, weight: .medium)).textSelection(.enabled)
                            Text(VocabularyBrowser.sourceTitle(row.entry.source)).font(SettingsTypography.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { edit(row) }.buttonStyle(.borderless).font(SettingsTypography.control)
                        Button("Delete") { delete(row) }.buttonStyle(.borderless).font(SettingsTypography.control)
                    }.padding(.vertical, 7)
                }
                .listStyle(.inset)
                .frame(minHeight: 380, idealHeight: 460, maxHeight: 560)
                .accessibilityIdentifier("terminology-list")
            }
            Text("The library is stored on this Mac; relevant terms, including names, may be sent as recognition hints or text-polish context to the services you select.")
                .font(SettingsTypography.detail).foregroundStyle(.secondary)
        }
        .task(id: VocabularyQuery(entries: terminology.entries, type: type, query: query, source: source)) {
            indexing = true
            let entries = terminology.entries, selectedType = type, search = query, selectedSource = source
            let result = await Task.detached(priority: .userInitiated) {
                let browser = VocabularyBrowser(entries: entries)
                return (browser, browser.filtered(type: selectedType, query: search, source: selectedSource))
            }.value
            guard !Task.isCancelled else { return }
            browser = result.0
            rows = result.1
            if !browser.sources.contains(source) { source = "" }
            page = 0
            indexing = false
        }
        .onChange(of: terminology.entries) { _ in clearEditor() }
    }

    private func clearEditor() { editing = nil; original = ""; replacement = "" }
    private func edit(_ row: VocabularyRow) {
        guard let current = VocabularyEdit(row: row, entries: terminology.entries) else {
            message = "The library changed. Choose the entry again."; error = true; return
        }
        editing = current
        original = current.original.original
        replacement = current.original.replacement ?? ""
    }
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
        if let editing {
            entry.aliases = editing.original.aliases
            entry.createdAt = editing.original.createdAt
            var entries = terminology.entries
            guard editing.replace(with: entry, in: &entries) else {
                clearEditor(); message = "The library changed. Choose the entry again."; error = true; return
            }
            terminology.entries = entries
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
                query = ""; source = VocabularyBrowser.sourceGroup(imported.source)
                message = "Read \(imported.entries.count) names."; error = false
            case .failure(let failure): message = failure.localizedDescription; error = true
            }
        }
    }
}

private struct VocabularyQuery: Equatable {
    let entries: [TerminologyEntry]
    let type: TerminologyEntryType
    let query: String
    let source: String
}
