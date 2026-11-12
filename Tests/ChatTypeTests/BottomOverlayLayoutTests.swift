import AppKit
import Testing
@testable import ChatType

@Test func bottomOverlayAvoidsComposerAndSendRowWithMaximumEnvelope() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let composer = CGRect(x: 100, y: 40, width: 1200, height: 140)
    let result = BottomOverlayLayout.place(size: CGSize(width: 480, height: 140), visible: visible, protected: [composer])
    #expect(!result.needsAdjustment)
    #expect(!result.frame.intersects(composer))
    #expect(result.frame.minY == composer.maxY + 12)
    #expect(result.frame.midX == visible.midX)
    let continued = BottomOverlayLayout.place(size: result.frame.size, visible: visible, protected: [], preferred: result.frame.origin)
    #expect(continued.frame == result.frame)
}

@Test func bottomOverlayHandlesSmallNegativeScreensAndImpossiblePlacement() {
    let visible = CGRect(x: -900, y: 800, width: 180, height: 90)
    let small = BottomOverlayLayout.place(size: CGSize(width: 480, height: 140), visible: visible, protected: [])
    #expect(visible.contains(small.frame))
    let blocked = BottomOverlayLayout.place(size: CGSize(width: 480, height: 140), visible: visible, protected: [visible])
    #expect(blocked.needsAdjustment)
    #expect(visible.contains(blocked.frame))
    let dragged = BottomOverlayLayout.place(size: CGSize(width: 100, height: 44), visible: visible, protected: [], preferred: CGPoint(x: -3000, y: 1900))
    #expect(visible.contains(dragged.frame))
}

@MainActor
@Test func multilineOverlayGrowsUpwardKeepsFooterAndFullTextThroughProcessing() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("第一句实时转写。")
    let short = overlay.debugSnapshot
    let long = String(repeating: "请保留每个需求、数字以及这条很长的路径：https://example.org/some-very-long-unbroken-path。", count: 25)
    overlay.updateTranscriptPreview(long)
    let full = overlay.debugSnapshot
    #expect(short.controlsInsidePanel)
    #expect(short.previewInsidePanel)
    #expect(full.controlsInsidePanel)
    #expect(full.previewInsidePanel)
    #expect(full.panelHeight >= short.panelHeight)
    #expect(full.panelHeight <= 140)
    #expect(full.footerY == short.footerY)
    #expect(full.transcript == long)
    overlay.showProcessing()
    #expect(overlay.debugSnapshot.transcript == long)
    #expect(overlay.debugSnapshot.isCancelControlVisible)
    overlay.showRetryableError("测试重试")
    #expect(overlay.debugSnapshot.transcript == long)
    #expect(overlay.debugSnapshot.isRetryControlVisible)
    overlay.hide()
    overlay.showRecording(elapsedText: "00:00")
    #expect(overlay.debugSnapshot.transcript.isEmpty)
    overlay.hide()
}

@MainActor
@Test func transcriptViewKeepsReviewPositionUntilReturnToLatest() {
    let view = OverlayTranscriptView(frame: NSRect(x: 0, y: 0, width: 456, height: 80))
    let original = String(repeating: "这一段文字用于回看测试，并且保留全部内容。\n", count: 30)
    view.update(original, width: 456, compact: false)
    #expect(view.followsLatest)
    view.setFrameSize(NSSize(width: 456, height: 60))
    view.reflectScrolledClipView(view.contentView)
    #expect(view.followsLatest)
    view.contentView.scroll(to: .zero)
    view.userDidScroll()
    #expect(!view.followsLatest)
    view.update(original + "最新的一句。", width: 456, compact: false)
    #expect(!view.followsLatest)
    #expect(view.contentView.bounds.minY == 0)
    #expect(view.fullText == original + "最新的一句。")
    view.resumeFollowing()
    #expect(view.followsLatest)
    #expect(view.contentView.bounds.maxY >= view.documentView!.bounds.maxY - 2)
    #expect(view.contentView.bounds.minX == 0)
}

