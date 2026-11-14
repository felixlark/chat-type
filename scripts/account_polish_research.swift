import Foundation
import CryptoKit
import Darwin
import Security

enum AccountTrialError: Error { case input, existing, session, http(Int), stream }
final class AccountRejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
struct AccountTrialStream {
    var text = "", completed = false
    var model: String?, usage: [String: Any]?
    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in:.whitespaces)
        guard let bytes = payload.data(using:.utf8), let event = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let type = event["type"] as? String else { throw AccountTrialError.stream }
        if type == "response.output_text.delta" {
            guard !completed, let delta = event["delta"] as? String else { throw AccountTrialError.stream }
            text += delta
            guard text.unicodeScalars.count <= 8192 else { throw AccountTrialError.stream }
        } else if type == "response.completed" {
            guard let response = event["response"] as? [String:Any], response["status"] as? String == "completed",
                  let actualUsage = response["usage"] as? [String:Any],
                  let inputNumber = actualUsage["input_tokens"] as? NSNumber, CFGetTypeID(inputNumber) != CFBooleanGetTypeID(),
                  let outputNumber = actualUsage["output_tokens"] as? NSNumber, CFGetTypeID(outputNumber) != CFBooleanGetTypeID(),
                  let input = actualUsage["input_tokens"] as? Int, input >= 0,
                  let output = actualUsage["output_tokens"] as? Int, output >= 0,
                  !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AccountTrialError.stream }
            model = response["model"] as? String; usage = actualUsage; completed = true
        } else if type == "response.failed" || type == "response.incomplete" || type == "error" { throw AccountTrialError.stream }
    }
}
enum AccountTrial {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ChatType/PolishSpeedEvaluation/20261112")
    static let inputSHA = "8470fb656028ba3e461d312116b48a3a11c44b7f8883aa7a302b4684074b2879"
    static let models = ["gpt-6-luna", "gpt-6.1-terra"]
    static let cases: Set<String> = ["history-short-6","history-short-7","history-short-8","history-medium-7","history-medium-9","history-long-2"]
    static func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func write(_ object:[String:Any], to out:FileHandle) throws {
        try out.write(contentsOf:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])+Data([10]));try out.synchronize()
    }
    static func exclusive(_ url:URL) throws -> FileHandle {
        let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL,S_IRUSR|S_IWUSR)
        guard fd >= 0 else { throw AccountTrialError.existing };return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
    static func existingSessionWithoutUI() throws -> ChatGPTSession? {
        let store=KeychainChatGPTSessionStore()
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:store.service,kSecAttrAccount as String:store.account,
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        var item:CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status == errSecItemNotFound {return nil}
        guard status == errSecSuccess,let data=item as? Data else {throw AccountTrialError.session}
        return try store.decoder.decode(ChatGPTSession.self,from:data)
    }
    static func selfTest() throws {
        var stream=AccountTrialStream()
        try stream.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"正文\"}")
        assert(!stream.completed)
        try stream.consume("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"model\":\"m\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}")
        assert(stream.completed && stream.text == "正文" && stream.model == "m" && stream.usage != nil)
        var rejected=false
        do { var s=AccountTrialStream();try s.consume("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}") } catch { rejected=true };assert(rejected)
        rejected=false
        do { var s=AccountTrialStream();try s.consume("data: {\"type\":\"response.incomplete\"}") } catch { rejected=true };assert(rejected)
        rejected=false
        do { var s=AccountTrialStream();try s.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"正文\"}");try s.consume("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"model\":\"m\"}}") } catch {rejected=true};assert(rejected)
        rejected=false
        do {var s=AccountTrialStream();try s.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"正文\"}");try s.consume("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"model\":\"m\",\"usage\":{\"input_tokens\":true,\"output_tokens\":1}}}")}catch{rejected=true};assert(rejected)
        print("Offline Responses completion checks passed; no credentials/network.")
    }
    static func run() async throws {
        if Array(CommandLine.arguments.dropFirst()) == ["--self-test"] {try selfTest();return}
        guard CommandLine.arguments.count == 1 else {throw AccountTrialError.input}
        let data=try Data(contentsOf:root.appendingPathComponent("account-minimal-messages-v1.jsonl"))
        guard hash(data) == inputSHA else {throw AccountTrialError.input}
        let rows=try String(decoding:data,as:UTF8.self).split(separator:"\n").map { line -> [String:Any] in
            guard let r=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
                  let id=r["case"] as? String,cases.contains(id),let text=r["polishInputText"] as? String,
                  let messages=r["messages"] as? [[String:String]],messages.count==2,
                  messages[0]["role"]=="system",messages[1]["role"]=="user",messages[1]["content"]==text,
                  try JSONSerialization.data(withJSONObject:messages).count <= 16384 else {throw AccountTrialError.input}
            return r
        }
        guard rows.count==6,Set(rows.compactMap {$0["case"] as? String})==cases else {throw AccountTrialError.input}
        // Fixed exclusive journal also locks out a second run after unknown execution.
        let journal=try exclusive(root.appendingPathComponent("account-minimal-starts-v1.jsonl"));defer{try? journal.close()}
        let out=try exclusive(root.appendingPathComponent("account-minimal-screen-v1.jsonl"));defer{try? out.close()}
        try write(["event":"run","inputSHA256":inputSHA,"maxRequests":12,"refreshEnabled":false],to:journal)
        guard let saved=try existingSessionWithoutUI(),saved.tokenIsUsable(now:Date()) else {throw AccountTrialError.session}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=60
        let session=URLSession(configuration:config,delegate:AccountRejectRedirects(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        for (index,row) in rows.enumerated() {
            let order=index%2==0 ? models : models.reversed().map{$0}
            for model in order {
                let messages=row["messages"] as! [[String:String]],id=UUID().uuidString
                let body:[String:Any]=["model":model,"instructions":messages[0]["content"]!,"input":[["type":"message","role":"user","content":[["type":"input_text","text":messages[1]["content"]!]]]],"stream":true,"store":false,"reasoning":["effort":"none"]]
                var request=URLRequest(url:URL(string:"https://chatgpt.com/backend-api/codex/responses")!)
                request.httpMethod="POST";request.setValue("Bearer "+saved.accessToken,forHTTPHeaderField:"Authorization")
                if let account=saved.chatGPTAccountID {request.setValue(account,forHTTPHeaderField:"ChatGPT-Account-ID")}
                request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("ChatType/0.5",forHTTPHeaderField:"User-Agent")
                request.httpBody=try JSONSerialization.data(withJSONObject:body)
                try write(["event":"request-start","id":id,"case":row["case"]!,"model":model,"bodySHA256":hash(request.httpBody!)],to:journal)
                let began=DispatchTime.now().uptimeNanoseconds
                func elapsed()->Double {Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000}
                var stream=AccountTrialStream(),status:Int?,mime:String?,headers:Double?,first:Double?,ready:Double?,failure:String?
                do {
                    let (bytes,response)=try await session.bytes(for:request);defer{bytes.task.cancel()}
                    status=(response as? HTTPURLResponse)?.statusCode;mime=response.mimeType;headers=elapsed()
                    guard status==200 else {throw AccountTrialError.http(status ?? 0)}
                    for try await line in bytes.lines {
                        try stream.consume(line)
                        if !stream.text.isEmpty && first==nil {first=elapsed()}
                        if stream.completed {ready=elapsed();break}
                    }
                    guard stream.completed,stream.model==model else {throw AccountTrialError.stream}
                } catch {failure=String(describing:type(of:error))}
                var result:[String:Any]=["case":row["case"]!,"group":row["group"]!,"requestedModel":model,"id":id,"rawModelOutput":stream.text,"status":failure==nil ? "completed":"failed","auditFinishedMs":elapsed()]
                result["responseModel"]=stream.model;result["usage"]=stream.usage;result["rawModelReadyMs"]=ready
                result["httpStatus"]=status;result["responseMIME"]=mime;result["headersMs"]=headers;result["firstTextMs"]=first;result["errorType"]=failure
                try write(result,to:out);try write(["event":"request-end","id":id,"status":result["status"]!],to:journal)
                print("Account trial: \(row["case"]!) \(model) \(result["status"]!)")
                if failure != nil {throw AccountTrialError.stream}
            }
        }
    }
}
@main struct AccountResearchMain {
    static func main() async {
        do {try await AccountTrial.run()}
        catch {FileHandle.standardError.write(Data("Account research stopped: \(String(describing:type(of:error))); evidence retained.\n".utf8));exit(1)}
    }
}
