import CoreGraphics
import Foundation
import Testing
@testable import ChatType

@MainActor
private final class FakeCoordinatorRecorder: RecordingControlling {
    private(set) var cancelRecordingCallCount = 0
    private(set) var stopRecordingCallCount = 0
    var onStartRecording: (@Sendable () async -> Void)?
    var startRecordingError: (any Error)?
    var reportsInputInterruption = false
    var nextAudio = RecordedAudio(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.wav"),
        durationMs: 1_000
    )

    func startRecording() async throws {
        await onStartRecording?()
        if let startRecordingError {
            throw startRecordingError
        }
    }

    func stopRecording() throws -> RecordedAudio {
        stopRecordingCallCount += 1
        return nextAudio
    }

    func cancelRecording() throws {
        cancelRecordingCallCount += 1
    }

    func currentLevel() -> CGFloat? {
        0.25
    }

    func inputInterruptionDetected() -> Bool {
        reportsInputInterruption
    }
}

@MainActor
private final class FakeCoordinatorOverlay: OverlayControlling {
    var onCancel: (@MainActor () -> Void)?
    var onRetry: (@MainActor () -> Void)?
    var onShowProcessing: (@MainActor () -> Void)?
    private(set) var hideCallCount = 0
    private(set) var recordingElapsedTexts: [String] = []
    private(set) var showProcessingCallCount = 0
    private(set) var retryableErrors: [String] = []

    func showRecording(elapsedText: String) {
        recordingElapsedTexts.append(elapsedText)
    }
    func updateRecording(level: CGFloat, elapsedText: String) {}
    func showProcessing() {
        showProcessingCallCount += 1
        onShowProcessing?()
    }
    func showResult(text: String, outcome: InjectionOutcome) {}
    func showError(_ message: String) {}
    func showRetryableError(_ message: String) {
        retryableErrors.append(message)
    }

    func hide() {
        hideCallCount += 1
    }
}

@MainActor
private final class FakeCoordinatorStatusMenu: StatusMenuUpdating {
    private(set) var updates: [(StatusMenuVisualState, String)] = []

    func update(state: StatusMenuVisualState, detail: String) {
        updates.append((state, detail))
    }
}

@MainActor
private final class FakeCoordinatorNotifier: NotificationDispatching {
    func ensureAuthorization() {}
    func notify(title: String, body: String) {}
}

@MainActor
private final class FakeSoundFeedback: SoundFeedbackPlaying {
    private(set) var events: [SoundFeedbackEvent] = []

    func play(_ event: SoundFeedbackEvent, enabled: Bool) {
        guard enabled else {
            return
        }
        events.append(event)
    }
}

@MainActor
private final class FakeCoordinatorInjector: TextInjecting {
    private(set) var injectCallCount = 0
    private(set) var launchContexts: [LaunchAppContext?] = []

    func inject(
        text: String,
        preserveClipboard: Bool,
        restoreDelayMilliseconds: UInt64,
        launchAppContext: LaunchAppContext?
    ) throws -> InjectionOutcome {
        injectCallCount += 1
        launchContexts.append(launchAppContext)
        return .pasted
    }
}

private struct FakeCoordinatorPipeline: DictationPreparing {
    func prepare(audio: RecordedAudio) async throws -> PreparedDictation {
        if !FileManager.default.fileExists(atPath: audio.fileURL.path) { try? Data().write(to: audio.fileURL) }
        return PreparedDictation(
            rawText: "raw",
            finalText: "final",
            normalizationApplied: false,
            exactReplacementCount: 0,
            fuzzyReplacementCount: 0,
            metrics: DictationMetrics(
                transcription: TranscriptionMetrics(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: audio.durationMs,
                    audioBytes: 4,
                    authMs: 0,
                    transcribeMs: 0,
                    promptIncluded: false
                ),
                normalizationMs: 0
            )
        )
    }
}

