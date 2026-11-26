import Foundation

struct AppConfig: Codable, Sendable, Equatable {
    var transcription: TranscriptionConfig = .init()
    var injection: InjectionConfig = .init()

    init() {
        transcription.provider = .doubaoIME
        transcription.textPolish.provider = .doubaoIME
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent(TranscriptionConfig.self, forKey: .transcription) {
            transcription = decoded
        } else {
            transcription = .init()
            transcription.provider = .chatGPTManagedAuth
            transcription.textPolish.provider = .chatGPTAuth
        }
        injection = try container.decodeIfPresent(InjectionConfig.self, forKey: .injection) ?? .init()
    }
}

enum TranscriptionProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case doubaoIME
    case chatGPTManagedAuth
    case deepSeek
    case openAICompatible

    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.doubaoIME.rawValue:
            self = .doubaoIME
        case "codexChatGPTBridge":
            self = .chatGPTManagedAuth
        case Self.chatGPTManagedAuth.rawValue:
            self = .chatGPTManagedAuth
        case Self.deepSeek.rawValue:
            self = .deepSeek
        case Self.openAICompatible.rawValue:
            self = .openAICompatible
        default:
            self = .chatGPTManagedAuth
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .doubaoIME:
            return "Doubao IME"
        case .chatGPTManagedAuth:
            return "ChatGPT Account"
        case .deepSeek:
            return "DeepSeek"
        case .openAICompatible:
            return "OpenAI-Compatible Recovery"
        }
    }

    var caption: String {
        switch self {
        case .doubaoIME:
            return "Audio goes to Doubao IME's private service. Configuration credentials stay in Keychain; no account Cookie is used. Availability and pricing are not guaranteed."
        case .chatGPTManagedAuth:
            return "ChatType signs in to ChatGPT directly and keeps its own session on this Mac."
        case .deepSeek:
            return "Complete recordings go to DeepSeek ASR through Markpipe using the Markpipe API key saved in Keychain."
        case .openAICompatible:
            return "Optional recovery route. Bring your own OpenAI-compatible API only if you want a separate endpoint."
        }
    }
}

enum LivePreviewProvider: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case automatic
    case doubaoIME
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "跟随识别服务"
        case .doubaoIME: return "豆包实时预览"
        case .appleSpeech: return "Apple 本机预览"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "豆包识别使用豆包预览；ChatGPT 识别在可用时使用 Apple 本机预览；DeepSeek 只显示录音状态。"
        case .doubaoIME:
            return "录音同时送往豆包实时接口；最终转写仍使用识别服务中的选择。"
        case .appleSpeech:
            return "录音只在本机预览；最终转写仍使用 ChatGPT 账户的完整录音路线。"
        }
    }

    func resolvedSource(
        for provider: TranscriptionProvider,
        applePreviewAvailable: Bool
    ) -> LivePreviewSource? {
        switch self {
        case .automatic:
            if provider == .doubaoIME { return .doubaoIME }
            if provider == .chatGPTManagedAuth, applePreviewAvailable { return .appleSpeech }
            return nil
        case .doubaoIME:
            return .doubaoIME
        case .appleSpeech:
            return provider == .chatGPTManagedAuth && applePreviewAvailable ? .appleSpeech : nil
        }
    }

    func recorderSampleRate(
        for provider: TranscriptionProvider,
        previewEnabled: Bool,
        configuredSampleRate: Int
    ) -> Int {
        guard provider == .doubaoIME || (previewEnabled && self == .doubaoIME) else {
            return configuredSampleRate
        }
        return 16_000
    }
}

enum LivePreviewSource: Sendable, Equatable {
    case doubaoIME
    case appleSpeech
}

enum TextPolishMode: String, Codable, Sendable, Equatable, CaseIterable {
    case automaticWhenKeyAvailable
    case disabled
    case always
}

enum TextPolishProviderID: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case doubaoIME
    case chatGPTAuth
    case glmFlash
    case qwenFlash
    case deepSeekFlash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubaoIME:
            return "Doubao IME"
        case .chatGPTAuth:
            return "ChatGPT Auth"
        case .glmFlash:
            return "GLM-4.7-Flash"
        case .qwenFlash:
            return "Qwen Flash"
        case .deepSeekFlash:
            return "DeepSeek Flash"
        }
    }
}

