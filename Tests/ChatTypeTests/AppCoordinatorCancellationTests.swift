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
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav"),
        durationMs: 1_000
    )

    func startRecording() async throws {
        if !FileManager.default.fileExists(atPath: nextAudio.fileURL.path) { try Data("test-audio".utf8).write(to: nextAudio.fileURL) }
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
    private(set) var captionSessions: [(LaunchAppContext?, Bool)] = []

    func beginSession(context: LaunchAppContext?, captionsEnabled: Bool) {
        captionSessions.append((context, captionsEnabled))
    }

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
    private(set) var notifications: [(String, String)] = []
    func ensureAuthorization() {}
    func notify(title: String, body: String) { notifications.append((title, body)) }
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

@MainActor
private final class StartupProbe {
    var entered = false
    var resumed = false
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
    case doubaoPartial
}

private final class CoordinatorPipelineScript: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ScriptedCoordinatorPipelineOutcome]
    private(set) var policies: [TranscriptionAttemptPolicy] = []
    private(set) var audioPaths: [String] = []
    private(set) var configs: [TranscriptionConfig] = []

    init(outcomes: [ScriptedCoordinatorPipelineOutcome]) {
        self.outcomes = outcomes
    }

    func makePipeline(policy: TranscriptionAttemptPolicy, config: TranscriptionConfig? = nil) -> any DictationPreparing {
        lock.lock()
        policies.append(policy)
        if let config { configs.append(config) }
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
        case .doubaoPartial:
            throw DoubaoTranscriptionFailure(partialText: "前半句", detail: "测试断线", requestID: "request-before-retry", underlyingError: URLError(.networkConnectionLost))
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
    @Test(arguments: [false, true])
    func lateStartupFailureCannotCancelNewSession(storageFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CoordinatorGate()
        let old = FakeCoordinatorRecorder(), new = FakeCoordinatorRecorder()
        defer { try? FileManager.default.removeItem(at: old.nextAudio.fileURL); try? FileManager.default.removeItem(at: new.nextAudio.fileURL) }
        let probe = StartupProbe()
        old.onStartRecording = {
            await MainActor.run { probe.entered = true }
            await gate.wait()
            await MainActor.run { probe.resumed = true }
        }
        old.startRecordingError = storageFailure
            ? RecorderError.recordingStorageFailed("archive failure") : CancellationError()
        let overlay = FakeCoordinatorOverlay(), notifier = FakeCoordinatorNotifier()
        var first = true
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: root),
            config: legacyAccountConfig(), notifier: notifier, injector: FakeCoordinatorInjector(), overlay: overlay,
            authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
            historyRecorder: FakeCoordinatorHistoryRecorder(), soundFeedback: FakeSoundFeedback(),
            recorderFactory: { _ in defer { first = false }; return first ? old : new },
            statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() },
            pipelineFactory: { _,_,_ in FakeCoordinatorPipeline() })
        coordinator.handleHotkeyPress()
        let oldStartup = try #require(coordinator.startRecordingTask)
        await waitForCondition { probe.entered }
        coordinator.cancelCurrentSession()
        coordinator.handleHotkeyPress()
        await waitForCoordinatorState(coordinator, toBecome: .recording)
        let hides = overlay.hideCallCount
        await gate.resume()
        await oldStartup.value
        #expect(probe.resumed)
        #expect(coordinator.state == .recording)
        #expect(new.cancelRecordingCallCount == 0)
        #expect(overlay.hideCallCount == hides)
        #expect(notifier.notifications.filter { $0.0 == "录音保存异常" }.count == (storageFailure ? 1 : 0))
        coordinator.cancelCurrentSession()
    }

    @Test
    func cancelCurrentSessionDiscardsActiveRecordingAndResetsState() throws {
        let recorder = FakeCoordinatorRecorder()
        let overlay = FakeCoordinatorOverlay()
        let statusMenu = FakeCoordinatorStatusMenu()
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        await waitForCoordinatorState(coordinator, toBecome: .idle)

        #expect(recorder.stopRecordingCallCount == 1)
        #expect(overlay.showProcessingCallCount >= 1)
        // An independent auth test can broadcast a readiness refresh after the
        // interruption. Assert that stopping capture reported the error rather
        // than depending on the final globally notified menu state.
        #expect(statusMenu.updates.contains { $0.0 == .error && $0.1.contains("麦克风输入已中断") })

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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
        var config = legacyAccountConfig()
        config.transcription.feedbackSoundsEnabled = false
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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
    func retryableTranscriptionFailureRetainsOneAudioWithSeparateAttempts() async throws {
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: configStore,
            config: legacyAccountConfig(),
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
        #expect(script.audioPaths[0] != originalAudioURL.path)
        #expect(script.audioPaths[1] == script.audioPaths[0])
        #expect(script.audioPaths[1] != originalAudioURL.path)
        #expect(FileManager.default.fileExists(atPath: script.audioPaths[1]) == true)
        #expect(injector.launchContexts == [capturedContext])
        #expect(latencyRecorder.samples.map(\.resultStatus) == ["error", "pasted"])

        let recoveryStore = RecoveryStore(
            directoryURL: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true)
        )
        let recoveryRecords = try recoveryStore.loadRecent(limit: 10)
        #expect(recoveryRecords.count == 1)
        let success = try #require(recoveryRecords.first)
        #expect(success.outcome == "pasted")
        #expect(success.attempts?.map(\.outcome) == ["error", "pasted"])
        #expect(success.attempts?.first?.snapshot.provider == .chatGPTManagedAuth)
        #expect(success.asrText == "retry final")
        for record in recoveryRecords {
            let savedURL = record.audioURL(baseDirectory: configStore.directoryURL.appendingPathComponent("Recovery", isDirectory: true))
            #expect(try Data(contentsOf: savedURL) == Data(contentsOf: originalAudioURL))
        }
        #expect(RecoveryHistoryPreview.recentItems(from: recoveryRecords, kind: .audio, limit: 10).count == 1)
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(fileManager: .default, homeDirectoryURL: root),
            config: legacyAccountConfig(),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: configStore,
            config: legacyAccountConfig(),
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

        let retryDirectory = configStore.directoryURL.appendingPathComponent("Recovery/Audio", isDirectory: true)
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: root),
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
        let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(),
            microphoneAccessRequester: {},
            configStore: ConfigStore(homeDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            config: legacyAccountConfig(),
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

@MainActor
@Test func recordingAndManualRetryUseTheF5StartTerminologySnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("snapshot.wav")
    try Data("recorded-audio".utf8).write(to: url)
    let recorder = FakeCoordinatorRecorder()
    recorder.nextAudio = RecordedAudio(fileURL: url, durationMs: 1_000, previewText: "请联系陶新蓝")
    let overlay = FakeCoordinatorOverlay()
    let observed = SnapshotConfigCapture()
    let previews = SnapshotConfigCapture()
    var initial = legacyAccountConfig()
    initial.transcription.hintTerms = ["pstack", "SmartShadow"]
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {},
        configStore: ConfigStore(homeDirectoryURL: root), config: initial,
        notifier: FakeCoordinatorNotifier(), injector: FakeCoordinatorInjector(), overlay: overlay,
        authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recorderFactory: { _ in recorder },
        statusMenuFactory: { _, _, _ in FakeCoordinatorStatusMenu() },
        pipelineFactory: { config, _, _ in
            observed.append(config.hintTerms)
            return SnapshotPreviewCapturingPipeline(captured: previews)
        })
    coordinator.recorder = recorder
    coordinator.handleHotkeyPress()
    await waitForCoordinatorState(coordinator, toBecome: .recording)
    coordinator.config.transcription.hintTerms = ["ChangedAfterStart"]
    coordinator.handleHotkeyPress()
    await waitForCondition { overlay.retryableErrors.count == 1 }
    overlay.onRetry?()
    await waitForCondition { overlay.retryableErrors.count == 2 }
    #expect(observed.values == [["pstack", "SmartShadow"], ["pstack", "SmartShadow"]])
    #expect(previews.values == [["请联系陶新蓝"], ["请联系陶新蓝"]])
}

