import Foundation
import Testing
@testable import ChatType

@Test
func recordingIntegrityRejectsLongDigitalSilenceTail() {
    let wav = makePCM16WAV(
        sampleRate: 100,
        segments: [
            (seconds: 6, amplitude: 2_000),
            (seconds: 114, amplitude: 1),
        ]
    )

    #expect(
        PCMRecordingIntegrityAnalyzer().analyze(wavData: wav)
            == .interruptedInput(capturedSignalSeconds: 6, silentTailSeconds: 114)
    )
}

@Test
func recordingIntegrityAcceptsHealthyLongRecording() {
    let wav = makePCM16WAV(
        sampleRate: 100,
        segments: [
            (seconds: 55, amplitude: 2_000),
            (seconds: 10, amplitude: 1),
            (seconds: 55, amplitude: 2_000),
        ]
    )

    #expect(PCMRecordingIntegrityAnalyzer().analyze(wavData: wav) == nil)
}

@Test
func inputHealthMonitorDetectsContinuousDigitalSilenceAfterSpeech() {
    var monitor = RecordingInputHealthMonitor(interruptionSeconds: 15)
    monitor.observe(powerDBFS: -24, elapsedSeconds: 2)
    monitor.observe(powerDBFS: -91, elapsedSeconds: 3)
    monitor.observe(powerDBFS: -91, elapsedSeconds: 17.9)
    #expect(monitor.interruptionDetected == false)

    monitor.observe(powerDBFS: -91, elapsedSeconds: 18)
    #expect(monitor.interruptionDetected == true)
}

@Test
func inputHealthMonitorDoesNotTreatOrdinaryQuietAsDigitalSilence() {
    var monitor = RecordingInputHealthMonitor(interruptionSeconds: 15)
    monitor.observe(powerDBFS: -24, elapsedSeconds: 1)
    monitor.observe(powerDBFS: -60, elapsedSeconds: 30)

    #expect(monitor.interruptionDetected == false)
}

private func makePCM16WAV(
    sampleRate: Int,
    segments: [(seconds: Int, amplitude: Int16)]
) -> Data {
    var samples = Data()
    for segment in segments {
        let sampleCount = sampleRate * segment.seconds
        let raw = UInt16(bitPattern: segment.amplitude)
        for _ in 0..<sampleCount {
            samples.append(UInt8(raw & 0xFF))
            samples.append(UInt8((raw >> 8) & 0xFF))
        }
    }

    var wav = Data("RIFF".utf8)
    wav.appendLittleEndian(UInt32(36 + samples.count))
    wav.append(Data("WAVEfmt ".utf8))
    wav.appendLittleEndian(UInt32(16))
    wav.appendLittleEndian(UInt16(1))
    wav.appendLittleEndian(UInt16(1))
    wav.appendLittleEndian(UInt32(sampleRate))
    wav.appendLittleEndian(UInt32(sampleRate * 2))
    wav.appendLittleEndian(UInt16(2))
    wav.appendLittleEndian(UInt16(16))
    wav.append(Data("data".utf8))
    wav.appendLittleEndian(UInt32(samples.count))
    wav.append(samples)
    return wav
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
