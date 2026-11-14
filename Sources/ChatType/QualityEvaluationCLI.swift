import Foundation

/// Explicit file evaluation reuses production post-processing without microphone or insertion.
enum QualityEvaluationCLI {
    private struct Suite: Decodable {
        let schemaVersion: Int
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let audio: String
        let kind: String
        let durationSeconds: Double
    }

    private struct CapturedASR: Decodable {
        let `case`: String
        let model: String
        let revision: String
        let run: Int
        let status: String
        let text: String?
        let asrMs: Int
        let errorType: String?
    }

    private struct FileReplay: Transcriber {
        let text: String
        let durationMs: Int
        let asrMs: Int
        let engine: String

        func transcribe(_ audio: RecordedAudio) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, metrics: TranscriptionMetrics(
                provider: .openAICompatible,
                audioDurationMs: durationMs, audioBytes: 0, authMs: 0,
                transcribeMs: asrMs, promptIncluded: true, uploadFormat: engine
            ))
        }
    }

    enum EvaluationError: LocalizedError {
        case invalidArguments
        case invalidSuite
        case unknownCase
        case outputExists
        case unapprovedProvider

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "quality-evaluate requires --suite PATH --output PATH, with optional --captured-asr PATH and --rounds N."
            case .invalidSuite: "Unsupported quality suite."
            case .unknownCase: "Captured ASR refers to a case outside the quality suite."
            case .outputExists: "Quality output already exists; choose a new output path to preserve evidence."
            case .unapprovedProvider: "Quality comparison requires the approved ChatGPT account route and ChatGPT Auth polish."
            }
        }
    }

    static func run(arguments: [String]) async throws {
        var options: [String: String] = [:]
        var position = 0
        while position < arguments.count {
            guard ["--suite", "--output", "--captured-asr", "--rounds", "--config-snapshot", "--context-output", "--resume-from"].contains(arguments[position]),
                  position + 1 < arguments.count else { throw EvaluationError.invalidArguments }
            options[arguments[position]] = arguments[position + 1]
            position += 2
        }
        guard let suitePath = options["--suite"], let outputPath = options["--output"],
              let rounds = Int(options["--rounds"] ?? "3"), rounds > 0 else {
            throw EvaluationError.invalidArguments
        }
        let suiteURL = URL(fileURLWithPath: suitePath)
        let decoder = JSONDecoder()
        let suite = try decoder.decode(Suite.self, from: Data(contentsOf: suiteURL))
        guard suite.schemaVersion == 1, !suite.cases.isEmpty,
              Set(suite.cases.map(\.id)).count == suite.cases.count else { throw EvaluationError.invalidSuite }
        var completed = Set<String>()
        if let path = options["--resume-from"] {
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      row["status"] as? String == "success", let model = row["model"] as? String,
                      let id = row["case"] as? String, let run = row["run"] as? Int else { continue }
                completed.insert("\(model)|\(run)|\(id)")
            }
        }
        let captured: [CapturedASR]
        if let path = options["--captured-asr"] {
            captured = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
                try decoder.decode(CapturedASR.self, from: Data($0.utf8))
            }
            guard !captured.isEmpty else { throw EvaluationError.invalidSuite }
        } else {
            captured = []
        }
        let config: AppConfig
        if let path = options["--config-snapshot"] {
            config = try decoder.decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            config = try ConfigStore().load()
        }
        guard config.transcription.provider == .chatGPTManagedAuth,
              config.transcription.textPolish.provider == .chatGPTAuth,
              config.transcription.textPolish.mode != .disabled else {
            throw EvaluationError.unapprovedProvider
        }
        if let path = options["--context-output"] {
            let prompt = TranscriptionPromptBuilder().buildPrompt(
                hintTerms: config.transcription.prioritizedHintTerms + config.transcription.promptHintTerms)
            let hints = prompt.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            let url = URL(fileURLWithPath: path)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw EvaluationError.outputExists }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(hints).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let auth = ChatGPTAuthManager()
        let outputURL = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw EvaluationError.outputExists }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let cases = Dictionary(uniqueKeysWithValues: suite.cases.map { ($0.id, $0) })
        let count = options["--captured-asr"] == nil ? rounds * suite.cases.count : captured.count
        for index in 0..<count {
            let entry = captured.isEmpty ? nil : captured[index]
            let fixture: Case
            if let entry {
                guard let found = cases[entry.case] else { throw EvaluationError.unknownCase }
                fixture = found
            } else {
                fixture = suite.cases[index % suite.cases.count]
            }
            let audioURL = suiteURL.deletingLastPathComponent().appendingPathComponent(fixture.audio)
            let audio = RecordedAudio(fileURL: audioURL, durationMs: Int(fixture.durationSeconds * 1000))
            let model = entry?.model ?? "chatgpt-account-asr"
            let run = entry?.run ?? (index / suite.cases.count + 1)
            if completed.contains("\(model)|\(run)|\(fixture.id)") { continue }
            var row: [String: Any] = ["case": fixture.id, "kind": fixture.kind,
                "model": model, "revision": entry?.revision ?? "private-backend-unspecified",
                "run": run, "mode": entry == nil ? "file-live-asr-pipeline" : "captured-asr-postprocess",
                "durationSeconds": fixture.durationSeconds,
                "polishModel": config.transcription.textPolish.chatGPTResponseModel]
            if let entry, entry.status != "success" || entry.text == nil {
                row["status"] = "asr-failed"
                row["errorType"] = entry.errorType ?? "CapturedASRFailure"
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A]))
                try output.synchronize()
                continue
            }
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                let transcriber: any Transcriber
                if let entry {
                    guard let text = entry.text else {
                        throw EvaluationError.invalidSuite
                    }
                    // Captured data came from the local OpenAI-compatible file transport.
                    transcriber = FileReplay(text: text, durationMs: audio.durationMs,
                                             asrMs: entry.asrMs, engine: model)
                } else {
                    transcriber = ChatGPTTranscriber(authManager: auth, config: config.transcription,
                                                     usesLocalSpeechForFiles: false)
                }
                let pipeline = DictationPipeline(transcriber: transcriber,
                    normalizer: TerminologyNormalizer(), importedEntries: config.transcription.activeDictionaryEntries,
                    hintTerms: config.transcription.prioritizedHintTerms,
                    textPolisher: OpenAICompatibleTextPolisher(config: config.transcription.textPolish,
                        chatGPTAuthProvider: auth, chatGPTAuthAvailable: auth.authSnapshot().state == .ready))
                let result = try await pipeline.prepare(audio: audio)
                row["status"] = "success"
                row["rawText"] = result.rawText
                row["finalText"] = result.finalText
                row["asrMs"] = result.metrics.transcription.transcribeMs
                row["polishMs"] = result.metrics.polishMs
                row["polishAttempted"] = result.metrics.textPolishAttempted
                row["polishFallback"] = result.metrics.textPolishErrorMessage != nil
                row["polishProvider"] = result.metrics.textPolishProvider?.rawValue ?? "none"
            } catch {
                row["status"] = "failed"
                row["errorType"] = String(describing: type(of: error))
                row["errorDomain"] = (error as NSError).domain
                row["errorCode"] = (error as NSError).code
                row[entry == nil ? "filePipelineMs" : "postprocessReplayMs"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                try output.write(contentsOf: data + Data([0x0A]))
                try output.synchronize()
                if (error as NSError).domain == NSURLErrorDomain { continue }
                throw error
            }
            row[entry == nil ? "filePipelineMs" : "postprocessReplayMs"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if let entry { row["capturedASRMs"] = entry.asrMs }
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([0x0A]))
            try output.synchronize()
            print("Quality case \(index + 1)/\(count): \(fixture.id) \(model)")
        }
    }
}