struct TextPolishConfig: Codable, Sendable, Equatable {
    var provider: TextPolishProviderID = .chatGPTAuth
    var mode: TextPolishMode = .automaticWhenKeyAvailable
    var chatGPTAuthEnabled: Bool = true
    var chatGPTResponseURL: String = "https://chatgpt.com/backend-api/codex/responses"
    var chatGPTResponseModel: String = "gpt-5.6-terra"
    var temperature: Double = 0.2
    var maxOutputTokens: Int = 1_200
    var glossaryBudgetCharacters: Int = 1_200
    var showCostEstimates: Bool = true

    var isEnabled: Bool { mode != .disabled && (provider != .chatGPTAuth || chatGPTAuthEnabled) }

    mutating func selectProvider(_ selection: TextPolishProviderID) {
        provider = selection
        if selection == .chatGPTAuth { chatGPTAuthEnabled = true }
    }

    mutating func setEnabled(_ enabled: Bool) {
        mode = enabled ? .automaticWhenKeyAvailable : .disabled
        if enabled && provider == .chatGPTAuth { chatGPTAuthEnabled = true }
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(TextPolishProviderID.self, forKey: .provider) ?? .chatGPTAuth
        mode = try container.decodeIfPresent(TextPolishMode.self, forKey: .mode) ?? .automaticWhenKeyAvailable
        chatGPTAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .chatGPTAuthEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .allowChatGPTAuthFallback)
            ?? true
        chatGPTResponseURL = try container.decodeIfPresent(String.self, forKey: .chatGPTResponseURL)
            ?? "https://chatgpt.com/backend-api/codex/responses"
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .chatGPTResponseModel)
            ?? "gpt-5.6-terra"
        chatGPTResponseModel = decodedModel == "gpt-5.5" ? "gpt-5.6-terra" : decodedModel
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 1_200
        glossaryBudgetCharacters = try container.decodeIfPresent(Int.self, forKey: .glossaryBudgetCharacters) ?? 1_200
        showCostEstimates = try container.decodeIfPresent(Bool.self, forKey: .showCostEstimates) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case mode
        case chatGPTAuthEnabled
        case chatGPTResponseURL
        case chatGPTResponseModel
        case temperature
        case maxOutputTokens
        case glossaryBudgetCharacters
        case showCostEstimates
        case allowChatGPTAuthFallback
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(mode, forKey: .mode)
        try container.encode(chatGPTAuthEnabled, forKey: .chatGPTAuthEnabled)
        try container.encode(chatGPTResponseURL, forKey: .chatGPTResponseURL)
        try container.encode(chatGPTResponseModel, forKey: .chatGPTResponseModel)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encode(glossaryBudgetCharacters, forKey: .glossaryBudgetCharacters)
        try container.encode(showCostEstimates, forKey: .showCostEstimates)
    }
}

