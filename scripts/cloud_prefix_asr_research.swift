import Foundation
import Security
import CryptoKit
import Darwin

// Isolated research: existing account, six fixed audio sources, no UI or refresh.
enum PrefixASRError: Error { case arguments, input, existing, session, http(Int), response, oversized }
final class PrefixASRRejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
enum PrefixASR {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChatType/PolishSpeedEvaluation/20261112/cloud-prefix-asr-v1")
    static let manifestSHA = "c7b501003f8c2be4d96cb33be226e0ca03dd8f2fe00411d32b605bd8d99109b8"
    static let cases: Set<String> = ["history-short-6","history-short-7","history-short-8","history-medium-7","history-medium-9","history-long-2"]
    static let maxRequests = 12, maxAudioBytes = 25_000_000, maxResponseBytes = 1_048_576, maxTextScalars = 8192
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func exclusive(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL,S_IRUSR|S_IWUSR)
        guard fd >= 0 else { throw PrefixASRError.existing }
        return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
    static func write(_ row: [String:Any], to file: FileHandle) throws {
        try file.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
        try file.synchronize()
    }
    static func safeToken(_ value: String?, max: Int) -> String? {
        guard let value, value.count <= max,
              value.range(of:"^[A-Za-z0-9_.:-]+$",options:.regularExpression) != nil else { return nil }
        return value
    }
    static func text(_ data: Data) throws -> String {
        guard data.count <= maxResponseBytes,
              let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let result = (object["text"] ?? object["transcript"]) as? String,
              !result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              result.unicodeScalars.count <= maxTextScalars else { throw PrefixASRError.response }
        return result
    }
    static func existingSessionWithoutUI() throws -> ChatGPTSession? {
        let store = KeychainChatGPTSessionStore()
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:store.service,kSecAttrAccount as String:store.account,
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PrefixASRError.session }
        return try store.decoder.decode(ChatGPTSession.self,from:data)
    }
    static func inputs() throws -> [[String:Any]] {
        let bytes = try Data(contentsOf:root.appendingPathComponent("audio-manifest.json"))
        guard hash(bytes) == manifestSHA,
              let document = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let rows = document["cases"] as? [[String:Any]], rows.count == 6,
              Set(rows.compactMap { $0["case"] as? String }) == cases else { throw PrefixASRError.input }
        let recovery = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChatType/Recovery/Audio").path + "/"
        for row in rows {
            guard let id = row["case"] as? String,
                  let source = row["sourceAudio"] as? String, canonical(source).hasPrefix(recovery),
                  let prefix = row["prefixAudio"] as? String,
                  canonical(prefix) == root.appendingPathComponent(id+"-prefix.wav").path,
                  row["cutFractionNumerator"] as? Int == 65, row["cutFractionDenominator"] as? Int == 100,
                  row["format"] as? String == "wav", row["promptIncluded"] as? Bool == false else { throw PrefixASRError.input }
            for (path,shaKey) in [(source,"sourceAudioSHA256"),(prefix,"prefixAudioSHA256")] {
                let data = try Data(contentsOf:URL(fileURLWithPath:path))
                guard !data.isEmpty, data.count <= maxAudioBytes, hash(data) == row[shaKey] as? String else { throw PrefixASRError.input }
            }
        }
        return rows
    }
    static func selfTest() throws {
        let first = try text(Data("{\"text\":\"原文 English\"}".utf8))
        let second = try text(Data("{\"transcript\":\"正文\"}".utf8))
        assert(first == "原文 English" && second == "正文")
        for value in ["{}", "{\"text\":\" \"}", "{\"text\":42}"] {
            var rejected = false
            do { _ = try text(Data(value.utf8)) } catch { rejected = true }
            assert(rejected)
        }
        assert(safeToken("AllocationQuota.FreeTierOnly",max:80) != nil)
        assert(safeToken("private text @ example",max:80) == nil)
        assert(cases.count * 2 == maxRequests)
        print("Offline ASR protocol checks passed; no credentials/network.")
    }
    static func run(_ args: [String]) async throws {
        if args == ["--self-test"] { try selfTest(); return }
        if args == ["--session-check"] {
            let usable = try existingSessionWithoutUI()?.tokenIsUsable(now:Date()) == true
            print("Existing no-UI session usable=\(usable); no network or refresh.")
            return
        }
        guard args.isEmpty || args == ["--preflight"] else { throw PrefixASRError.arguments }
        let rows = try inputs()
        if args == ["--preflight"] { print("Six sources/twelve variants verified; no credentials/network."); return }
        let journal = try exclusive(root.appendingPathComponent("request-journal.jsonl")); defer { try? journal.close() }
        let output = try exclusive(root.appendingPathComponent("results.jsonl")); defer { try? output.close() }
        try write(["event":"run","manifestSHA256":manifestSHA,"maxRequests":maxRequests,"promptIncluded":false,
                   "format":"wav","refreshEnabled":false,"cookiesEnabled":false],to:journal)
        guard let saved = try existingSessionWithoutUI(), saved.tokenIsUsable(now:Date()) else { throw PrefixASRError.session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration:configuration,delegate:PrefixASRRejectRedirects(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var attempts = 0
        for row in rows {
            for variant in ["prefix","full"] {
                guard attempts < maxRequests else { throw PrefixASRError.input }
                let id = UUID().uuidString, began = DispatchTime.now().uptimeNanoseconds
                func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000 }
                let pathKey = variant == "prefix" ? "prefixAudio" : "sourceAudio"
                let shaKey = variant == "prefix" ? "prefixAudioSHA256" : "sourceAudioSHA256"
                let audio = try Data(contentsOf:URL(fileURLWithPath:row[pathKey] as! String))
                guard !audio.isEmpty, audio.count <= maxAudioBytes, hash(audio) == row[shaKey] as? String else { throw PrefixASRError.input }
                let boundary = "ChatType-prefix-\(UUID().uuidString)"
                var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
                body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                var request = URLRequest(url:URL(string:"https://chatgpt.com/backend-api/transcribe")!)
                request.httpMethod = "POST"; request.httpBody = body
                request.setValue("Bearer "+saved.accessToken,forHTTPHeaderField:"Authorization")
                if let account = saved.chatGPTAccountID { request.setValue(account,forHTTPHeaderField:"ChatGPT-Account-ID") }
                request.setValue("ChatType/0.5 (macOS)",forHTTPHeaderField:"User-Agent")
                request.setValue("application/json",forHTTPHeaderField:"Accept")
                request.setValue("multipart/form-data; boundary="+boundary,forHTTPHeaderField:"Content-Type")
                try write(["event":"request-start","id":id,"case":row["case"]!,"variant":variant,"ordinal":attempts+1,
                           "audioSHA256":hash(audio),"bodySHA256":hash(body)],to:journal)
                attempts += 1
                var result: [String:Any] = ["id":id,"case":row["case"]!,"variant":variant,"status":"failed",
                    "audioSHA256":hash(audio),"audioBytes":audio.count,"ordinal":attempts,"promptIncluded":false,"responseModelKnown":false,"usageKnown":false]
                var failure: Error?
                do {
                    let (stream,response) = try await session.bytes(for:request); defer { stream.task.cancel() }
                    let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
                    result["httpStatus"] = status; result["responseMIME"] = response.mimeType; result["headersMs"] = elapsed()
                    result["requestID"] = safeToken(http?.value(forHTTPHeaderField:"x-request-id"),max:160)
                    var data = Data()
                    for try await byte in stream {
                        guard data.count < maxResponseBytes else { throw PrefixASRError.oversized }
                        data.append(byte)
                    }
                    guard status == 200 else {
                        if let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                           let e = object["error"] as? [String:Any] {
                            result["refusalCode"] = safeToken((e["code"] ?? e["type"]) as? String,max:80)
                        }
                        if status == 403 && response.mimeType?.contains("html") == true { result["refusalCategory"] = "challenge" }
                        throw PrefixASRError.http(status)
                    }
                    result["text"] = try text(data); result["status"] = "completed"
                    if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                        if let model = safeToken(object["model"] as? String,max:128) {
                            result["responseModel"] = model; result["responseModelKnown"] = true
                        }
                        if let usage = object["usage"] as? [String:Any] {
                            var known: [String:Int] = [:]
                            for key in ["input_tokens","output_tokens","prompt_tokens","completion_tokens","total_tokens"] {
                                if let number = usage[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                                   let count = usage[key] as? Int, count >= 0 { known[key] = count }
                            }
                            if !known.isEmpty { result["usage"] = known; result["usageKnown"] = true }
                        }
                    }
                } catch { failure = error; result["errorType"] = String(describing:type(of:error)) }
                result["completeMs"] = elapsed()
                try write(result,to:output)
                try write(["event":"request-end","id":id,"status":result["status"]!],to:journal)
                print("Prefix ASR: \(row["case"]!) \(variant) \(result["status"]!)")
                if failure != nil { try write(["event":"trial-stopped","id":id,"retainedAttempts":attempts],to:journal); throw PrefixASRError.response }
            }
        }
    }
}
@main struct CloudPrefixASRResearchMain {
    static func main() async {
        do { try await PrefixASR.run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Prefix ASR research stopped: \(String(describing:type(of:error))); evidence retained.\n".utf8)); exit(1) }
    }
}
