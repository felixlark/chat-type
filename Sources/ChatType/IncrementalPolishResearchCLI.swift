import Foundation
import CryptoKit

/// Research entry points never record a microphone, insert text, or save configuration.
enum IncrementalPolishResearchCLI {
    enum Failure: Error { case arguments, unsupported, outputExists, conversion }

    static func run(command: String, arguments: [String]) async throws {
        var options: [String: String] = [:]
        var i = 0
        while i < arguments.count {
            guard i + 1 < arguments.count, options[arguments[i]] == nil,
                  ["--audio", "--output", "--config-snapshot"].contains(arguments[i]) else { throw Failure.arguments }
            options[arguments[i]] = arguments[i + 1]; i += 2
        }
        if command == "capture-preview-trace" {
            guard #available(macOS 26.0, *), options.count == 2,
                  let audio = options["--audio"], let output = options["--output"] else { throw Failure.arguments }
            try await LocalSpeechPreviewTrace.capture(audio: URL(fileURLWithPath: audio), output: URL(fileURLWithPath: output))
        } else {
            guard options.count == 1, let configPath = options["--config-snapshot"] else { throw Failure.arguments }
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
            guard config.transcription.textPolish.provider == .chatGPTAuth,
                  config.transcription.textPolish.chatGPTResponseModel == "gpt-6.1-terra" else { throw Failure.arguments }
            var auth: ChatGPTAuthManager?
            let entries = config.transcription.activeDictionaryEntries
            let alignment = entries.filter { $0.type == .term || ($0.type == .correction && $0.original == $0.replacement) }
            let normalizer = TerminologyNormalizer()
            while let line = readLine() {
                let request = try JSONDecoder().decode(ResearchRequest.self, from: Data(line.utf8))
                guard ["prewarm", "prepare", "full", "patch", "postprocess"].contains(request.mode) else { throw Failure.arguments }
                if request.mode == "prewarm" {
                    let began = ProcessingTiming.now()
                    if auth == nil { auth = ChatGPTAuthManager() }
                    await auth?.prewarmSession()
                    let ready = auth?.authSnapshot().state == .ready
                    let row: [String: Any] = ["id": request.id, "status": ready ? "completed" : "failed",
                        "authReady": ready, "elapsedMs": ProcessingTiming.milliseconds(since: began)]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
                    continue
                }
                let hints = config.transcription.prioritizedHintTerms + PersonalNameHints.relatedTerms(in: request.text, entries: entries)
                let input = normalizer.normalize(text: request.text, importedEntries: alignment,
                    hintTerms: config.transcription.prioritizedHintTerms).text
                var messages = TextPolishPromptBuilder().buildMessages(transcript: input,
                    terminologyEntries: alignment, config: config.transcription.textPolish, priorityTerms: hints)
                let context = try JSONSerialization.data(withJSONObject: messages.map { ["role": $0.role, "content": $0.content] }, options: [.sortedKeys])
                let trace = ProcessingTiming(), started = ProcessingTiming.now()
                var result: [String: Any] = ["id": request.id, "input": input,
                    "contextSHA256": SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()]
                do {
                    if request.mode == "prepare" {
                        result["text"] = ""
                    } else if request.mode == "postprocess" {
                        guard let draft = request.base else { throw Failure.arguments }
                        result["text"] = DictationTextFormatter().format(normalizer.applyCorrections(text:
                            normalizer.normalize(text: draft, importedEntries: alignment, hintTerms: hints).text, entries: entries).text)
                    } else {
                        if auth == nil {
                            let manager = ChatGPTAuthManager()
                            await manager.prewarmSession()
                            auth = manager
                        }
                        let polisher = OpenAICompatibleTextPolisher(config: config.transcription.textPolish,
                            chatGPTAuthProvider: auth, chatGPTAuthAvailable: true)
                        if request.mode == "patch" {
                            guard let base = request.base, let version = request.baseVersion else { throw Failure.arguments }
                            let format = "只返回一个JSON对象，严格为{\"schema\":1,\"base_version\":\(version),\"edits\":[{\"old\":\"提前稿中的唯一原样片段\",\"new\":\"替换片段\"}]}。无须修改时edits为空。old非空、须在提前稿中原样仅出现一次，修改互不重叠；new可为空。追加用唯一末尾锚替换，不用空old。勿加其他字段、解释或代码围栏。以完整最终转写为准，校正提前稿中的尾段、误识及全文撤回，不可保留被后文撤回的决定，也不可丢失仍有效的要求或理由。"
                            messages[0] = TextPolishMessage(role: "system", content: messages[0].content.replacingOccurrences(of: "output only the final text.", with: "return only the strict JSON edit object specified below.") + "\n" + format)
                            let payload = try JSONSerialization.data(withJSONObject: ["completeFinalTranscript": input, "immutableEarlyDraft": base], options: [.sortedKeys])
                            messages[1] = TextPolishMessage(role: "user", content: String(decoding: payload, as: UTF8.self))
                        }
                        let text = try await ProcessingTrace.$current.withValue(trace) {
                            try await polisher.evaluatePreparedMessages(messages)
                        }
                        if request.mode == "full" {
                            result["text"] = DictationTextFormatter().format(normalizer.applyCorrections(text:
                                normalizer.normalize(text: text, importedEntries: alignment, hintTerms: hints).text, entries: entries).text)
                        } else { result["text"] = text }
                    }
                    result["status"] = "completed"
                } catch {
                    result["status"] = "failed"; result["errorType"] = String(describing: type(of: error))
                }
                result["elapsedMs"] = ProcessingTiming.milliseconds(since: started)
                let timing = trace.snapshot()
                result["timing"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) + Data([10]))
                if timing.polishCalls.flatMap(\.httpAttempts).contains(where: { $0.statusCode == 403 }) { return }
            }
        }
    }

    private struct ResearchRequest: Decodable {
        let id: String
        let mode: String
        let text: String
        let base: String?
        let baseVersion: Int?
    }

}
