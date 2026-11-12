import CryptoKit
import Foundation

/// Explicit text-only research entry. It never records, inserts text or saves configuration.
enum PolishEvaluationCLI {
    struct Fixture: Decodable {
        let id: String
        let text: String
        let group: String
    }
    struct Suite: Decodable {
        let schemaVersion: Int
        let cases: [Fixture]
    }
    struct Candidate: Sendable {
        let id: String
        let model: String
        let effort: String
        let style: TextPolishPromptBuilder.Style
    }
    static let candidates: [Candidate] = [
        Candidate(id: "terra-standard", model: "gpt-6.1-terra", effort: "none", style: .standard),
        Candidate(id: "terra-compact", model: "gpt-6.1-terra", effort: "none", style: .compactEditing),
        Candidate(id: "sol-standard", model: "gpt-6.1-sol", effort: "low", style: .standard),
        Candidate(id: "sol-compact", model: "gpt-6.1-sol", effort: "low", style: .compactEditing),
        Candidate(id: "luna-standard", model: "gpt-6-luna", effort: "none", style: .standard),
        Candidate(id: "luna-compact", model: "gpt-6-luna", effort: "none", style: .compactEditing),
    ]
    enum EvaluationError: Error {
        case invalidArguments, invalidSuite, unapprovedProvider, outputExists
    }

