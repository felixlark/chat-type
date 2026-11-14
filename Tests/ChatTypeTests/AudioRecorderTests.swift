import AVFoundation
import Testing
@testable import ChatType

private final class FakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    var prepareToRecordResult = true
    var recordResult = true
    private(set) var stopCallCount = 0
    var currentTime: TimeInterval = 1.25
    var averagePowerValue: Float = -30

    func prepareToRecord() -> Bool {
        prepareToRecordResult
    }

    func record() -> Bool {
        recordResult
    }

    func stop() {
        stopCallCount += 1
        currentTime = 0
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

struct AudioRecorderTests {
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
