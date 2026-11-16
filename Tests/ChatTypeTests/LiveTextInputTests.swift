import AppKit
import ApplicationServices
import Testing
@testable import ChatType

@MainActor private final class Target: LiveTextTarget {
    var value: String? = "前🙂选中后"
    var selection: NSRange? = NSRange(location: 3, length: 2)
    var anchor: InputCompositionAnchor? = InputCompositionAnchor(caret: CGRect(x: 20, y: 50, width: 1, height: 20),
        input: CGRect(x: 10, y: 20, width: 400, height: 80), font: .systemFont(ofSize: 16), foreground: .black, background: .white)
    var rejects = false
    var transformed = false
    var unreadable = false
    var nativePasteTarget: (any PinnedPasteTarget)?
    var writes = 0
    var caret = 0
    func write(_ value: String, caret: Int) -> LiveTextWriteResult {
        writes += 1
        if rejects { return .rejected }
        self.value = transformed ? value + "edited" : value
        self.caret = caret
        return .applied(observedValue: unreadable ? nil : self.value)
    }
}
@MainActor private final class Composition: InputCompositionPresenting {
    var text: String?
    var rendered = true
    var provider: (@MainActor () async -> InputCompositionAnchor?)?
    func show(_ text: String, anchor: @escaping @MainActor () async -> InputCompositionAnchor?) { self.text = text; provider = anchor }
    func waitUntilRendered(_ text: String) async -> Bool { rendered }
    func hide() { text = nil; provider = nil }
}
@MainActor private final class LiveInputHolder { var input: LiveTextInput? }
private actor PreviewDwellGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    var waiting: Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
}
@MainActor private final class Clipboard: TextInjecting {
    var copied: String?
    func copyToClipboard(text: String) throws -> InjectionOutcome { copied = text; return .copiedToClipboard(reason: .userSelected) }
    func inject(text: String, preserveClipboard: Bool, restoreDelayMilliseconds: UInt64, launchAppContext: LaunchAppContext?) throws -> InjectionOutcome {
        Issue.record("Pinned output must not use current focus"); return .pasted
    }
}
@MainActor private final class Editor: PinnedEditorSession {
    var commits: [String] = []
    var ready = true
    var applied = true
    var unknown = false
    var closeCount = 0
    var gate: CheckedContinuation<Void, Never>?
    var wait = false
    func prepare() async throws -> EditorBridgeResponse {
        if !ready { throw EditorDeliveryError.unavailable }
        return EditorBridgeResponse(protocol: 1, build: 136, status: "active")
    }
    func geometry() async throws -> EditorBridgeResponse { EditorBridgeResponse(protocol: 1, build: 136, status: "active", visible: true) }
    func commit(_ text: String) async throws -> Bool {
        commits.append(text)
        if wait { await withCheckedContinuation { gate = $0 } }
        if unknown { throw EditorDeliveryError.outputUnknown }
        return applied
    }
    func cancelPending() {}
    func close() { closeCount += 1 }
}

@Test @MainActor func liveCompositionDoesNotModifyDocumentAndFinalUsesOriginalSelection() async throws {
    let original = Target(), other = Target(), composition = Composition(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in original }, composition: composition)
    input.begin(context: nil, enabled: true); await input.prepare()
    input.update("实时初稿"); input.update("完整初稿")
    #expect(original.value == "前🙂选中后" && original.writes == 0)
    #expect(composition.text == "完整初稿")
    #expect(await composition.provider?()?.font.pointSize == 16)
    input.endRecording()
    #expect(composition.text == "完整初稿")
    #expect(try await input.finish("终稿", injector: clipboard) == .pasted)
    #expect(original.value == "前🙂终稿后" && original.writes == 1 && original.caret == 5)
    #expect(other.writes == 0 && clipboard.copied == nil && composition.text == nil)
}

