import AVFoundation
import Foundation
import Testing
@testable import ChatType

private func uploadFixture() throws -> (URL, Data) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        for i in 0..<24_000 { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 0.12) * 6_000) }
        for _ in 0..<20 { try file.write(from: buffer) }
    }
    return (url, try Data(contentsOf: url))
}

@Test func compressedUploadPreservesOriginalAndAudioDuration() throws {
    let (url, original) = try uploadFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = try AudioUploadPreparation().prepare(audio: .init(fileURL: url, durationMs: 20_000), original: original, mode: .automatic)
    #expect(payload.filename == "voice.m4a")
    #expect(payload.mimeType == "audio/mp4")
    #expect(payload.data.count < original.count / 3)
    #expect(try Data(contentsOf: url) == original)
    let encodedURL = url.deletingPathExtension().appendingPathExtension("m4a")
    defer { try? FileManager.default.removeItem(at: encodedURL) }
    try payload.data.write(to: encodedURL)
    let decoded = try AVAudioFile(forReading: encodedURL)
    #expect(decoded.processingFormat.sampleRate == 24_000)
    #expect(decoded.processingFormat.channelCount == 1)
    #expect(abs(Double(decoded.length) / 24_000 - 20) < 0.1)
}

@Test func shortUploadAvoidsEncodingAndInvalidCodecInputFallsBack() throws {
    let original = Data("fake-audio".utf8)
    let audio = RecordedAudio(fileURL: URL(fileURLWithPath: "/nonexistent/audio.wav"), durationMs: 1_000)
    let short = try AudioUploadPreparation().prepare(audio: audio, original: original, mode: .automatic)
    #expect(short.data == original)
    let fallback = try AudioUploadPreparation().prepare(audio: audio, original: original, mode: .aac)
    #expect(fallback.data == original)
    #expect(fallback.filename == "voice.wav")
}

@Test func canceledUploadPreparationDoesNotEncode() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try AudioUploadPreparation().prepare(audio: .init(fileURL: URL(fileURLWithPath: "/nonexistent"), durationMs: 20_000), original: Data([1]), mode: .automatic)
    }
    do {
        _ = try await task.value
        Issue.record("Canceled encoding succeeded")
    } catch is CancellationError { }
}

@Test func managedUploadUsesEncodedMultipartMetadata() async throws {
    let (url, original) = try uploadFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let transcriber = ChatGPTTranscriber(authManager: FakeChatGPTAuthManager(), config: AppConfig().transcription,
        bridgePromptCapability: BridgePromptCapabilityStore(), dataLoader: { request in
            let prefix = String(decoding: (request.httpBody ?? Data()).prefix(4_000), as: UTF8.self)
            #expect(prefix.contains("filename=\"voice.m4a\""))
            #expect(prefix.contains("Content-Type: audio/mp4"))
            #expect(request.url?.host == "chatgpt.com")
            return (Data(#"{"text":"完整转写"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    let result = try await transcriber.transcribe(.init(fileURL: url, durationMs: 20_000))
    #expect(result.metrics.uploadedBytes < result.metrics.audioBytes / 3)
    #expect(result.metrics.uploadFormat == "voice.m4a")
    #expect(try Data(contentsOf: url) == original)
}