private final class SnapshotConfigCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    func append(_ terms: [String]) { lock.withLock { stored.append(terms) } }
    var values: [[String]] { lock.withLock { stored } }
}

private struct SnapshotPreviewCapturingPipeline: DictationPreparing {
    let captured: SnapshotConfigCapture
    func prepare(audio: RecordedAudio) async throws -> PreparedDictation {
        captured.append([audio.previewText])
        throw TranscriptionError.retryableCloudflareChallenge(attempts: 1)
    }
}

private final class CloudCancelFlag: @unchecked Sendable {
    let lock = NSLock(); private var cancelled = false
    func mark() { lock.withLock { cancelled = true } }
    var value: Bool { lock.withLock { cancelled } }
}
private struct UnwritableRecovery: RecoveryRecording {
    let directoryURL = FileManager.default.temporaryDirectory
    func record(_ input: RecoveryRecordInput) throws { throw CocoaError(.fileWriteNoPermission) }
    func loadRecent(limit: Int) throws -> [RecoveryRecord] { [] }
}

@Test @MainActor func independentCloudTaskIsCancelledWhenInitialAuditFails() async throws {
    let gate = CoordinatorGate(); let cancelled = CloudCancelFlag()
    let cloud = Task<TranscriptionResult, Error> {
        try await withTaskCancellationHandler {
            await gate.wait(); try Task.checkCancellation()
            return TranscriptionResult(text: "unused", metrics: .init(provider: .doubaoIME, audioDurationMs: 1,
                audioBytes: 1, authMs: 0, transcribeMs: 0, promptIncluded: false))
        } onCancel: { cancelled.mark() }
    }
    let recorder = FakeCoordinatorRecorder(); recorder.nextAudio.cloudTranscript = cloud
    let overlay = FakeCoordinatorOverlay(); let menu = FakeCoordinatorStatusMenu(); let injector = FakeCoordinatorInjector()
    let script = CoordinatorPipelineScript(outcomes: [.success("must not run")])
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, config: legacyAccountConfig(),
        notifier: FakeCoordinatorNotifier(), injector: injector, overlay: overlay, authManager: FakeChatGPTAuthManager(),
        latencyRecorder: FakeLatencyRecorder(), historyRecorder: FakeCoordinatorHistoryRecorder(),
        recoveryRecorder: UnwritableRecovery(), soundFeedback: FakeSoundFeedback(), recorderFactory: { _ in recorder },
        statusMenuFactory: { _,_,_ in menu }, pipelineFactory: { _,_,p in script.makePipeline(policy:p) })
    coordinator.statusMenu = menu
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator,toBecome:.recording)
    coordinator.handleHotkeyPress()
    await waitForCondition { cancelled.value }
    #expect(cancelled.value); #expect(script.audioPaths.isEmpty); #expect(injector.injectCallCount == 0)
    await gate.resume(); _ = try? await cloud.value
}