    static func selectedCandidates(_ names: String?) throws -> [Candidate] {
        guard let names else { return candidates }
        let ids = names.split(separator: ",").map(String.init)
        guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ id in candidates.contains { $0.id == id } }) else {
            throw EvaluationError.invalidArguments
        }
        return ids.compactMap { id in candidates.first { $0.id == id } }
    }

    static func run(arguments: [String]) async throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard ["--suite", "--output", "--config-snapshot", "--candidates", "--rounds", "--prepare-only"].contains(arguments[index]),
                  index + 1 < arguments.count, options[arguments[index]] == nil else {
                throw EvaluationError.invalidArguments
            }
            options[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let suitePath = options["--suite"], let outputPath = options["--output"],
              let configPath = options["--config-snapshot"],
              let rounds = Int(options["--rounds"] ?? "1"), rounds > 0 else {
            throw EvaluationError.invalidArguments
        }
        let selected = try selectedCandidates(options["--candidates"])
        if let value = options["--prepare-only"], value != "1" { throw EvaluationError.invalidArguments }
        let prepareOnly = options["--prepare-only"] == "1"
        let suiteBytes = try Data(contentsOf: URL(fileURLWithPath: suitePath))
        let suite = try JSONDecoder().decode(Suite.self, from: suiteBytes)
        guard suite.schemaVersion == 1, !suite.cases.isEmpty,
              Set(suite.cases.map(\.id)).count == suite.cases.count,
              suite.cases.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EvaluationError.invalidSuite
        }
        let configBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try JSONDecoder().decode(AppConfig.self, from: configBytes)
        guard config.transcription.textPolish.provider == .chatGPTAuth,
              config.transcription.textPolish.mode != .disabled,
              OpenAICompatibleTextPolisher.isAuditedChatGPTURL(config.transcription.textPolish.chatGPTResponseURL) else {
            throw EvaluationError.unapprovedProvider
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        let manifestURL = outputURL.appendingPathExtension("manifest.json")
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              !FileManager.default.fileExists(atPath: manifestURL.path) else { throw EvaluationError.outputExists }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let manifest: [String: Any] = ["scope": prepareOnly ? "offline exact prompt export; no authentication or network request" : "fixed-ASR-text polish only; no microphone, ASR request or insertion",
            "suiteSHA256": hash(suiteBytes), "configSHA256": hash(configBytes),
            "cases": suite.cases.map(\.id), "rounds": rounds,
            "candidates": selected.map { ["id": $0.id, "model": $0.model, "effort": $0.effort, "style": $0.style.rawValue] },
            "expectedCaseRuns": rounds * suite.cases.count * selected.count]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let entries = config.transcription.activeDictionaryEntries
        let alignmentEntries = entries.filter { $0.type == .term || ($0.type == .correction && $0.original == $0.replacement) }
        let normalizer = TerminologyNormalizer()
        // Prepare exactly the same input/hints for every candidate; excluded from model latency.
        let inputs = suite.cases.map { fixture in
            let hints = config.transcription.prioritizedHintTerms + PersonalNameHints.relatedTerms(in: fixture.text, entries: entries)
            return (hints, normalizer.normalize(text: fixture.text, importedEntries: alignmentEntries, hintTerms: hints).text)
        }
        if prepareOnly {
            for (caseIndex, fixture) in suite.cases.enumerated() {
                for candidate in selected {
                    let messages = TextPolishPromptBuilder(style: candidate.style).buildMessages(
                        transcript: inputs[caseIndex].1, terminologyEntries: alignmentEntries,
                        config: config.transcription.textPolish, priorityTerms: inputs[caseIndex].0)
                    let row: [String: Any] = ["case": fixture.id, "group": fixture.group,
                        "candidate": candidate.id, "promptStyle": candidate.style.rawValue,
                        "sourceASRText": fixture.text, "polishInputText": inputs[caseIndex].1,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] }]
                    try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A]))
                }
            }
            try output.synchronize()
            return
        }
        let auth = ChatGPTAuthManager()
        await auth.prewarmSession()
        var failedModels = Set<String>()
        for run in 1...rounds {
            for (caseIndex, fixture) in suite.cases.enumerated() {
                let offset = (run - 1 + caseIndex) % selected.count
                let order = Array(selected[offset...]) + Array(selected[..<offset])
                for candidate in order where !failedModels.contains(candidate.model) {
                    try Task.checkCancellation()
                    var polishConfig = config.transcription.textPolish
                    polishConfig.chatGPTResponseModel = candidate.model
                    let polisher = OpenAICompatibleTextPolisher(config: polishConfig, chatGPTAuthProvider: auth,
                        chatGPTAuthAvailable: auth.authSnapshot().state == .ready,
                        promptBuilder: TextPolishPromptBuilder(style: candidate.style), reasoningEffort: candidate.effort)
                    let trace = ProcessingTiming()
                    let started = ProcessingTiming.now()
                    var row: [String: Any] = ["case": fixture.id, "group": fixture.group, "run": run,
                        "candidate": candidate.id, "requestedModel": candidate.model, "effort": candidate.effort,
                        "promptStyle": candidate.style.rawValue, "sourceASRText": fixture.text,
                        "polishInputText": inputs[caseIndex].1, "inputSHA256": hash(Data(inputs[caseIndex].1.utf8))]
                    do {
                        let result = try await ProcessingTrace.$current.withValue(trace) {
                            try await polisher.polish(text: inputs[caseIndex].1,
                                terminologyEntries: alignmentEntries, hintTerms: inputs[caseIndex].0)
                        }
                        row["polishMs"] = ProcessingTiming.milliseconds(since: started)
                        row["polishOutputText"] = result.text
                        let aligned = normalizer.normalize(text: result.text, importedEntries: alignmentEntries, hintTerms: inputs[caseIndex].0).text
                        let corrected = normalizer.applyCorrections(text: aligned, entries: entries).text
                        row["finalText"] = DictationTextFormatter().format(corrected)
                        row["status"] = "success"
                    } catch {
                        row["polishMs"] = ProcessingTiming.milliseconds(since: started)
                        row["status"] = "failed"
                        row["errorType"] = String(describing: type(of: error))
                        failedModels.insert(candidate.model)
                    }
                    row["textReadyMs"] = ProcessingTiming.milliseconds(since: started)
                    let snapshot = trace.snapshot()
                    row["timing"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
                    try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A]))
                    try output.synchronize()
                    print("Polish evaluation: \(fixture.id) \(candidate.id) run\(run) \(row["status"] ?? "unknown")")
                    // A forbidden/challenge result stops all requests to this shared account host.
                    if snapshot.polishCalls.flatMap(\.httpAttempts).contains(where: { $0.statusCode == 403 }) { return }
                }
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
