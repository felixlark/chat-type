import Foundation

/// AVAudioRecorder writes PCM incrementally, but finalizes RIFF lengths on stop.
/// Only invoked after relaunch for unfinished recordings, never on a live file.
enum InterruptedWAVRecovery {
    static func repair(url: URL) throws -> Int? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 65_536) ?? Data()
        guard header.count >= 12,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << ($1 * 8) }
        }
        var offset = 12
        var bytesPerSecond: UInt32 = 0
        var blockAlign: UInt16 = 0
        while offset + 8 <= header.count {
            let size = Int(uint32(offset + 4))
            let name = String(data: header[offset..<(offset + 4)], encoding: .ascii)
            let payload = offset + 8
            if name == "fmt ", size >= 16, payload + 16 <= header.count {
                bytesPerSecond = uint32(payload + 8)
                blockAlign = UInt16(header[payload + 12]) | UInt16(header[payload + 13]) << 8
            }
            if name == "data", bytesPerSecond > 0, blockAlign > 0, length >= UInt64(payload) {
                let available = length - UInt64(payload)
                // A finalized data chunk may have trailing metadata. Only recover
                // beyond its declared length when the RIFF header is unfinished.
                let declared = UInt64(uint32(offset + 4))
                let unfinished = UInt64(uint32(4)) + 8 != length || declared == 0 || declared > available
                let dataBytes = unfinished ? available - available % UInt64(blockAlign) : declared
                guard dataBytes <= UInt32.max, length - 8 <= UInt32.max else { return nil }
                if unfinished {
                    func writeUInt32(_ value: UInt32, at position: UInt64) throws {
                        var littleEndian = value.littleEndian
                        let data = withUnsafeBytes(of: &littleEndian) { Data($0) }
                        try handle.seek(toOffset: position)
                        try handle.write(contentsOf: data)
                    }
                    try writeUInt32(UInt32(length - 8), at: 4)
                    try writeUInt32(UInt32(dataBytes), at: UInt64(offset + 4))
                    try handle.synchronize()
                }
                return Int(Double(dataBytes) / Double(bytesPerSecond) * 1_000)
            }
            guard size <= header.count - payload else { return nil }
            offset = payload + size + size % 2
        }
        return nil
    }
}