private actor CoordinatorGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct BlockingCoordinatorPipeline: DictationPreparing {
    let gate: CoordinatorGate

    func prepare(audio: RecordedAudio) async throws -> PreparedDictation {
        if !FileManager.default.fileExists(atPath: audio.fileURL.path) { try? Data().write(to: audio.fileURL) }
        await gate.wait()
        return PreparedDictation(
            rawText: "raw",
            finalText: "final",
            normalizationApplied: false,
            exactReplacementCount: 0,
            fuzzyReplacementCount: 0,
            metrics: DictationMetrics(
                transcription: TranscriptionMetrics(
                    provider: .chatGPTManagedAuth,
                    audioDurationMs: audio.durationMs,
                    audioBytes: 4,
                    authMs: 0,
                    transcribeMs: 0,
                    promptIncluded: false
                ),
                normalizationMs: 0
            )
        )
    }
}

private struct FakeCoordinatorHistoryRecorder: TranscriptionHistoryRecording {
    func record(_ record: TranscriptionHistoryRecord) throws {}
    func loadRecent(limit: Int) throws -> [TranscriptionHistoryRecord] { [] }
}

private final class FakeLatencyRecorder: LatencyRecording, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var samples: [LatencySample] = []

    func record(_ sample: LatencySample) throws {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }
}

private enum ScriptedCoordinatorPipelineOutcome: Sendable {
    case success(String)
    case retryableCloudflare(Int)
}

private final class CoordinatorPipelineScript: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ScriptedCoordinatorPipelineOutcome]
    private(set) var policies: [TranscriptionAttemptPolicy] = []
    private(set) var audioPaths: [String] = []

    init(outcomes: [ScriptedCoordinatorPipelineOutcome]) {
        self.outcomes = outcomes
    }

    func makePipeline(policy: TranscriptionAttemptPolicy) -> any DictationPreparing {
        lock.lock()
        policies.append(policy)
        lock.unlock()
        return ScriptedCoordinatorPipeline(script: self)
    }

    func prepare(audio: RecordedAudio) throws -> PreparedDictation {
        lock.lock()
        audioPaths.append(audio.fileURL.path)
        let outcome = outcomes.isEmpty ? .success("final") : outcomes.removeFirst()
        lock.unlock()

        switch outcome {
        case .success(let text):
            return PreparedDictation(
                rawText: text,
                finalText: text,
                normalizationApplied: false,
                exactReplacementCount: 0,
                fuzzyReplacementCount: 0,
                metrics: DictationMetrics(
                    transcription: TranscriptionMetrics(
                        provider: .chatGPTManagedAuth,
                        audioDurationMs: audio.durationMs,
                        audioBytes: (try? Data(contentsOf: audio.fileURL).count) ?? 0,
                        authMs: 0,
                        transcribeMs: 1,
                        promptIncluded: true
                    ),
                    normalizationMs: 0
                )
            )
        case .retryableCloudflare(let attempts):
            throw TranscriptionError.retryableCloudflareChallenge(attempts: attempts)
        }
    }
}

private struct ScriptedCoordinatorPipeline: DictationPreparing {
    let script: CoordinatorPipelineScript

    func prepare(audio: RecordedAudio) async throws -> PreparedDictation {
        try script.prepare(audio: audio)
    }
}