@Test @MainActor func cancelBeforeProcessingTaskStartsClosesIndependentCloudTask() async throws {
    let gate = CoordinatorGate(); let cancelled = CloudCancelFlag()
    let cloud = Task<TranscriptionResult, Error> {
        try await withTaskCancellationHandler {
            await gate.wait(); try Task.checkCancellation()
            return TranscriptionResult(text: "unused", metrics: .init(provider: .doubaoIME, audioDurationMs: 1,
                audioBytes: 1, authMs: 0, transcribeMs: 0, promptIncluded: false))
        } onCancel: { cancelled.mark() }
    }
    let recorder = FakeCoordinatorRecorder(); recorder.nextAudio.cloudTranscript = cloud
    let overlay = FakeCoordinatorOverlay(); let menu = FakeCoordinatorStatusMenu(); let injector = FakeCoordinatorInjector()
    let script = CoordinatorPipelineScript(outcomes: [.success("must not run")])
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, config: legacyAccountConfig(),
        notifier: FakeCoordinatorNotifier(), injector: injector, overlay: overlay, authManager: FakeChatGPTAuthManager(),
        latencyRecorder: FakeLatencyRecorder(), historyRecorder: FakeCoordinatorHistoryRecorder(),
        soundFeedback: FakeSoundFeedback(), recorderFactory: { _ in recorder }, statusMenuFactory: { _,_,_ in menu },
        pipelineFactory: { _,_,p in script.makePipeline(policy:p) })
    coordinator.statusMenu = menu
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator,toBecome:.recording)
    overlay.onShowProcessing = { coordinator.cancelCurrentSession() }
    coordinator.handleHotkeyPress()
    await waitForCondition { cancelled.value }
    #expect(cancelled.value); #expect(script.audioPaths.isEmpty); #expect(injector.injectCallCount == 0)
    await gate.resume(); _ = try? await cloud.value
}

