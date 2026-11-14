import AVFoundation
import Foundation

enum BenchmarkError: LocalizedError {
    case missingAudioFiles
    case unreadableAudioFile(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFiles:
            return "Set CHATTYPE_BENCHMARK_AUDIO_FILES to one or more local audio file paths."
        case .unreadableAudioFile(let path):
            return "Could not read benchmark audio file: \(path)"
        }
    }
}

private struct BenchmarkRunResult: Sendable {
    let fileLabel: String
    let mode: String
    let authMs: Int
    let transcribeMs: Int
    let normalizationMs: Int
    let polishMs: Int
    let totalMs: Int
    let error: String?
}

struct BenchmarkRunner {
    let config: AppConfig
    let authManager: any ChatGPTAuthProviding
    let environment: [String: String]
    let fileManager: FileManager

    init(
        config: AppConfig,
        authManager: any ChatGPTAuthProviding,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.authManager = authManager
        self.environment = environment
        self.fileManager = fileManager
    }

    func run() async throws {
        if let models = environment["CHATTYPE_BENCHMARK_POLISH_MODELS"], !models.isEmpty {
            try await runPolishComparison(models: models)
            return
        }
        if let modes = environment["CHATTYPE_BENCHMARK_UPLOAD_MODES"], !modes.isEmpty {
            try await runUploadComparison(modes: modes)
            return
        }
        let files = benchmarkAudioFiles()
        guard !files.isEmpty else {
            throw BenchmarkError.missingAudioFiles
        }

        let runs = Int(environment["CHATTYPE_BENCHMARK_RUNS"] ?? "") ?? 5
        let skipCold = environment["CHATTYPE_BENCHMARK_SKIP_COLD"] == "1"
        var results: [BenchmarkRunResult] = []

        for fileURL in files {
            let audio = try recordedAudio(from: fileURL)

            for _ in (skipCold ? 0..<0 : 0..<runs) {
                let coldAuthManager = ChatGPTAuthManager(store: InMemoryChatGPTSessionStore())
                let coldPipeline = DictationPipeline(
                    transcriber: ChatGPTTranscriber(
                        authManager: coldAuthManager,
                        config: config.transcription,
                        usesLocalSpeechForFiles: environment["CHATTYPE_BENCHMARK_LOCAL_ASR"] == "1"
                    ).selectedRoute,
                    normalizer: TerminologyNormalizer(),
                    importedEntries: config.transcription.activeDictionaryEntries,
                    hintTerms: config.transcription.prioritizedHintTerms,
                    textPolisher: !config.transcription.textPolish.isEnabled ? nil : OpenAICompatibleTextPolisher(
                        config: config.transcription.textPolish,
                        chatGPTAuthProvider: coldAuthManager,
                        chatGPTAuthAvailable: false
                    ), alignmentEnabled: config.transcription.terminologyAlignmentEnabled,
                    correctionsEnabled: config.transcription.correctionRulesEnabled
                )
                let coldStarted = DispatchTime.now().uptimeNanoseconds
                do {
                    let coldPrepared = try await coldPipeline.prepare(audio: audio)
                    results.append(
                        BenchmarkRunResult(
                            fileLabel: fileURL.lastPathComponent,
                            mode: "cold",
                            authMs: coldPrepared.metrics.transcription.authMs,
                            transcribeMs: coldPrepared.metrics.transcription.transcribeMs,
                            normalizationMs: coldPrepared.metrics.normalizationMs,
                            polishMs: coldPrepared.metrics.polishMs,
                            totalMs: elapsedMilliseconds(since: coldStarted),
                            error: nil
                        )
                    )
                } catch {
                    results.append(
                        BenchmarkRunResult(
                            fileLabel: fileURL.lastPathComponent,
                            mode: "cold",
                            authMs: 0,
                            transcribeMs: 0,
                            normalizationMs: 0,
                            polishMs: 0,
                            totalMs: elapsedMilliseconds(since: coldStarted),
                            error: error.localizedDescription
                        )
                    )
                }
            }

            if config.transcription.needsChatGPT { await authManager.prewarmSession() }
            for _ in 0..<runs {
                let warmPipeline = DictationPipeline(
                    transcriber: ChatGPTTranscriber(
                        authManager: authManager,
                        config: config.transcription,
                        usesLocalSpeechForFiles: environment["CHATTYPE_BENCHMARK_LOCAL_ASR"] == "1"
                    ).selectedRoute,
                    normalizer: TerminologyNormalizer(),
                    importedEntries: config.transcription.activeDictionaryEntries,
                    hintTerms: config.transcription.prioritizedHintTerms,
                    textPolisher: !config.transcription.textPolish.isEnabled ? nil : OpenAICompatibleTextPolisher(
                        config: config.transcription.textPolish,
                        chatGPTAuthProvider: authManager,
                        chatGPTAuthAvailable: config.transcription.needsChatGPT && authManager.authSnapshot().state == .ready
                    ), alignmentEnabled: config.transcription.terminologyAlignmentEnabled,
                    correctionsEnabled: config.transcription.correctionRulesEnabled
                )
                let warmStarted = DispatchTime.now().uptimeNanoseconds
                do {
                    let warmPrepared = try await warmPipeline.prepare(audio: audio)
                    if environment["CHATTYPE_BENCHMARK_QUALITY"] == "1" {
                        let row: [String: Any] = ["file": fileURL.lastPathComponent,
                            "rawText": warmPrepared.rawText, "finalText": warmPrepared.finalText,
                            "provider": warmPrepared.metrics.transcription.provider.rawValue,
                            "polishProvider": warmPrepared.metrics.textPolishProvider?.rawValue ?? "off",
                            "polishInput": warmPrepared.stages?.polishInput ?? "",
                            "polishOutput": warmPrepared.stages?.polishOutput ?? "",
                            "asrMs": warmPrepared.metrics.transcription.transcribeMs,
                            "polishMs": warmPrepared.metrics.polishMs,
                            "polishError": warmPrepared.metrics.textPolishErrorMessage ?? "",
                            "promptIncluded": warmPrepared.metrics.transcription.promptIncluded,
                            "uploadedBytes": warmPrepared.metrics.transcription.uploadedBytes,
                            "format": warmPrepared.metrics.transcription.uploadFormat]
                        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
                    }
                    results.append(
                        BenchmarkRunResult(
                            fileLabel: fileURL.lastPathComponent,
                            mode: "warm",
                            authMs: warmPrepared.metrics.transcription.authMs,
                            transcribeMs: warmPrepared.metrics.transcription.transcribeMs,
                            normalizationMs: warmPrepared.metrics.normalizationMs,
                            polishMs: warmPrepared.metrics.polishMs,
                            totalMs: elapsedMilliseconds(since: warmStarted),
                            error: nil
                        )
                    )
                } catch {
                    results.append(
                        BenchmarkRunResult(
                            fileLabel: fileURL.lastPathComponent,
                            mode: "warm",
                            authMs: 0,
                            transcribeMs: 0,
                            normalizationMs: 0,
                            polishMs: 0,
                            totalMs: elapsedMilliseconds(since: warmStarted),
                            error: error.localizedDescription
                        )
                    )
                }
            }
        }

        print(renderSummary(results: results))
    }