struct TranscriptionConfig: Codable, Sendable, Equatable {
    var provider: TranscriptionProvider = .chatGPTManagedAuth
    var livePreviewEnabled: Bool = true
    var livePreviewProvider: LivePreviewProvider = .automatic
    var terminologyAlignmentEnabled: Bool = true
    var correctionRulesEnabled: Bool = true
    var hotkeyKeyCode: UInt32 = 96
    var hotkeyModifiers: UInt32 = 0
    var hotkeyIsCustomized: Bool = false
    var chatGPTURL: String = "https://chatgpt.com/backend-api/transcribe"
    var openAITranscriptionURL: String = "https://api.openai.com/v1/audio/transcriptions"
    var openAIModel: String = "gpt-4o-mini-transcribe"
    var openAIAuthTokenEnv: String = "OPENAI_API_KEY"
    var localFinalizationTimeoutSeconds: Double = 10
    var sampleRateHz: Int = 24_000
    var maxDurationSeconds: Int = 120
    var hintTerms: [String] = []
    var speechCleanupEnabled: Bool = true
    var feedbackSoundsEnabled: Bool = true
    var terminology: TerminologyConfig = .init()
    var textPolish: TextPolishConfig = .init()

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedProvider = try container.decodeIfPresent(TranscriptionProvider.self, forKey: .provider) {
            provider = decodedProvider
        } else {
            provider = .chatGPTManagedAuth
        }
        hotkeyKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .hotkeyKeyCode) ?? 96
        hotkeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .hotkeyModifiers) ?? 0
        hotkeyIsCustomized = try container.decodeIfPresent(Bool.self, forKey: .hotkeyIsCustomized) ?? false
        livePreviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .livePreviewEnabled) ?? true
        livePreviewProvider = try container.decodeIfPresent(LivePreviewProvider.self, forKey: .livePreviewProvider) ?? .automatic
        terminologyAlignmentEnabled = try container.decodeIfPresent(Bool.self, forKey: .terminologyAlignmentEnabled) ?? true
        correctionRulesEnabled = try container.decodeIfPresent(Bool.self, forKey: .correctionRulesEnabled) ?? true
        chatGPTURL = try container.decodeIfPresent(String.self, forKey: .chatGPTURL) ?? "https://chatgpt.com/backend-api/transcribe"
        openAITranscriptionURL = try container.decodeIfPresent(String.self, forKey: .openAITranscriptionURL) ?? "https://api.openai.com/v1/audio/transcriptions"
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4o-mini-transcribe"
        openAIAuthTokenEnv = try container.decodeIfPresent(String.self, forKey: .openAIAuthTokenEnv) ?? "OPENAI_API_KEY"
        localFinalizationTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .localFinalizationTimeoutSeconds) ?? 10
        sampleRateHz = try container.decodeIfPresent(Int.self, forKey: .sampleRateHz) ?? 24_000
        maxDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .maxDurationSeconds) ?? 120
        hintTerms = try container.decodeIfPresent([String].self, forKey: .hintTerms) ?? []
        speechCleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .speechCleanupEnabled) ?? true
        feedbackSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .feedbackSoundsEnabled) ?? true
        terminology = try container.decodeIfPresent(TerminologyConfig.self, forKey: .terminology) ?? .init()
        // Missing old settings must retain their original account destination.
        if let decoded = try container.decodeIfPresent(TextPolishConfig.self, forKey: .textPolish) {
            textPolish = decoded
        } else {
            textPolish = .init()
            textPolish.provider = .chatGPTAuth
        }
    }

    var activeDictionaryEntries: [TerminologyEntry] {
        terminology.entries
    }

    var needsChatGPT: Bool {
        provider == .chatGPTManagedAuth || (textPolish.isEnabled && textPolish.provider == .chatGPTAuth)
    }

    var prioritizedHintTerms: [String] {
        hintTerms + VocabularyIndexCache.shared.index(for: activeDictionaryEntries).userChineseTerms
    }

    var promptHintTerms: [String] {
        VocabularyIndexCache.shared.index(for: activeDictionaryEntries).asrHints(priorities: prioritizedHintTerms)
    }

}

struct TerminologyConfig: Codable, Sendable, Equatable {
    var entries: [TerminologyEntry] = []
    var lastImportedSource: String?
    var lastImportedAt: String?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try container.decodeIfPresent([TerminologyEntry].self, forKey: .entries) ?? []
        let legacyImportedEntries = try container.decodeIfPresent([TerminologyEntry].self, forKey: .importedEntries) ?? []
        entries = TerminologyPolicy.sanitizedEntries(
            decodedEntries.isEmpty ? legacyImportedEntries : decodedEntries
        )
        lastImportedSource = Self.normalizedImportedSource(
            try container.decodeIfPresent(String.self, forKey: .lastImportedSource)
        )
        lastImportedAt = try container.decodeIfPresent(String.self, forKey: .lastImportedAt)
    }

    private static func normalizedImportedSource(_ source: String?) -> String? {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if source.localizedCaseInsensitiveContains("TypeWhisper") {
            return nil
        }

        return source
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(lastImportedSource, forKey: .lastImportedSource)
        try container.encodeIfPresent(lastImportedAt, forKey: .lastImportedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case importedEntries
        case lastImportedSource
        case lastImportedAt
    }
}

enum TerminologyEntryType: String, Codable, Sendable, Equatable, CaseIterable {
    case term
    case correction

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.correction.rawValue:
            self = .correction
        case Self.term.rawValue, "suggestion":
            self = .term
        default:
            self = .term
        }
    }
}

