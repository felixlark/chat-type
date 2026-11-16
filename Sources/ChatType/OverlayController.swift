import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol OverlayControlling: AnyObject {
    var onCancel: (@MainActor () -> Void)? { get set }
    var onRetry: (@MainActor () -> Void)? { get set }

    func showRecording(elapsedText: String)
    func updateRecording(level: CGFloat, elapsedText: String)
    func updateTranscriptPreview(_ text: String)
    func showProcessing()
    func showResult(text: String, outcome: InjectionOutcome)
    func showError(_ message: String)
    func showRetryableError(_ message: String)
    func hide()
}

extension OverlayControlling {
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
    private let iconView = NSImageView()
    private let closeButton = OverlayHitTargetButton()
    private let retryButton = OverlayHitTargetButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingTimerLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let trailingAccessoryStack = NSStackView()
    private let dragHandle = OverlayDragHandle()
    private var anchor: CGPoint?
    private var userAnchor: CGPoint?
    private var dragSession: (pointer: CGPoint, frame: CGRect)?
    private var isPresented = false
    private var presentationGeneration = 0
    private let hideDelay: @Sendable (Double) async throws -> Void
    private var geometryOverride: OverlayFocusGeometry?
    private var visibleOverride: CGRect?
    private var needsPositionAdjustment = false
    private var geometry = OverlayFocusGeometry(protected: [], hasEditableGeometry: false)
    private var nextGeometryRead = Date.distantPast
    private var geometryTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var processingTimer: Timer?
    private var processingFrameIndex = 0
    private var displayedLevels: [CGFloat]
    private var currentState: OverlayVisualState
    private var escapeHotkeyMonitor: HotkeyMonitor?
    private var placementSession = OverlayPlacementSession()
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
    }

    func showRecording(elapsedText: String) {
        // The coordinator also calls this when starting level updates. Do not
        // reselect the display on that second call within the same recording.
        if case .recording = currentState {} else {
            placementSession.reset(); anchor = nil; userAnchor = nil
            dragSession = nil
            nextGeometryRead = .distantPast
        }
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

    // Transcript presentation belongs to the pinned input, never the status HUD.
    func updateTranscriptPreview(_ text: String) {}

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
        _ = text
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
        scheduleHide(afterSeconds: style.successAutoHideDelay ?? 1.2)
    }

    func showError(_ message: String) {
        stopProcessingAnimation()
        transition(to: .error(message))
        present()
        scheduleHide(afterSeconds: style.errorAutoHideDelay ?? 2.0)
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
        dragSession = nil
        stopProcessingAnimation()
        hideSessionControls()
        panel.alphaValue = 0
        panel.orderOut(nil)
        currentState = .processing
        placementSession.reset()
        anchor = nil
        userAnchor = nil
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
        if needsPositionAdjustment { titleLabel.stringValue += " · 拖动调整位置" }
        titleLabel.toolTip = needsPositionAdjustment ? "拖动底部空白区域，避开当前应用按钮" : nil
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
        case .processing:
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
                if case .processing = self.currentState {
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

    func beginDrag(at pointer: CGPoint) {
        guard isPresented else { return }
        dragSession = (pointer, panel.frame)
    }

    func updateDrag(to pointer: CGPoint) {
        guard let drag = dragSession else { return }
        let origin = CGPoint(x: drag.frame.minX + pointer.x - drag.pointer.x,
                             y: drag.frame.minY + pointer.y - drag.pointer.y)
        panel.setFrameOrigin(origin)
    }

    func endDrag(at pointer: CGPoint) {
        guard dragSession != nil else { return }
        updateDrag(to: pointer)
        userAnchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        dragSession = nil
        nextGeometryRead = .distantPast
        render()
    }

    private func configureViews() {
        panelRootView.translatesAutoresizingMaskIntoConstraints = false
        panelRootView.wantsLayer = false
        panelRootView.interactiveViewsProvider = { [weak self] in
            guard let self else {
                return []
            }
            return [self.dragHandle, self.closeButton, self.retryButton]
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
        leadingBadgeView.layer?.cornerRadius = 14
        leadingBadgeView.layer?.borderWidth = 1
        leadingBadgeView.isHidden = true

        waveformView.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .bold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
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

        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.setAccessibilityLabel("拖动状态浮窗")
        dragHandle.onBegin = { [weak self] in self?.beginDrag(at: $0) }
        dragHandle.onChange = { [weak self] in self?.updateDrag(to: $0) }
        dragHandle.onEnd = { [weak self] in self?.endDrag(at: $0) }
        backgroundView.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: style.pillHeight),
        ])
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
            leadingBadgeView.widthAnchor.constraint(equalToConstant: 48),
            leadingBadgeView.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: leadingBadgeView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: leadingBadgeView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

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

    private func positionPanel(size: NSSize) {
        guard dragSession == nil else { return }
        let pinned = placementSession.resolve {
            guard presentsPanel else { return NSRect(x: 0, y: 0, width: 1440, height: 900) }
            return (activeScreen() ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
        let visible: NSRect
        if let visibleOverride { visible = visibleOverride }
        else if presentsPanel {
            let sameScreen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: pinned.midX, y: pinned.midY)) }
            visible = (sameScreen ?? activeScreen() ?? NSScreen.main)?.visibleFrame ?? pinned
        } else { visible = pinned }
        if let geometryOverride { geometry = geometryOverride }
        else if Date() >= nextGeometryRead,
           !presentsPanel || NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            geometry = presentsPanel ? OverlayFocusGeometry.read(visible: visible) : OverlayFocusGeometry(protected: [], hasEditableGeometry: true)
            nextGeometryRead = Date().addingTimeInterval(0.25)
        }
        let unknown = !geometry.hasEditableGeometry
        let preferred = userAnchor.map { CGPoint(x: $0.x - size.width / 2, y: $0.y) }
            ?? anchor ?? (unknown ? CGPoint(x: visible.minX + 16, y: visible.minY + 16) : nil)
        let placement = BottomOverlayLayout.place(size: size, visible: visible, protected: geometry.protected,
            preferred: preferred, manual: userAnchor != nil)
        needsPositionAdjustment = unknown || placement.needsAdjustment
        anchor = placement.frame.origin
        panel.setFrame(placement.frame, display: false)
        panelRootView.layoutSubtreeIfNeeded()
    }

    func debugSetGeometry(visible: CGRect, protected: [CGRect], hasEditableGeometry: Bool = true) {
        visibleOverride = visible
        geometryOverride = OverlayFocusGeometry(protected: protected, hasEditableGeometry: hasEditableGeometry)
    }


    static func panelFrame(
        for size: NSSize,
        in visibleFrame: NSRect,
        topInset: CGFloat
    ) -> NSRect {
        let fittedSize = NSSize(
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )
        _ = topInset
        return BottomOverlayLayout.place(size: fittedSize, visible: visibleFrame, protected: []).frame
    }

    private func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let windowFrame = focusedWindowFrame(),
           let index = OverlayPlacementSession.screenIndex(
               for: windowFrame,
               screens: screens.map(\.frame)
           ) {
            return screens[index]
        }
        let mouseLocation = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouseLocation) })
    }

    // Read existing Accessibility authorization without requesting new permissions.
    // AX coordinates start at the top-left of the primary display; AppKit uses bottom-left.
    private func focusedWindowFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let primaryScreen = NSScreen.screens.first else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return OverlayPlacementSession.appKitFrame(
            fromAccessibility: CGRect(origin: origin, size: size),
            primaryScreenTop: primaryScreen.frame.maxY
        )
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
            userAnchor: userAnchor,
            isPresented: isPresented,
            panelWidth: panel.frame.width,
            transcript: "",
            panelHeight: panel.frame.height,
            footerY: panel.frame.minY,
            followsLatest: true,
            controlsInsidePanel: panelRootView.bounds.contains(panelRootView.convert(closeButton.bounds, from: closeButton)),
            previewInsidePanel: true
        )
    }
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
    let userAnchor: CGPoint?
    let isPresented: Bool
    let panelWidth: CGFloat
    let transcript: String
    let panelHeight: CGFloat
    let footerY: CGFloat
    let followsLatest: Bool
    let controlsInsidePanel: Bool
    let previewInsidePanel: Bool
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
