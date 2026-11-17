import AppKit
import Testing
@testable import ChatType

@MainActor private final class PasteProbe: PinnedPasteTarget {
    private var storedValue: String? = "前🙂选中后"
    var onRead: (() -> Void)?
    var value: String? {
        get { onRead?(); return storedValue }
        set { storedValue = newValue }
    }
    let processIdentifier: pid_t = 12345
    var placeholderLabel: String?
    var focus = false
    var requested: [NSRange] = []
    var checks = 0
    var onCheck: ((Int) -> Void)?
    func requestPasteFocus(selection: NSRange) { requested.append(selection); focus = true }
    func hasPasteFocus(selection: NSRange) -> Bool { checks += 1; onCheck?(checks); return focus }
}

@MainActor private final class WebInputProbe: LiveTextTarget {
    let pin: PasteProbe
    var writes = 0
    init(_ pin: PasteProbe) { self.pin = pin }
    var value: String? { pin.value }
    var selection: NSRange? { NSRange(location: 3, length: 2) }
    var nativePasteTarget: (any PinnedPasteTarget)? { pin }
    func write(_ value: String, caret: Int) -> LiveTextWriteResult { writes += 1; return .rejected }
}

@Test @MainActor func webTargetRestoresOriginalPinAndUsesOneVerifiedNativePaste() async throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe(), target = WebInputProbe(pin)
    var posts: [pid_t?] = []
    let injector = TextInjector(pasteboard: board, sendPaste: { pid in
        posts.append(pid); pin.value = "前🙂终稿后"
    }, settleAfterPaste: {})
    let input = LiveTextInput(capture: { _ in target })
    input.begin(context: nil, enabled: true)
    #expect(try await input.finish("终稿", injector: injector) == .pasted)
    #expect(posts == [pin.processIdentifier] && target.writes == 0)
    #expect(pin.requested == [NSRange(location: 3, length: 2)])
}

@Test @MainActor func unacknowledgedNativePasteNeverPostsTwiceOrClaimsSuccess() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe()
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    var posts = 0
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in posts += 1 }, settleAfterPaste: {})
    do { _ = try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: InjectionConfig()); Issue.record("Missing receipt must remain unknown") }
    catch { #expect(error is EditorDeliveryError) }
    #expect(posts == 1 && pin.value == span.original)
}

@Test @MainActor func delayedExactNativeReceiptIsObservedWithoutPostingAgain() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe()
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    var posts = 0, postReads = 0
    pin.onRead = {
        if posts == 1 {
            postReads += 1
            if postReads == 2 { pin.value = "前🙂终稿后" }
        }
    }
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in posts += 1 }, settleAfterPaste: {})
    #expect(try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: InjectionConfig()) == .pasted)
    #expect(posts == 1 && postReads == 2)
}

@Test @MainActor func unknownReceiptNeverRestoresClipboardBeforePossibleDelayedConsumption() async throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setString("original clipboard", forType: .string)
    let pin = PasteProbe()
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    var posts = 0
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in posts += 1 }, settleAfterPaste: {})
    var config = InjectionConfig(); config.preserveClipboard = true; config.restoreDelayMilliseconds = 0
    do { _ = try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: config); Issue.record("Missing receipt must remain unknown") }
    catch { #expect(error is EditorDeliveryError) }
    for _ in 0..<10 { await Task.yield() }
    #expect(posts == 1 && board.string(forType: .string) == "终稿")
}

@Test @MainActor func changedPinnedSelectionCannotPasteIntoAnotherFocusedInput() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe()
    pin.onCheck = { count in if count == 2 { pin.focus = false } }
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    var posts = 0
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in posts += 1 }, settleAfterPaste: {})
    #expect(try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: InjectionConfig()) == .copiedToClipboard(reason: .originalTargetUnavailable))
    #expect(posts == 0 && pin.value == span.original)
}

@Test @MainActor func clipboardChangeBeforeEventPreventsPasteOfSomeoneElsesCopy() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe()
    pin.onCheck = { count in if count == 2 { board.clearContents(); board.setString("later user copy", forType: .string) } }
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    var posts = 0
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in posts += 1 }, settleAfterPaste: {})
    do { _ = try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: InjectionConfig()); Issue.record("Changed clipboard must stop output") }
    catch { #expect(error as? InjectionError == .clipboardChanged) }
    #expect(posts == 0 && board.string(forType: .string) == "later user copy")
}