struct TerminologyEntry: Codable, Sendable, Equatable {
    var type: TerminologyEntryType
    var original: String
    var replacement: String?
    var aliases: [String]
    var source: String
    var usageCount: Int
    var createdAt: String

    var canonical: String {
        switch type {
        case .term:
            return original
        case .correction:
            return replacement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? replacement!
                : original
        }
    }

    init(
        type: TerminologyEntryType,
        original: String,
        replacement: String?,
        aliases: [String],
        source: String,
        usageCount: Int,
        createdAt: String
    ) {
        self.type = type
        self.original = original
        self.replacement = replacement
        self.aliases = aliases
        self.source = source
        self.usageCount = usageCount
        self.createdAt = createdAt
    }

    init(
        canonical: String,
        aliases: [String],
        source: String = "dictionary-import"
    ) {
        self.init(
            type: .term,
            original: canonical,
            replacement: nil,
            aliases: aliases,
            source: source,
            usageCount: 0,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? TerminologyEntryType.term.rawValue
        type = rawType == TerminologyEntryType.correction.rawValue ? .correction : .term
        original = try container.decodeIfPresent(String.self, forKey: .original)
            ?? container.decodeIfPresent(String.self, forKey: .canonical)
            ?? ""
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        let decodedSource = try container.decodeIfPresent(String.self, forKey: .source) ?? "dictionary-import"
        source = Self.normalizedSource(rawType: rawType, source: decodedSource)
        usageCount = try container.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? ISO8601DateFormatter().string(from: Date())
    }

    private static func normalizedSource(rawType: String, source: String) -> String {
        if rawType == "suggestion", source == "auto-suggestion" {
            return "legacy-import"
        }

        if source == "typewhisper-import" || source.localizedCaseInsensitiveContains("TypeWhisper") {
            return "dictionary-import"
        }

        return source
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(original, forKey: .original)
        try container.encodeIfPresent(replacement, forKey: .replacement)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(source, forKey: .source)
        try container.encode(usageCount, forKey: .usageCount)
        try container.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case original
        case replacement
        case aliases
        case source
        case usageCount
        case createdAt
        case canonical
    }
}

struct InjectionConfig: Codable, Sendable, Equatable {
    var clipboardOnly: Bool = false
    var preserveClipboard: Bool = false
    var restoreDelayMilliseconds: UInt64 = 350

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preserveClipboard = try container.decodeIfPresent(Bool.self, forKey: .preserveClipboard) ?? false
        clipboardOnly = try container.decodeIfPresent(Bool.self, forKey: .clipboardOnly) ?? false
        restoreDelayMilliseconds = try container.decodeIfPresent(UInt64.self, forKey: .restoreDelayMilliseconds) ?? 350
    }
}

enum ConfigError: LocalizedError {
    case invalidPromptOutput

    var errorDescription: String? {
        switch self {
        case .invalidPromptOutput:
            return "转写提示词返回了空文本。"
        }
    }
}

struct ConfigStore {
    let fileManager: FileManager
    let homeDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
    }

    var directoryURL: URL {
        homeDirectoryURL
            .appendingPathComponent("Library/Application Support/ChatType", isDirectory: true)
    }

    var configURL: URL {
        directoryURL.appendingPathComponent("config.json")
    }

    func load() throws -> AppConfig {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: configURL.path) else {
            let config = AppConfig()
            try save(config)
            return config
        }

        let data = try Data(contentsOf: configURL)
        // Preserve original bytes before the decoder migrates legacy input-method shortcuts.
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let transcription = root["transcription"] as? [String: Any],
           let terminology = transcription["terminology"] as? [String: Any] {
            let entries = (terminology["entries"] as? [[String: Any]] ?? [])
                + (terminology["importedEntries"] as? [[String: Any]] ?? [])
            if entries.contains(where: { $0["source"] as? String == "macos-text-replacements" && $0["type"] as? String == "correction" }) {
                let backup = directoryURL.appendingPathComponent("config-before-keyboard-shortcut-migration.json")
                if !fileManager.fileExists(atPath: backup.path) {
                    let descriptor = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
                    catch { try? fileManager.removeItem(at: backup); throw error }
                } else {
                    // A directory or an unrelated file must never masquerade as a recovery copy.
                    guard (try? Data(contentsOf: backup)) == data else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }
            }
        }
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try save(config)
        return config
    }

    func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
