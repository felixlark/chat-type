import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
protocol OverlayControlling: AnyObject {
    var onCancel: (@MainActor () -> Void)? { get set }
    var onRetry: (@MainActor () -> Void)? { get set }

    func beginSession(context: LaunchAppContext?, captionsEnabled: Bool)
    func showRecording(elapsedText: String)
    func updateRecording(level: CGFloat, elapsedText: String)
    func updateTranscriptPreview(_ text: String)
    func showProcessing()
    func showConfirming()
    func showResult(text: String, outcome: InjectionOutcome)
    func showError(_ message: String)
    func showOutputUnconfirmed(_ message: String)
    func showRetryableError(_ message: String)
    func hide()
}

extension OverlayControlling {
    func beginSession(context: LaunchAppContext?, captionsEnabled: Bool) {}
    func showConfirming() { showProcessing() }
    func showOutputUnconfirmed(_ message: String) { showError(message) }
    func updateTranscriptPreview(_ text: String) {}
}

@MainActor
final class OverlayController: OverlayControlling {
    private let style = OverlayStylePreset.typeWhisperIndicator
    private let panel: NSPanel
    private let presentsPanel: Bool
    private let panelRootView = OverlayPassthroughView()
    private let backgroundView = NSView()
    private let leadingContainer = NSView()
    private let leadingBadgeView = NSView()
    private let waveformView: OverlayWaveformView
    private let iconView = OverlaySymbolImageView()
    private let closeButton = OverlayHitTargetButton()
    private let retryButton = OverlayHitTargetButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingTimerLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let trailingAccessoryStack = NSStackView()
    private let caption: OverlayCaptionPanel
    private var captionsEnabled = true
    private var pinnedScreenNumber: NSNumber?
    private var isPresented = false
    private var presentationGeneration = 0
    private let hideDelay: @Sendable (Double) async throws -> Void
    private var visibleOverride: CGRect?
    private var geometryTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var processingTimer: Timer?
    private var processingFrameIndex = 0
    private var displayedLevels: [CGFloat]
    private var currentState: OverlayVisualState
    private var escapeHotkeyMonitor: HotkeyMonitor?
    var onCancel: (@MainActor () -> Void)?
    var onRetry: (@MainActor () -> Void)?

