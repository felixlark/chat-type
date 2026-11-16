import CoreGraphics
import Testing
@testable import ChatType

@Test
func minimalOverlayPresetUsesNineBarVoiceGlyph() {
    let preset = OverlayStylePreset.typeWhisperIndicator

    #expect(preset.pillHeight == 44)
    #expect(preset.cornerRadius == 15)
    #expect(preset.topInset == 16)
    #expect(preset.waveformBarCount == 9)
    #expect(preset.showsTranscriptPreview == false)
    #expect(preset.inlineCancelControlSize == 14)
    #expect(preset.timerFontSize == 10)
}

@Test(arguments: [InjectionOutcome.pasted, .copiedToClipboard(reason: .userSelected)]) @MainActor
func outputBadgeAndSymbolRemainInsideCompactStatusHUD(outcome: InjectionOutcome) {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showResult(text: "终稿", outcome: outcome)
    overlay.debugAcknowledgeCaptionDraw()
    let snapshot = overlay.debugSnapshot
    #expect(snapshot.panelHeight == 44)
    #expect(snapshot.badgeFrame.width == 20 && snapshot.badgeFrame.height == 20)
    #expect(snapshot.iconFrame.width == 14 && snapshot.iconFrame.height == 14)
    #expect(snapshot.badgeFrame.contains(snapshot.iconFrame))
    if case .copiedToClipboard = outcome { #expect(snapshot.displayedTitle == "已复制，未粘贴") }
    overlay.hide()
}

@Test
func overlayStatesStillDifferentiateLeadingVisualFamilies() {
    #expect(OverlayVisualState.recording(levels: Array(repeating: 0.2, count: 9), elapsedText: "00:03").leadingVisual == .waveform)
    #expect(OverlayVisualState.processing.leadingVisual == .waveform)
    #expect(OverlayVisualState.success(.pasted).leadingVisual == .icon(symbolName: "checkmark.circle.fill"))
    #expect(OverlayVisualState.error("Microphone permission is missing").leadingVisual == .icon(symbolName: "exclamationmark.triangle.fill"))
}

@Test
func overlayStatesStayCompactExceptErrors() {
    #expect(OverlayVisualState.recording(levels: Array(repeating: 0.2, count: 9), elapsedText: "00:03").allowsSupplementaryText == false)
    #expect(OverlayVisualState.processing.allowsSupplementaryText == false)
    #expect(OverlayVisualState.success(.pasted).allowsSupplementaryText == false)
    #expect(OverlayVisualState.error("Microphone permission is missing").allowsSupplementaryText == true)
}

@Test
func recordingOverlayStateShowsCancelControlAndTimer() {
    let state = OverlayVisualState.recording(
        levels: Array(repeating: 0.2, count: 9),
        elapsedText: "00:07"
    )

    #expect(state.showsCancelControl == true)
    #expect(state.trailingText == "00:07")
}

@Test
func processingOverlayStateShowsCancelControlWithoutTimer() {
    #expect(OverlayVisualState.processing.showsCancelControl == true)
    #expect(OverlayVisualState.processing.trailingText == nil)
}

@Test
func successHidesCancelWhileOrdinaryErrorCanBeDismissed() {
    #expect(OverlayVisualState.success(.pasted).showsCancelControl == false)
    #expect(OverlayVisualState.error("boom").showsCancelControl == true)
    #expect(OverlayVisualState.error("boom").showsRetryControl == false)
}

@Test
func retryableErrorStateShowsRetryAndCancelControls() {
    let state = OverlayVisualState.retryableError("Cloudflare 403")

    #expect(state.showsCancelControl == true)
    #expect(state.showsRetryControl == true)
    #expect(state.trailingText == nil)
}

@Test
func overlayErrorMessageIsCollapsedToSingleShortLine() {
    let state = OverlayVisualState.error("Microphone permission is missing.\nGrant access in Settings and try again after restarting ChatType.")

    #expect(state.supplementaryText == "Microphone permission is missing. Grant access in Settings and try…")
}

@Test
func waveformNormalizerClampsSilenceAndLoudInput() {
    #expect(WaveformNormalizer.normalizedLevel(fromAveragePower: -160) == 0.08)
    #expect(WaveformNormalizer.normalizedLevel(fromAveragePower: 0) == 1)
}

@Test
func waveformNormalizerRecordingProfileStaysSymmetricAndWithinBounds() {
    let smoothed = WaveformNormalizer.smoothedLevels(
        previous: Array(repeating: 0.12, count: 9),
        targetLevel: 0.9,
        barCount: 9
    )

    #expect(smoothed.count == 9)
    #expect(smoothed.allSatisfy { $0 >= 0.08 && $0 <= 1 })
    #expect(smoothed[4] > smoothed[0])
    #expect(smoothed[4] > smoothed[8])
    #expect(abs(smoothed[0] - smoothed[8]) < 0.0001)
}

@Test
func waveformNormalizerProcessingPulseTravelsAcrossTheGlyph() {
    let early = WaveformNormalizer.processingPulseLevels(frame: 0, barCount: 9)
    let later = WaveformNormalizer.processingPulseLevels(frame: 5, barCount: 9)

    #expect(early.count == 9)
    #expect(later.count == 9)
    #expect(early.allSatisfy { $0 >= 0.08 && $0 <= 1 })
    #expect(later.allSatisfy { $0 >= 0.08 && $0 <= 1 })
    #expect(early != later)
    #expect(early.max() != later.max())
}

@Test
func waveformNormalizerPadsMissingSamplesToTheRequestedWaveCount() {
    let smoothed = WaveformNormalizer.smoothedLevels(
        previous: [0.2, 0.3, 0.4],
        targetLevel: 0.6,
        barCount: 9
    )

    #expect(smoothed.count == 9)
    #expect(smoothed.allSatisfy { $0 >= 0.08 && $0 <= 1 })
}

@Test
func overlayRecordingWidthExpandsToFitTimer() {
    let preset = OverlayStylePreset.typeWhisperIndicator

    #expect(
        preset.width(for: .recording(levels: Array(repeating: 0.2, count: 9), elapsedText: "00:07")) >
            preset.width(for: .processing)
    )
    #expect(preset.width(for: .error("boom")) == preset.errorPillWidth)
    #expect(preset.width(for: .processing) >= preset.inlineControlReservedWidth)
}

