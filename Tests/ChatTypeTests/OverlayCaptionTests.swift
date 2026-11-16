import AppKit
import Testing
@testable import ChatType

@Test func topHUDUsesMenuBarAndCameraSafetyAndCenteredCaption() {
    let visible = CGRect(x: -1000, y: 100, width: 1500, height: 900)
    let hud = TopOverlayLayout.hud(size: CGSize(width: 224, height: 44), visible: visible, safeTop: 980)
    #expect(hud.midX == visible.midX && hud.maxY == 964)
    let two = TopOverlayLayout.caption(hud: hud, visible: visible, lines: 1)
    let four = TopOverlayLayout.caption(hud: hud, visible: visible, lines: 4)
    #expect(two.midX == hud.midX && four.midX == hud.midX)
    #expect(two.maxY == hud.minY - 12 && four.maxY == two.maxY)
    #expect(two.height == 84 && four.height == 144)
}

@Test @MainActor func captionsRetainLatestSentenceAndCompleteWrappedTail() {
    #expect(OverlayCaptionText.lines("第一句。第二句话。", width: 568).joined() == "第二句话。")
    #expect(OverlayCaptionText.lines("第一句。他说“再见。”", width: 568).joined() == "他说“再见。”")
    let tail = "结尾标记🙂123"
    let long = String(repeating: "连续不断说话也不能省略最后的内容", count: 20) + tail
    let lines = OverlayCaptionText.lines(long, width: 568)
    #expect(lines.count == 4 && lines.joined().hasSuffix(tail))
    #expect(!lines.joined().contains("�"))
    for line in lines { #expect((line as NSString).size(withAttributes: OverlayCaptionText.attributes()).width <= 569) }
}

@Test func finalDrawGenerationCannotConsumeTimeDuringDeliveryOrAcceptOldDraw() {
    var state = CaptionPresentationState()
    let live = state.change(final: false)
    let liveDraw = state.didDraw(live)
    #expect(!liveDraw)
    // Delivery can block for any duration; final reading has not begun.
    let final = state.change(final: true)
    let staleDraw = state.didDraw(live)
    #expect(!staleDraw && state.awaitsFinalDraw)
    let finalDraw = state.didDraw(final), repeatedDraw = state.didDraw(final)
    #expect(finalDraw && !repeatedDraw)
    let sameStringAgain = state.change(final: true)
    let oldDraw = state.didDraw(final)
    #expect(!oldDraw && state.awaitsFinalDraw)
    state.reset()
    let cancelledDraw = state.didDraw(sameStringAgain)
    #expect(!cancelledDraw)
}

private actor CaptionDelayProbe {
    var seconds: [Double] = []
    var pending: CheckedContinuation<Void, Never>?
    func wait(_ value: Double) async { seconds.append(value); await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}

@Test @MainActor func resultReadingStartsOnlyAfterDrawAndCannotHideNextRecording() async {
    let delay = CaptionDelayProbe()
    let overlay = OverlayController(presentsPanel: false, hideDelay: { await delay.wait($0) })
    overlay.debugSetGeometry(visible: CGRect(x: 0, y: 0, width: 1200, height: 800))
    overlay.showRecording(elapsedText: "00:01")
    overlay.updateTranscriptPreview("同一段字幕结尾")
    let initialFrame = overlay.debugSnapshot.panelFrame
    overlay.showConfirming()
    #expect(overlay.debugSnapshot.displayedTitle == "确认中")
    overlay.showResult(text: "同一段字幕结尾", outcome: .pasted)
    #expect(overlay.debugHideTask == nil)
    overlay.debugAcknowledgeCaptionDraw()
    let oldHide = overlay.debugHideTask
    while await delay.seconds.isEmpty { await Task.yield() }
    #expect(await delay.seconds == [1.5])
    overlay.hide(); overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("下一次录音")
    await delay.release(); await oldHide?.value
    #expect(overlay.debugSnapshot.isPresented && overlay.debugCaptionLines.joined() == "下一次录音")
    #expect(overlay.debugSnapshot.panelFrame == initialFrame)
    overlay.hide()
}

@Test @MainActor func captionAndStatusStayCenteredThroughUpdatesWithoutInputGeometry() {
    let overlay = OverlayController(presentsPanel: false)
    let visible = CGRect(x: 2000, y: 100, width: 1600, height: 1000)
    overlay.debugSetGeometry(visible: visible)
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview(String(repeating: "长字幕连续换行", count: 30))
    #expect(overlay.debugCaptionLines.count == 4)
    #expect(overlay.debugCaptionFrame.midX == visible.midX)
    #expect(overlay.debugCaptionFrame.maxY == overlay.debugSnapshot.panelFrame.minY - 12)
    #expect(overlay.debugSnapshot.panelHeight == 44)
    overlay.showProcessing(); overlay.refreshGeometry()
    #expect(overlay.debugCaptionFrame.midX == overlay.debugSnapshot.panelFrame.midX)
    overlay.hide()
}

@Test @MainActor func unconfirmedOutputRemainsTruthfulAndLatePreviewCannotReplaceFinal() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:01")
    overlay.updateTranscriptPreview("已显示的句尾")
    overlay.showOutputUnconfirmed("原输入框可能已收到终稿，请先核对。")
    overlay.updateTranscriptPreview("迟到的旧预览")
    #expect(overlay.debugSnapshot.displayedTitle == "请核对输入框")
    #expect(overlay.debugCaptionLines.joined() == "已显示的句尾")
    #expect(!overlay.debugSnapshot.isRetryControlVisible && overlay.debugHideTask == nil)
    #expect(overlay.debugSnapshot.isCancelControlVisible)
    overlay.hide()
}