    init(
        onCancel: (@MainActor () -> Void)? = nil,
        onRetry: (@MainActor () -> Void)? = nil,
        presentsPanel: Bool = true,
        hideDelay: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.caption = OverlayCaptionPanel(presentsPanel: presentsPanel)
        self.presentsPanel = presentsPanel
        self.hideDelay = hideDelay
        displayedLevels = Array(
            repeating: WaveformNormalizer.minimumVisibleLevel,
            count: style.waveformBarCount
        )
        currentState = .processing
        waveformView = OverlayWaveformView(
            levels: displayedLevels,
            style: style
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: style.pillWidth, height: style.pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.title = "ChatType Status HUD"
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        self.onCancel = onCancel
        self.onRetry = onRetry

        configureViews()
        caption.onFinalDraw = { [weak self] in
            guard let self, case .success = self.currentState else { return }
            self.scheduleHide(afterSeconds: 1.5)
        }
    }

    func beginSession(context: LaunchAppContext?, captionsEnabled: Bool) {
        hide()
        self.captionsEnabled = captionsEnabled
        let screen = activeScreen(context: context)
        pinnedScreenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    func showRecording(elapsedText: String) {
        stopProcessingAnimation()
        displayedLevels = Array(
            repeating: WaveformNormalizer.minimumVisibleLevel,
            count: style.waveformBarCount
        )
        transition(to: .recording(levels: displayedLevels, elapsedText: elapsedText))
        present()
    }

    func updateRecording(level: CGFloat, elapsedText: String) {
        guard case .recording = currentState else { return }
        stopProcessingAnimation()
        displayedLevels = WaveformNormalizer.smoothedLevels(
            previous: displayedLevels,
            targetLevel: level,
            barCount: style.waveformBarCount
        )
        currentState = .recording(levels: displayedLevels, elapsedText: elapsedText)
        render()
        present()
    }

    func updateTranscriptPreview(_ text: String) {
        guard captionsEnabled, !text.isEmpty else { return }
        switch currentState {
        case .recording, .processing, .confirming: break
        default: return
        }
        caption.update(text, hud: panel.frame, visible: currentVisibleFrame())
    }

    func showConfirming() {
        transition(to: .confirming)
        present()
        if presentsPanel {
            panel.displayIfNeeded()
            CATransaction.flush()
        }
    }

    func showProcessing() {
        processingFrameIndex = 0
        displayedLevels = WaveformNormalizer.processingPulseLevels(
            frame: processingFrameIndex,
            barCount: style.waveformBarCount
        )
        transition(to: .processing)
        present()
        startProcessingAnimation()
    }

    func showResult(text: String, outcome: InjectionOutcome) {
        stopProcessingAnimation()

        let successKind: OverlaySuccessKind
        switch outcome {
        case .pasted:
            successKind = .pasted
        case .copiedToClipboard:
            successKind = .copied
        }

        transition(to: .success(successKind))
        present()
        if captionsEnabled, !text.isEmpty {
            caption.update(text, final: true, hud: panel.frame, visible: currentVisibleFrame())
        } else { scheduleHide(afterSeconds: style.successAutoHideDelay ?? 1.2) }
    }

    func showError(_ message: String) {
        stopProcessingAnimation()
        transition(to: .error(message))
        present()
        scheduleHide(afterSeconds: style.errorAutoHideDelay ?? 2.0)
    }

    func showOutputUnconfirmed(_ message: String) {
        stopProcessingAnimation()
        transition(to: .unconfirmed(message))
        present()
    }

    func showRetryableError(_ message: String) {
        stopProcessingAnimation()
        transition(to: .retryableError(message))
        present()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        presentationGeneration += 1
        isPresented = false
        stopProcessingAnimation()
        hideSessionControls()
        panel.alphaValue = 0
        panel.orderOut(nil)
        currentState = .processing
        pinnedScreenNumber = nil
        caption.reset()
        geometryTimer?.invalidate(); geometryTimer = nil
    }

    private func transition(to state: OverlayVisualState) {
        hideTask?.cancel()
        hideTask = nil
        presentationGeneration += 1
        currentState = state
        panel.alphaValue = 1
        render()
    }

    private func render() {
        let state = currentState
        positionPanel(size: panelSize(for: state))

        titleLabel.stringValue = state.label
        detailLabel.stringValue = state.supplementaryText ?? ""
        detailLabel.isHidden = !state.allowsSupplementaryText
        trailingTimerLabel.stringValue = state.trailingText ?? ""
        trailingTimerLabel.isHidden = state.trailingText == nil
        trailingAccessoryStack.isHidden = !state.showsCancelControl && !state.showsRetryControl && state.trailingText == nil
        updateSessionControls(for: state)

        switch state {
        case .recording(let levels, _):
            displayedLevels = levels
            waveformView.isHidden = false
            waveformView.update(levels: levels)
            leadingBadgeView.isHidden = true
            iconView.isHidden = true
        case .processing, .confirming:
            waveformView.isHidden = false
            waveformView.update(levels: displayedLevels)
            leadingBadgeView.isHidden = true
            iconView.isHidden = true
        case .success(let kind):
            waveformView.isHidden = true
            configureBadge(
                symbolName: kind == .pasted ? "checkmark" : "doc.on.clipboard.fill",
                tintColor: kind == .pasted ? ChatTypePalette.success : ChatTypePalette.amber,
                fillColor: kind == .pasted ? ChatTypePalette.success.withAlphaComponent(0.14) : ChatTypePalette.amber.withAlphaComponent(0.16),
                borderColor: kind == .pasted ? ChatTypePalette.success.withAlphaComponent(0.34) : ChatTypePalette.amber.withAlphaComponent(0.38)
            )
        case .unconfirmed:
            waveformView.isHidden = true
            configureBadge(symbolName: "questionmark", tintColor: ChatTypePalette.amber,
                fillColor: ChatTypePalette.amber.withAlphaComponent(0.16), borderColor: ChatTypePalette.amber.withAlphaComponent(0.38))
        case .error, .retryableError:
            waveformView.isHidden = true
            configureBadge(
                symbolName: "exclamationmark",
                tintColor: ChatTypePalette.error,
                fillColor: ChatTypePalette.error.withAlphaComponent(0.15),
                borderColor: ChatTypePalette.error.withAlphaComponent(0.34)
            )
        }
        panelRootView.layoutSubtreeIfNeeded()
    }

    private func configureBadge(
        symbolName: String,
        tintColor: NSColor,
        fillColor: NSColor,
        borderColor: NSColor
    ) {
        leadingBadgeView.isHidden = false
        leadingBadgeView.layer?.backgroundColor = fillColor.cgColor
        leadingBadgeView.layer?.borderColor = borderColor.cgColor

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            iconView.image = image
            iconView.contentTintColor = tintColor
        } else {
            iconView.image = nil
        }

        iconView.isHidden = false
    }

    private func startProcessingAnimation() {
        stopProcessingAnimation()

        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processingFrameIndex += 1
                self.displayedLevels = WaveformNormalizer.processingPulseLevels(
                    frame: self.processingFrameIndex,
                    barCount: self.style.waveformBarCount
                )
                if self.currentState == .processing || self.currentState == .confirming {
                    self.waveformView.update(levels: self.displayedLevels)
                }
            }
        }
    }

    private func stopProcessingAnimation() {
        processingTimer?.invalidate()
        processingTimer = nil
    }

    private func present() {
        isPresented = true
        guard presentsPanel else { return }
        if geometryTimer == nil {
            geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.panel.isVisible else { return }
                    self.refreshGeometry()
                }
            }
        }
        if panel.alphaValue == 0 || !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func scheduleHide(afterSeconds: Double) {
        let generation = presentationGeneration
        hideTask = Task { @MainActor [weak self, hideDelay] in
            do { try await hideDelay(afterSeconds) } catch { return }
            guard let self, !Task.isCancelled,
                  self.presentationGeneration == generation else { return }
            self.hide()
        }
    }

    // Geometry ticks share this entry with headless lifecycle regression tests.
    func refreshGeometry() {
        guard isPresented else { return }
        render()
    }

    private func configureViews() {
        panelRootView.translatesAutoresizingMaskIntoConstraints = false
        panelRootView.wantsLayer = false
        panelRootView.interactiveViewsProvider = { [weak self] in
            guard let self else {
                return []
            }
            return [self.closeButton, self.retryButton]
        }
        panel.contentView = panelRootView
        panelRootView.addSubview(backgroundView)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = ChatTypePalette.graphite.cgColor
        backgroundView.layer?.cornerRadius = style.cornerRadius
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.borderColor = ChatTypePalette.mist.withAlphaComponent(0.08).cgColor
        backgroundView.shadow = NSShadow()
        backgroundView.shadow?.shadowBlurRadius = 18
        backgroundView.shadow?.shadowOffset = NSSize(width: 0, height: -2)
        backgroundView.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.35)

        leadingContainer.translatesAutoresizingMaskIntoConstraints = false
        leadingContainer.wantsLayer = false

        leadingBadgeView.translatesAutoresizingMaskIntoConstraints = false
        leadingBadgeView.wantsLayer = true
        leadingBadgeView.layer?.cornerRadius = 10
        leadingBadgeView.layer?.borderWidth = 1
        leadingBadgeView.layer?.masksToBounds = true
        leadingBadgeView.isHidden = true

        waveformView.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = true
        iconView.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = ChatTypePalette.mist
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = ChatTypePalette.mistMuted
        detailLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = true

        trailingTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingTimerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: style.timerFontSize, weight: .medium)
        trailingTimerLabel.textColor = ChatTypePalette.mistMuted.withAlphaComponent(style.timerOpacity)
        trailingTimerLabel.alignment = .right
        trailingTimerLabel.isHidden = true

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel dictation")
        closeButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = ChatTypePalette.mistMuted.withAlphaComponent(0.78)
        closeButton.target = self
        closeButton.action = #selector(handleCancelControlPressed)
        closeButton.setButtonType(.momentaryChange)
        closeButton.focusRingType = .none
        closeButton.isHidden = true

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isBordered = false
        retryButton.bezelStyle = .regularSquare
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重试原录音")
        retryButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        retryButton.imagePosition = .imageOnly
        retryButton.contentTintColor = ChatTypePalette.mistMuted.withAlphaComponent(0.84)
        retryButton.target = self
        retryButton.action = #selector(handleRetryControlPressed)
        retryButton.setButtonType(.momentaryChange)
        retryButton.focusRingType = .none
        retryButton.isHidden = true

        trailingAccessoryStack.translatesAutoresizingMaskIntoConstraints = false
        trailingAccessoryStack.orientation = .horizontal
        trailingAccessoryStack.spacing = style.inlineControlGap
        trailingAccessoryStack.alignment = .centerY
        trailingAccessoryStack.addArrangedSubview(trailingTimerLabel)
        trailingAccessoryStack.addArrangedSubview(retryButton)
        trailingAccessoryStack.addArrangedSubview(closeButton)

        backgroundView.addSubview(leadingContainer)
        backgroundView.addSubview(textStack)
        backgroundView.addSubview(trailingAccessoryStack)
        leadingContainer.addSubview(waveformView)
        leadingContainer.addSubview(leadingBadgeView)
        leadingContainer.addSubview(iconView)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: panelRootView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: panelRootView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: panelRootView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: panelRootView.bottomAnchor),

            leadingContainer.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: style.contentPaddingH),
            leadingContainer.centerYAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -style.pillHeight / 2),
            leadingContainer.widthAnchor.constraint(equalToConstant: style.leadingVisualWidth),
            leadingContainer.heightAnchor.constraint(equalToConstant: style.leadingVisualHeight),

            waveformView.leadingAnchor.constraint(equalTo: leadingContainer.leadingAnchor),
            waveformView.trailingAnchor.constraint(equalTo: leadingContainer.trailingAnchor),
            waveformView.topAnchor.constraint(equalTo: leadingContainer.topAnchor),
            waveformView.bottomAnchor.constraint(equalTo: leadingContainer.bottomAnchor),

            leadingBadgeView.centerXAnchor.constraint(equalTo: leadingContainer.centerXAnchor),
            leadingBadgeView.centerYAnchor.constraint(equalTo: leadingContainer.centerYAnchor),
            leadingBadgeView.widthAnchor.constraint(equalToConstant: 20),
            leadingBadgeView.heightAnchor.constraint(equalToConstant: 20),

            iconView.centerXAnchor.constraint(equalTo: leadingBadgeView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: leadingBadgeView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: leadingContainer.trailingAnchor, constant: style.textGap),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAccessoryStack.leadingAnchor, constant: -style.textGap),
            textStack.centerYAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -style.pillHeight / 2),

            trailingAccessoryStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -style.contentPaddingH),
            trailingAccessoryStack.centerYAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -style.pillHeight / 2),
            trailingTimerLabel.widthAnchor.constraint(equalToConstant: style.timerWidth),
            retryButton.widthAnchor.constraint(equalToConstant: style.inlineCancelControlSize),
            retryButton.heightAnchor.constraint(equalToConstant: style.inlineCancelControlSize),
            closeButton.widthAnchor.constraint(equalToConstant: style.inlineCancelControlSize),
            closeButton.heightAnchor.constraint(equalToConstant: style.inlineCancelControlSize),
        ])
    }

    private func panelSize(for state: OverlayVisualState) -> NSSize {
        let width = style.width(for: state)
        return NSSize(width: width, height: style.pillHeight)
    }

    private func currentScreen() -> NSScreen? {
        guard presentsPanel else { return nil }
        if let pinnedScreenNumber,
           let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == pinnedScreenNumber }) { return screen }
        let screen = activeScreen(context: nil)
        pinnedScreenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return screen
    }
    private func currentVisibleFrame() -> CGRect {
        visibleOverride ?? currentScreen()?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }
    private func positionPanel(size: NSSize) {
        let visible = currentVisibleFrame()
        let screen = currentScreen()
        let safeTop = visibleOverride == nil ? min(visible.maxY, (screen?.frame.maxY ?? visible.maxY) - (screen?.safeAreaInsets.top ?? 0)) : visible.maxY
        panel.setFrame(TopOverlayLayout.hud(size: size, visible: visible, safeTop: safeTop), display: false)
        panelRootView.layoutSubtreeIfNeeded()
        caption.position(hud: panel.frame, visible: visible)
    }
    func debugSetGeometry(visible: CGRect) { visibleOverride = visible }
    func debugAcknowledgeCaptionDraw() { caption.debugAcknowledgeFinalDraw() }
    var debugCaptionLines: [String] { caption.displayedLines }
    var debugCaptionFrame: CGRect { caption.frame }

    static func panelFrame(for size: NSSize, in visibleFrame: NSRect, topInset: CGFloat) -> NSRect {
        TopOverlayLayout.hud(size: size, visible: visibleFrame, safeTop: visibleFrame.maxY, inset: topInset)
    }
    private func activeScreen(context: LaunchAppContext?) -> NSScreen? {
        guard presentsPanel else { return nil }
        let screens = NSScreen.screens
        if let windowFrame = focusedWindowFrame(pid: context?.processIdentifier),
           let index = OverlayPlacementSession.screenIndex(for: windowFrame, screens: screens.map(\.frame)) { return screens[index] }
        return NSScreen.main ?? screens.first
    }
    private func focusedWindowFrame(pid: pid_t?) -> NSRect? {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first,
              let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return OverlayPlacementSession.appKitFrame(fromAccessibility: CGRect(origin: point, size: size), primaryScreenTop: primary.frame.maxY)
    }

    private func updateSessionControls(for state: OverlayVisualState) {
        if state.showsCancelControl {
            closeButton.isHidden = false
            activateEscapeHotkeyIfNeeded()
        } else {
            escapeHotkeyMonitor = nil
            closeButton.isHidden = true
        }
        retryButton.isHidden = !state.showsRetryControl
    }

    private func activateEscapeHotkeyIfNeeded() {
        guard presentsPanel, escapeHotkeyMonitor == nil else { return }
        escapeHotkeyMonitor = try? HotkeyMonitor(keyCode: 53) { [weak self] in
            Task { @MainActor [weak self] in
                self?.onCancel?()
            }
        }
    }

    private func hideSessionControls() {
        escapeHotkeyMonitor = nil
        closeButton.isHidden = true
        retryButton.isHidden = true
    }

    @objc
    private func handleCancelControlPressed() {
        onCancel?()
    }

    @objc
    private func handleRetryControlPressed() {
        onRetry?()
    }

    @discardableResult
    func debugSimulateCancelControlClick() -> Bool {
        guard !closeButton.isHidden else {
            return false
        }

        let centerInRoot = panelRootView.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        )
        guard let hitView = panelRootView.hitTest(centerInRoot) as? NSControl else {
            return false
        }

        _ = hitView.sendAction(hitView.action, to: hitView.target)
        return true
    }

    @discardableResult
    func debugSimulateRetryControlClick() -> Bool {
        guard !retryButton.isHidden else {
            return false
        }

        let centerInRoot = panelRootView.convert(
            NSPoint(x: retryButton.bounds.midX, y: retryButton.bounds.midY),
            from: retryButton
        )
        guard panelRootView.hitTest(centerInRoot) is NSControl else {
            return false
        }

        retryButton.performClick(nil)
        return true
    }

    var debugHideTask: Task<Void, Never>? { hideTask }

    var debugSnapshot: OverlayDebugSnapshot {
        OverlayDebugSnapshot(
            usesIntegratedSessionControl: closeButton.superview === trailingAccessoryStack,
            hasDetachedClosePanel: false,
            panelIgnoresMouseEvents: panel.ignoresMouseEvents,
            isCancelControlVisible: !closeButton.isHidden,
            isRetryControlVisible: !retryButton.isHidden,
            isTimerVisible: !trailingTimerLabel.isHidden,
            displayedTitle: titleLabel.stringValue,
            panelFrame: panel.frame,
            isPresented: isPresented,
            panelWidth: panel.frame.width,
            transcript: "",
            panelHeight: panel.frame.height,
            footerY: panel.frame.minY,
            followsLatest: true,
            controlsInsidePanel: panelRootView.bounds.contains(panelRootView.convert(closeButton.bounds, from: closeButton)),
            previewInsidePanel: true,
            badgeFrame: panelRootView.convert(leadingBadgeView.bounds, from: leadingBadgeView),
            iconFrame: panelRootView.convert(iconView.bounds, from: iconView)
        )
    }
}