@MainActor
@Test
func overlayPanelPlacementDefaultsBelowTopSafeArea() {
    let preset = OverlayStylePreset.typeWhisperIndicator
    let visibleFrame = CGRect(x: 40, y: 30, width: 1440, height: 860)
    let frame = OverlayController.panelFrame(
        for: CGSize(width: preset.width(for: .processing), height: preset.pillHeight),
        in: visibleFrame,
        topInset: preset.topInset
    )

    #expect(frame.maxY == visibleFrame.maxY - 16)
    #expect(abs(frame.midX - visibleFrame.midX) < 0.0001)
    #expect(visibleFrame.contains(frame))
}

@MainActor
@Test
func overlayPanelPlacementFitsSmallAndOffsetScreens() {
    let visibleFrame = CGRect(x: -800, y: 900, width: 180, height: 50)
    let frame = OverlayController.panelFrame(
        for: CGSize(width: 286, height: 44), in: visibleFrame, topInset: 24
    )
    #expect(visibleFrame.contains(frame))
    #expect(frame.width == 180)
    #expect(frame.minY == visibleFrame.minY)
    #expect(frame.midX == visibleFrame.midX)
}

@Test
func overlayPlacementPinsScreenUntilNextSession() {
    let first = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    var session = OverlayPlacementSession()
    #expect(session.resolve { first } == first)
    var lookups = 0
    #expect(session.resolve { lookups += 1; return second } == first)
    #expect(lookups == 0)
    session.reset()
    #expect(session.resolve { second } == second)
}

