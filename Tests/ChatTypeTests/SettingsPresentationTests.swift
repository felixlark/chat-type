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

@MainActor
private final class RecordingStatusMenu: StatusMenuUpdating {
    private(set) var ensureVisibleCount = 0

    func update(state: StatusMenuVisualState, detail: String) {}

    func ensureVisible() {
        ensureVisibleCount += 1
    }
}