@Test(arguments: [false, true]) @MainActor
func clipboardRestoresOnlyAfterReceiptAndOnlyWhileStillOwned(newCopy: Bool) async throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setString("original clipboard", forType: .string)
    let pin = PasteProbe()
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 3, length: 2)))
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in
        #expect(board.string(forType: .string) == "终稿")
    }, settleAfterPaste: {
        #expect(board.string(forType: .string) == "终稿")
        pin.value = "前🙂终稿后"
        if newCopy { board.clearContents(); board.setString("later user copy", forType: .string) }
    })
    var config = InjectionConfig(); config.preserveClipboard = true; config.restoreDelayMilliseconds = 0
    #expect(try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: config) == .pasted)
    for _ in 0..<10 { await Task.yield() }
    #expect(board.string(forType: .string) == (newCopy ? "later user copy" : "original clipboard"))
}

@Test func emptyChromiumPlaceholderReceiptRequiresExactWholeContent() throws {
    let span = try #require(LiveTextSpan(value: "Work with Codex\n", selection: NSRange(location: 0, length: 0)))
    #expect(PinnedPasteReceipt.matches(observed: "终稿", span: span, inserted: "终稿", placeholder: "Work with Codex"))
    #expect(PinnedPasteReceipt.matches(observed: "终稿\n", span: span, inserted: "终稿", placeholder: "Work with Codex"))
    #expect(PinnedPasteReceipt.matches(observed: "终稿Work with Codex\n", span: span, inserted: "终稿", placeholder: "Work with Codex"))
    #expect(!PinnedPasteReceipt.matches(observed: "别的终稿\n", span: span, inserted: "终稿", placeholder: "Work with Codex"))
    #expect(!PinnedPasteReceipt.matches(observed: "终稿\n\n", span: span, inserted: "终稿", placeholder: "Work with Codex"))
    #expect(!PinnedPasteReceipt.matches(observed: "终稿\n", span: span, inserted: "终稿", placeholder: "different"))
    #expect(!PinnedPasteReceipt.matches(observed: nil, span: span, inserted: "终稿", placeholder: "Work with Codex"))
}

@Test func emptyWebParagraphReceiptRequiresExactWholeContent() throws {
    let span = try #require(LiveTextSpan(value: "\n", selection: NSRange(location: 0, length: 0)))
    for final in ["终稿。", "第一行。\n第二行。", "保留末尾换行。\n"] {
        #expect(PinnedPasteReceipt.matches(observed: final, span: span, inserted: final, placeholder: nil))
        #expect(PinnedPasteReceipt.matches(observed: final + "\n", span: span, inserted: final, placeholder: nil))
        #expect(!PinnedPasteReceipt.matches(observed: final + "\n\n", span: span, inserted: final, placeholder: nil))
        #expect(!PinnedPasteReceipt.matches(observed: "别的" + final, span: span, inserted: final, placeholder: nil))
    }
    #expect(!PinnedPasteReceipt.matches(observed: nil, span: span, inserted: "终稿。", placeholder: nil))
    let nonempty = try #require(LiveTextSpan(value: "原文\n", selection: NSRange(location: 0, length: 0)))
    #expect(!PinnedPasteReceipt.matches(observed: "终稿。", span: nonempty, inserted: "终稿。", placeholder: nil))
    let afterParagraph = try #require(LiveTextSpan(value: "\n", selection: NSRange(location: 1, length: 0)))
    #expect(!PinnedPasteReceipt.matches(observed: "终稿。", span: afterParagraph, inserted: "终稿。", placeholder: nil))
}

@Test @MainActor func emptyWebParagraphNativePasteIsAcknowledgedWithoutAnotherEvent() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe(); pin.value = "\n"
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 0, length: 0)))
    var posts = 0
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in
        posts += 1; pin.value = "原输入框收到终稿。"
    }, settleAfterPaste: {})
    #expect(try injector.injectPinned(text: "原输入框收到终稿。", span: span, target: pin, configuration: InjectionConfig()) == .pasted)
    #expect(posts == 1)
}

@Test(arguments: ["终稿", "终稿\n"]) @MainActor
func nativePasteUsesCapturedPlaceholderLabelForReceipt(observed: String) throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let pin = PasteProbe(); pin.value = "Work with Codex\n"; pin.placeholderLabel = "Work with Codex"
    let span = try #require(LiveTextSpan(value: pin.value!, selection: NSRange(location: 0, length: 0)))
    let injector = TextInjector(pasteboard: board, sendPaste: { _ in
        pin.placeholderLabel = nil; pin.value = observed
    }, settleAfterPaste: {})
    #expect(try injector.injectPinned(text: "终稿", span: span, target: pin, configuration: InjectionConfig()) == .pasted)
}
