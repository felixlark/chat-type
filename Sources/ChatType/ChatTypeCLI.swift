import AVFAudio
import Foundation

enum ChatTypeCLI {
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == "process" else { return false }
        Task {
            do {
                let result = try await process(arguments: Array(arguments.dropFirst(2)))
                let data = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.sortedKeys]
                )
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("ChatType CLI: \(error.localizedDescription)\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }

    private static func process(arguments: [String]) async throws -> [String: Any] {
        guard let audioIndex = arguments.firstIndex(of: "--audio"),
              audioIndex + 1 < arguments.count else {
            throw CLIError.usage("process requires --audio PATH")
        }
        if let formatIndex = arguments.firstIndex(of: "--format"),
           formatIndex + 1 < arguments.count,
           arguments[formatIndex + 1] != "json" {
            throw CLIError.usage("only --format json is supported")
        }
        let audioURL = URL(fileURLWithPath: arguments[audioIndex + 1]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CLIError.usage("audio file does not exist")
        }
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = max(audioFile.processingFormat.sampleRate, 1)
        let durationMs = Int((Double(audioFile.length) / sampleRate * 1000).rounded(.up))
        let store = ConfigStore()
        let config = try store.load()
        let authManager = ChatGPTAuthManager()
        let transcriber = ChatGPTTranscriber(
            authManager: authManager,
            config: config.transcription
        )
        let transcription = try await transcriber.transcribe(
            RecordedAudio(fileURL: audioURL, durationMs: durationMs)
        )
        let normalized = TerminologyNormalizer().normalize(
            text: transcription.text,
            importedEntries: config.transcription.activeDictionaryEntries,
            hintTerms: config.transcription.hintTerms
        )
        let transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw CLIError.emptyTranscript }
        return [
            "transcript": transcript,
            "polished_text": normalized.text,
            "provider": transcription.metrics.provider.rawValue,
            "duration_ms": durationMs,
            "audio_bytes": transcription.metrics.audioBytes,
            "normalization_applied": normalized.applied
        ]
    }

    private enum CLIError: LocalizedError {
        case usage(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .usage(let message): message
            case .emptyTranscript: "ChatType returned an empty transcript."
            }
        }
    }
}