@Test @MainActor func cancellingOrFailedProcessingOnlyRemovesComposition() {
    let target = Target(), composition = Composition()
    let input = LiveTextInput(capture: { _ in target }, composition: composition)
    input.begin(context: nil, enabled: true); input.update("草稿"); input.suspend()
    #expect(target.value == "前🙂选中后" && target.writes == 0 && composition.text == nil && input.hasSession)
    input.reset()
    #expect(!input.hasSession && target.writes == 0)
}

@Test @MainActor func completeAsrTailRemainsReadableBeforeFinalHandoff() async throws {
    let composition = Composition(), target = Target(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in target }, composition: composition, previewReadDelay: {
        await MainActor.run {
            #expect(composition.text == "停录后才到达的完整末尾")
            #expect(target.writes == 0)
        }
    })
    input.begin(context: nil, enabled: true); input.update("停录前初稿")
    input.endRecording()
    try await input.completePreview("停录后才到达的完整末尾")
    #expect(composition.text == "停录后才到达的完整末尾")
    #expect(try await input.finish("终稿", injector: clipboard) == .pasted)
    #expect(composition.text == nil && target.writes == 1)
}

@Test(arguments: [false, true]) @MainActor
func unavailablePreviewNeverDelaysTargetFallback(noTarget: Bool) async throws {
    let composition = Composition(); composition.rendered = false
    let target = Target(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in noTarget ? nil : target }, composition: composition,
        previewReadDelay: { Issue.record("Unavailable preview must not wait for future visibility") })
    input.begin(context: nil, enabled: true)
    try await input.completePreview("完整末尾")
    let outcome = try await input.finish("终稿", injector: clipboard)
    #expect(outcome == (noTarget ? .copiedToClipboard(reason: .originalTargetUnavailable) : .pasted))
}