@Test @MainActor func failedPartialAsrAndErrorRemainAfterSuccessfulRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = RecoveryStore(directoryURL:root.appendingPathComponent("Recovery"))
    defer { try? FileManager.default.removeItem(at:root) }
    let recorder = FakeCoordinatorRecorder(); let overlay = FakeCoordinatorOverlay(); let menu = FakeCoordinatorStatusMenu()
    let injector = FakeCoordinatorInjector(); let script = CoordinatorPipelineScript(outcomes:[.doubaoPartial,.success("完整结果")])
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester:{}, config:AppConfig(), notifier:FakeCoordinatorNotifier(),
        injector:injector, overlay:overlay, authManager:FakeChatGPTAuthManager(), latencyRecorder:FakeLatencyRecorder(),
        historyRecorder:FakeCoordinatorHistoryRecorder(), recoveryRecorder:store, soundFeedback:FakeSoundFeedback(),
        recorderFactory:{_ in recorder}, statusMenuFactory:{_,_,_ in menu}, pipelineFactory:{_,_,p in script.makePipeline(policy:p)})
    coordinator.statusMenu = menu
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator,toBecome:.recording)
    coordinator.handleHotkeyPress(); await waitForCondition { overlay.retryableErrors.count == 1 }
    coordinator.config.transcription.provider = .chatGPTManagedAuth
    overlay.onRetry?(); await waitForCondition { injector.injectCallCount == 1 }
    let record = try #require(store.loadRecent(limit:10).last)
    #expect(record.attempts?.count == 2)
    #expect(record.attempts?.first?.stages.asrPartialText == "前半句")
    #expect(record.attempts?.first?.stages.error?.contains("测试断线") == true)
    #expect(record.attempts?.first?.stages.asrRequestID == "request-before-retry")
    #expect(record.attempts?.map(\.snapshot.provider) == [.doubaoIME,.doubaoIME])
    #expect(record.audioSHA256 != nil)
}


@Test @MainActor
func hudRetryPreservesOriginalRouteDespiteChangedVisibleFlow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
    let recorder = FakeCoordinatorRecorder(), overlay = FakeCoordinatorOverlay(), menu = FakeCoordinatorStatusMenu()
    let injector = FakeCoordinatorInjector()
    let script = CoordinatorPipelineScript(outcomes: [.doubaoPartial, .success("完整结果")])
    let original = AppConfig()
    let draft = PreferencesDraft(config: original)
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: root),
        config: original, notifier: FakeCoordinatorNotifier(), injector: injector, overlay: overlay,
        authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recoveryRecorder: store, soundFeedback: FakeSoundFeedback(),
        recorderFactory: { _ in recorder }, statusMenuFactory: { _,_,_ in menu },
        pipelineFactory: { c,_,p in script.makePipeline(policy: p, config: c) })
    coordinator.preferencesDraft = draft; coordinator.statusMenu = menu
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator, toBecome: .recording)
    // Changing future choices during recording cannot redirect this attempt.
    draft.config.transcription.provider = .chatGPTManagedAuth
    draft.config.transcription.textPolish.provider = .chatGPTAuth
    draft.config.transcription.textPolish.chatGPTAuthEnabled = true
    draft.config.transcription.textPolish.chatGPTResponseModel = "selected-model"
    draft.config.injection.preserveClipboard = true
    coordinator.handleHotkeyPress(); await waitForCondition { overlay.retryableErrors.count == 1 }
    overlay.onRetry?()
    await waitForCondition { injector.injectCallCount == 1 }
    let expected: TranscriptionProvider = .doubaoIME
    #expect(script.configs.map(\.provider) == [.doubaoIME, expected])
    #expect(script.configs.last?.textPolish.provider == .doubaoIME)
    let record = try #require(store.loadRecent().last)
    #expect(record.attempts?.map(\.snapshot.provider) == [.doubaoIME, expected])
    #expect(record.attempts?.first?.injectionSnapshot?.preserveClipboard == false)
    #expect(record.attempts?.last?.injectionSnapshot?.preserveClipboard == false)
    #expect(draft.hasChanges == true)
    #expect(script.audioPaths[0] == script.audioPaths[1])
    #expect(record.attempts?.first?.stages.asrPartialText == "前半句")
}

