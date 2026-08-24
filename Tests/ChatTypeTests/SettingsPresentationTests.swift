import AppKit
import Testing
@testable import ChatType

@Test @MainActor
func approvedStatusMenuPresentationPreservesOriginalDynamicIcon() {
    let states: [StatusMenuVisualState] = [
        .ready,
        .setupRequired,
        .recording,
        .processing,
        .error,
        .demo,
    ]

    for state in states {
        let presentation = StatusMenuButtonPresentation.approved(for: state)
        #expect(presentation.title.isEmpty)
        #expect(presentation.image.size == NSSize(width: 18, height: 18))
        #expect(presentation.image.isTemplate)
        #expect(presentation.imagePosition == .imageOnly)
        #expect(presentation.imageScaling == .scaleProportionallyDown)
        #expect(presentation.accessibilityLabel == "ChatType \(state.stateDescription)")
        #expect(presentation.toolTip == "ChatType: \(state.stateDescription)")
    }
}

@Test @MainActor
func showingAndClosingSettingsKeepsMenuBarOnlyActivationPolicy() {
    let app = NSApplication.shared
    let originalPolicy = app.activationPolicy()
    defer {
        app.setActivationPolicy(originalPolicy)
    }

    app.setActivationPolicy(.accessory)
    let coordinator = AppCoordinator(
        authManager: ChatGPTAuthManager(store: InMemoryChatGPTSessionStore())
    )
    let statusMenu = RecordingStatusMenu()
    coordinator.statusMenu = statusMenu

    coordinator.showSettings()

    let settingsWindow = app.windows.first { $0.title == "ChatType Settings" }
    #expect(app.activationPolicy() == .accessory)
    #expect(settingsWindow?.isVisible == true)
    #expect(statusMenu.ensureVisibleCount == 2)

    settingsWindow?.close()
    #expect(app.activationPolicy() == .accessory)
    #expect(statusMenu.ensureVisibleCount == 3)
}

@Test @MainActor
func settingsWindowCommandQInvokesQuitHandler() throws {
    var didRequestQuit = false
    let window = CommandClosingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false,
        onQuit: { didRequestQuit = true }
    )
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "q",
        charactersIgnoringModifiers: "q",
        isARepeat: false,
        keyCode: 12
    ))

    #expect(window.performKeyEquivalent(with: event))
    #expect(didRequestQuit)
}

@MainActor
private final class RecordingStatusMenu: StatusMenuUpdating {
    private(set) var ensureVisibleCount = 0

    func update(state: StatusMenuVisualState, detail: String) {}

    func ensureVisible() {
        ensureVisibleCount += 1
    }
}
