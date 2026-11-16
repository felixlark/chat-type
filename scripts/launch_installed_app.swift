import AppKit
import Foundation

// LaunchServices supplies the actual NSRunningApplication instead of guessing
// a process-start deadline. Reuse an exact live installation without sending
// a reopen event, which could open Settings or activate a window.
guard CommandLine.arguments.count == 2 else { exit(64) }
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let executable = target.appendingPathComponent("Contents/MacOS/ChatType").standardizedFileURL

func finish(_ app: NSRunningApplication?) -> Never {
    guard let app, !app.isTerminated,
          app.bundleURL?.standardizedFileURL == target,
          app.executableURL?.standardizedFileURL == executable else {
        FileHandle.standardError.write(Data("Normal installed ChatType launch failed.\n".utf8))
        exit(1)
    }
    let result: [String: Any] = ["pid": app.processIdentifier, "path": target.path]
    do {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(0)
    } catch { exit(1) }
}

if let running = NSWorkspace.shared.runningApplications.first(where: {
    !$0.isTerminated && $0.bundleURL?.standardizedFileURL == target
}) {
    finish(running)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.promptsUserIfNeeded = false
configuration.addsToRecentItems = false
configuration.allowsRunningApplicationSubstitution = false
configuration.arguments = []
NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, _ in
    finish(app)
}
RunLoop.main.run()