@Test @MainActor func replacementDuringPreviewReadTimeCannotCommitOrHideNewDraft() async throws {
    let composition = Composition(), target = Target()
    let holder = LiveInputHolder()
    let input = LiveTextInput(capture: { _ in target }, composition: composition, previewReadDelay: {
        await MainActor.run { holder.input?.reset(); holder.input?.begin(context: nil, enabled: true); holder.input?.update("新的录音") }
    })
    holder.input = input
    input.begin(context: nil, enabled: true)
    do { try await input.completePreview("旧的完整末尾"); Issue.record("Replaced preview must abort") }
    catch { #expect(error is CancellationError) }
    #expect(composition.text == "新的录音" && target.writes == 0)
}

@Test @MainActor func cancellationDuringCompletePreviewPreventsFinalOutput() async throws {
    let composition = Composition(), target = Target(), gate = PreviewDwellGate()
    let input = LiveTextInput(capture: { _ in target }, composition: composition, previewReadDelay: { await gate.wait() })
    input.begin(context: nil, enabled: true)
    let task = Task { try await input.completePreview("完整末尾") }
    while !(await gate.waiting) { await Task.yield() }
    task.cancel(); await gate.resume()
    do { try await task.value; Issue.record("Cancelled readable tail must abort") }
    catch { #expect(error is CancellationError) }
    #expect(target.writes == 0)
    input.reset()
}

@Test @MainActor func manualEditsPreservedAndFinalCopiedTruthfully() async throws {
    let target = Target(), composition = Composition(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in target }, composition: composition)
    input.begin(context: nil, enabled: true); input.update("草稿")
    target.value = "后来手工写入"
    #expect(await composition.provider?() == nil)
    #expect(try await input.finish("终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(target.value == "后来手工写入" && target.writes == 0 && clipboard.copied == "终稿")
}

@Test(arguments: [false, true]) @MainActor
func appliedButUnverifiedAXFinalNeverCopiesOrRollsBack(unreadable: Bool) async {
    let target = Target(), clipboard = Clipboard()
    target.unreadable = unreadable; target.transformed = !unreadable
    let input = LiveTextInput(capture: { _ in target }, composition: Composition())
    input.begin(context: nil, enabled: true)
    do { _ = try await input.finish("终稿", injector: clipboard); Issue.record("Must report unknown output") }
    catch { #expect(error is EditorDeliveryError) }
    input.suspend(); input.reset()
    #expect(target.writes == 1 && clipboard.copied == nil)
    #expect(target.value == (unreadable ? "前🙂终稿后" : "前🙂终稿后edited"))
}

@Test @MainActor func actualEditorRouteWorksWithoutAnyAXTextElementAndRetainsPinForRetry() async throws {
    let editor = Editor(), composition = Composition(), clipboard = Clipboard()
    var captures = 0
    let input = LiveTextInput(capture: { _ in captures += 1; return nil }, composition: composition, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare(); input.update("初稿")
    input.suspend()
    #expect(editor.commits.isEmpty && captures == 0 && editor.closeCount == 0)
    #expect(try await input.finish("重跑终稿", injector: clipboard) == .pasted)
    #expect(editor.commits == ["重跑终稿"] && editor.closeCount == 1 && clipboard.copied == nil)
}

@Test @MainActor func missingEditorReadinessCannotClaimPasteOrRecaptureFocus() async throws {
    let editor = Editor(), clipboard = Clipboard(); editor.ready = false
    let input = LiveTextInput(capture: { _ in nil }, composition: Composition(), editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    #expect(try await input.finish("保留终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(editor.commits.isEmpty && clipboard.copied == "保留终稿")
}

@Test @MainActor func uncertainEditorCommitNeverCopiesAnotherFinal() async {
    let editor = Editor(), clipboard = Clipboard(); editor.unknown = true
    let input = LiveTextInput(capture: { _ in nil }, composition: Composition(), editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    do { _ = try await input.finish("终稿", injector: clipboard); Issue.record("Must report uncertainty") }
    catch { #expect(error is EditorDeliveryError) }
    #expect(editor.commits == ["终稿"] && clipboard.copied == nil)
}

@Test @MainActor func staleFinalReceiptCannotResetTheNextComposition() async {
    let editor = Editor(), composition = Composition(); editor.wait = true
    let input = LiveTextInput(capture: { _ in nil }, composition: composition, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    let finish = Task { try await input.finish("旧终稿", injector: Clipboard()) }
    while editor.gate == nil { await Task.yield() }
    input.reset(); input.begin(context: nil, enabled: true); input.update("新初稿")
    editor.gate?.resume()
    do { _ = try await finish.value; Issue.record("Old final must not complete new session") } catch { #expect(error is CancellationError) }
    #expect(input.hasSession && composition.text == "新初稿")
    input.reset()
}

@Test @MainActor func clipboardOnlyDoesNotCaptureAnyInput() async throws {
    let input = LiveTextInput(capture: { _ in Issue.record("Must not inspect target"); return nil }, composition: Composition())
    input.begin(context: nil, enabled: false); input.update("草稿")
    #expect(try await input.finish("终稿", injector: Clipboard()) == nil)
}
@Test func invalidUTF16SelectionCannotReplaceText() {
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 4, length: 0)) == nil)
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 1, length: 3)) == nil)
}

@Test @MainActor func sourceFontUsesAnAdjacentWholeUTF16CharacterAndAXFontDictionary() throws {
    #expect(InputCompositionTextStyle.adjacentRange(in: "A🙂Z", caret: 1) == NSRange(location: 1, length: 2))
    #expect(InputCompositionTextStyle.adjacentRange(in: "A🙂", caret: 3) == NSRange(location: 1, length: 2))
    #expect(InputCompositionTextStyle.adjacentRange(in: "", caret: 0) == nil)
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key("AXFont"): [
        "AXFontName": "Menlo-Regular", "AXFontSize": NSNumber(value: 24)]]
    let font = InputCompositionTextStyle.font(attributes, fallbackSize: 13)
    #expect(font.pointSize == 24 && font.fontName == "Menlo-Regular")
}
