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

    typealias RecorderFactory = @MainActor (Int) -> any RecordingControlling
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
    private var microphonePermissionWindowController: MicrophonePermissionWindowController?
    var state: State = .idle
    private var recordingLevelTimer: Timer?
    private var overlayDemoFrameIndex = 0
    var launchAppContext: LaunchAppContext?
    var processingTask: Task<Void, Never>?
    private var startRecordingTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var recordingStartedAt: DispatchTime?
    private var pendingRetry: PendingRetry?
    private var authStateObserver: NSObjectProtocol?

    private struct PendingRetry {
        let audio: RecordedAudio
        let launchAppContext: LaunchAppContext?
        let transcriptionConfig: TranscriptionConfig
        let injectionConfig: InjectionConfig
    }

    init(
        configStore: ConfigStore = ConfigStore(),
        config: AppConfig = AppConfig(),
        notifier: any NotificationDispatching = Notifier(),
        injector: any TextInjecting = TextInjector(),
        overlay: (any OverlayControlling)? = nil,
        authManager: any ChatGPTAuthProviding = ChatGPTAuthManager(),
        latencyRecorder: any LatencyRecording = LatencyRecorder(),
        historyRecorder: any TranscriptionHistoryRecording = TranscriptionHistoryRecorder(),
        recoveryRecorder: (any RecoveryRecording)? = nil,
        soundFeedback: any SoundFeedbackPlaying = SoundFeedbackService(),
        recorderFactory: @escaping RecorderFactory = { AudioRecorder(sampleRateHz: $0) },
        statusMenuFactory: @escaping StatusMenuFactory = { openSettings, openConfig, quit in
            StatusMenuController(
                openSettingsHandler: openSettings,
                openConfigHandler: openConfig,
                quitHandler: quit
            )
        },
        pipelineFactory: @escaping PipelineFactory = { transcriptionConfig, authManager, attemptPolicy in
            DictationPipeline(
                transcriber: ChatGPTTranscriber(
                    authManager: authManager,
                    config: transcriptionConfig,
                    cloudflareChallengeMaxAttempts: attemptPolicy.cloudflareChallengeMaxAttempts
                ),
                normalizer: TerminologyNormalizer(),
                importedEntries: transcriptionConfig.activeDictionaryEntries,
                hintTerms: transcriptionConfig.hintTerms,
                textPolisher: OpenAICompatibleTextPolisher(
                    config: transcriptionConfig.textPolish,
                    chatGPTAuthProvider: authManager,
                    chatGPTAuthAvailable: authManager.authSnapshot().state == .ready
                )
            )
        },
        launchAppContextProvider: @escaping LaunchAppContextProvider = { LaunchAppContext.current() }
    ) {
        self.configStore = configStore
        self.config = config
        self.notifier = notifier
        self.injector = injector
        let resolvedOverlay = overlay ?? OverlayController()
        self.overlay = resolvedOverlay
        self.authManager = authManager
        self.latencyRecorder = latencyRecorder
        self.historyRecorder = historyRecorder
        self.recoveryRecorder = recoveryRecorder ?? RecoveryStore(
            directoryURL: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true)
        )
        self.soundFeedback = soundFeedback
        self.recorderFactory = recorderFactory
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

            statusMenu = statusMenuFactory(
                { [weak self] in self?.openSettings() },
                { [weak self] in self?.openConfigFolder() },
                { NSApplication.shared.terminate(nil) }
            )

            switch launchMode {
            case .normal, .settings:
                config = try configStore.load()
                recorder = recorderFactory(config.transcription.sampleRateHz)
                refreshReadyState()
                checkLaunchLoginState()
                prewarmAuthIfNeeded()

                hotkeyMonitor = try HotkeyMonitor(keyCode: config.transcription.hotkeyKeyCode) { [weak self] in
                    Task { @MainActor in
                        self?.handleHotkeyPress()
                    }
                }
                notifier.ensureAuthorization()
                if launchMode == .settings {
                    openSettings()
                }
            case .overlayDemo:
                config = (try? configStore.load()) ?? config
                runOverlayDemo()
                return
            case .overlayDemoState(let demoState):
                config = (try? configStore.load()) ?? config
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
            statusMenu?.update(state: .error, detail: error.localizedDescription)
        }
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

    func cancelCurrentSession() {
        guard state != .idle || activeSessionID != nil || processingTask != nil || startRecordingTask != nil else {
            return
        }

        startRecordingTask?.cancel()
        startRecordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        stopRecordingLevelUpdates()
        clearPendingRetry()

        if state == .recording {
            try? recorder?.cancelRecording()
        }

        state = .idle
        activeSessionID = nil
        recordingStartedAt = nil
        launchAppContext = nil
        overlay.hide()
        refreshReadyState()
    }

    private func startRecording() {
        guard let recorder else { return }

        clearPendingRetry()
        logger.info("Start recording requested from hotkey")
        let sessionID = UUID()
        activeSessionID = sessionID
        launchAppContext = launchAppContextProvider()
        state = .processing
        statusMenu?.update(state: .processing, detail: "Requesting microphone")
        overlay.showProcessing()

        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.requestMicrophoneAccess()
                guard self.shouldContinue(sessionID: sessionID) else { return }
                logger.info("Microphone access stage completed")

                let issues = RuntimePreflight.issues(
                    for: self.config,
                    environment: ProcessInfo.processInfo.environment,
                    authSnapshotProvider: { self.authManager.authSnapshot() }
                )
                if let message = RuntimePreflight.summary(for: issues) {
                    logger.error("Runtime preflight blocked recording with \(issues.count, privacy: .public) issue(s): \(message, privacy: .public)")
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

                logger.info("Recording session started successfully")
                self.recordingStartedAt = .now()
                self.state = .recording
                self.statusMenu?.update(state: .recording, detail: "Recording on F5")
                self.overlay.showRecording(elapsedText: "00:00")
                self.soundFeedback.play(.recordingStarted, enabled: self.config.transcription.feedbackSoundsEnabled)
                self.startRecordingLevelUpdates()
            } catch is CancellationError {
                self.cancelCurrentSession()
            } catch {
                guard self.shouldContinue(sessionID: sessionID) else { return }
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
        guard let recorder, let sessionID = activeSessionID else { return }

        do {
            stopRecordingLevelUpdates()
            let audio = try recorder.stopRecording()
            recordingStartedAt = nil
            state = .processing
            statusMenu?.update(state: .processing, detail: "Processing")
            overlay.showProcessing()
            soundFeedback.play(.recordingStopped, enabled: config.transcription.feedbackSoundsEnabled)

            let transcriptionConfig = config.transcription
            let injectionConfig = config.injection
            let launchAppContext = self.launchAppContext
            startProcessing(
                audio: audio,
                sessionID: sessionID,
                transcriptionConfig: transcriptionConfig,
                injectionConfig: injectionConfig,
                launchAppContext: launchAppContext,
                attemptPolicy: .automatic,
                deleteAudioWhenFinished: true
            )
        } catch {
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
            attemptPolicy: .manualRetry,
            deleteAudioWhenFinished: false
        )
    }

    private func startProcessing(
        audio: RecordedAudio,
        sessionID: UUID,
        transcriptionConfig: TranscriptionConfig,
        injectionConfig: InjectionConfig,
        launchAppContext: LaunchAppContext?,
        attemptPolicy: TranscriptionAttemptPolicy,
        deleteAudioWhenFinished: Bool
    ) {
        let processingStarted = DispatchTime.now().uptimeNanoseconds

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if deleteAudioWhenFinished {
                    try? FileManager.default.removeItem(at: audio.fileURL)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.activeSessionID == sessionID || self.activeSessionID == nil {
                        self.processingTask = nil
                    }
                }
            }

            let pipeline = self.pipelineFactory(transcriptionConfig, self.authManager, attemptPolicy)

            do {
                let prepared = try await pipeline.prepare(audio: audio)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.shouldContinue(sessionID: sessionID) else { return }

                    do {
                        let injectStarted = DispatchTime.now().uptimeNanoseconds
                        let outcome = try self.injector.inject(
                            text: prepared.finalText,
                            preserveClipboard: injectionConfig.preserveClipboard,
                            restoreDelayMilliseconds: injectionConfig.restoreDelayMilliseconds,
                            launchAppContext: launchAppContext
                        )
                        let injectMs = self.elapsedMilliseconds(since: injectStarted)
                        let totalProcessingMs = self.elapsedMilliseconds(since: processingStarted)
                        self.recordLatency(
                            prepared: prepared,
                            outcome: outcome,
                            injectMs: injectMs,
                            totalProcessingMs: totalProcessingMs,
                            errorCategory: nil
                        )
                        self.recordHistory(
                            prepared: prepared,
                            outcome: outcome,
                            launchAppContext: launchAppContext
                        )
                        self.recordRecoverySuccess(
                            audio: audio,
                            prepared: prepared,
                            outcome: outcome,
                            launchAppContext: launchAppContext
                        )
                        self.clearPendingRetry()
                        self.state = .idle
                        self.activeSessionID = nil
                        self.statusMenu?.update(
                            state: .ready,
                            detail: self.statusDetail(for: outcome)
                        )
                        self.overlay.showResult(text: prepared.finalText, outcome: outcome)
                        self.launchAppContext = nil
                    } catch {
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
                        self.overlay.showError(error.localizedDescription)
                        self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                        self.launchAppContext = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.shouldContinue(sessionID: sessionID) else { return }

                    self.recordTranscriptionFailure(
                        audio: audio,
                        transcriptionConfig: transcriptionConfig,
                        processingStarted: processingStarted
                    )
                    self.recordRecoveryFailure(
                        audio: audio,
                        launchAppContext: launchAppContext,
                        error: error
                    )

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
            preferencesWindowController = PreferencesWindowController(
                config: config,
                authManager: authManager,
                onSave: { [weak self] newConfig in
                    guard let self else { return }
                    do {
                        try self.configStore.save(newConfig)
                        self.config = newConfig
                        self.refreshReadyState(detailOverride: "Settings saved", state: .ready)
                        self.prewarmAuthIfNeeded()
                    } catch {
                        self.overlay.showError(error.localizedDescription)
                        self.notifier.notify(title: "ChatType", body: error.localizedDescription)
                    }
                },
                onImportAppleContactRemarks: { [weak self] currentConfig in
                    guard let self else {
                        return .failure(
                            NSError(
                                domain: "ChatType.Preferences",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "ChatType settings are no longer available."]
                            )
                        )
                    }

                    do {
                        let imported = try await AppleContactRemarkImporter().importEntries()
                        return .success(
                            try self.persistTerminologyImport(
                                currentConfig: currentConfig,
                                imported: imported,
                                lastImportedSource: imported.source
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                },
                onImportWeixinRemarks: { [weak self] currentConfig, fileURL in
                    guard let self else {
                        return .failure(
                            NSError(
                                domain: "ChatType.Preferences",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "ChatType settings are no longer available."]
                            )
                        )
                    }

                    do {
                        let data = try Data(contentsOf: fileURL)
                        let imported = try WeixinRemarkCSVImporter().importEntries(
                            from: data,
                            sourceName: fileURL.lastPathComponent
                        )
                        return .success(
                            try self.persistTerminologyImport(
                                currentConfig: currentConfig,
                                imported: imported,
                                lastImportedSource: fileURL.path
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                },
                onLoadRecentHistory: { [weak self] in
                    guard let self else {
                        return []
                    }
                    return (try? self.historyRecorder.loadRecent(limit: 200)) ?? []
                },
                onLoadRecoveryHistory: { [weak self] in
                    guard let self else {
                        return []
                    }
                    return (try? self.recoveryRecorder.loadRecent(limit: 10)) ?? []
                },
                recoveryDirectoryURL: recoveryRecorder.directoryURL,
                onRetryRecoveryRecord: { [weak self] record in
                    self?.retryRecoveryRecord(record)
                },
                onOpenConfigFolder: { [weak self] in
                    self?.openConfigFolder()
                },
                focusRecoveryHistory: focusRecoveryHistory
            )
        }

        preferencesWindowController?.show()
    }

    private func persistTerminologyImport(
        currentConfig: AppConfig,
        imported: TerminologyImportResult,
        lastImportedSource: String
    ) throws -> AppConfig {
        var updatedConfig = currentConfig
        updatedConfig.transcription.terminology.entries = Self.mergedTerminologyEntries(
            existing: updatedConfig.transcription.terminology.entries,
            incoming: imported.entries
        )
        updatedConfig.transcription.terminology.lastImportedSource = lastImportedSource
        updatedConfig.transcription.terminology.lastImportedAt = imported.importedAt

        try configStore.save(updatedConfig)
        config = updatedConfig
        refreshReadyState(
            detailOverride: "Imported \(imported.entries.count) terminology terms",
            state: .ready
        )
        return updatedConfig
    }

    private func retryRecoveryRecord(_ record: RecoveryRecord) {
        guard state == .idle else {
            NSSound.beep()
            return
        }

        let audioURL = record.audioURL(baseDirectory: recoveryRecorder.directoryURL)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            overlay.showError("Saved recovery audio is missing.")
            return
        }

        let sessionID = UUID()
        activeSessionID = sessionID
        state = .processing
        let audio = RecordedAudio(fileURL: audioURL, durationMs: record.audioDurationMs)
        statusMenu?.update(state: .processing, detail: "Retrying saved audio")
        overlay.showProcessing()
        startProcessing(
            audio: audio,
            sessionID: sessionID,
            transcriptionConfig: config.transcription,
            injectionConfig: config.injection,
            launchAppContext: launchAppContextProvider(),
            attemptPolicy: .manualRetry,
            deleteAudioWhenFinished: false
        )
    }

    private func openConfigFolder() {
        let directoryURL = configStore.directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directoryURL)
    }

    func checkLaunchLoginState() {
        guard config.transcription.provider == .chatGPTManagedAuth else {
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
        let demoLevels: [CGFloat] = [0.14, 0.28, 0.46, 0.72, 0.54, 0.32, 0.18, 0.64]

        state = .processing
        statusMenu?.update(state: .demo, detail: "Overlay demo")
        overlay.showRecording(elapsedText: "00:00")
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
        state = .processing
        statusMenu?.update(state: .demo, detail: "Overlay demo")

        switch demoState {
        case .recording:
            overlay.showRecording(elapsedText: "00:07")
            overlay.updateRecording(level: 0.72, elapsedText: "00:07")
        case .processing:
            overlay.showProcessing()
        case .result:
            overlay.showResult(text: "Demo", outcome: .pasted)
        case .error:
            overlay.showError("Clipboard only")
        case .retryableError:
            overlay.showRetryableError("403 after 3 tries")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            NSApplication.shared.terminate(nil)
        }
    }

    private func startRecordingLevelUpdates() {
        stopRecordingLevelUpdates()
        overlay.showRecording(elapsedText: elapsedRecordingText())

        recordingLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let level = self.recorder?.currentLevel() else {
                    return
                }
                self.overlay.updateRecording(level: level, elapsedText: self.elapsedRecordingText())
            }
        }
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
        guard config.transcription.provider == .chatGPTManagedAuth else {
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
        if pendingRetry?.audio.fileURL == audio.fileURL {
            pendingRetry = PendingRetry(
                audio: audio,
                launchAppContext: launchAppContext,
                transcriptionConfig: transcriptionConfig,
                injectionConfig: injectionConfig
            )
            return
        }

        clearPendingRetry()
        let retryDirectory = configStore.directoryURL.appendingPathComponent("Retry", isDirectory: true)
        try FileManager.default.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
        let retryURL = retryDirectory.appendingPathComponent("retry-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: audio.fileURL, to: retryURL)
        pendingRetry = PendingRetry(
            audio: RecordedAudio(fileURL: retryURL, durationMs: audio.durationMs),
            launchAppContext: launchAppContext,
            transcriptionConfig: transcriptionConfig,
            injectionConfig: injectionConfig
        )
    }

    private func clearPendingRetry() {
        if let pendingRetry {
            try? FileManager.default.removeItem(at: pendingRetry.audio.fileURL)
        }
        pendingRetry = nil
    }

    private func isRetryableTranscriptionError(_ error: Error) -> Bool {
        if case TranscriptionError.retryableCloudflareChallenge = error {
            return true
        }
        return false
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
            errorCategory: errorCategory
        )
        try? latencyRecorder.record(sample)
    }

    private func recordHistory(
        prepared: PreparedDictation,
        outcome: InjectionOutcome,
        launchAppContext: LaunchAppContext?
    ) {
        try? historyRecorder.record(
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
        launchAppContext: LaunchAppContext?
    ) {
        try? recoveryRecorder.record(
            RecoveryRecordInput(
                timestamp: Date(),
                sourceAudioURL: audio.fileURL,
                durationMs: audio.durationMs,
                asrText: prepared.rawText,
                polishText: prepared.finalText,
                appName: launchAppContext?.localizedName,
                appBundleIdentifier: launchAppContext?.bundleIdentifier,
                outcome: latencyResultStatus(for: outcome),
                errorMessage: prepared.metrics.textPolishErrorMessage
            )
        )
    }

    private func recordRecoveryFailure(
        audio: RecordedAudio,
        launchAppContext: LaunchAppContext?,
        error: any Error
    ) {
        try? recoveryRecorder.record(
            RecoveryRecordInput(
                timestamp: Date(),
                sourceAudioURL: audio.fileURL,
                durationMs: audio.durationMs,
                asrText: nil,
                polishText: nil,
                appName: launchAppContext?.localizedName,
                appBundleIdentifier: launchAppContext?.bundleIdentifier,
                outcome: "error",
                errorMessage: error.localizedDescription
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
