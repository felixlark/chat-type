import Foundation
import Testing

@Test
func printModeDescribesOfficialChromePluginWorkflow() throws {
    let result = try runPostScript(arguments: ["--print", "ChatType update"])

    #expect(result.status == 0, Comment(rawValue: result.stderr))
    #expect(result.stdout.contains("official Chrome plugin"))
    #expect(result.stdout.contains("signed-in Chrome/default profile"))
    #expect(result.stdout.contains("https://x.com/compose/post"))
    #expect(result.stdout.contains("/status/ URL"))
    #expect(!result.stdout.contains("chrome-auth"))
    #expect(!result.stdout.contains("auth-cdp"))
}

@Test
func liveModeRefusesLegacyCliPosting() throws {
    let result = try runPostScript(arguments: ["ChatType v0.5.x shipped"])

    #expect(result.status == 2)
    #expect(result.stderr.contains("Live X posting from scripts/post_x.sh is disabled."))
    #expect(result.stderr.contains("official Chrome plugin"))
    #expect(result.stdout.isEmpty)
}

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runPostScript(arguments: [String]) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["scripts/post_x.sh"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    process.environment = ProcessInfo.processInfo.environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
        status: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}
