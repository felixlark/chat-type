import Foundation
import Testing
@testable import ChatType

@Test
func qualityEvaluationRejectsUnapprovedProvidersBeforeReadingCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = directory.appendingPathComponent("suite.json")
    try Data(#"{"schemaVersion":1,"cases":[{"id":"one","audio":"missing.wav","kind":"synthetic","durationSeconds":1}]}"#.utf8).write(to: suite)
    for compatible in [true, false] {
        var config = legacyAccountConfig()
        if compatible { config.transcription.provider = .openAICompatible }
        else { config.transcription.textPolish.provider = .qwenFlash }
        let snapshot = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(config).write(to: snapshot)
        let output = directory.appendingPathComponent("result.jsonl")
        do {
            try await QualityEvaluationCLI.run(arguments: ["--suite", suite.path, "--output", output.path,
                                                            "--config-snapshot", snapshot.path])
            Issue.record("An unapproved provider reached evaluation")
        } catch QualityEvaluationCLI.EvaluationError.unapprovedProvider {
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}

@Test
func qualityEvaluationRejectsDuplicateCaseIDsBeforeLoadingConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = directory.appendingPathComponent("suite.json")
    let fixture: [String: Any] = ["id": "one", "audio": "missing.wav", "kind": "synthetic", "durationSeconds": 1]
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "cases": [fixture, fixture]]).write(to: suite)
    do {
        try await QualityEvaluationCLI.run(arguments: ["--suite", suite.path, "--output", directory.appendingPathComponent("result.jsonl").path])
        Issue.record("Duplicate case ids reached evaluation")
    } catch QualityEvaluationCLI.EvaluationError.invalidSuite {}
}
