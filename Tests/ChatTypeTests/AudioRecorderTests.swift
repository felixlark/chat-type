import AVFoundation
import Testing
@testable import ChatType

private final class FakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    var prepareToRecordResult = true
    var recordResult = true
    private(set) var stopCallCount = 0
    var currentTime: TimeInterval = 1.25
    var isRecording = true
    private(set) var recordCallCount = 0
    var averagePowerValue: Float = -30

    func prepareToRecord() -> Bool {
        prepareToRecordResult
    }

    func record() -> Bool {
        recordCallCount += 1
        return recordResult
    }

    func stop() {
        stopCallCount += 1
        currentTime = 0
        isRecording = false
    }

    func updateMeters() {}

    func averagePower(forChannel channelNumber: Int) -> Float {
        averagePowerValue
    }
}

private actor AccessRequestProbe {
    private var requested = false

    func markRequested() {
        requested = true
    }

    func wasRequested() -> Bool {
        requested
    }
}

private final class FailingArchiveAttributes: FileManager, @unchecked Sendable {
    var fail = false
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

struct AudioRecorderTests {
    @Test @MainActor
    func recordingIsNotReadyUntilCaptureClockAdvances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = FakeRecordingSession(); session.currentTime = 0
        let recorder = AudioRecorder(sampleRateHz: 16000, permissionProvider: { .granted },
            sessionFactory: { _, _ in session }, temporaryFileURLFactory: { url })
        var ready = false
        let startup = Task { try await recorder.startRecording(); ready = true }
        while session.recordCallCount == 0 { await Task.yield() }
        #expect(!ready)
        session.currentTime = 0.02
        try await startup.value
        #expect(ready)
        try recorder.cancelRecording()
    }

    @Test @MainActor
    func cancellingBeforeReadyStopsInputAndSealsOriginalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(directoryURL: root)
        let session = FakeRecordingSession(); session.currentTime = 0
        let original = Data("reserved PCM samples".utf8)
        let recorder = AudioRecorder(sampleRateHz: 16000, permissionProvider: { .granted },
            sessionFactory: { url, _ in try original.write(to: url); return session }, recoveryStore: store)
        let startup = Task { try await recorder.startRecording() }
        while session.recordCallCount == 0 { await Task.yield() }
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(session.stopCallCount == 1)
        let record = try #require(store.loadRecent().first)
        #expect(record.outcome == "cancelled")
        #expect(try Data(contentsOf: record.audioURL(baseDirectory: root)) == original)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1]) @MainActor
    func invalidCaptureClockFailsWithoutConvertingItToDuration(clock: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = FakeRecordingSession(); session.currentTime = clock
        let recorder = AudioRecorder(sampleRateHz: 16000, permissionProvider: { .granted },
            sessionFactory: { _, _ in session }, temporaryFileURLFactory: { url })
        await #expect(throws: RecorderError.recorderStartFailed) { try await recorder.startRecording() }
        #expect(session.stopCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor
    func stoppedSessionDoesNotWaitForeverForItsZeroClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = FakeRecordingSession(); session.currentTime = 0; session.isRecording = false
        let recorder = AudioRecorder(sampleRateHz: 16000, permissionProvider: { .granted },
            sessionFactory: { _, _ in session }, temporaryFileURLFactory: { url })
        await #expect(throws: RecorderError.recorderStartFailed) { try await recorder.startRecording() }
        #expect(session.stopCallCount == 1)
    }