@MainActor
private func waitForCoordinatorState(
    _ coordinator: AppCoordinator,
    toBecome expectedState: AppCoordinator.State,
    attempts: Int = 100
) async {
    for _ in 0..<attempts where coordinator.state != expectedState {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func waitForCondition(
    attempts: Int = 100,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<attempts where condition() == false {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
struct AppCoordinatorCancellationTests {
    @Test
    func cancelCurrentSessionDiscardsActiveRecordingAndResetsState() throws {
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.state = AppCoordinator.State.recording
        coordinator.launchAppContext = LaunchAppContext(
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            processIdentifier: 123
        )

        coordinator.cancelCurrentSession()

        #expect(recorder.cancelRecordingCallCount == 1)
        #expect(coordinator.state == AppCoordinator.State.idle)
        #expect(coordinator.launchAppContext == nil)
        #expect(overlay.hideCallCount == 1)
        #expect(statusMenu.updates.last?.0 == .ready)
    }

    @Test
    func cancelCurrentSessionCancelsProcessingTaskWithoutInjecting() async throws {
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let injector = FakeCoordinatorInjector()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: injector,
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )

        let processingTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        coordinator.state = AppCoordinator.State.processing
        coordinator.statusMenu = statusMenu
        coordinator.processingTask = processingTask
        coordinator.launchAppContext = LaunchAppContext(
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            processIdentifier: 123
        )

        coordinator.cancelCurrentSession()
        await Task.yield()

        #expect(processingTask.isCancelled == true)
        #expect(injector.injectCallCount == 0)
        #expect(coordinator.state == AppCoordinator.State.idle)
        #expect(coordinator.processingTask == nil)
        #expect(coordinator.launchAppContext == nil)
        #expect(overlay.hideCallCount == 1)
        #expect(statusMenu.updates.last?.0 == .ready)
    }

    @Test
    func startRecordingCapturesLaunchContextBeforeProcessingOverlay() async throws {
        let startGate = CoordinatorGate()
        let recorder = FakeCoordinatorRecorder()
        recorder.onStartRecording = {
            await startGate.wait()
        }
        let capturedContext = LaunchAppContext(
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            processIdentifier: 123
        )
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        var contextWhenProcessing: LaunchAppContext?
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() },
            launchAppContextProvider: { capturedContext }
        )
        overlay.onShowProcessing = {
            contextWhenProcessing = coordinator.launchAppContext
        }

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()

        #expect(contextWhenProcessing == capturedContext)
        #expect(overlay.showProcessingCallCount == 1)
        #expect(overlay.recordingElapsedTexts.isEmpty)
        #expect(soundFeedback.events.isEmpty)

        coordinator.cancelCurrentSession()
        await startGate.resume()
    }

    @Test
    func secondHotkeyTransitionsRecordingSessionIntoProcessing() async throws {
        let processingGate = CoordinatorGate()
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in BlockingCoordinatorPipeline(gate: processingGate) }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu

        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)

        coordinator.handleHotkeyPress()
        await Task.yield()

        #expect(recorder.stopRecordingCallCount == 1)
        #expect(coordinator.state == AppCoordinator.State.processing)
        #expect(overlay.showProcessingCallCount >= 1)
        #expect(statusMenu.updates.last?.0 == .processing)
        #expect(soundFeedback.events == [.recordingStarted, .recordingStopped])

        await processingGate.resume()
    }

    @Test
    func recordingStartSoundPlaysOnlyAfterRecorderStarts() async throws {
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)

        #expect(soundFeedback.events == [.recordingStarted])

        coordinator.cancelCurrentSession()
    }

    @Test
    func detectedInputInterruptionStopsRecordingInsteadOfContinuingSilently() async throws {
        let recorder = FakeCoordinatorRecorder()
        recorder.reportsInputInterruption = true
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let processingGate = CoordinatorGate()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in BlockingCoordinatorPipeline(gate: processingGate) }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        await waitForCoordinatorState(coordinator, toBecome: .processing)

        #expect(recorder.stopRecordingCallCount == 1)
        #expect(overlay.showProcessingCallCount >= 1)
        #expect(statusMenu.updates.last?.0 == .processing)

        await processingGate.resume()
    }

    @Test
    func recordingStartFailureDoesNotPlayFeedbackSound() async throws {
        let recorder = FakeCoordinatorRecorder()
        recorder.startRecordingError = NSError(
            domain: "ChatTypeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "recorder failed"]
        )
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .idle)

        #expect(soundFeedback.events.isEmpty)
    }

    @Test
    func disabledFeedbackSoundSettingSuppressesRecordingSounds() async throws {
        let processingGate = CoordinatorGate()
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        var config = AppConfig()
        config.transcription.feedbackSoundsEnabled = false
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: config,
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in BlockingCoordinatorPipeline(gate: processingGate) }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        coordinator.handleHotkeyPress()
        await Task.yield()

        #expect(soundFeedback.events.isEmpty)

        await processingGate.resume()
    }

    @Test
    func processingHotkeyDoesNotPlayRecordingFeedbackSound() {
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let soundFeedback = FakeSoundFeedback()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            soundFeedback: soundFeedback,
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.state = AppCoordinator.State.processing
        coordinator.handleHotkeyPress()

        #expect(soundFeedback.events.isEmpty)
    }

    @Test
    func retryableTranscriptionFailureCopiesAudioAndRetriesSavedRecordingOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalAudioURL = root.appendingPathComponent("original.wav")
        try Data("saved-audio".utf8).write(to: originalAudioURL)

        let recorder = FakeCoordinatorRecorder()
        recorder.nextAudio = RecordedAudio(fileURL: originalAudioURL, durationMs: 1_000)
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let injector = FakeCoordinatorInjector()
        let latencyRecorder = FakeLatencyRecorder()
        let capturedContext = LaunchAppContext(
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            processIdentifier: 123
        )
        let script = CoordinatorPipelineScript(outcomes: [
            .retryableCloudflare(3),
            .success("retry final"),
        ])
        let configStore = ConfigStore(fileManager: .default, homeDirectoryURL: root)
        let coordinator = AppCoordinator(
            configStore: configStore,
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: injector,
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: latencyRecorder,
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, policy in script.makePipeline(policy: policy) },
            launchAppContextProvider: { capturedContext }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        coordinator.handleHotkeyPress()
        await waitForCondition { overlay.retryableErrors.count == 1 }

        #expect(FileManager.default.fileExists(atPath: originalAudioURL.path) == true)
        #expect(script.policies == [.automatic])
        #expect(script.audioPaths.count == 1)

        overlay.onRetry?()
        await waitForCondition { injector.injectCallCount == 1 }

        #expect(script.audioPaths.count == 2)
        #expect(script.policies == [.automatic, .manualRetry])
        #expect(script.audioPaths[0] == originalAudioURL.path)
        #expect(script.audioPaths[1] != originalAudioURL.path)
        #expect(FileManager.default.fileExists(atPath: script.audioPaths[1]) == true)
        #expect(injector.launchContexts == [capturedContext])
        #expect(latencyRecorder.samples.map(\.resultStatus) == ["error", "pasted"])

        let recoveryStore = RecoveryStore(
            directoryURL: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true)
        )
        let recoveryRecords = try recoveryStore.loadRecent(limit: 10)
        #expect(recoveryRecords.count == 2)
        #expect(Set(recoveryRecords.map(\.outcome)) == Set(["error", "pasted"]))
        #expect(Set(recoveryRecords.map(\.id)).count == 2)
        let failure = try #require(recoveryRecords.first { $0.outcome == "error" })
        let success = try #require(recoveryRecords.first { $0.outcome == "pasted" })
        #expect(failure.errorMessage?.contains("Cloudflare") == true)
        #expect(success.asrText == "retry final")
        for record in recoveryRecords {
            let savedURL = record.audioURL(baseDirectory: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true))
            #expect(try Data(contentsOf: savedURL) == Data(contentsOf: originalAudioURL))
        }
        #expect(RecoveryHistoryPreview.recentItems(from: recoveryRecords, kind: .audio, limit: 10).count == 2)
        #expect(
            RecoveryHistoryPreview.recentItems(from: recoveryRecords, kind: .asr, limit: 10).map(\.copyText)
                == ["retry final"]
        )
    }

    @Test
    func retryFailureKeepsSavedAudioAndRetryControlAvailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalAudioURL = root.appendingPathComponent("original.wav")
        try Data("saved-audio".utf8).write(to: originalAudioURL)

        let recorder = FakeCoordinatorRecorder()
        recorder.nextAudio = RecordedAudio(fileURL: originalAudioURL, durationMs: 1_000)
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let script = CoordinatorPipelineScript(outcomes: [
            .retryableCloudflare(3),
            .retryableCloudflare(1),
        ])
        let coordinator = AppCoordinator(
            configStore: ConfigStore(fileManager: .default, homeDirectoryURL: root),
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, policy in script.makePipeline(policy: policy) }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        coordinator.handleHotkeyPress()
        await waitForCondition { overlay.retryableErrors.count == 1 }

        overlay.onRetry?()
        await waitForCondition { overlay.retryableErrors.count == 2 }

        #expect(script.policies == [.automatic, .manualRetry])
        #expect(script.audioPaths.count == 2)
        #expect(script.audioPaths[1] != originalAudioURL.path)
        #expect(FileManager.default.fileExists(atPath: script.audioPaths[1]) == true)
    }

    @Test
    func startingNewRecordingAfterRetryableFailurePreservesSavedRetryAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalAudioURL = root.appendingPathComponent("original.wav")
        try Data("saved-audio".utf8).write(to: originalAudioURL)

        let recorder = FakeCoordinatorRecorder()
        recorder.nextAudio = RecordedAudio(fileURL: originalAudioURL, durationMs: 1_000)
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let script = CoordinatorPipelineScript(outcomes: [.retryableCloudflare(3)])
        let configStore = ConfigStore(fileManager: .default, homeDirectoryURL: root)
        let coordinator = AppCoordinator(
            configStore: configStore,
            config: AppConfig(),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: overlay,
            authManager: FakeChatGPTAuthManager(),
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, policy in script.makePipeline(policy: policy) }
        )

        coordinator.recorder = recorder
        coordinator.statusMenu = statusMenu
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        coordinator.handleHotkeyPress()
        await waitForCondition { overlay.retryableErrors.count == 1 }

        let retryDirectory = configStore.directoryURL.appendingPathComponent("Retry", isDirectory: true)
        let savedRetryFiles = (try? FileManager.default.contentsOfDirectory(atPath: retryDirectory.path)) ?? []
        #expect(savedRetryFiles.count == 1)

        coordinator.handleHotkeyPress()
        let remainingRetryFiles = (try? FileManager.default.contentsOfDirectory(atPath: retryDirectory.path)) ?? []

        #expect(remainingRetryFiles == savedRetryFiles)
        coordinator.cancelCurrentSession()
    }

    @Test
    func cancellingProcessingPreservesReservedAudioAndPreventsLateInjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
        let url = try store.beginRecording()
        let samples = Data("original voice bytes".utf8)
        try samples.write(to: url)
        try store.finishRecording(RecordedAudio(fileURL: url, durationMs: 1_000), outcome: "recorded")
        let gate = CoordinatorGate()
        let recorder = FakeCoordinatorRecorder()
        recorder.nextAudio = RecordedAudio(fileURL: url, durationMs: 1_000)
        let injector = FakeCoordinatorInjector()
        let coordinator = AppCoordinator(configStore: ConfigStore(homeDirectoryURL: root),
            notifier: FakeCoordinatorNotifier(), injector: injector, overlay: FakeCoordinatorOverlay(),
            authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
            recoveryRecorder: store, recorderFactory: { _ in recorder },
            statusMenuFactory: { _, _, _ in FakeCoordinatorStatusMenu() },
            pipelineFactory: { _, _, _ in BlockingCoordinatorPipeline(gate: gate) })
        coordinator.recorder = recorder
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        coordinator.handleHotkeyPress()
        await Task.yield()
        coordinator.cancelCurrentSession()
        await gate.resume()
        await Task.yield()
        #expect(try Data(contentsOf: url) == samples)
        let records = try store.loadRecent(limit: 10)
        #expect(records.count == 1)
        #expect(records.first?.outcome == "cancelled")
        #expect(injector.injectCallCount == 0)
    }

    @Test
    func launchWithMissingChatGPTSessionShowsSetupStateWithoutLoginWindow() throws {
        let authManager = FakeChatGPTAuthManager(
            snapshot: ChatGPTAuthSnapshot(
                state: .signedOut,
                detail: "Sign in first",
                userEmail: nil
            )
        )
        let statusMenu = FakeCoordinatorStatusMenu()
        let coordinator = AppCoordinator(
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            notifier: FakeCoordinatorNotifier(),
            injector: FakeCoordinatorInjector(),
            overlay: FakeCoordinatorOverlay(),
            authManager: authManager,
            latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(),
            recorderFactory: { _ in FakeCoordinatorRecorder() },
            statusMenuFactory: { _, _, _ in statusMenu },
            pipelineFactory: { _, _, _ in FakeCoordinatorPipeline() }
        )
        coordinator.statusMenu = statusMenu

        coordinator.checkLaunchLoginState()

        #expect(statusMenu.updates.contains { $0.0 == .setupRequired && $0.1 == "Sign in first" })
    }
}
