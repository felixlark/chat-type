import Foundation
import Testing

@Test
func visualAcceptanceScriptRunsInstalledChatTypeOverlayDemo() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scriptURL = root.appendingPathComponent("scripts/visual_acceptance.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    #expect(script.contains("/Applications/ChatType.app"))
    #expect(script.contains("CHATTYPE_OVERLAY_DEMO=1"))
    #expect(script.contains("--args --overlay-demo-state"))
    #expect(script.contains("find_visual_acceptance_window.swift"))
    #expect(script.contains("screencapture -x -l"))
    #expect(script.contains("verify_visual_acceptance.swift"))
    #expect(!script.contains("sleep 0.8"))
    #expect(!script.contains("00-before.png"))
    #expect(!script.contains("dist/ChatType.app/Contents/MacOS/ChatType"))
}

@Test
func visualAcceptanceWindowDiscoveryUsesCoreGraphicsWindowList() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scriptURL = root.appendingPathComponent("scripts/find_visual_acceptance_window.swift")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    #expect(script.contains("CGWindowListCopyWindowInfo"))
    #expect(script.contains("kCGWindowOwnerName"))
    #expect(script.contains("kCGWindowName"))
    #expect(script.contains("ChatType Status HUD"))
    #expect(script.contains("kCGWindowNumber"))
    #expect(script.contains("kCGWindowBounds"))
}

@Test
func visualAcceptanceVerifierDocumentsRequiredStates() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let verifierURL = root.appendingPathComponent("scripts/verify_visual_acceptance.swift")
    let verifier = try String(contentsOf: verifierURL, encoding: .utf8)

    for state in ["recording", "processing", "result", "error", "retryable-error"] {
        #expect(verifier.contains(state))
    }
    #expect(verifier.contains("visible HUD pixels"))
    #expect(verifier.contains("changed HUD-window pixels"))
    #expect(verifier.contains("distinct window size"))
    #expect(!verifier.contains("expected HUD band"))
}
