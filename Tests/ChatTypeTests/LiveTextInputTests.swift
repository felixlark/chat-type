import AppKit
import ApplicationServices
import Testing
@testable import ChatType

@MainActor private final class Target: LiveTextTarget {
    var value: String? = "前🙂选中后"
    var selection: NSRange? = NSRange(location: 3, length: 2)
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

@Test @MainActor func capturedTargetIsUnmodifiedUntilFinalAndUsesOriginalUTF16Selection() async throws {
    let target = Target(), other = Target(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in target })
    input.begin(context: nil, enabled: true); await input.prepare()
    #expect(target.value == "前🙂选中后" && target.writes == 0)
    #expect(try await input.finish("终稿", injector: clipboard) == .pasted)
    #expect(target.value == "前🙂终稿后" && target.writes == 1 && target.caret == 5)
    #expect(other.writes == 0 && clipboard.copied == nil)
}

@Test @MainActor func suspendKeepsOriginalTargetForRetryWithoutWriting() {
    let target = Target(); let input = LiveTextInput(capture: { _ in target })
    input.begin(context: nil, enabled: true); input.suspend()
    #expect(target.writes == 0 && input.hasSession)
    input.reset(); #expect(!input.hasSession)
}

@Test @MainActor func manualEditsPreservedAndFinalCopiedTruthfully() async throws {
    let target = Target(), clipboard = Clipboard()
    let input = LiveTextInput(capture: { _ in target })
    input.begin(context: nil, enabled: true)
    target.value = "后来手工写入"
    #expect(try await input.finish("终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(target.value == "后来手工写入" && target.writes == 0 && clipboard.copied == "终稿")
}

@Test(arguments: [false, true]) @MainActor
func appliedButUnverifiedAXFinalNeverCopiesOrRollsBack(unreadable: Bool) async {
    let target = Target(), clipboard = Clipboard()
    target.unreadable = unreadable; target.transformed = !unreadable
    let input = LiveTextInput(capture: { _ in target })
    input.begin(context: nil, enabled: true)
    do { _ = try await input.finish("终稿", injector: clipboard); Issue.record("Must report unknown output") }
    catch { #expect(error is EditorDeliveryError) }
    input.suspend(); input.reset()
    #expect(target.writes == 1 && clipboard.copied == nil)
    #expect(target.value == (unreadable ? "前🙂终稿后" : "前🙂终稿后edited"))
}

@Test @MainActor func actualEditorRouteWorksWithoutAnyAXTextElementAndRetainsPinForRetry() async throws {
    let editor = Editor(), clipboard = Clipboard()
    var captures = 0
    let input = LiveTextInput(capture: { _ in captures += 1; return nil }, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    input.suspend()
    #expect(editor.commits.isEmpty && captures == 0 && editor.closeCount == 0)
    #expect(try await input.finish("重跑终稿", injector: clipboard) == .pasted)
    #expect(editor.commits == ["重跑终稿"] && editor.closeCount == 1 && clipboard.copied == nil)
}

@Test @MainActor func missingEditorReadinessCannotClaimPasteOrRecaptureFocus() async throws {
    let editor = Editor(), clipboard = Clipboard(); editor.ready = false
    let input = LiveTextInput(capture: { _ in nil }, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    #expect(try await input.finish("保留终稿", injector: clipboard) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(editor.commits.isEmpty && clipboard.copied == "保留终稿")
}

@Test @MainActor func uncertainEditorCommitNeverCopiesAnotherFinal() async {
    let editor = Editor(), clipboard = Clipboard(); editor.unknown = true
    let input = LiveTextInput(capture: { _ in nil }, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    do { _ = try await input.finish("终稿", injector: clipboard); Issue.record("Must report uncertainty") }
    catch { #expect(error is EditorDeliveryError) }
    #expect(editor.commits == ["终稿"] && clipboard.copied == nil)
}

@Test @MainActor func staleFinalReceiptCannotResetTheNextComposition() async {
    let editor = Editor(); editor.wait = true
    let input = LiveTextInput(capture: { _ in nil }, editorFactory: { _ in editor })
    input.begin(context: nil, enabled: true); await input.prepare()
    let finish = Task { try await input.finish("旧终稿", injector: Clipboard()) }
    while editor.gate == nil { await Task.yield() }
    input.reset(); input.begin(context: nil, enabled: true)
    editor.gate?.resume()
    do { _ = try await finish.value; Issue.record("Old final must not complete new session") } catch { #expect(error is CancellationError) }
    #expect(input.hasSession)
    input.reset()
}

@Test @MainActor func clipboardOnlyDoesNotCaptureAnyInput() async throws {
    let input = LiveTextInput(capture: { _ in Issue.record("Must not inspect target"); return nil })
    input.begin(context: nil, enabled: false)
    #expect(try await input.finish("终稿", injector: Clipboard()) == nil)
}
@Test func invalidUTF16SelectionCannotReplaceText() {
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 4, length: 0)) == nil)
    #expect(LiveTextSpan(value: "abc", selection: NSRange(location: 1, length: 3)) == nil)
}