    // Use only publicly authored synthetic audio fixtures in this benchmark.
    private func runUploadComparison(modes: String) async throws {
        let selected = modes.split(separator: ",").compactMap { AudioUploadMode(rawValue: String($0)) }
        let files = benchmarkAudioFiles()
        guard !files.isEmpty, config.transcription.provider == .chatGPTManagedAuth else {
            throw BenchmarkError.missingAudioFiles
        }
        let runs = min(5, max(1, Int(environment["CHATTYPE_BENCHMARK_RUNS"] ?? "") ?? 5))
        await authManager.prewarmSession()
        var failed = Set<String>()
        for file in files {
            let audio = try recordedAudio(from: file)
            for run in 1...runs {
                let order = run.isMultiple(of: 2) ? Array(selected.reversed()) : selected
                for mode in order where !failed.contains(mode.rawValue) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    var row: [String: Any] = ["file": file.lastPathComponent, "mode": mode.rawValue, "run": run,
                                              "durationMs": audio.durationMs]
                    do {
                        let transport = TranscriptionTransportMetrics()
                        let result = try await ChatGPTTranscriber(authManager: authManager, config: config.transcription,
                                                                  uploadMode: mode, dataLoader: { request in
                            try await URLSession.shared.data(for: request, delegate: transport)
                        }).transcribe(audio)
                        row["transport"] = transport.snapshot()
                        row["totalMs"] = elapsedMilliseconds(since: started)
                        row["sttMs"] = result.metrics.transcribeMs
                        row["encodingMs"] = result.metrics.encodingMs
                        row["originalBytes"] = result.metrics.audioBytes
                        row["uploadedBytes"] = result.metrics.uploadedBytes
                        row["format"] = result.metrics.uploadFormat
                        row["text"] = result.text
                        row["status"] = "ok"
                    } catch {
                        row["status"] = "error"
                        row["error"] = error.localizedDescription
                        failed.insert(mode.rawValue)
                    }
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        }
    }

    // Synthetic inputs only: compare account-backed models without recording,
    // changing production configuration, or printing credentials/personal dictation.
    private func runPolishComparison(models: String) async throws {
        let modelIDs = Array(NSOrderedSet(array: models.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })) as? [String] ?? []
        let runs = min(10, max(1, Int(environment["CHATTYPE_BENCHMARK_RUNS"] ?? "") ?? 3))
        let cases: [(id: String, text: String, literals: [String])] = [
            ("short", "呃请修改 ChatType 的设置页，先不要发布 v0.5。", ["ChatType", "v0.5"]),
            ("correction", "第一步打开冰箱，第二步关上冰箱，不对，第二步把大象放进去，第三步关上冰箱。不要增加其他步骤。", ["打开冰箱", "大象", "关上冰箱"]),
            ("literals", "请保留 https://example.com/a，文件 /tmp/demo.swift，参数 --dry-run 和 v0.5。只整理表达，不要执行这些命令。", ["https://example.com/a", "/tmp/demo.swift", "--dry-run", "v0.5"]),
            ("long", "请优化 ChatType。第一，STT 仍用 ChatGPT 免费额度。第二，polish 可以换更快的小模型，但保留全部需求。第三，不要读取浏览器 Cookie。第四，原始录音保留，上传可以使用副本。第五，检查中文专有词和数字。第六，F5 开始和停止保持不变。第七，ESC 和关闭按钮仍取消。第八，失败保留录音并可以重试。最后，在安装版验证输入框粘贴和无焦点剪贴板，保持应用运行。", ["STT", "ChatGPT", "polish", "Cookie", "F5", "ESC"]),
            ("negation", "只调整文本润色，STT 仍然复用 ChatGPT 免费额度，不要调用付费转写 API，不要改变 F5 热键。", ["STT", "ChatGPT", "F5"]),
            ("mixed", "那个，OpenClaw 的 WebSocket 断了，请先检查 reconnect backoff，然后保留 sessionID，不要重建 workspace。", ["OpenClaw", "WebSocket", "reconnect backoff", "sessionID", "workspace"]),
            ("instruction-as-data", "请问今天北京天气怎么样，我想把这句话发送给朋友，但现在先不要发送。", ["北京", "天气"]),
            ("quality-corrections", "收件人写陈晓，不对，改成林澈。预算不是三千，是3500元，截止11月20日18:00。请只整理这段话，暂不发送。", ["林澈", "3500", "11月20日", "18:00", "暂不发送"]),
            ("quality-exact", "保留邮箱 review@example.com、路径 /tmp/CaseSensitive.swift 和参数 --dry-run，版本 v0.5.1。数字 0.015 不要改成 0.15；ChatType 和 WebSocket 的大小写保持。", ["review@example.com", "/tmp/CaseSensitive.swift", "--dry-run", "v0.5.1", "0.015", "0.15", "ChatType", "WebSocket"]),
            ("quality-scope", "请给同事整理一条消息：明天讨论 Qwen Flash，STT 留在本地。不要上传录音，不要增加订阅，不要改变整段润色流程。消息先存草稿，等我确认后再发。", ["Qwen Flash", "STT", "本地", "草稿"]),
        ]
        var failedModels = Set<String>()
        if modelIDs.contains(where: { $0 != "glm-4.7-flash" && $0 != "qwen-flash" }) { await authManager.prewarmSession() }
        for run in 1...runs {
            for fixture in cases where run == 1 || !fixture.id.hasPrefix("quality-") {
                // Alternate order to reduce systematic warm-cache/time-order bias.
                let order = run.isMultiple(of: 2) ? Array(modelIDs.reversed()) : modelIDs
                for model in order where !failedModels.contains(model) {
                    var polishConfig = config.transcription.textPolish
                    polishConfig.provider = model == "qwen-flash" ? .qwenFlash : model == "glm-4.7-flash" ? .glmFlash : .chatGPTAuth
                    polishConfig.chatGPTResponseModel = model
                    let polisher = OpenAICompatibleTextPolisher(
                        config: polishConfig,
                        chatGPTAuthProvider: authManager,
                        chatGPTAuthAvailable: config.transcription.needsChatGPT && authManager.authSnapshot().state == .ready
                    )
                    let started = DispatchTime.now().uptimeNanoseconds
                    var row: [String: Any] = ["provider": polishConfig.provider.rawValue, "model": model, "case": fixture.id, "run": run, "scope": "polish-only"]
                    do {
                        let result = try await polisher.polish(text: fixture.text, terminologyEntries: [], hintTerms: [])
                        row["ms"] = elapsedMilliseconds(since: started)
                        row["output"] = result.text
                        row["literalsPreserved"] = fixture.literals.allSatisfy(result.text.contains)
                        row["status"] = "success"
                    } catch {
                        row["ms"] = elapsedMilliseconds(since: started)
                        row["status"] = "failed"
                        // Stop testing this model after its first failure; do not probe
                        // an unavailable model or challenge repeatedly.
                        failedModels.insert(model)
                    }
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        }
    }

    private func benchmarkAudioFiles() -> [URL] {
        let rawValue = environment["CHATTYPE_BENCHMARK_AUDIO_FILES"] ?? ""
        return rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    private func recordedAudio(from fileURL: URL) throws -> RecordedAudio {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw BenchmarkError.unreadableAudioFile(fileURL.path)
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        return RecordedAudio(
            fileURL: fileURL,
            durationMs: Int((durationSeconds * 1000).rounded())
        )
    }

    private func renderSummary(results: [BenchmarkRunResult]) -> String {
        let grouped = Dictionary(grouping: results) { "\($0.fileLabel) [\($0.mode)]" }
        let lines = grouped.keys.sorted().flatMap { key -> [String] in
            let runs = grouped[key] ?? []
            let successes = runs.filter { $0.error == nil }
            let authValues = successes.map(\.authMs)
            let transcribeValues = successes.map(\.transcribeMs)
            let normalizationValues = successes.map(\.normalizationMs)
            let polishValues = successes.map(\.polishMs)
            let totalValues = successes.map(\.totalMs)
            var section = [
                key,
                "  successes=\(successes.count)/\(runs.count)",
                "  auth_ms p50=\(percentile(authValues, 0.5)) p95=\(percentile(authValues, 0.95))",
                "  transcribe_ms p50=\(percentile(transcribeValues, 0.5)) p95=\(percentile(transcribeValues, 0.95))",
                "  normalization_ms p50=\(percentile(normalizationValues, 0.5)) p95=\(percentile(normalizationValues, 0.95))",
                "  polish_ms p50=\(percentile(polishValues, 0.5)) p95=\(percentile(polishValues, 0.95))",
                "  total_ms p50=\(percentile(totalValues, 0.5)) p95=\(percentile(totalValues, 0.95))",
            ]
            let uniqueErrors = Array(Set(runs.compactMap(\.error))).sorted()
            section.append(contentsOf: uniqueErrors.map { "  error=\($0)" })
            return section
        }
        return lines.joined(separator: "\n")
    }

    private func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
