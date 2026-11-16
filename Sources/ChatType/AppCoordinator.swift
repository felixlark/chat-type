import AppKit
import AVFoundation
import Foundation
import OSLog

struct TranscriptionAttemptPolicy: Sendable, Equatable {
    let cloudflareChallengeMaxAttempts: Int

    static let automatic = TranscriptionAttemptPolicy(cloudflareChallengeMaxAttempts: 3)
    static let manualRetry = TranscriptionAttemptPolicy(cloudflareChallengeMaxAttempts: 1)
}

@MainActor
final class AppCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    typealias RecorderFactory = @MainActor (TranscriptionConfig) -> any RecordingControlling
    typealias StatusMenuFactory = @MainActor (
        @escaping () -> Void,
        @escaping () -> Void,
        @escaping () -> Void
    ) -> any StatusMenuUpdating
    typealias PipelineFactory = @Sendable (TranscriptionConfig, any ChatGPTAuthProviding, TranscriptionAttemptPolicy) -> any DictationPreparing
    typealias LaunchAppContextProvider = @MainActor () -> LaunchAppContext?

    let configStore: ConfigStore
    let notifier: any NotificationDispatching
    let injector: any TextInjecting
    let liveTextInput: any LiveTextInputControlling
    let overlay: any OverlayControlling
    let authManager: any ChatGPTAuthProviding
    let latencyRecorder: any LatencyRecording
    let historyRecorder: any TranscriptionHistoryRecording
    let recoveryRecorder: any RecoveryRecording
    let soundFeedback: any SoundFeedbackPlaying
    let recorderFactory: RecorderFactory
    let statusMenuFactory: StatusMenuFactory
    let pipelineFactory: PipelineFactory
    let launchAppContextProvider: LaunchAppContextProvider
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.longbiaochen.chattype",
        category: "Permissions"
    )

    var config: AppConfig
    private var hotkeyMonitor: HotkeyMonitor?
    var recorder: (any RecordingControlling)?
    var statusMenu: (any StatusMenuUpdating)?
    private var preferencesWindowController: PreferencesWindowController?
    var preferencesDraft: PreferencesDraft?
    private let replayDecision: @MainActor (RecoveryReplayDecision) -> Bool
    private let microphoneAccessRequester: (@MainActor () async throws -> Void)?
    private var microphonePermissionWindowController: MicrophonePermissionWindowController?
    var state: State = .idle
    private var recordingLevelTimer: Timer?
    private var overlayDemoFrameIndex = 0
    var launchAppContext: LaunchAppContext?
    var processingTask: Task<Void, Never>?
    private(set) var startRecordingTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var recordingStartedAt: DispatchTime?
    private var recordingConfig: AppConfig?
    private var pendingRetry: PendingRetry?
    private var activeProcessingAudio: RecordedAudio?
    private var liveDoubao: DoubaoLiveRecognition?
    private var activeAttemptID: UUID?
    private var processingConfig: TranscriptionConfig?
    private var interruptedParentRecordID: UUID?
    private var authStateObserver: NSObjectProtocol?

    private struct PendingRetry {
        let audio: RecordedAudio
        let launchAppContext: LaunchAppContext?
        let transcriptionConfig: TranscriptionConfig
        let injectionConfig: InjectionConfig
    }

    init(
        liveTextInput: (any LiveTextInputControlling)? = nil,
        microphoneAccessRequester: (@MainActor () async throws -> Void)? = nil,
        configStore: ConfigStore = ConfigStore(),
        config: AppConfig = AppConfig(),
        notifier: any NotificationDispatching = Notifier(),
        injector: any TextInjecting = TextInjector(),
        overlay: (any OverlayControlling)? = nil,
        authManager: any ChatGPTAuthProviding = ChatGPTAuthManager(),
        latencyRecorder: any LatencyRecording = LatencyRecorder(),
        historyRecorder: any TranscriptionHistoryRecording = TranscriptionHistoryRecorder(),
        recoveryRecorder: (any RecoveryRecording)? = nil,
        replayDecision: @escaping @MainActor (RecoveryReplayDecision) -> Bool = RecoveryReplayDecision.present,
        soundFeedback: any SoundFeedbackPlaying = SoundFeedbackService(),
        recorderFactory: RecorderFactory? = nil,
        statusMenuFactory: @escaping StatusMenuFactory = { openSettings, openConfig, quit in
            StatusMenuController(
                openSettingsHandler: openSettings,
                openConfigHandler: openConfig,
                quitHandler: quit
            )
        },
        pipelineFactory: @escaping PipelineFactory = { transcriptionConfig, authManager, attemptPolicy in
            DictationServiceFactory.make(config: transcriptionConfig, auth: authManager, policy: attemptPolicy)
        },
        launchAppContextProvider: @escaping LaunchAppContextProvider = { LaunchAppContext.current() }
    ) {
        self.liveTextInput = liveTextInput ?? LiveTextInput()
        self.microphoneAccessRequester = microphoneAccessRequester
        self.configStore = configStore
        self.config = config
        self.notifier = notifier
        self.injector = injector
        let resolvedOverlay = overlay ?? OverlayController()
        self.overlay = resolvedOverlay
        self.authManager = authManager
        self.latencyRecorder = latencyRecorder
        self.historyRecorder = historyRecorder
        self.replayDecision = replayDecision
        self.recoveryRecorder = recoveryRecorder ?? RecoveryStore(
            directoryURL: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true)
        )
        self.soundFeedback = soundFeedback
        let recordingStore = self.recoveryRecorder as? RecoveryStore
        self.recorderFactory = recorderFactory ?? { current in
            if #available(macOS 26.0, *), current.provider == .chatGPTManagedAuth, current.livePreviewEnabled {
                return LocalSpeechRecorder(sampleRateHz: current.sampleRateHz, store: recordingStore ?? RecoveryStore(), finalizationTimeoutSeconds: current.localFinalizationTimeoutSeconds, hintTerms: current.hintTerms)
            }
            return AudioRecorder(sampleRateHz: current.provider == .doubaoIME ? 16_000 : current.sampleRateHz, recoveryStore: recordingStore)
        }
        self.statusMenuFactory = statusMenuFactory
        self.pipelineFactory = pipelineFactory
        self.launchAppContextProvider = launchAppContextProvider
        self.overlay.onCancel = { [weak self] in
            self?.cancelCurrentSession()
        }
        self.overlay.onRetry = { [weak self] in
            self?.retryPendingTranscription()
        }
        authStateObserver = NotificationCenter.default.addObserver(
            forName: .chatGPTAuthStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshReadyState()
            }
        }
    }

    func start(launchMode: AppLaunchMode = .normal) {
        do {
            if let launchBlocker = AppInstallLocation.launchBlocker() {
                NSSound.beep()
                showInstallRequiredAlert(message: launchBlocker.message)
                notifier.notify(title: "ChatType install required", body: launchBlocker.message)
                AppInstallLocation.revealApplicationsFolder()
                NSApplication.shared.terminate(nil)
                return
            }

            switch launchMode {
            case .normal, .settings:
                config = try configStore.load()
                try (recoveryRecorder as? RecoveryStore)?.recoverInterruptedRecordings()
                recorder = recorderFactory(config.transcription)

                hotkeyMonitor = try HotkeyMonitor(keyCode: config.transcription.hotkeyKeyCode) { [weak self] in
                    Task { @MainActor in
                        self?.handleHotkeyPress()
                    }
                }
                notifier.ensureAuthorization()
                installStatusMenuIfNeeded()
                refreshReadyState()
                checkLaunchLoginState()
                prewarmAuthIfNeeded()
                if launchMode == .settings {
                    openSettings()
                }
            case .overlayDemo:
                config = (try? configStore.load()) ?? config
                installStatusMenuIfNeeded()
                runOverlayDemo()
                return
            case .overlayDemoState(let demoState):
                config = (try? configStore.load()) ?? config
                installStatusMenuIfNeeded()
                runOverlayDemoState(demoState)
                return
            case .benchmark:
                config = try configStore.load()
                Task {
                    defer { NSApplication.shared.terminate(nil) }
                    do {
                        let runner = BenchmarkRunner(
                            config: config,
                            authManager: authManager
                        )
                        try await runner.run()
                    } catch {
                        print("Benchmark failed: \(error.localizedDescription)")
                    }
                }
                return
            }
        } catch {
            NSSound.beep()
            notifier.notify(title: "ChatType launch failed", body: error.localizedDescription)
            installStatusMenuIfNeeded()
            statusMenu?.update(state: .error, detail: error.localizedDescription)
        }
    }

    private func installStatusMenuIfNeeded() {
        guard statusMenu == nil else {
            return
        }

        statusMenu = statusMenuFactory(
            { [weak self] in self?.openSettings() },
            { [weak self] in self?.openConfigFolder() },
            { NSApplication.shared.terminate(nil) }
        )
        statusMenu?.ensureVisible()
    }

    func handleHotkeyPress() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            NSSound.beep()
        }
    }

    func showSettings() {
        openSettings()
    }

    func cancelCurrentSession() {
        liveTextInput.reset()
        activeProcessingAudio?.cloudTranscript?.cancel()
        guard state != .idle || activeSessionID != nil || startRecordingTask != nil else {
            interruptedParentRecordID = nil
            clearPendingRetry()
            overlay.hide()
            refreshReadyState()
            return
        }

        liveDoubao?.cancel()
        liveDoubao = nil
        recordingConfig = nil
        startRecordingTask?.cancel()
        startRecordingTask = nil
        if let audio = activeProcessingAudio {
            do {
                try recoveryRecorder.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                    durationMs: audio.durationMs, asrText: nil, polishText: nil,
                    appName: launchAppContext?.localizedName, appBundleIdentifier: launchAppContext?.bundleIdentifier,
                    outcome: "cancelled", errorMessage: nil, snapshot: processingConfig, attemptID: activeAttemptID))
            } catch {
                logger.error("Could not update cancellation journal; raw audio remains saved: \(error.localizedDescription, privacy: .public)")
            }
            activeProcessingAudio = nil
        }
        processingTask?.cancel()
        processingTask = nil
        stopRecordingLevelUpdates()
        clearPendingRetry()

        if state == .recording {
            do { try recorder?.cancelRecording() }
            catch { notifier.notify(title: "录音保存异常", body: error.localizedDescription) }
        }

        state = .idle
        activeSessionID = nil
        recordingStartedAt = nil
        launchAppContext = nil
        overlay.hide()
        refreshReadyState()
    }

    private func startRecording() {
        guard applyPendingPreferences() else { return }
        var sessionConfig = config
        if sessionConfig.transcription.provider == .doubaoIME { sessionConfig.transcription.sampleRateHz = 16_000 }
        recordingConfig = sessionConfig
        let recorder = recorderFactory(sessionConfig.transcription)
        self.recorder = recorder

        clearPendingRetry()
        logger.info("Start recording requested from hotkey")
        let sessionID = UUID()
        activeSessionID = sessionID
        launchAppContext = launchAppContextProvider()
        liveTextInput.begin(context: launchAppContext, enabled: !sessionConfig.injection.clipboardOnly)
        overlay.beginSession(context: launchAppContext, captionsEnabled: sessionConfig.transcription.livePreviewEnabled)
        state = .processing
        statusMenu?.update(state: .processing, detail: "Requesting microphone")
        overlay.showProcessing()

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                await self.liveTextInput.prepare()
                guard self.shouldContinue(sessionID: sessionID) else { return }
                try await self.requestMicrophoneAccess()
                guard self.shouldContinue(sessionID: sessionID) else { return }
                logger.info("Microphone access stage completed")

                let issues = RuntimePreflight.issues(
                    for: sessionConfig,
                    environment: ProcessInfo.processInfo.environment,
                    authSnapshotProvider: { self.authManager.authSnapshot() }
                )
                if let message = RuntimePreflight.summary(for: issues) {
                    logger.error("Runtime preflight blocked recording with \(issues.count, privacy: .public) issue(s): \(message, privacy: .public)")
                    self.liveTextInput.reset()
                    self.stopRecordingLevelUpdates()
                    self.state = .idle
                    self.activeSessionID = nil
                    self.statusMenu?.update(state: .setupRequired, detail: message)
                    self.overlay.showError(message)
                    self.notifier.notify(title: "ChatType setup required", body: message)
                    self.openSettings()
                    return
                }

                logger.info("Runtime preflight passed; starting recording session")
                try await recorder.startRecording()
                guard self.shouldContinue(sessionID: sessionID) else {
                    try? recorder.cancelRecording()
                    return
                }

                if let url = recorder.activeAudioURL {
                    let recordingAttemptID = UUID()
                    self.activeAttemptID = recordingAttemptID
                    do {
                        try self.recoveryRecorder.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: url,
                            durationMs: 0, asrText: nil, polishText: nil, appName: self.launchAppContext?.localizedName,
                            appBundleIdentifier: self.launchAppContext?.bundleIdentifier, outcome: "recording", errorMessage: nil,
                            snapshot: sessionConfig.transcription, attemptID: recordingAttemptID,
                            injectionSnapshot: sessionConfig.injection, parentRecordID: self.interruptedParentRecordID))
                        self.interruptedParentRecordID = nil
                    } catch {
                        try? recorder.cancelRecording()
                        throw RecorderError.recordingStorageFailed(error.localizedDescription)
                    }
                    if sessionConfig.transcription.provider == .doubaoIME, sessionConfig.transcription.livePreviewEnabled {
                        let store = self.recoveryRecorder as? RecoveryStore
                        self.liveDoubao = DoubaoLiveRecognition(url: url, sessionAudit: { sessions in
                            do { try store?.recordASRSessions(audioURL: url, attemptID: recordingAttemptID, sessions: sessions) }
                            catch { throw RecorderError.recordingStorageFailed(error.localizedDescription) }
                        })
                    }
                }
                logger.info("Recording session started successfully")
                self.recordingStartedAt = .now()
                self.state = .recording
                self.statusMenu?.update(state: .recording, detail: "Recording on F5")
                self.overlay.showRecording(elapsedText: "00:00")
                self.soundFeedback.play(.recordingStarted, enabled: self.config.transcription.feedbackSoundsEnabled)
                self.startRecordingLevelUpdates()
            } catch is CancellationError {
                // A canceled startup may finish after a subsequent F5 has
                // opened a new session. Its recorder already cleaned itself.
                if self.shouldContinue(sessionID: sessionID) { self.cancelCurrentSession() }
            } catch {
                if case RecorderError.recordingStorageFailed = error,
                   !self.shouldContinue(sessionID: sessionID) {
                    // Report an old recorder's archival failure without
                    // replacing the new session's HUD or stopping its input.
                    self.logger.error("Canceled startup could not seal raw recording: \(error.localizedDescription, privacy: .public)")
                    self.notifier.notify(title: "录音保存异常", body: error.localizedDescription)
                    return
                }
                guard self.shouldContinue(sessionID: sessionID) else { return }
                self.liveTextInput.reset()
                logger.error("Start recording failed: \(error.localizedDescription, privacy: .public)")
                self.stopRecordingLevelUpdates()
                self.state = .idle
                self.activeSessionID = nil
                self.recordingStartedAt = nil
                self.refreshReadyState(detailOverride: error.localizedDescription, state: .error)
                self.overlay.showError(error.localizedDescription)
                self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                self.launchAppContext = nil
            }

            if self.activeSessionID == sessionID {
                self.startRecordingTask = nil
            }
        }
    }

    private func stopRecording() {
        let stopRequestedAt = DispatchTime.now().uptimeNanoseconds
        guard let recorder, let sessionID = activeSessionID else { return }

        do {
            stopRecordingLevelUpdates()
            var audio = try recorder.stopRecording()
            if let live = liveDoubao { audio.cloudTranscript = live.finish(audio) }
            liveDoubao = nil
            recordingStartedAt = nil
            state = .processing
            statusMenu?.update(state: .processing, detail: "Processing")
            overlay.showProcessing()
            soundFeedback.play(.recordingStopped, enabled: config.transcription.feedbackSoundsEnabled)

            let sessionConfig = recordingConfig ?? config
            let transcriptionConfig = sessionConfig.transcription
            let injectionConfig = sessionConfig.injection
            recordingConfig = nil
            let launchAppContext = self.launchAppContext
            startProcessing(
                audio: audio,
                sessionID: sessionID,
                transcriptionConfig: transcriptionConfig,
                injectionConfig: injectionConfig,
                launchAppContext: launchAppContext,
                attemptPolicy: .automatic,
                continuingAttemptID: activeAttemptID,
                stopRequestedAt: stopRequestedAt
            )
        } catch {
            liveTextInput.reset()
            liveDoubao?.cancel(); liveDoubao = nil
            stopRecordingLevelUpdates()
            state = .idle
            activeSessionID = nil
            recordingStartedAt = nil
            statusMenu?.update(state: .error, detail: error.localizedDescription)
            overlay.showError(error.localizedDescription)
            notifier.notify(title: "ChatType", body: error.localizedDescription)
        }
    }

    private func retryPendingTranscription() {
        guard state == .idle, let pendingRetry else {
            NSSound.beep()
            return
        }

        let sessionID = UUID()
        activeSessionID = sessionID
        state = .processing
        statusMenu?.update(state: .processing, detail: "Retrying")
        overlay.showProcessing()

        startProcessing(
            audio: pendingRetry.audio,
            sessionID: sessionID,
            transcriptionConfig: pendingRetry.transcriptionConfig,
            injectionConfig: pendingRetry.injectionConfig,
            launchAppContext: pendingRetry.launchAppContext,
            attemptPolicy: .manualRetry
        )
    }

    private func savePreferences(_ newConfig: AppConfig) -> Result<Void, any Error> {
        do {
            try configStore.save(newConfig)
            config = newConfig
            // Saving future choices must not make an active task look Ready.
            refreshReadyState(detailOverride: "Settings saved", state: .ready)
            prewarmAuthIfNeeded()
            return .success(())
        } catch { return .failure(error) }
    }

    private func applyPendingPreferences() -> Bool {
        guard state == .idle else { return false }
        if preferencesDraft == nil { preferencesDraft = PreferencesDraft(config: config) }
        guard let preferencesDraft else { return false }
        if case .failure(let error) = preferencesDraft.apply(using: savePreferences) {
            let message = "设置未能应用，未开始新的处理。\(error.localizedDescription)"
            if pendingRetry != nil { overlay.showRetryableError(message) } else { overlay.showError(message) }
            return false
        }
        return true
    }

    private func startProcessing(
        audio sourceAudio: RecordedAudio,
        sessionID: UUID,
        transcriptionConfig: TranscriptionConfig,
        injectionConfig: InjectionConfig,
        launchAppContext: LaunchAppContext?,
        attemptPolicy: TranscriptionAttemptPolicy,
        continuingAttemptID: UUID? = nil,
        stopRequestedAt: UInt64? = nil
    ) {
        let processingStarted = stopRequestedAt ?? DispatchTime.now().uptimeNanoseconds
        guard shouldContinue(sessionID: sessionID) else { sourceAudio.cloudTranscript?.cancel(); return }
        let audio: RecordedAudio
        do {
            if let store = recoveryRecorder as? RecoveryStore { audio = try store.adopt(sourceAudio) }
            else { audio = sourceAudio }
        } catch {
            liveTextInput.suspend()
            sourceAudio.cloudTranscript?.cancel()
            self.state = .idle; activeSessionID = nil
            overlay.showError("录音未能安全归档，未继续处理或输出。\(error.localizedDescription)")
            return
        }
        activeProcessingAudio = audio
        let attemptID = continuingAttemptID ?? UUID()
        activeAttemptID = attemptID
        processingConfig = transcriptionConfig

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { audio.cloudTranscript?.cancel(); return }
            defer {
                audio.cloudTranscript?.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.activeSessionID == sessionID || self.activeSessionID == nil {
                        self.processingTask = nil
                        self.activeProcessingAudio = nil
                    }
                }
            }

            var pipeline = self.pipelineFactory(transcriptionConfig, self.authManager, attemptPolicy)
            let store = self.recoveryRecorder
            let audit: @Sendable (DictationStageAudit) throws -> Void = { stages in
                let auditStarted = ProcessingTiming.now()
                defer { ProcessingTrace.current?.recordStage("recoveryAudit", since: auditStarted) }
                try Task.checkCancellation()
                var stages = stages
                stages.partialAudio = audio.isPartialReplay
                do {
                    try store.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                        durationMs: audio.durationMs, asrText: stages.asrText, polishText: stages.polishOutput,
                        appName: launchAppContext?.localizedName, appBundleIdentifier: launchAppContext?.bundleIdentifier,
                        outcome: "processing", errorMessage: stages.error, snapshot: transcriptionConfig,
                        attemptID: attemptID, stages: stages, injectionSnapshot: injectionConfig))
                } catch { throw RecorderError.recordingStorageFailed(error.localizedDescription) }
            }
            if var concrete = pipeline as? DictationPipeline {
                concrete.audit = audit
                pipeline = concrete
            }

            do {
                try audit(.init())
                let prepared = try await DoubaoSessionAudit.$observer.withValue({ sessions in
                    do { try (store as? RecoveryStore)?.recordASRSessions(audioURL: audio.fileURL, attemptID: attemptID, sessions: sessions) }
                    catch { throw RecorderError.recordingStorageFailed(error.localizedDescription) }
                }) {
                    try await pipeline.prepare(audio: audio)
                }
                guard !Task.isCancelled else { return }


                guard self.shouldContinue(sessionID: sessionID) else { return }

                var outputWritten = false
                var outputSealed = false
                do {
                    try self.recoveryRecorder.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                        durationMs: audio.durationMs, asrText: prepared.rawText, polishText: prepared.stages?.polishOutput,
                        appName: launchAppContext?.localizedName, appBundleIdentifier: launchAppContext?.bundleIdentifier,
                        outcome: "readyToInject", errorMessage: nil, snapshot: transcriptionConfig,
                        attemptID: attemptID, stages: prepared.stages ?? DictationStageAudit(asrText: prepared.rawText, finalText: prepared.finalText),
                        injectionSnapshot: injectionConfig))
                    outputSealed = true
                    if transcriptionConfig.livePreviewEnabled {
                        self.overlay.updateTranscriptPreview(prepared.rawText)
                        guard !Task.isCancelled, self.shouldContinue(sessionID: sessionID) else { return }
                    }
                    self.overlay.showConfirming()
                    let injectStarted = DispatchTime.now().uptimeNanoseconds
                    let liveOutcome = try await self.liveTextInput.finish(prepared.finalText, injector: self.injector,
                                                                         configuration: injectionConfig)
                    guard !Task.isCancelled, self.shouldContinue(sessionID: sessionID) else { return }
                    let outcome = try liveOutcome ?? (injectionConfig.clipboardOnly ? self.injector.copyToClipboard(text: prepared.finalText) : self.injector.inject(
                        text: prepared.finalText,
                        preserveClipboard: injectionConfig.preserveClipboard,
                        restoreDelayMilliseconds: injectionConfig.restoreDelayMilliseconds,
                        launchAppContext: launchAppContext
                    ))
                    outputWritten = true
                    let injectMs = self.elapsedMilliseconds(since: injectStarted)
                    let totalProcessingMs = self.elapsedMilliseconds(since: processingStarted)
                    self.recordLatency(
                        prepared: prepared,
                        outcome: outcome,
                        injectMs: injectMs,
                        totalProcessingMs: totalProcessingMs,
                        errorCategory: nil
                    )
                    try self.recordHistory(
                        prepared: prepared,
                        outcome: outcome,
                        launchAppContext: launchAppContext
                    )
                    try self.recordRecoverySuccess(
                        audio: audio,
                        prepared: prepared,
                        outcome: outcome,
                        launchAppContext: launchAppContext, snapshot: transcriptionConfig, attemptID: attemptID
                    )
                    self.clearPendingRetry()
                    self.state = .idle
                    self.activeSessionID = nil
                    self.statusMenu?.update(
                        state: .ready,
                        detail: self.statusDetail(for: outcome)
                    )
                    self.overlay.showResult(text: prepared.finalText, outcome: outcome)
                    if case .copiedToClipboard(reason: .originalTargetUnavailable) = outcome {
                        self.notifier.notify(title: "ChatType · 终稿已复制", body: ClipboardFallbackReason.originalTargetUnavailable.overlaySubtitle)
                    }
                    if let reason = prepared.stages?.polishProtectionReason {
                        self.statusMenu?.update(state: .ready, detail: reason)
                        self.notifier.notify(title: "ChatType · 已保留识别原文", body: reason)
                    }
                    self.launchAppContext = nil
                } catch {
                    guard !Task.isCancelled, self.shouldContinue(sessionID: sessionID) else { return }
                    if !outputWritten {
                        self.liveTextInput.suspend()
                        if outputSealed {
                            do {
                                try self.recoveryRecorder.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                                    durationMs: audio.durationMs, asrText: prepared.rawText, polishText: prepared.stages?.polishOutput,
                                    appName: launchAppContext?.localizedName, appBundleIdentifier: launchAppContext?.bundleIdentifier,
                                    outcome: "readyToInject", errorMessage: error.localizedDescription, snapshot: transcriptionConfig,
                                    attemptID: attemptID, stages: prepared.stages ?? DictationStageAudit(asrText: prepared.rawText, finalText: prepared.finalText),
                                    injectionSnapshot: injectionConfig))
                            } catch {
                                self.logger.error("Could not retain output failure details; sealed final text remains saved: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                    let totalProcessingMs = self.elapsedMilliseconds(since: processingStarted)
                    self.recordLatency(
                        prepared: prepared,
                        outcome: nil,
                        injectMs: 0,
                        totalProcessingMs: totalProcessingMs,
                        errorCategory: "inject"
                    )
                    self.clearPendingRetry()
                    self.state = .idle
                    self.activeSessionID = nil
                    self.statusMenu?.update(state: .error, detail: error.localizedDescription)
                    let message = outputWritten ? "文字已经输出，但结果保存未完成；请先核对目标，避免重复粘贴。\(error.localizedDescription)" : "保存或输出未完成；未报告成功。\(error.localizedDescription)"
                    if case EditorDeliveryError.outputUnknown = error { self.overlay.showOutputUnconfirmed(message) }
                    else { self.overlay.showError(message) }
                    self.notifier.notify(title: "ChatType", body: message)
                    self.launchAppContext = nil
                }

            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.shouldContinue(sessionID: sessionID) else { return }

                    self.liveTextInput.suspend()
                    self.recordTranscriptionFailure(
                        audio: audio,
                        transcriptionConfig: transcriptionConfig,
                        processingStarted: processingStarted
                    )
                    do {
                        try self.recordRecoveryFailure(audio: audio, launchAppContext: launchAppContext,
                            error: error, snapshot: transcriptionConfig, attemptID: attemptID)
                    } catch {
                        self.clearPendingRetry(); self.state = .idle; self.activeSessionID = nil
                        self.overlay.showError("审计保存失败；原文件仍保留，未自动输出。\(error.localizedDescription)")
                        self.statusMenu?.update(state: .error, detail: "Recording audit could not be saved")
                        return
                    }

                    if self.isRetryableTranscriptionError(error) {
                        do {
                            try self.storePendingRetry(
                                audio: audio,
                                launchAppContext: launchAppContext,
                                transcriptionConfig: transcriptionConfig,
                                injectionConfig: injectionConfig
                            )
                            self.state = .idle
                            self.activeSessionID = nil
                            self.statusMenu?.update(state: .error, detail: error.localizedDescription)
                            self.overlay.showRetryableError(error.localizedDescription)
                            self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                            self.launchAppContext = nil
                        } catch {
                            self.clearPendingRetry()
                            self.state = .idle
                            self.activeSessionID = nil
                            self.statusMenu?.update(state: .error, detail: error.localizedDescription)
                            self.overlay.showError(error.localizedDescription)
                            self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                            self.launchAppContext = nil
                        }
                    } else {
                        self.clearPendingRetry()
                        self.state = .idle
                        self.activeSessionID = nil
                        self.statusMenu?.update(state: .error, detail: error.localizedDescription)
                        self.overlay.showError(error.localizedDescription)
                        self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                        self.launchAppContext = nil
                    }
                }
            }
        }
    }

    private func openSettings(focusRecoveryHistory: Bool = false) {
        statusMenu?.ensureVisible()

        if focusRecoveryHistory {
            preferencesWindowController = nil
        }

        if preferencesWindowController == nil {
            let authManager: ChatGPTAuthManager
            if let concrete = self.authManager as? ChatGPTAuthManager {
                authManager = concrete
            } else {
                authManager = ChatGPTAuthManager()
            }
            if preferencesDraft == nil { preferencesDraft = PreferencesDraft(config: config) }
            // Separate production readers from the live recorder lock. Preserve
            // injected implementations and their data sources in tests/embedders.
            let historyReader: any TranscriptionHistoryRecording = (historyRecorder as? TranscriptionHistoryRecorder)
                .map { TranscriptionHistoryRecorder(directoryURL: $0.directoryURL) } ?? historyRecorder
            let recoveryReader: any RecoveryRecording = (recoveryRecorder as? RecoveryStore)
                .map { RecoveryStore(directoryURL: $0.directoryURL) } ?? recoveryRecorder
            preferencesWindowController = PreferencesWindowController(
                config: config,
                draft: preferencesDraft,
                authManager: authManager,
                onSave: { [weak self] newConfig in
                    self?.savePreferences(newConfig) ?? .failure(CocoaError(.userCancelled))
                },
                onImportAppleContactRemarks: {
                    do { return .success(try await AppleContactRemarkImporter().importEntries()) }
                    catch { return .failure(error) }
                },
                onImportWeixinRemarks: {
                    do {
                        let imported = try await Task.detached { try WeixinNameImporter().importEntries() }.value
                        return .success(imported)
                    } catch { return .failure(error) }
                },
                onLoadRecentHistory: { [historyReader] in
                    try historyReader.loadRecent(limit: 200)
                },
                onLoadRecoveryHistory: { [recoveryReader] in
                    try recoveryReader.loadRecent(limit: 10)
                },
                recoveryDirectoryURL: recoveryRecorder.directoryURL,
                onRetryRecoveryRecord: { [weak self] record in self?.retryRecoveryRecord(record) },
                onReprocessRecoveryRecord: { [weak self] record in self?.reprocessRecoveryRecord(record) },
                onOpenConfigFolder: { [weak self] in
                    self?.openConfigFolder()
                },
                focusRecoveryHistory: focusRecoveryHistory,
                onClose: { [weak self] in
                    self?.statusMenu?.ensureVisible()
                }
            )
        }

        preferencesWindowController?.show()
        statusMenu?.ensureVisible()
    }

    static func refreshedTerminologyEntries(
        existing: [TerminologyEntry],
        incoming: [TerminologyEntry],
        replacingSources: Set<String>
    ) -> [TerminologyEntry] {
        let userShortcuts = Set(existing.filter { $0.source == "user" && $0.type == .correction }
            .map { $0.original.lowercased() })
        let allowed = incoming.filter {
            $0.source != "macos-text-replacements" || !userShortcuts.contains($0.original.lowercased())
        }
        return TerminologyPolicy.sanitizedEntries(
            mergedTerminologyEntries(
                existing: existing.filter { !replacingSources.contains($0.source) },
                incoming: allowed
            )
        )
    }

    private func retryRecoveryRecord(_ record: RecoveryRecord) {
        replayRecoveryRecord(record, useCurrentFlow: false)
    }

    func reprocessRecoveryRecord(_ record: RecoveryRecord) {
        replayRecoveryRecord(record, useCurrentFlow: true)
    }

    private func replayRecoveryRecord(_ record: RecoveryRecord, useCurrentFlow: Bool) {
        guard state == .idle else { NSSound.beep(); return }
        let audioURL = record.audioURL(baseDirectory: recoveryRecorder.directoryURL)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            overlay.showError("Saved recovery audio is missing."); return
        }
        if ["readyToInject", "outputUnknown"].contains(record.outcome), !replayDecision(.possiblePreviousOutput) { return }
        let partial = ["interrupted", "cancelled"].contains(record.outcome)
            || record.attempts?.last?.stages.partialAudio == true
            || { if case .interruptedInput = PCMRecordingIntegrityAnalyzer().analyze(wavData: (try? Data(contentsOf: audioURL)) ?? Data()) { return true }; return false }()
        if partial, !replayDecision(.partialAudio) { return }
        let replay: TranscriptionConfig
        let injection: InjectionConfig
        if useCurrentFlow {
            guard applyPendingPreferences() else { return }
            replay = config.transcription; injection = config.injection
        } else if let original = record.attempts?.last?.snapshot ?? record.snapshot {
            replay = original
            injection = record.attempts?.last?.injectionSnapshot ?? record.injectionSnapshot ?? config.injection
        } else {
            let selected = preferencesDraft?.config.transcription ?? config.transcription
            let title = "ASR: \(selected.provider.title)；润色: \(selected.textPolish.isEnabled ? selected.textPolish.provider.title : "关闭")"
            guard replayDecision(.unknownOriginalRoute(title)), applyPendingPreferences() else { return }
            replay = config.transcription; injection = config.injection
        }
        liveTextInput.reset()
        let sessionID = UUID()
        activeSessionID = sessionID; state = .processing
        let audio = RecordedAudio(fileURL: audioURL, durationMs: record.audioDurationMs,
            previewText: record.asrText ?? "", isPartialReplay: partial)
        let replayContext = launchAppContextProvider()
        statusMenu?.update(state: .processing, detail: useCurrentFlow ? "按当前流程重跑" : "重试原路线")
        overlay.beginSession(context: replayContext, captionsEnabled: replay.livePreviewEnabled)
        overlay.showProcessing()
        startProcessing(audio: audio, sessionID: sessionID, transcriptionConfig: replay,
            injectionConfig: injection, launchAppContext: replayContext, attemptPolicy: .manualRetry)
    }

    private func openConfigFolder() {
        let directoryURL = configStore.directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directoryURL)
    }

    func checkLaunchLoginState() {
        guard config.transcription.needsChatGPT else {
            return
        }

        let snapshot = authManager.authSnapshot()
        guard snapshot.state != .ready else {
            return
        }

        statusMenu?.update(state: .setupRequired, detail: snapshot.detail)
        notifier.notify(title: "ChatType setup required", body: snapshot.detail)
    }

    private static func mergedTerminologyEntries(
        existing: [TerminologyEntry],
        incoming: [TerminologyEntry]
    ) -> [TerminologyEntry] {
        var output = existing
        var keys = Set(existing.map(terminologyEntryKey(_:)))

        for entry in incoming {
            let key = terminologyEntryKey(entry)
            guard keys.insert(key).inserted else {
                continue
            }
            output.append(entry)
        }

        return output
    }

    private static func terminologyEntryKey(_ entry: TerminologyEntry) -> String {
        [
            entry.type.rawValue,
            entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            (entry.replacement ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
        ].joined(separator: "|")
    }

    private func showInstallRequiredAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install ChatType to /Applications first"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func requestMicrophoneAccess() async throws {
        if let microphoneAccessRequester { try await microphoneAccessRequester(); return }
        let status = AudioRecorder.microphonePermissionState()
        let app = NSApplication.shared
        let previousActivationPolicy = app.activationPolicy()

        logger.info(
            "Preparing microphone request with status=\(String(describing: status), privacy: .public) activationPolicy=\(String(describing: previousActivationPolicy), privacy: .public)"
        )

        if status == .undetermined {
            if previousActivationPolicy != .regular {
                logger.info("Temporarily switching activation policy to regular for first-run microphone prompt")
                _ = app.setActivationPolicy(.regular)
            }

            let controller = microphonePermissionWindowController ?? MicrophonePermissionWindowController()
            microphonePermissionWindowController = controller
            logger.info("Presenting first-run microphone permission window")
            let shouldContinue = await controller.present()
            logger.info("First-run microphone permission window returned shouldContinue=\(shouldContinue, privacy: .public)")
            guard shouldContinue else {
                if previousActivationPolicy != .regular {
                    _ = app.setActivationPolicy(previousActivationPolicy)
                }
                logger.error("User cancelled first-run microphone permission window")
                throw RecorderError.microphoneDenied
            }
        }

        defer {
            if previousActivationPolicy != .regular {
                logger.info("Restoring activation policy to \(String(describing: previousActivationPolicy), privacy: .public)")
                _ = app.setActivationPolicy(previousActivationPolicy)
            }
        }

        logger.info("Calling microphone access request helper")
        try await AudioRecorder.ensureMicrophoneAccess()
    }

    private func runOverlayDemo() {
        placeOverlayDemoOnRightScreen()
        let demoLevels: [CGFloat] = [0.14, 0.28, 0.46, 0.72, 0.54, 0.32, 0.18, 0.64]

        state = .processing
        statusMenu?.update(state: .demo, detail: "Overlay demo")
        overlay.showRecording(elapsedText: "00:00")
        overlay.updateTranscriptPreview("字幕跟随说话实时出现，自动换行；常态两行，长句可以自然扩展。")
        overlayDemoFrameIndex = 0

        recordingLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = demoLevels[self.overlayDemoFrameIndex % demoLevels.count]
                self.overlayDemoFrameIndex += 1
                self.overlay.updateRecording(level: level, elapsedText: self.demoElapsedText())
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 1_400_000_000)
            self.stopRecordingLevelUpdates()
            self.overlay.showProcessing()

            try? await Task.sleep(nanoseconds: 1_300_000_000)
            self.overlay.showResult(text: "Demo", outcome: .pasted)

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.overlay.showError("Clipboard only")

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.overlay.showRetryableError("403 after 3 tries")

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            NSApplication.shared.terminate(nil)
        }
    }

    private func runOverlayDemoState(_ demoState: OverlayDemoState) {
        placeOverlayDemoOnRightScreen()
        state = .processing
        statusMenu?.update(state: .demo, detail: "Overlay demo")

        switch demoState {
        case .recording:
            overlay.showRecording(elapsedText: "00:07")
            overlay.updateRecording(level: 0.72, elapsedText: "00:07")
            // Explicit, local-only subtitle demo: no microphone or document access.
            overlay.updateTranscriptPreview("实时字幕在这里显示，自动换行。说话时可以切换焦点，录音继续。")
        case .processing:
            overlay.showProcessing()
        case .result:
            overlay.showResult(text: "Demo", outcome: .pasted)
        case .copied:
            overlay.showResult(text: "Demo", outcome: .copiedToClipboard(reason: .noEditableTarget))
        case .error:
            overlay.showError("Clipboard only")
        case .retryableError:
            overlay.showRetryableError("403 after 3 tries")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            NSApplication.shared.terminate(nil)
        }
    }

    private func placeOverlayDemoOnRightScreen() {
        guard let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }),
              let controller = overlay as? OverlayController else { return }
        controller.debugSetGeometry(visible: screen.visibleFrame)
    }

    private func startRecordingLevelUpdates() {
        stopRecordingLevelUpdates()
        overlay.showRecording(elapsedText: elapsedRecordingText())

        recordingLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording, let recorder = self.recorder,
                      let level = recorder.currentLevel() else {
                    return
                }
                if recorder.inputInterruptionDetected() {
                    self.interruptRecording()
                    return
                }
                self.overlay.updateRecording(level: level, elapsedText: self.elapsedRecordingText())
                guard self.recordingConfig?.transcription.livePreviewEnabled == true else { return }
                if let live = self.liveDoubao {
                    let session = self.activeSessionID
                    let text = await live.state.preview
                    guard self.state == .recording, self.activeSessionID == session else { return }
                    self.overlay.updateTranscriptPreview(text)
                } else { self.overlay.updateTranscriptPreview(recorder.liveTranscript) }
            }
        }
    }

    private func interruptRecording() {
        liveTextInput.reset()
        stopRecordingLevelUpdates()
        liveDoubao?.cancel(); liveDoubao = nil
        let snapshot = recordingConfig ?? config
        let message = "麦克风输入已中断；已保存片段保留，云端处理已停止，未生成或粘贴完整结果。可在 History 明确重放已保存片段。"
        do {
            if let audio = try recorder?.stopRecording() {
                try recoveryRecorder.record(RecoveryRecordInput(timestamp: Date(), sourceAudioURL: audio.fileURL,
                    durationMs: audio.durationMs, asrText: nil, polishText: nil,
                    appName: launchAppContext?.localizedName, appBundleIdentifier: launchAppContext?.bundleIdentifier,
                    outcome: "interrupted", errorMessage: message, snapshot: snapshot.transcription,
                    injectionSnapshot: snapshot.injection))
                interruptedParentRecordID = UUID(uuidString: audio.fileURL.deletingPathExtension().lastPathComponent)
            }
            overlay.showError(message)
        } catch { overlay.showError("采集已停止；保存状态需核查。\(error.localizedDescription)") }
        state = .idle; activeSessionID = nil; recordingConfig = nil; recordingStartedAt = nil
        statusMenu?.update(state: .error, detail: message)
    }

    private func stopRecordingLevelUpdates() {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
    }

    private func elapsedRecordingText() -> String {
        guard let recordingStartedAt else {
            return "00:00"
        }
        let elapsedSeconds = Int((DispatchTime.now().uptimeNanoseconds - recordingStartedAt.uptimeNanoseconds) / 1_000_000_000)
        return Self.formatElapsed(seconds: elapsedSeconds)
    }

    private func demoElapsedText() -> String {
        Self.formatElapsed(seconds: overlayDemoFrameIndex / 12)
    }

    private static func formatElapsed(seconds: Int) -> String {
        let boundedSeconds = max(0, seconds)
        return String(format: "%02d:%02d", boundedSeconds / 60, boundedSeconds % 60)
    }

    private func statusDetail(for outcome: InjectionOutcome) -> String {
        switch outcome {
        case .pasted:
            return "Pasted transcript"
        case .copiedToClipboard(let reason):
            return reason.statusDetail
        }
    }

    private func prewarmAuthIfNeeded() {
        let entries = config.transcription.activeDictionaryEntries
        Task.detached(priority: .utility) {
            _ = VocabularyIndexCache.shared.index(for: entries)
            PersonalNameHints.prewarm(entries: entries)
        }
        guard config.transcription.needsChatGPT else {
            return
        }

        let authManager = self.authManager
        Task.detached(priority: .utility) {
            await authManager.prewarmSession()
        }
    }

    private func storePendingRetry(
        audio: RecordedAudio,
        launchAppContext: LaunchAppContext?,
        transcriptionConfig: TranscriptionConfig,
        injectionConfig: InjectionConfig
    ) throws {
        pendingRetry = PendingRetry(
            audio: RecordedAudio(fileURL: audio.fileURL, durationMs: audio.durationMs, previewText: audio.previewText, isPartialReplay: audio.isPartialReplay),
            launchAppContext: launchAppContext,
            transcriptionConfig: transcriptionConfig,
            injectionConfig: injectionConfig
        )
    }

    private func clearPendingRetry() {
        // Retry files are user material too; clearing UI state must not delete them.
        pendingRetry = nil
    }

    private func isRetryableTranscriptionError(_ error: Error) -> Bool {
        if let failure = error as? DoubaoTranscriptionFailure {
            return failure.underlyingError.map { isRetryableTranscriptionError($0) } ?? true
        }
        if error is LocalTranscriptionFailure || error is DictationPipelineFailure { return true }
        if let error = error as? DoubaoError {
            switch error {
            case .incomplete, .http, .rejected, .serviceDiscoveryFailure, .credentials, .unexpectedContent: return true
            default: return false
            }
        }
        if case TranscriptionError.retryableCloudflareChallenge = error {
            return true
        }
        return ChatGPTTranscriber.isRetryable(error)
    }

    private func recordTranscriptionFailure(
        audio: RecordedAudio,
        transcriptionConfig: TranscriptionConfig,
        processingStarted: UInt64
    ) {
        let sample = LatencySample(
            timestamp: Date(),
            audioDurationMs: audio.durationMs,
            audioBytes: (try? Data(contentsOf: audio.fileURL).count) ?? 0,
            provider: transcriptionConfig.provider.rawValue,
            authMs: 0,
            transcribeMs: 0,
            normalizationMs: 0,
            polishMs: 0,
            estimatedPolishInputTokens: 0,
            estimatedPolishOutputTokens: 0,
            injectMs: 0,
            totalProcessingMs: elapsedMilliseconds(since: processingStarted),
            resultStatus: "error",
            errorCategory: "transcribe"
        )
        try? latencyRecorder.record(sample)
    }

    private func recordLatency(
        prepared: PreparedDictation,
        outcome: InjectionOutcome?,
        injectMs: Int,
        totalProcessingMs: Int,
        errorCategory: String?
    ) {
        let sample = LatencySample(
            timestamp: Date(),
            audioDurationMs: prepared.metrics.transcription.audioDurationMs,
            audioBytes: prepared.metrics.transcription.audioBytes,
            provider: prepared.metrics.transcription.provider.rawValue,
            textPolishProvider: prepared.metrics.textPolishProvider?.rawValue,
            authMs: prepared.metrics.transcription.authMs,
            transcribeMs: prepared.metrics.transcription.transcribeMs,
            normalizationMs: prepared.metrics.normalizationMs,
            polishMs: prepared.metrics.polishMs,
            textPolishAttempted: prepared.metrics.textPolishAttempted,
            textPolishError: prepared.metrics.textPolishErrorMessage,
            estimatedPolishInputTokens: prepared.metrics.estimatedPolishInputTokens,
            estimatedPolishOutputTokens: prepared.metrics.estimatedPolishOutputTokens,
            injectMs: injectMs,
            totalProcessingMs: totalProcessingMs,
            resultStatus: latencyResultStatus(for: outcome),
            errorCategory: errorCategory,
            uploadedAudioBytes: prepared.metrics.transcription.uploadedBytes,
            uploadEncodingMs: prepared.metrics.transcription.encodingMs,
            uploadAudioFormat: prepared.metrics.transcription.uploadFormat,
            processingTiming: prepared.metrics.timing,
            liveFinishToLastSendMs: prepared.metrics.transcription.liveFinishToLastSendMs,
            sessionFinishWaitMs: prepared.metrics.transcription.sessionFinishWaitMs,
            recoveryWriteStats: (recoveryRecorder as? RecoveryStore)?.persistenceStats()
        )
        try? latencyRecorder.record(sample)
    }

    private func recordHistory(
        prepared: PreparedDictation,
        outcome: InjectionOutcome,
        launchAppContext: LaunchAppContext?
    ) throws {
        try historyRecorder.record(
            TranscriptionHistoryRecord(
                timestamp: Date(),
                rawText: prepared.rawText,
                finalText: prepared.finalText,
                appName: launchAppContext?.localizedName,
                appBundleIdentifier: launchAppContext?.bundleIdentifier,
                outcome: latencyResultStatus(for: outcome),
                textPolishProvider: prepared.metrics.textPolishProvider?.rawValue
            )
        )
    }

    private func recordRecoverySuccess(
        audio: RecordedAudio,
        prepared: PreparedDictation,
        outcome: InjectionOutcome,
        launchAppContext: LaunchAppContext?,
        snapshot: TranscriptionConfig, attemptID: UUID
    ) throws {
        try recoveryRecorder.record(
            RecoveryRecordInput(
                timestamp: Date(),
                sourceAudioURL: audio.fileURL,
                durationMs: audio.durationMs,
                asrText: prepared.rawText,
                polishText: prepared.stages?.polishOutput,
                appName: launchAppContext?.localizedName,
                appBundleIdentifier: launchAppContext?.bundleIdentifier,
                outcome: latencyResultStatus(for: outcome),
                errorMessage: prepared.metrics.textPolishErrorMessage, snapshot: snapshot,
                attemptID: attemptID, stages: prepared.stages
            )
        )
    }

    private func recordRecoveryFailure(
        audio: RecordedAudio,
        launchAppContext: LaunchAppContext?,
        error: any Error, snapshot: TranscriptionConfig, attemptID: UUID
    ) throws {
        var stages = (error as? DictationPipelineFailure)?.stages ?? .init()
        stages.error = error.localizedDescription
        stages.asrPartialText = (error as? DoubaoTranscriptionFailure)?.partialText
            ?? (error as? LocalTranscriptionFailure)?.partialText
        stages.asrRequestID = (error as? DoubaoTranscriptionFailure)?.requestID ?? stages.asrRequestID
        stages.asrSessions = (error as? DoubaoTranscriptionFailure)?.sessions ?? stages.asrSessions
        try recoveryRecorder.record(
            RecoveryRecordInput(
                timestamp: Date(),
                sourceAudioURL: audio.fileURL,
                durationMs: audio.durationMs,
                asrText: (error as? DictationPipelineFailure)?.stages.asrText
                    ?? (error as? DoubaoTranscriptionFailure)?.partialText
                    ?? (error as? LocalTranscriptionFailure)?.partialText,
                polishText: nil,
                appName: launchAppContext?.localizedName,
                appBundleIdentifier: launchAppContext?.bundleIdentifier,
                outcome: "error",
                errorMessage: error.localizedDescription, snapshot: snapshot, attemptID: attemptID,
                stages: stages
            )
        )
    }

    private func latencyResultStatus(for outcome: InjectionOutcome?) -> String {
        guard let outcome else {
            return "error"
        }

        switch outcome {
        case .pasted:
            return "pasted"
        case .copiedToClipboard:
            return "clipboard"
        }
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func shouldContinue(sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }

    private func refreshReadyState(detailOverride: String? = nil, state: StatusMenuVisualState = .ready) {
        guard self.state == .idle else { return }
        let issues = RuntimePreflight.issues(
            for: config,
            environment: ProcessInfo.processInfo.environment,
            authSnapshotProvider: { self.authManager.authSnapshot() }
        )
        if let detailOverride {
            statusMenu?.update(state: state, detail: detailOverride)
        } else if let summary = RuntimePreflight.summary(for: issues) {
            statusMenu?.update(state: .setupRequired, detail: summary)
        } else {
            statusMenu?.update(state: state, detail: "Ready. Press F5 to dictate")
        }
    }
}
