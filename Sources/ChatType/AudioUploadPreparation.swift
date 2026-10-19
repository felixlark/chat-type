import AVFoundation
import Foundation

enum AudioUploadMode: String, Sendable {
    case automatic, wav, aac, flac
}

struct AudioUploadPayload: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
}

/// The durable PCM is never modified. Only this short-lived upload derivative is encoded.
struct AudioUploadPreparation: Sendable {
    func prepare(audio: RecordedAudio, original: Data, mode: AudioUploadMode) throws -> AudioUploadPayload {
        try Task.checkCancellation()
        let wav = AudioUploadPayload(data: original, filename: "voice.wav", mimeType: "audio/wav")
        let selected: AudioUploadMode = mode == .automatic ? (audio.durationMs >= 15_000 ? .aac : .wav) : mode
        guard selected != .wav else { return wav }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatType-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = selected == .aac ? "voice.m4a" : "voice.flac"
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encode(source: audio.fileURL, destination: destination, mode: selected)
            try Task.checkCancellation()
            let encoded = try Data(contentsOf: destination)
            guard !encoded.isEmpty, encoded.count < original.count else { return wav }
            return AudioUploadPayload(data: encoded, filename: name, mimeType: selected == .aac ? "audio/mp4" : "audio/flac")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A local codec failure must not prevent recovery/transcription of the original.
            try Task.checkCancellation()
            return wav
        }
    }

    private func encode(source: URL, destination: URL, mode: AudioUploadMode) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: mode == .aac ? kAudioFormatMPEG4AAC : kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if mode == .aac {
            settings[AVEncoderBitRateKey] = 64_000 * Int(format.channelCount)
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        } else {
            settings[AVEncoderBitDepthHintKey] = 16
        }
        // AVAudioFile converts PCM to the file codec; no resampling is performed.
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw TranscriptionError.invalidAudio
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        // Returning releases output and finalizes the container before it is read.
    }
}
