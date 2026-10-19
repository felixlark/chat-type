import Foundation

enum RecordingIntegrityIssue: Sendable, Equatable {
    case noUsableSignal
    case interruptedInput(capturedSignalSeconds: Int, silentTailSeconds: Int)
}

struct PCMRecordingIntegrityAnalyzer: Sendable {
    let digitalSilenceAmplitude: Int
    let minimumRecordingSeconds: Double
    let minimumSilentTailSeconds: Double

    init(
        digitalSilenceAmplitude: Int = 4,
        minimumRecordingSeconds: Double = 20,
        minimumSilentTailSeconds: Double = 15
    ) {
        self.digitalSilenceAmplitude = max(0, digitalSilenceAmplitude)
        self.minimumRecordingSeconds = max(0, minimumRecordingSeconds)
        self.minimumSilentTailSeconds = max(0, minimumSilentTailSeconds)
    }

    func analyze(wavData: Data) -> RecordingIntegrityIssue? {
        guard let wav = PCM16WAV(data: wavData) else {
            return nil
        }

        let totalFrames = wav.audioData.count / wav.blockAlign
        guard totalFrames > 0 else {
            return .noUsableSignal
        }

        var lastSignalFrame: Int?
        for frame in 0..<totalFrames {
            let frameOffset = frame * wav.blockAlign
            for channel in 0..<wav.channelCount {
                let sampleOffset = frameOffset + channel * 2
                let rawValue = UInt16(wav.audioData[sampleOffset])
                    | (UInt16(wav.audioData[sampleOffset + 1]) << 8)
                let sample = Int(Int16(bitPattern: rawValue))
                if sample > digitalSilenceAmplitude || sample < -digitalSilenceAmplitude {
                    lastSignalFrame = frame
                    break
                }
            }
        }

        guard let lastSignalFrame else {
            return .noUsableSignal
        }

        let totalSeconds = Double(totalFrames) / wav.sampleRate
        let capturedSignalSeconds = Double(lastSignalFrame + 1) / wav.sampleRate
        let silentTailSeconds = totalSeconds - capturedSignalSeconds
        guard totalSeconds >= minimumRecordingSeconds,
              silentTailSeconds >= minimumSilentTailSeconds else {
            return nil
        }

        return .interruptedInput(
            capturedSignalSeconds: Int(capturedSignalSeconds.rounded()),
            silentTailSeconds: Int(silentTailSeconds.rounded())
        )
    }
}

struct RecordingInputHealthMonitor: Sendable {
    let digitalSilenceThresholdDBFS: Float
    let interruptionSeconds: TimeInterval

    private(set) var hasObservedSignal = false
    private(set) var interruptionDetected = false
    private var digitalSilenceStartedAt: TimeInterval?

    init(
        digitalSilenceThresholdDBFS: Float = -85,
        interruptionSeconds: TimeInterval = 15
    ) {
        self.digitalSilenceThresholdDBFS = digitalSilenceThresholdDBFS
        self.interruptionSeconds = max(0, interruptionSeconds)
    }

    mutating func observe(powerDBFS: Float, elapsedSeconds: TimeInterval) {
        guard !interruptionDetected else {
            return
        }

        if powerDBFS > digitalSilenceThresholdDBFS {
            hasObservedSignal = true
            digitalSilenceStartedAt = nil
            return
        }

        guard hasObservedSignal else {
            return
        }

        if let digitalSilenceStartedAt {
            if elapsedSeconds - digitalSilenceStartedAt >= interruptionSeconds {
                interruptionDetected = true
            }
        } else {
            digitalSilenceStartedAt = elapsedSeconds
        }
    }
}

private struct PCM16WAV {
    let channelCount: Int
    let sampleRate: Double
    let blockAlign: Int
    let audioData: Data

    init?(data: Data) {
        guard data.count >= 12,
              data.ascii(at: 0, count: 4) == "RIFF",
              data.ascii(at: 8, count: 4) == "WAVE" else {
            return nil
        }

        var format: (channels: Int, sampleRate: Double, blockAlign: Int)?
        var audioData: Data?
        var offset = 12

        while offset + 8 <= data.count {
            guard let chunkSizeValue = data.littleEndianUInt32(at: offset + 4) else {
                return nil
            }
            let chunkSize = Int(chunkSizeValue)
            let payloadOffset = offset + 8
            guard chunkSize >= 0, payloadOffset + chunkSize <= data.count else {
                return nil
            }

            let chunkID = data.ascii(at: offset, count: 4)
            if chunkID == "fmt ", chunkSize >= 16,
               let audioFormat = data.littleEndianUInt16(at: payloadOffset),
               let channels = data.littleEndianUInt16(at: payloadOffset + 2),
               let sampleRate = data.littleEndianUInt32(at: payloadOffset + 4),
               let blockAlign = data.littleEndianUInt16(at: payloadOffset + 12),
               let bitsPerSample = data.littleEndianUInt16(at: payloadOffset + 14),
               audioFormat == 1, channels > 0, sampleRate > 0,
               bitsPerSample == 16, blockAlign == channels * 2 {
                format = (Int(channels), Double(sampleRate), Int(blockAlign))
            } else if chunkID == "data" {
                audioData = data.subdata(in: payloadOffset..<(payloadOffset + chunkSize))
            }

            offset = payloadOffset + chunkSize + (chunkSize % 2)
        }

        guard let format, let audioData else {
            return nil
        }

        self.channelCount = format.channels
        self.sampleRate = format.sampleRate
        self.blockAlign = format.blockAlign
        self.audioData = audioData
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= self.count else {
            return nil
        }
        return String(data: subdata(in: offset..<(offset + count)), encoding: .ascii)
    }

    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else {
            return nil
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