@Test(arguments: ["cancelled", "interrupted", "partial", "outputUnknown"]) @MainActor
func currentFlowReplayRequiresEveryApplicableSavedAudioDecision(source: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
    let url = try store.beginRecording(); try Data("retained audio".utf8).write(to: url)
    let id = UUID(); var stages = DictationStageAudit(); stages.partialAudio = source == "partial"
    try store.record(.init(timestamp: Date(), sourceAudioURL: url, durationMs: 1000, asrText: nil,
        polishText: nil, appName: nil, appBundleIdentifier: nil, outcome: source == "partial" ? "error" : source,
        errorMessage: nil, snapshot: AppConfig().transcription, attemptID: id, stages: stages))
    let record = try #require(store.loadRecent().first)
    let script = CoordinatorPipelineScript(outcomes: [])
    var decisions: [RecoveryReplayDecision] = []
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: root),
        config: AppConfig(), notifier: FakeCoordinatorNotifier(), injector: FakeCoordinatorInjector(),
        overlay: FakeCoordinatorOverlay(), authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recoveryRecorder: store,
        replayDecision: { decisions.append($0); return false }, soundFeedback: FakeSoundFeedback(),
        recorderFactory: { _ in FakeCoordinatorRecorder() }, statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() },
        pipelineFactory: { _,_,p in script.makePipeline(policy: p) })
    coordinator.reprocessRecoveryRecord(record)
    #expect(decisions == [source == "outputUnknown" ? .possiblePreviousOutput : .partialAudio])
    #expect(script.policies.isEmpty)
    #expect(try store.loadRecent().first?.attempts?.count == 1)
    #expect(try Data(contentsOf: url) == Data("retained audio".utf8))
}

@Test @MainActor func failedVisibleFlowSaveCannotStartRecordingOrReplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocked = root.appendingPathComponent("blocked"); try Data("not a directory".utf8).write(to: blocked)
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
    let url = try store.beginRecording(); try Data("retained audio".utf8).write(to: url)
    try store.record(.init(timestamp: Date(), sourceAudioURL: url, durationMs: 1000, asrText: nil,
        polishText: nil, appName: nil, appBundleIdentifier: nil, outcome: "error", errorMessage: nil,
        snapshot: AppConfig().transcription, attemptID: UUID()))
    let record = try #require(store.loadRecent().first)
    let script = CoordinatorPipelineScript(outcomes: [])
    let recorder = FakeCoordinatorRecorder()
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: blocked),
        config: AppConfig(), notifier: FakeCoordinatorNotifier(), injector: FakeCoordinatorInjector(),
        overlay: FakeCoordinatorOverlay(), authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recoveryRecorder: store, soundFeedback: FakeSoundFeedback(),
        recorderFactory: { _ in recorder }, statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() },
        pipelineFactory: { _,_,p in script.makePipeline(policy: p) })
    let draft = PreferencesDraft(config: AppConfig()); draft.config.transcription.provider = .chatGPTManagedAuth
    coordinator.preferencesDraft = draft
    coordinator.handleHotkeyPress()
    coordinator.reprocessRecoveryRecord(record)
    #expect(coordinator.state == .idle)
    #expect(script.policies.isEmpty)
    #expect(coordinator.config.transcription.provider == .doubaoIME)
    #expect(draft.hasChanges && draft.isError)
    #expect(try store.loadRecent().first?.attempts?.count == 1)
}


