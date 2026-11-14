import Foundation
import AudioToolbox
import Darwin
import COpusBridge

/// One worker owns this encoder. Production loads only the signed, bundled
/// Xiph library; the development cache is used only outside an app bundle.
final class DoubaoOpusEncoder {
    typealias Create = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<Int32>) -> OpaquePointer?
    typealias Encode = @convention(c) (OpaquePointer, UnsafePointer<Int16>, Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    typealias Destroy = @convention(c) (OpaquePointer) -> Void
    private let library: UnsafeMutableRawPointer
    private let encoder: OpaquePointer
    private let encodeFunction: Encode
    private let destroy: Destroy

    init(libraryURL: URL? = nil) throws {
        let url = libraryURL ?? Self.libraryURL
        guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw DoubaoError.codec }
        guard let createSymbol = dlsym(library, "opus_encoder_create"),
              let encodeSymbol = dlsym(library, "opus_encode"),
              let destroySymbol = dlsym(library, "opus_encoder_destroy"),
              let controlSymbol = dlsym(library, "opus_encoder_ctl") else { dlclose(library); throw DoubaoError.codec }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        var error: Int32 = 0
        guard let encoder = create(16_000, 1, 2049, &error), error == 0 else { dlclose(library); throw DoubaoError.codec }
        let destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        // Native 1.1.0 speech_opus uses AUDIO + CBR. Its compression ratio
        // is 4 for mono PCM16/16kHz: 256,000 / 4 = 64,000 bit/s. Keeping the
        // libopus VOIP/VBR defaults reduced actual speech data to ~14kbps and
        // lost mixed-language words in matched-WAV replay. Keep the existing
        // supported 20ms transport frame; this is a codec quality setting.
        guard chattype_opus_ctl_int(controlSymbol, UnsafeMutableRawPointer(encoder), 4002, 64_000) == 0,
              chattype_opus_ctl_int(controlSymbol, UnsafeMutableRawPointer(encoder), 4006, 0) == 0 else {
            destroy(encoder); dlclose(library); throw DoubaoError.codec
        }
        self.library = library; self.encoder = encoder
        encodeFunction = unsafeBitCast(encodeSymbol, to: Encode.self)
        self.destroy = destroy
    }
    deinit { destroy(encoder); dlclose(library) }

    static var libraryURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libopus.0.dylib")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/chat-type/opus-1.6.1-\(architecture)/install/lib/libopus.0.dylib")
    }

    func encode(_ pcm: Data) throws -> Data {
        guard pcm.count <= 640, pcm.count % 2 == 0 else { throw DoubaoError.audioFormat }
        let bytes = Array(pcm)
        var samples = [Int16](repeating: 0, count: 320)
        for i in 0..<(bytes.count / 2) {
            samples[i] = Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)
        }
        var output = [UInt8](repeating: 0, count: 4000)
        let size = encodeFunction(encoder, &samples, 320, &output, Int32(output.count))
        guard size > 0 else { throw DoubaoError.codec }
        return Data(output.prefix(Int(size)))
    }
}

/// Core Audio performs file-format/sample-rate conversion for historical audio.
final class DoubaoFilePCM {
    private let file: ExtAudioFileRef
    init(url: URL) throws {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { throw DoubaoError.audioFormat }
        var format = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: format)), &format) == noErr else {
            ExtAudioFileDispose(file); throw DoubaoError.audioFormat
        }
        self.file = file
    }
    deinit { ExtAudioFileDispose(file) }
    func next() throws -> Data? {
        var pcm = Data(count: 640)
        var frames: UInt32 = 320
        let status = pcm.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: 640, mData: raw.baseAddress))
            return ExtAudioFileRead(file, &frames, &list)
        }
        guard status == noErr else { throw DoubaoError.audioFormat }
        return frames == 0 ? nil : Data(pcm.prefix(Int(frames) * 2))
    }
}

/// The live recorder writes mono PCM16 at 16 kHz. Ignore the data chunk's
/// provisional size while recording; the filesystem is the bounded-memory queue.
final class DoubaoGrowingPCM {
    private let handle: FileHandle
    private var offset: UInt64
    private let dataStart: UInt64
    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            func read(_ count: Int) throws -> Data {
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else { throw DoubaoError.audioNotReady }
                return data
            }
            let header = try read(12)
            guard String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
                  String(decoding: header.suffix(4), as: UTF8.self) == "WAVE" else { throw DoubaoError.audioFormat }
            var validFormat = false
            while true {
                let chunk = [UInt8](try read(8))
                let size = Int(chunk[4]) | Int(chunk[5]) << 8 | Int(chunk[6]) << 16 | Int(chunk[7]) << 24
                let name = String(decoding: chunk.prefix(4), as: UTF8.self)
                if name == "data" {
                    guard validFormat else { throw DoubaoError.audioFormat }
                    break
                }
                if name == "fmt " {
                    guard size >= 16 else { throw DoubaoError.audioFormat }
                    let format = [UInt8](try read(16))
                    let rate = Int(format[4]) | Int(format[5]) << 8 | Int(format[6]) << 16 | Int(format[7]) << 24
                    validFormat = format[0] == 1 && format[1] == 0 && format[2] == 1 && format[3] == 0
                        && rate == 16000 && format[14] == 16 && format[15] == 0
                    try handle.seek(toOffset: handle.offset() + UInt64(size - 16 + size % 2))
                } else { try handle.seek(toOffset: handle.offset() + UInt64(size + size % 2)) }
            }
            self.handle = handle; offset = try handle.offset(); dataStart = offset
        } catch { try? handle.close(); throw error }
    }
    deinit { try? handle.close() }
    func next(final: Bool) throws -> Data? {
        var count = 640
        if final {
            try handle.seek(toOffset: dataStart - 4)
            let bytes = [UInt8](try handle.read(upToCount: 4) ?? Data())
            guard bytes.count == 4 else { throw DoubaoError.audioFormat }
            let length = UInt64(bytes[0]) | UInt64(bytes[1]) << 8 | UInt64(bytes[2]) << 16 | UInt64(bytes[3]) << 24
            let end = dataStart + length
            guard offset <= end else { throw DoubaoError.audioFormat }
            count = Int(min(640, end - offset))
            if count == 0 { return nil }
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        if data.count < 640 && !final { return nil }
        guard !data.isEmpty else { return nil }
        guard data.count % 2 == 0 else { throw DoubaoError.audioFormat }
        offset += UInt64(data.count)
        return data
    }
}