private final class OverlaySymbolImageView: NSImageView {
    // SF Symbols have optical alignment insets. Constrain the actual view's
    // frame so a tall clipboard symbol cannot extend outside the status pill.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

struct OverlayDebugSnapshot: Sendable, Equatable {
    let usesIntegratedSessionControl: Bool
    let hasDetachedClosePanel: Bool
    let panelIgnoresMouseEvents: Bool
    let isCancelControlVisible: Bool
    let isRetryControlVisible: Bool
    let isTimerVisible: Bool
    let displayedTitle: String
    let panelFrame: CGRect
    let isPresented: Bool
    let panelWidth: CGFloat
    let transcript: String
    let panelHeight: CGFloat
    let footerY: CGFloat
    let followsLatest: Bool
    let controlsInsidePanel: Bool
    let previewInsidePanel: Bool
    let badgeFrame: CGRect
    let iconFrame: CGRect
}

private final class OverlayPassthroughView: NSView {
    var interactiveViewsProvider: (() -> [NSView])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveViews = interactiveViewsProvider?() else {
            return nil
        }

        for view in interactiveViews.reversed() where !view.isHidden && view.alphaValue > 0 {
            let pointInView = (view.superview ?? view).convert(point, from: self)
            if let hitView = view.hitTest(pointInView) {
                return hitView
            }
        }