@Test @MainActor func F5StartAppliesTheVisibleDraftWithoutASeparateSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = FakeCoordinatorRecorder(), overlay = FakeCoordinatorOverlay(), menu = FakeCoordinatorStatusMenu()
    let script = CoordinatorPipelineScript(outcomes: [.success("selected route")])
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: ConfigStore(homeDirectoryURL: root),
        config: AppConfig(), notifier: FakeCoordinatorNotifier(), injector: FakeCoordinatorInjector(), overlay: overlay,
        authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(), historyRecorder: FakeCoordinatorHistoryRecorder(),
        recoveryRecorder: RecoveryStore(directoryURL: root.appendingPathComponent("Recovery")), soundFeedback: FakeSoundFeedback(),
        recorderFactory: { _ in recorder }, statusMenuFactory: { _,_,_ in menu },
        pipelineFactory: { c,_,p in script.makePipeline(policy: p, config: c) })
    let draft = PreferencesDraft(config: AppConfig()); draft.config.transcription.provider = .chatGPTManagedAuth
    draft.config.transcription.textPolish.provider = .chatGPTAuth; draft.config.transcription.textPolish.chatGPTAuthEnabled = true
    coordinator.preferencesDraft = draft; coordinator.statusMenu = menu
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator, toBecome: .recording)
    coordinator.handleHotkeyPress(); await waitForCondition { script.configs.count == 1 }
    #expect(script.configs.first?.provider == .chatGPTManagedAuth)
    #expect(script.configs.first?.textPolish.provider == .chatGPTAuth)
    #expect(!draft.hasChanges)
    await waitForCoordinatorState(coordinator, toBecome: .idle)
}


@Test(arguments: [TextPolishProviderID.qwenFlash, .glmFlash]) @MainActor
func missingPolishCredentialPreventsBothAutomaticApplyEntryPoints(provider: TextPolishProviderID) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
    let url = try store.beginRecording(); try Data("original".utf8).write(to: url)
    try store.record(.init(timestamp: Date(), sourceAudioURL: url, durationMs: 100, asrText: nil, polishText: nil,
        appName: nil, appBundleIdentifier: nil, outcome: "error", errorMessage: nil, snapshot: AppConfig().transcription, attemptID: UUID()))
    let record = try #require(store.loadRecent().first)
    let configStore = ConfigStore(homeDirectoryURL: root); let original = AppConfig(); try configStore.save(original)
    let script = CoordinatorPipelineScript(outcomes: [])
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {}, configStore: configStore, config: original,
        notifier: FakeCoordinatorNotifier(), injector: FakeCoordinatorInjector(), overlay: FakeCoordinatorOverlay(),
        authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(), historyRecorder: FakeCoordinatorHistoryRecorder(),
        recoveryRecorder: store, soundFeedback: FakeSoundFeedback(), recorderFactory: { _ in FakeCoordinatorRecorder() },
        statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() }, pipelineFactory: { _,_,p in script.makePipeline(policy:p) })
    let draft = PreferencesDraft(config: original, hasPolishCredential: { _ in false })
    draft.config.transcription.textPolish.selectProvider(provider); coordinator.preferencesDraft = draft
    coordinator.handleHotkeyPress(); coordinator.reprocessRecoveryRecord(record)
    #expect(coordinator.state == .idle && script.policies.isEmpty)
    #expect(try configStore.load() == original)
    #expect(try store.loadRecent().first?.attempts?.count == 1)
    #expect(draft.hasChanges && draft.isError)
}

@MainActor
private final class FakeLiveTextInput: LiveTextInputControlling {
    func begin(context: LaunchAppContext?, enabled: Bool) {}
    func update(_ text: String) {}
    func finish(_ text: String, injector: any TextInjecting, configuration: InjectionConfig) throws -> InjectionOutcome? { nil }
    func endRecording() {}
    func suspend() {}
    func reset() {}
}

private struct SelectivelyFailingRecovery: RecoveryRecording {
    let directoryURL = FileManager.default.temporaryDirectory
    let outcome: String
    func record(_ input: RecoveryRecordInput) throws {
        if input.outcome == outcome { throw CocoaError(.fileWriteNoPermission) }
    }
    func loadRecent(limit: Int) throws -> [RecoveryRecord] { [] }
}

