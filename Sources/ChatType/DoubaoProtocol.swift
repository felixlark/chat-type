import Foundation

enum DoubaoError: LocalizedError, Sendable, Equatable {
    case malformedMessage
    case incomplete(String)
    case rejected(Int)
    case serviceDiscoveryFailure
    case http(Int)
    case credentials
    case codec
    case audioFormat
    case audioNotReady
    case unexpectedContent

    var errorDescription: String? {
        switch self {
        case .malformedMessage: return "豆包返回了无法解析的协议消息；录音仍保留。"
        case .incomplete(let stage): return "豆包\(stage)未完整结束；录音和已取得的文字仍保留，可重试。"
        case .rejected(let code): return "豆包拒绝请求（\(code)）；录音保留，未切换服务。可稍后重试，或在设置中更新豆包配置。"
        case .serviceDiscoveryFailure: return "豆包识别服务暂时不可用（50700000：服务发现失败）；原声保留，未更换凭据或服务。"
        case .http(let code): return "豆包服务返回 HTTP \(code)；未切换服务。"
        case .credentials: return "未能取得豆包识别配置；请在设置中更新配置后重试。"
        case .codec: return "随应用安装的 Opus 编码器不可用，请重新安装 ChatType。"
        case .audioFormat: return "豆包需要可读取的单声道 PCM 音频；原文件仍保留。"
        case .audioNotReady: return "正在等待本地录音写入。"
        case .unexpectedContent: return "豆包整理未返回有效事件流；HTTP 成功不代表文字整理完成。"
        }
    }
}

/// Wire facts recovered from the installed IME and verified by controlled replay.
/// This is a small, independent codec, not copied from third-party clients.
enum DoubaoProtobuf {
    enum Value: Equatable { case number(UInt64), bytes(Data) }

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            result.append(value == 0 ? byte : byte | 128)
        } while value != 0
        return result
    }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    static func text(_ field: UInt64, _ value: String) -> Data { bytes(field, Data(value.utf8)) }

    static func request(token: String, method: String, id: String,
                        payload: Data? = nil, audio: Data? = nil, frame: UInt64? = nil) -> Data {
        var result = text(2, token) + text(3, "ASR") + text(5, method)
        if let payload { result += bytes(6, payload) }
        if let audio { result += bytes(7, audio) }
        result += text(8, id)
        if let frame { result += varint(9 << 3) + varint(frame) }
        return result
    }

    static func decode(_ data: Data) throws -> [Int: Value] {
        let data = Array(data)
        var cursor = 0
        var result: [Int: Value] = [:]
        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < data.count else { throw DoubaoError.malformedMessage }
                let byte = data[cursor]; cursor += 1
                guard shift < 63 || byte <= 1 else { throw DoubaoError.malformedMessage }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw DoubaoError.malformedMessage
        }
        while cursor < data.count {
            let tag = try readVarint()
            let field = Int(tag >> 3)
            guard field > 0 else { throw DoubaoError.malformedMessage }
            switch tag & 7 {
            case 0: result[field] = .number(try readVarint())
            case 2:
                let length = try readVarint()
                guard length <= UInt64(data.count - cursor) else { throw DoubaoError.malformedMessage }
                let end = cursor + Int(length)
                result[field] = .bytes(Data(data[cursor..<end])); cursor = end
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard length <= data.count - cursor else { throw DoubaoError.malformedMessage }
                cursor += length
            default: throw DoubaoError.malformedMessage
            }
        }
        return result
    }
}

struct DoubaoReply: Sendable {
    let kind: String
    let result: Data?

    init(_ data: Data) throws {
        let fields = try DoubaoProtobuf.decode(data)
        if case .number(let code) = fields[5], code != 20_000_000 {
            // Field 6 can contain arbitrary server text. Classify this observed
            // transient reason only; never persist/print the untrusted message.
            if code == 50_700_000, case .bytes(let message) = fields[6],
               case .bytes(let kind) = fields[4], String(decoding: kind, as: UTF8.self) == "SessionFailed",
               String(decoding: message, as: UTF8.self) == "read backend response: rpc error: code = 2 desc = service discovery failure" {
                throw DoubaoError.serviceDiscoveryFailure
            }
            throw DoubaoError.rejected(Int(clamping: code))
        }
        if case .bytes(let value) = fields[4] { kind = String(decoding: value, as: UTF8.self) }
        else { kind = "" }
        if kind.contains("Failed") { throw DoubaoError.incomplete("识别") }
        if case .bytes(let value) = fields[7] { result = value } else { result = nil }
    }
}