@MainActor
@Test func transcriptWrapsChineseAndUnbrokenPathsWithinVisibleWidth() {
    let view = OverlayTranscriptView(frame: NSRect(x: 0, y: 0, width: 456, height: 80))
    let source = String(repeating: "实时文字需要自动换行。https://example.org/" + String(repeating: "a", count: 100), count: 6)
    view.update(source, width: 456, compact: false)
    let text = view.documentView as! NSTextView
    let manager = text.layoutManager!
    let glyphs = manager.glyphRange(for: text.textContainer!)
    var lines = 0
    manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
        lines += 1
        #expect(used.maxX <= 440.5)
    }
    #expect(lines > 4)
    #expect(view.desiredHeight == 80)
    #expect(view.fullText == source)
    #expect(view.contentView.bounds.minX == 0)
}

@MainActor
@Test func cancellingRecordingClearsPreviewBeforeNextSessionStarts() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("上一段应在取消后清空。")
    overlay.hide()
    overlay.showRecording(elapsedText: "00:00")
    #expect(overlay.debugSnapshot.transcript.isEmpty)
    overlay.updateTranscriptPreview("新的一段。")
    #expect(overlay.debugSnapshot.transcript == "新的一段。")
    overlay.hide()
}

@Test func manualOverlayChoosesNearestSafeSideAndKeepsFallbackIntent() {
    let visible = CGRect(x: -1000, y: 100, width: 1000, height: 800)
    let obstacle = CGRect(x: -600, y: 350, width: 60, height: 100)
    let preferred = CGPoint(x: -700, y: 380)
    let size = CGSize(width: 160, height: 80)
    let placed = BottomOverlayLayout.place(size: size, visible: visible, protected: [obstacle], preferred: preferred, manual: true)
    #expect(placed.frame.origin == CGPoint(x: -772, y: 380))
    #expect(!placed.frame.intersects(obstacle))
    #expect(!placed.needsAdjustment)
    let blocked = BottomOverlayLayout.place(size: size, visible: visible, protected: [visible], preferred: preferred, manual: true)
    #expect(blocked.needsAdjustment)
    #expect(blocked.frame.origin == preferred)
    let restored = BottomOverlayLayout.place(size: size, visible: visible, protected: [], preferred: preferred, manual: true)
    #expect(restored.frame.origin == preferred)
}

@MainActor
@Test func overlayDragUsesTotalScreenDisplacementAndFreezesLayoutUntilMouseUp() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("短句")
    let initial = overlay.debugSnapshot.panelFrame
    let pointer = CGPoint(x: initial.midX, y: initial.minY + 20)
    overlay.beginDrag(at: pointer)
    overlay.updateDrag(to: CGPoint(x: pointer.x + 60, y: pointer.y + 100))
    overlay.updateDrag(to: CGPoint(x: pointer.x + 90, y: pointer.y + 200))
    let dragged = overlay.debugSnapshot.panelFrame
    #expect(dragged.origin == CGPoint(x: initial.minX + 90, y: initial.minY + 200))
    #expect(dragged.size == initial.size)
    let long = String(repeating: "拖动期间继续采集全部实时文字。", count: 60)
    overlay.updateTranscriptPreview(long)
    overlay.updateRecording(level: 0.7, elapsedText: "00:03")
    overlay.refreshGeometry()
    #expect(overlay.debugSnapshot.panelFrame == dragged)
    overlay.endDrag(at: CGPoint(x: pointer.x + 90, y: pointer.y + 200))
    let anchor = CGPoint(x: dragged.midX, y: dragged.minY)
    #expect(overlay.debugSnapshot.userAnchor == anchor)
    #expect(overlay.debugSnapshot.transcript == long)
    #expect(overlay.debugSnapshot.panelHeight > initial.height)
    for _ in 0..<8 { overlay.refreshGeometry() }
    overlay.showProcessing()
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor.x)
    #expect(overlay.debugSnapshot.footerY == anchor.y)
    overlay.hide()
}