@MainActor
private final class LiveInputProbe: LiveTextInputControlling {
    var events: [String] = []
    var finalized = false
    func begin(context: LaunchAppContext?, enabled: Bool) { events.append("begin") }
    func update(_ text: String) { events.append("update") }
    func finish(_ text: String, injector: any TextInjecting, configuration: InjectionConfig) throws -> InjectionOutcome? {
        events.append("finish"); finalized = true; return .pasted
    }
    func endRecording() { events.append("endRecording") }
    func suspend() { events.append("suspend"); finalized = false }
    func reset() { events.append("reset"); finalized = false }
}

@Test(arguments: ["readyToInject", "pasted"]) @MainActor
func pinnedFinalizationWaitsForSealAndSurvivesPostOutputAuditFailure(outcome: String) async throws {
    let recorder = FakeCoordinatorRecorder(); let input = LiveInputProbe(); let injector = FakeCoordinatorInjector()
    let coordinator = AppCoordinator(liveTextInput: input, microphoneAccessRequester: {}, config: AppConfig(),
        notifier: FakeCoordinatorNotifier(), injector: injector, overlay: FakeCoordinatorOverlay(),
        authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recoveryRecorder: SelectivelyFailingRecovery(outcome: outcome),
        soundFeedback: FakeSoundFeedback(), recorderFactory: { _ in recorder },
        statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() }, pipelineFactory: { _,_,_ in FakeCoordinatorPipeline() })
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator, toBecome: .recording)
    coordinator.handleHotkeyPress(); await waitForCoordinatorState(coordinator, toBecome: .idle)
    #expect(input.finalized == (outcome == "pasted"))
    #expect(input.events.contains("finish") == (outcome == "pasted"))
    #expect(input.events.contains("suspend") == (outcome == "readyToInject"))
    #expect(injector.injectCallCount == 0)
}

@Test(arguments: [false, true]) @MainActor
func historyReplayStartsItsOwnCaptionSessionAndUsesOneCapturedContext(enabled: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoveryStore(directoryURL: root.appendingPathComponent("Recovery"))
    let audio = try store.beginRecording(); try Data("retained audio".utf8).write(to: audio)
    try store.record(.init(timestamp: Date(), sourceAudioURL: audio, durationMs: 1000,
        asrText: nil, polishText: nil, appName: nil, appBundleIdentifier: nil, outcome: "error",
        errorMessage: nil, snapshot: AppConfig().transcription, attemptID: UUID()))
    let record = try #require(store.loadRecent().first)
    let overlay = FakeCoordinatorOverlay(), injector = FakeCoordinatorInjector()
    overlay.beginSession(context: nil, captionsEnabled: !enabled)
    var config = AppConfig(); config.transcription.livePreviewEnabled = enabled
    let context = LaunchAppContext(bundleIdentifier: "com.example.editor", localizedName: "Editor", processIdentifier: 123)
    var captures = 0
    let coordinator = AppCoordinator(liveTextInput: FakeLiveTextInput(), microphoneAccessRequester: {},
        configStore: ConfigStore(homeDirectoryURL: root), config: config, notifier: FakeCoordinatorNotifier(),
        injector: injector, overlay: overlay, authManager: FakeChatGPTAuthManager(), latencyRecorder: FakeLatencyRecorder(),
        historyRecorder: FakeCoordinatorHistoryRecorder(), recoveryRecorder: store, soundFeedback: FakeSoundFeedback(),
        recorderFactory: { _ in FakeCoordinatorRecorder() }, statusMenuFactory: { _,_,_ in FakeCoordinatorStatusMenu() },
        pipelineFactory: { _,_,_ in FakeCoordinatorPipeline() }, launchAppContextProvider: { captures += 1; return context })
    coordinator.reprocessRecoveryRecord(record)
    await waitForCoordinatorState(coordinator, toBecome: .idle)
    #expect(overlay.captionSessions.map { $0.1 } == [!enabled, enabled])
    #expect(overlay.captionSessions.last?.0 == context && captures == 1)
    #expect(injector.launchContexts == [context])
}
