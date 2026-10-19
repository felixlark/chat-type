import AppKit

if ChatTypeCLI.runIfRequested(arguments: ProcessInfo.processInfo.arguments) {
    fatalError("ChatType CLI returned unexpectedly")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