        return nil
    }
}

private final class OverlayHitTargetButton: NSButton {
    private let hitTargetPadding: CGFloat = 6

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitBounds = bounds.insetBy(dx: -hitTargetPadding, dy: -hitTargetPadding)
        return hitBounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class OverlayWaveformView: NSView {
    private var levels: [CGFloat]
    private let style: OverlayStylePreset

    init(levels: [CGFloat], style: OverlayStylePreset) {
        self.levels = levels
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(levels: [CGFloat]) {
        let trimmed = Array(levels.prefix(style.waveformBarCount))
        if trimmed.count == style.waveformBarCount {
            self.levels = trimmed
        } else {
            self.levels = trimmed + Array(
                repeating: WaveformNormalizer.minimumVisibleLevel,
                count: max(0, style.waveformBarCount - trimmed.count)
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let activeLevels = levels.isEmpty
            ? Array(repeating: WaveformNormalizer.minimumVisibleLevel, count: style.waveformBarCount)
            : levels

        let totalSpacing = style.waveformBarSpacing * CGFloat(max(0, activeLevels.count - 1))
        let availableWidth = bounds.width - totalSpacing
        let rawBarWidth = availableWidth / CGFloat(max(1, activeLevels.count))
        let barWidth = max(2, min(3, floor(rawBarWidth)))
        let contentWidth = (barWidth * CGFloat(activeLevels.count)) + totalSpacing
        var x = bounds.midX - (contentWidth / 2)
        let center = CGFloat(max(0, activeLevels.count - 1)) / 2

        for (index, level) in activeLevels.enumerated() {
            let barHeight = max(style.waveformMinimumBarHeight, bounds.height * level)
            let barRect = CGRect(
                x: x,
                y: bounds.midY - (barHeight / 2),
                width: barWidth,
                height: barHeight
            )

            let distanceFromCenter = abs(CGFloat(index) - center) / max(1, center)
            let accentMix = (1 - min(1, distanceFromCenter)) * min(1, 0.42 + (level * 0.68))
            let barColor = NSColor.blend(
                from: ChatTypePalette.mist.withAlphaComponent(0.68),
                to: ChatTypePalette.iceBlue,
                amount: accentMix
            )
            barColor.setFill()
            NSBezierPath(
                roundedRect: barRect,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()

            x += barWidth + style.waveformBarSpacing
        }
    }
}