@MainActor
@Test func overlayManualPositionRestoresUserIntentAfterAvoidanceAndUnknownGeometry() {
    let overlay = OverlayController(presentsPanel: false)
    let visible = CGRect(x: -1000, y: 100, width: 1000, height: 800)
    overlay.debugSetGeometry(visible: visible, protected: [])
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("短句")
    overlay.beginDrag(at: .zero)
    overlay.endDrag(at: CGPoint(x: 30, y: 250))
    let intended = overlay.debugSnapshot.panelFrame
    let anchor = overlay.debugSnapshot.userAnchor
    let obstacle = CGRect(x: intended.maxX - 15, y: intended.minY, width: 40, height: intended.height)
    overlay.debugSetGeometry(visible: visible, protected: [obstacle])
    overlay.refreshGeometry()
    #expect(!overlay.debugSnapshot.panelFrame.intersects(obstacle))
    #expect(overlay.debugSnapshot.panelFrame.minX == intended.minX - 27)
    #expect(overlay.debugSnapshot.userAnchor == anchor)
    overlay.debugSetGeometry(visible: visible, protected: [], hasEditableGeometry: false)
    overlay.refreshGeometry()
    #expect(overlay.debugSnapshot.panelFrame == intended)
    #expect(overlay.debugSnapshot.displayedTitle.contains("拖动调整位置"))
    overlay.hide()
}

@MainActor
@Test func overlayManualCompactResolvesOnceAndRestoresNormalWidthWithSameFooterCenter() {
    let overlay = OverlayController(presentsPanel: false)
    let visible = CGRect(x: 0, y: 0, width: 600, height: 260)
    overlay.debugSetGeometry(visible: visible, protected: [])
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("短句")
    overlay.beginDrag(at: .zero)
    overlay.endDrag(at: CGPoint(x: 0, y: 70))
    let anchor = overlay.debugSnapshot.userAnchor
    let sides = [CGRect(x: 0, y: 0, width: 130, height: 260), CGRect(x: 470, y: 0, width: 130, height: 260)]
    overlay.debugSetGeometry(visible: visible, protected: sides)
    overlay.refreshGeometry()
    #expect(overlay.debugSnapshot.panelWidth == 280)
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor?.x)
    #expect(overlay.debugSnapshot.footerY == anchor?.y)
    #expect(sides.allSatisfy { !$0.intersects(overlay.debugSnapshot.panelFrame) })
    overlay.debugSetGeometry(visible: visible, protected: [])
    overlay.refreshGeometry()
    #expect(overlay.debugSnapshot.panelWidth == 480)
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor?.x)
    #expect(overlay.debugSnapshot.footerY == anchor?.y)
    overlay.hide()
}

@MainActor
@Test func overlayCancelledDragIgnoresLateMouseUpInNextSession() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    overlay.beginDrag(at: CGPoint(x: 10, y: 10))
    overlay.updateDrag(to: CGPoint(x: 100, y: 200))
    overlay.hide()
    overlay.showRecording(elapsedText: "00:00")
    let next = overlay.debugSnapshot.panelFrame
    overlay.endDrag(at: CGPoint(x: 900, y: 600))
    overlay.updateDrag(to: CGPoint(x: 1000, y: 700))
    #expect(overlay.debugSnapshot.userAnchor == nil)
    #expect(overlay.debugSnapshot.panelFrame == next)
    overlay.hide()
}

@MainActor
@Test func overlayDraggedFooterKeepsCenterWhenFirstPreviewWidensAndGrows() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    #expect(overlay.debugSnapshot.panelWidth < 480)
    overlay.beginDrag(at: CGPoint(x: 400, y: 30))
    overlay.endDrag(at: CGPoint(x: 500, y: 230))
    let anchor = overlay.debugSnapshot.userAnchor
    overlay.updateTranscriptPreview("第一句")
    #expect(overlay.debugSnapshot.panelWidth == 480)
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor?.x)
    #expect(overlay.debugSnapshot.footerY == anchor?.y)
    overlay.updateTranscriptPreview(String(repeating: "长文字继续增长并保留用户选择的位置。", count: 70))
    for _ in 0..<4 { overlay.refreshGeometry() }
    #expect(overlay.debugSnapshot.panelHeight == 140)
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor?.x)
    #expect(overlay.debugSnapshot.footerY == anchor?.y)
    overlay.showProcessing()
    #expect(overlay.debugSnapshot.panelFrame.midX == anchor?.x)
    #expect(overlay.debugSnapshot.footerY == anchor?.y)
    overlay.hide()
}
