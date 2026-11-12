import Foundation
import Testing
@testable import ChatType

private final class PolishRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(URLRequest, String)] = []
    func append(_ request: URLRequest, body: String) { lock.withLock { requests.append((request, body)) } }
    func urls() -> [String] { lock.withLock { requests.map { $0.0.url!.absoluteString } } }
    func bodies() -> [String] { lock.withLock { requests.map(\.1) } }
}

@Test(arguments: [
    (#"{"status":"completed","output_text":"complete"}"#, true),
    (#"{"output_text":"partial"}"#, false),
    (#"{"status":"incomplete","output_text":"partial"}"#, false),
    ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"complete\"}\n\ndata: {\"type\":\"response.completed\"}\n", true),
    ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n", false),
    ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\ndata: {\"type\":\"response.failed\"}\n", false),
    ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\ndata: {\"type\":\"response.incomplete\"}\n", false),
    ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}\n", false),
])
func polishWithoutSSEMIMEStillRequiresExplicitCompletion(payload: String, succeeds: Bool) async throws {
    let polisher = OpenAICompatibleTextPolisher(config: TextPolishConfig(),
        chatGPTAuthProvider: FakeChatGPTAuthManager(), chatGPTAuthAvailable: true,
        dataLoader: { request in
            (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    do {
        let result = try await polisher.polish(text: "complete", terminologyEntries: [], hintTerms: [])
        #expect(succeeds)
        #expect(result.text == "complete")
    } catch {
        #expect(!succeeds)
    }
}

@Test func polish403ChallengeNeverRefreshesOrRetriesCredentials() async {
    let auth = FakeChatGPTAuthManager()
    let capture = PolishRequestCapture()
    let polisher = OpenAICompatibleTextPolisher(config: TextPolishConfig(), chatGPTAuthProvider: auth,
        chatGPTAuthAvailable: true, dataLoader: { request in
            capture.append(request, body: "")
            return (Data("<html>Cloudflare challenge</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: ["Content-Type": "text/html", "Server": "cloudflare"])!)
        })
    do {
        _ = try await polisher.polish(text: "请保留要求", terminologyEntries: [], hintTerms: [])
        Issue.record("A challenge was accepted as successful polish")
    } catch {}
    #expect(auth.refreshCallCount == 0)
    #expect(capture.urls().count == 1)
}

@Test func polish401RefreshesOnceAndExplicitLowEffortIsSent() async throws {
    let auth = FakeChatGPTAuthManager(bestTokens: [.success("initial")], refreshTokens: [.success("fresh")])
    let capture = PolishRequestCapture()
    let polisher = OpenAICompatibleTextPolisher(config: TextPolishConfig(), chatGPTAuthProvider: auth,
        chatGPTAuthAvailable: true, reasoningEffort: "low", dataLoader: { request in
            capture.append(request, body: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let initial = request.value(forHTTPHeaderField: "Authorization") == "Bearer initial"
            return (Data((initial ? "{}" : #"{"status":"completed","output_text":"complete"}"#).utf8),
                HTTPURLResponse(url: request.url!, statusCode: initial ? 401 : 200, httpVersion: nil, headerFields: nil)!)
        })
    let result = try await polisher.polish(text: "complete", terminologyEntries: [], hintTerms: [])
    #expect(result.text == "complete")
    #expect(auth.refreshCallCount == 1)
    #expect(capture.urls().count == 2)
    for body in capture.bodies() {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let reasoning = object?["reasoning"] as? [String: String]
        #expect(reasoning?["effort"] == "low")
    }
}

@Test func compactPolishKeepsInputAndIdentityRulesWithoutConcreteBusinessExamples() {
    let input = "smart shade 是普通短语，之后改为蓝色。"
    let entries = [TerminologyEntry(type: .correction, original: "smart shade", replacement: "smart shade",
        aliases: [], source: "user", usageCount: 0, createdAt: "test")]
    let standard = TextPolishPromptBuilder().buildMessages(transcript: input, terminologyEntries: entries, config: TextPolishConfig())
    let compact = TextPolishPromptBuilder(style: .compactEditing).buildMessages(transcript: input, terminologyEntries: entries, config: TextPolishConfig())
    #expect(compact.last?.content == input)
    #expect(standard.last?.content == compact.last?.content)
    let system = compact.first?.content ?? ""
    #expect(system.contains("smart shade"))
    #expect(system.contains("Later self-corrections"))
    #expect(!system.contains("只修改设置页"))
    #expect(!system.contains("先不要发布"))
}

@Test func polishEvaluationRejectsNewProviderBeforeReadingCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = directory.appendingPathComponent("suite.json")
    try Data(#"{"schemaVersion":1,"cases":[{"id":"one","text":"keep this","group":"short"}]}"#.utf8).write(to: suite)
    var config = AppConfig()
    config.transcription.textPolish.provider = .qwenFlash
    let snapshot = directory.appendingPathComponent("config.json")
    try JSONEncoder().encode(config).write(to: snapshot)
    let output = directory.appendingPathComponent("out.jsonl")
    do {
        try await PolishEvaluationCLI.run(arguments: ["--suite", suite.path, "--output", output.path, "--config-snapshot", snapshot.path])
        Issue.record("A new paid provider reached the account-only evaluator")
    } catch PolishEvaluationCLI.EvaluationError.unapprovedProvider {}
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