    @Test @MainActor
    func cancellationArchiveFailureIsExplicitAndDoesNotDeleteRawAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FailingArchiveAttributes()
        let store = RecoveryStore(fileManager: files, directoryURL: root)
        let session = FakeRecordingSession(); session.currentTime = 0
        let original = Data("original PCM".utf8)
        var audioURL: URL?
        let recorder = AudioRecorder(sampleRateHz: 16000, permissionProvider: { .granted },
            sessionFactory: { url, _ in try original.write(to: url); return session }, recoveryStore: store)
        let startup = Task { try await recorder.startRecording() }
        while session.recordCallCount == 0 { await Task.yield() }
        let reserved = try #require(store.loadRecent().first)
        audioURL = reserved.audioURL(baseDirectory: root)
        files.fail = true; startup.cancel()
        do { try await startup.value; Issue.record("Storage failure must be surfaced") }
        catch let error as RecorderError {
            guard case .recordingStorageFailed = error else { Issue.record("Wrong recorder error"); return }
        }
        #expect(session.stopCallCount == 1)
        let savedURL = try #require(audioURL)
        #expect(try Data(contentsOf: savedURL) == original)
    }

    @Test
    func microphoneRepairActionsAppearOnlyWhenPermissionWasDenied() {
        #expect(AudioRecorder.repairActions(for: .granted).isEmpty)
        #expect(AudioRecorder.repairActions(for: .undetermined).isEmpty)

        let actions = AudioRecorder.repairActions(for: .denied)
        #expect(actions.count == 1)
        #expect(actions[0].title == "Open Microphone Settings")
        #expect(
            actions[0].kind == .openSettings(
                PermissionSettingsDestination(
                    url: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!,
                    paneIdentifier: "com.apple.settings.PrivacySecurity.extension",
                    anchor: "Privacy_Microphone"
                )
            )
        )
    }

    @Test
    func microphoneAccessRequestsSystemPromptWhenStatusIsUndetermined() async throws {
        let probe = AccessRequestProbe()

        try await AudioRecorder.ensureMicrophoneAccess(
            permissionProvider: { .undetermined },
            requestPermission: {
                await probe.markRequested()
                return true
            }
        )

        #expect(await probe.wasRequested())
    }

    @Test
    func microphoneAccessSkipsSystemPromptWhenAlreadyAuthorized() async throws {
        let probe = AccessRequestProbe()

        try await AudioRecorder.ensureMicrophoneAccess(
            permissionProvider: { .granted },
            requestPermission: {
                await probe.markRequested()
                return true
            }
        )

        #expect(!(await probe.wasRequested()))
    }

    @Test
    func microphoneAccessFailsImmediatelyWhenDenied() async {
        let probe = AccessRequestProbe()

        await #expect(throws: RecorderError.microphoneDenied) {
            try await AudioRecorder.ensureMicrophoneAccess(
                permissionProvider: { .denied },
                requestPermission: {
                    await probe.markRequested()
                    return false
                }
            )
        }

        #expect(!(await probe.wasRequested()))
    }

    @MainActor
    @Test
    func cancelRecordingStopsSessionAndPreservesRawFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-recording-test.wav")
        try Data("wave".utf8).write(to: fileURL)

        let session = FakeRecordingSession()
        let recorder = AudioRecorder(
            sampleRateHz: 16_000,
            permissionProvider: { .granted },
            permissionRequester: { true },
            sessionFactory: { _, _ in session },
            temporaryFileURLFactory: { fileURL },
            fileManager: .default
        )

        try await recorder.startRecording()
        try recorder.cancelRecording()

        #expect(session.stopCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == true)

        #expect(throws: RecorderError.noActiveRecording) {
            try recorder.stopRecording()
        }
    }

    @MainActor
    @Test
    func stopRecordingCapturesDurationBeforeStoppingRecorder() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("duration-recording-test.wav")
        try Data("wave".utf8).write(to: fileURL)

        let session = FakeRecordingSession()
        session.currentTime = 3.45
        let recorder = AudioRecorder(
            sampleRateHz: 16_000,
            permissionProvider: { .granted },
            permissionRequester: { true },
            sessionFactory: { _, _ in session },
            temporaryFileURLFactory: { fileURL },
            fileManager: .default
        )

        try await recorder.startRecording()
        let audio = try recorder.stopRecording()

        #expect(audio.durationMs == 3_450)
        #expect(session.stopCallCount == 1)
        try? FileManager.default.removeItem(at: fileURL)
    }
    @MainActor
    @Test
    func storageFailurePreventsMicrophoneSessionCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let recorder = AudioRecorder(sampleRateHz: 24_000, permissionProvider: { .granted },
            permissionRequester: { true }, sessionFactory: { _, _ in
                Issue.record("Audio session must not be created without a writable archive")
                return FakeRecordingSession()
            }, recoveryStore: RecoveryStore(directoryURL: root))
        await #expect(throws: (any Error).self) { try await recorder.startRecording() }
    }

    @MainActor
    @Test
    func cancelRealArchiveKeepsOneJournalAndRawSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(directoryURL: root)
        let session = FakeRecordingSession()
        let recorder = AudioRecorder(sampleRateHz: 24_000, permissionProvider: { .granted },
            permissionRequester: { true }, sessionFactory: { url, _ in
                try Data("PCM samples".utf8).write(to: url)
                return session
            }, recoveryStore: store)
        try await recorder.startRecording()
        let initial = try #require(store.loadRecent(limit: 10).first)
        #expect(initial.outcome == "recording")
        try recorder.cancelRecording()
        let records = try store.loadRecent(limit: 10)
        #expect(records.count == 1)
        #expect(records.first?.outcome == "cancelled")
        #expect(try Data(contentsOf: initial.audioURL(baseDirectory: root)) == Data("PCM samples".utf8))
    }

}
