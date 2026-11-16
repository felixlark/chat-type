import AppKit
import Testing
@testable import ChatType

@MainActor
private final class Target: LiveTextTarget {
    var value: String? = "前🙂选中后"
    var selection: NSRange? = NSRange(location: 3, length: 2)
    var frame: CGRect? = CGRect(x: 10, y: 20, width: 400, height: 80)
    var rejects = false
    var transforms = false
    var writes = 0
    var caret = 0
    func write(_ value: String, caret: Int) -> Bool {
        writes += 1
        guard !rejects else { return false }
        self.value = transforms ? value + "edited" : value
        self.caret = caret
        return !transforms
    }
}

@MainActor
private final class Preview: LiveTextPresenting {
    var text: String?
    var frame: CGRect?
    func show(_ text: String, frame: CGRect) { self.text = text; self.frame = frame }
    func hide() { text = nil }
}

@MainActor
private final class Clipboard: TextInjecting {
    var copied: String?
    func copyToClipboard(text: String) throws -> InjectionOutcome { copied = text; return .copiedToClipboard(reason: .userSelected) }
    func inject(text: String, preserveClipboard: Bool, restoreDelayMilliseconds: UInt64, launchAppContext: LaunchAppContext?) throws -> InjectionOutcome {
        Issue.record("Pinned live output must never use current-focus injection")
        return .pasted
    }
}

@MainActor private final class Focus {
    var target: Target
    init(_ target: Target) { self.target = target }
}

@Test @MainActor func pinnedInputRevisesUTF16SelectionAndFinalizesWithoutRecapturingFocus() throws {
    let original = Target(); let other = Target(); let preview = Preview(); let clipboard = Clipboard()
    let focus = Focus(original); var captures = 0
    let input = LiveTextInput(capture: { _ in captures += 1; return focus.target }, preview: preview)
    input.begin(context: nil, enabled: true)
    input.update("初稿")
    #expect(original.value == "前🙂初稿后")
    focus.target = other
    input.update("实时修正")
    #expect(original.value == "前🙂实时修正后")
    #expect(other.writes == 0 && captures == 1)
    #expect(try input.finish("终稿", injector: clipboard) == .pasted)
    #expect(original.value == "前🙂终稿后" && original.caret == 5)
    input.reset()
    #expect(original.value == "前🙂终稿后" && clipboard.copied == nil)
}

@Test @MainActor func cancellationRestoresOriginalAndRetryRetainsPinnedTarget() throws {
    let target = Target(); let input = LiveTextInput(capture: { _ in target }, preview: Preview())
    input.begin(context: nil, enabled: true); input.update("草稿")
    input.suspend()
    #expect(target.value == "前🙂选中后")
    #expect(input.hasSession)
    #expect(try input.finish("重跑终稿", injector: Clipboard()) == .pasted)
    #expect(target.value == "前🙂重跑终稿后")
    input.begin(context: nil, enabled: true); input.update("下一段")
    input.reset()
    #expect(target.value == "前🙂重跑终稿后")
    #expect(!input.hasSession)
}

@Test @MainActor func editsAfterPreviewRemainUntouchedAndFinalGoesToClipboard() throws {
    let target = Target(); let preview = Preview(); let clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in target }, preview: preview)
    input.begin(context: nil, enabled: true); input.update("草稿")
    target.value = "手工修改了草稿"
    input.update("新草稿")
    #expect(target.value == "手工修改了草稿")
    #expect(preview.text == "新草稿" && preview.frame == target.frame)
    #expect(try input.finish("最终结果", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(target.value == "手工修改了草稿" && clipboard.copied == "最终结果")
    #expect(preview.text == nil)
}

@Test @MainActor func rejectedAndTransformedWritesUseSeparateInputPreview() throws {
    for transforms in [false, true] {
        let target = Target(); target.rejects = !transforms; target.transforms = transforms
        let preview = Preview(); let clipboard = Clipboard()
        let input = LiveTextInput(capture: { _ in target }, preview: preview)
        input.begin(context: nil, enabled: true); input.update("草稿")
        #expect(preview.text == "草稿" && preview.frame == target.frame)
        let current = target.value
        input.suspend()
        #expect(target.value == current && preview.text == nil)
        #expect(try input.finish("终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
        #expect(target.value == current && clipboard.copied == "终稿")
    }
}

@Test @MainActor func unavailableOrUnreadableTargetsKeepRecordingSessionAndClipboardOutput() throws {
    for missing in [false, true] {
        let target = Target(); target.selection = nil; target.rejects = true
        let preview = Preview(); let clipboard = Clipboard()
        let input = LiveTextInput(capture: { _ in missing ? nil : target }, preview: preview)
        input.begin(context: nil, enabled: true); input.update("实时文字")
        #expect(input.hasSession)
        #expect(preview.text == (missing ? nil : "实时文字"))
        target.frame = nil; input.update("实时文字")
        #expect(preview.text == nil)
        #expect(try input.finish("终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    }
}

@Test @MainActor func clipboardOnlyDoesNotCaptureOrChangeAnyInput() throws {
    let input = LiveTextInput(capture: { _ in Issue.record("Must not inspect target"); return nil }, preview: Preview())
    input.begin(context: nil, enabled: false); input.update("草稿")
    #expect(try input.finish("终稿", injector: Clipboard()) == nil)
}

@Test func invalidLiveSelectionDoesNotProduceInsertionPlan() {
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 4, length: 0)) == nil)
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 1, length: 3)) == nil)
}

@Test @MainActor func stoppingRecordingHidesFallbackBeforeProcessingWhileRetainingTarget() throws {
    let target = Target(); target.rejects = true
    let preview = Preview(); let input = LiveTextInput(capture: { _ in target }, preview: preview)
    input.begin(context: nil, enabled: true); input.update("草稿")
    #expect(preview.text == "草稿")
    input.endRecording()
    #expect(preview.text == nil && input.hasSession)
    target.frame = nil
    #expect(try input.finish("终稿", injector: Clipboard()) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(preview.text == nil)
}