/// Each indexed VAD segment is replaced in place; final segments are never
/// replaced by late interim text. Ambiguous unindexed multi-segment replies fail
/// explicitly instead of silently dropping earlier speech.
struct DoubaoTranscript: Sendable {
    struct Segment: Sendable { var text: String; var final: Bool }
    private var order: [String] = []
    private var segments: [String: Segment] = [:]
    var text: String { order.compactMap { segments[$0]?.text }.joined() }
    var finalText: String { order.compactMap { segments[$0].flatMap { $0.final ? $0.text : nil } }.joined() }
    var complete: Bool { !order.isEmpty && order.allSatisfy { segments[$0]?.final == true } }

    mutating func consume(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DoubaoError.malformedMessage
        }
        guard let results = object["results"] as? [[String: Any]] else { return }
        for result in results {
            guard let text = result["text"] as? String, !text.isEmpty else { continue }
            let extra = result["extra"] as? [String: Any]
            if extra?["nonstream_result"] as? Bool == true, order.count > 1 {
                throw DoubaoError.incomplete("离线结果（多段覆盖范围未知）")
            }
            let final = (result["is_interim"] as? Bool == false && result["is_vad_finished"] as? Bool == true)
                || extra?["nonstream_result"] as? Bool == true
            let key: String
            if let index = result["index"] as? NSNumber { key = "index:\(index)" }
            else if let start = result["start_time"] as? NSNumber { key = "start:\(start)" }
            else {
                key = "unindexed"
                if extra?["nonstream_result"] as? Bool == true, !order.isEmpty, segments[key] == nil {
                    throw DoubaoError.incomplete("离线结果（分段覆盖范围未知）")
                }
                if let old = segments[key], old.final, old.text != text {
                    throw DoubaoError.incomplete("分段识别（缺少分段标识）")
                }
            }
            if let old = segments[key], old.final && !final { continue }
            if segments[key] == nil { order.append(key) }
            segments[key] = Segment(text: text, final: final)
        }
    }
}

/// SSE event blocks, not individual data lines, are JSON documents.
struct DoubaoOrganizationStream {
    private var event = ""
    private var data: [String] = []
    private(set) var completedText: String?
    private(set) var done = false
    private(set) var noRewrite = false
    private var deltaText = ""
    var partialText: String? { completedText ?? (deltaText.isEmpty ? nil : deltaText) }

    mutating func consume(line: String) throws {
        if line.isEmpty { try finishEvent(); return }
        if line.hasPrefix(":") { return }
        let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let value = pair.count == 2 ? String(pair[1]).replacingOccurrences(of: "^ ", with: "", options: .regularExpression) : ""
        if pair[0] == "event" { event = value }
        if pair[0] == "data" { data.append(value) }
    }

    mutating func finishEvent() throws {
        defer { event = ""; data = [] }
        guard !data.isEmpty else { return }
        let body = data.joined(separator: "\n")
        if event == "done", body == "[DONE]" { done = true; return }
        guard let json = body.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DoubaoError.malformedMessage
        }
        if event.contains("error") || event.contains("failed") || object["code"] as? Int != nil {
            throw DoubaoError.incomplete("文字整理")
        }
        if event == "scene.completed" { completedText = object["content"] as? String }
        if event == "scene.delta" {
            if object["no_rewrite"] as? Bool == true { noRewrite = true }
            if let content = object["content"] as? String { deltaText += content }
        }
    }

    func result(originalText: String? = nil) throws -> String {
        guard done, let text = completedText else {
            throw DoubaoError.incomplete("文字整理")
        }
        // Observed short-input success: no_rewrite=true, empty completed content,
        // then [DONE]. This is an explicit unchanged result, not error fallback.
        if text.isEmpty, deltaText.isEmpty, noRewrite,
           let originalText, !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return originalText
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoError.incomplete("文字整理")
        }
        return text
    }
}