@Test
func overlayPlacementSelectsFocusedWindowScreenByLargestOverlap() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 200, width: 1920, height: 1080)]
    #expect(OverlayPlacementSession.screenIndex(for: CGRect(x: -1000, y: 250, width: 1200, height: 600), screens: screens) == 1)
    #expect(OverlayPlacementSession.screenIndex(for: CGRect(x: 200, y: 30, width: 900, height: 800), screens: screens) == 0)
    #expect(OverlayPlacementSession.screenIndex(for: CGRect(x: 5000, y: 0, width: 300, height: 300), screens: screens) == nil)
    #expect(OverlayPlacementSession.screenIndex(for: .zero, screens: []) == nil)
}

@Test
func overlayPlacementConvertsAXCoordinatesForVerticallyOffsetDisplays() {
    let frame = OverlayPlacementSession.appKitFrame(
        fromAccessibility: CGRect(x: -1800, y: -300, width: 1000, height: 600), primaryScreenTop: 900
    )
    #expect(frame == CGRect(x: -1800, y: 600, width: 1000, height: 600))
}

@MainActor
@Test
func overlayControllerUsesIntegratedSessionControlInsideMainPanel() {
    let overlay = OverlayController(presentsPanel: false)
    let snapshot = overlay.debugSnapshot

    #expect(snapshot.usesIntegratedSessionControl == true)
    #expect(snapshot.hasDetachedClosePanel == false)
    #expect(snapshot.panelIgnoresMouseEvents == false)
}

@MainActor
@Test
func overlayControllerHidesInlineCancelAfterSuccess() {
    let overlay = OverlayController(presentsPanel: false)

    overlay.showRecording(elapsedText: "00:04")
    #expect(overlay.debugSnapshot.isCancelControlVisible == true)
    #expect(overlay.debugSnapshot.isTimerVisible == true)

    overlay.showProcessing()
    #expect(overlay.debugSnapshot.isCancelControlVisible == true)
    #expect(overlay.debugSnapshot.isTimerVisible == false)

    overlay.showResult(text: "Done", outcome: .pasted)
    overlay.debugAcknowledgeCaptionDraw()
    #expect(overlay.debugSnapshot.isCancelControlVisible == false)
    #expect(overlay.debugSnapshot.isRetryControlVisible == false)
}

@MainActor
@Test
func overlayControllerRetryableErrorShowsRetryAndCancelControls() {
    let overlay = OverlayController(presentsPanel: false)

    overlay.showRetryableError("Cloudflare 403")

    #expect(overlay.debugSnapshot.isCancelControlVisible == true)
    #expect(overlay.debugSnapshot.isRetryControlVisible == true)
}

@MainActor
@Test
func overlayControllerCancelControlRoutesClickIntoOnCancel() {
    var cancelCallCount = 0
    let overlay = OverlayController(onCancel: {
        cancelCallCount += 1
    }, presentsPanel: false)

    overlay.showRecording(elapsedText: "00:04")

    #expect(overlay.debugSimulateCancelControlClick() == true)
    #expect(cancelCallCount == 1)
}

@MainActor
@Test
func errorCloseControlDismissesPanelAndAllowsNewRecording() {
    for retryable in [false, true] {
        let overlay = OverlayController(presentsPanel: false)
        var cancelCallCount = 0
        var retryCallCount = 0
        overlay.onCancel = {
            cancelCallCount += 1
            overlay.hide()
        }
        overlay.onRetry = { retryCallCount += 1 }
        if retryable { overlay.showRetryableError("Transcription failed") }
        else { overlay.showError("Microphone unavailable") }

        #expect(overlay.debugSnapshot.isPresented)
        #expect(overlay.debugSnapshot.controlsInsidePanel)
        #expect(overlay.debugSimulateCancelControlClick())
        #expect(cancelCallCount == 1)
        #expect(retryCallCount == 0)
        #expect(!overlay.debugSnapshot.isPresented)
        #expect(!overlay.debugSnapshot.isRetryControlVisible)

        overlay.showRecording(elapsedText: "00:00")
        #expect(overlay.debugSnapshot.isPresented)
        #expect(overlay.debugSnapshot.isCancelControlVisible)
        overlay.hide()
        overlay.onCancel = nil
    }
}

@MainActor
@Test
func overlayControllerRetryControlRoutesClickIntoOnRetry() {
    var retryCallCount = 0
    let overlay = OverlayController(onRetry: {
        retryCallCount += 1
    }, presentsPanel: false)

    overlay.showRetryableError("Cloudflare 403")

    #expect(overlay.debugSimulateRetryControlClick() == true)
    #expect(retryCallCount == 1)
}

@MainActor
@Test func statusHUDIgnoresTranscriptDuringMeterUpdatesAndNewRecording() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("这是一段正在更新的文字")
    overlay.updateRecording(level: 0.5, elapsedText: "00:01")
    #expect(overlay.debugSnapshot.transcript.isEmpty)
    #expect(overlay.debugSnapshot.panelWidth == 224)
    overlay.showProcessing()
    overlay.showRecording(elapsedText: "00:00")
    #expect(overlay.debugSnapshot.transcript.isEmpty)
    overlay.hide()
}

private actor OverlayDeadlineGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var start: CheckedContinuation<Double, Never>?
    private var delay: Double?

    func sleep(seconds: Double) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            delay = seconds
            start?.resume(returning: seconds)
            start = nil
        }
    }

    func started() async -> Double {
        if let delay { return delay }
        return await withCheckedContinuation { start = $0 }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Test func overlayDeadlineSurvivesProductionGeometryRefreshEntry() async {
    for isError in [false, true] {
        let gate = OverlayDeadlineGate()
        let overlay = OverlayController(presentsPanel: false, hideDelay: { await gate.sleep(seconds: $0) })
        overlay.showRecording(elapsedText: "00:00")
        overlay.updateTranscriptPreview("保留全文直到终态结束。")
        if isError { overlay.showError("普通错误") }
        else { overlay.showResult(text: "完成", outcome: .pasted); overlay.debugAcknowledgeCaptionDraw() }
        let duration = await gate.started()
        #expect(duration == (isError ? 2 : 1.5))
        let deadline = overlay.debugHideTask
        for _ in 0..<8 { overlay.refreshGeometry() }
        overlay.updateRecording(level: 0.8, elapsedText: "00:09")
        overlay.updateTranscriptPreview("晚到的实时文字")
        #expect(overlay.debugSnapshot.isCancelControlVisible == isError)
        #expect(overlay.debugSnapshot.transcript.isEmpty)
        #expect(overlay.debugSnapshot.isPresented)
        await gate.fire()
        await deadline?.value
        #expect(!overlay.debugSnapshot.isPresented)
        #expect(!overlay.debugSnapshot.isCancelControlVisible)
        #expect(overlay.debugHideTask == nil)
    }
}

@MainActor
@Test func overlayOldDeadlineCannotHideNewRecording() async {
    let gate = OverlayDeadlineGate()
    let overlay = OverlayController(presentsPanel: false, hideDelay: { await gate.sleep(seconds: $0) })
    overlay.showResult(text: "完成", outcome: .copiedToClipboard(reason: .noEditableTarget))
    overlay.debugAcknowledgeCaptionDraw()
    _ = await gate.started()
    let oldDeadline = overlay.debugHideTask
    overlay.showRecording(elapsedText: "00:00")
    overlay.updateTranscriptPreview("新会话")
    await gate.fire()
    await oldDeadline?.value
    for _ in 0..<8 { overlay.refreshGeometry() }
    #expect(overlay.debugSnapshot.isPresented)
    #expect(overlay.debugSnapshot.isCancelControlVisible)
    #expect(overlay.debugSnapshot.transcript.isEmpty)
    overlay.hide()
}

@MainActor
@Test func overlayRetryableErrorRemainsVisibleAcrossRefreshes() {
    let overlay = OverlayController(presentsPanel: false)
    overlay.showRetryableError("请重试")
    for _ in 0..<12 { overlay.refreshGeometry() }
    #expect(overlay.debugHideTask == nil)
    #expect(overlay.debugSnapshot.isPresented)
    #expect(overlay.debugSnapshot.isRetryControlVisible)
    overlay.hide()
}
