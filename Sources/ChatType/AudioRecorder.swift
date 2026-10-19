import AVFoundation
import AVFAudio
import CoreGraphics
import Foundation
import OSLog

struct RecordedAudio: Sendable {
    let fileURL: URL
    let durationMs: Int
}

protocol RecordingSessionControlling: AnyObject, Sendable {
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
    var currentTime: TimeInterval { get }
}

@MainActor
protocol RecordingControlling: AnyObject {
    func startRecording() async throws
    func stopRecording() throws -> RecordedAudio
    func cancelRecording() throws
    func currentLevel() -> CGFloat?
    func inputInterruptionDetected() -> Bool
}

extension RecordingControlling {
    func inputInterruptionDetected() -> Bool { false }
}

enum MicrophonePermissionState: Sendable {
    case granted
    case undetermined
    case denied
}

enum RecorderError: LocalizedError, Equatable {
    case microphoneDenied
    case recorderInitFailed
    case recorderStartFailed
    case noActiveRecording
    case recordingStorageFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "没有麦克风权限，无法开始录音。"
        case .recorderInitFailed:
            return "无法初始化录音器。"
        case .recorderStartFailed:
            return "录音启动失败。"
        case .noActiveRecording:
            return "当前没有录音中的会话。"
        case .recordingStorageFailed(let detail):
            return "无法安全保存录音，已停止采集；已有音频仍保留。\(detail)"
        }
    }
}

@MainActor
final class AudioRecorder: RecordingControlling {
    typealias PermissionProvider = @Sendable () -> MicrophonePermissionState
    typealias PermissionRequester = @Sendable () async -> Bool
    typealias SessionFactory = @Sendable (URL, [String: Any]) throws -> any RecordingSessionControlling
    typealias TemporaryFileURLFactory = @Sendable () -> URL

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.longbiaochen.chattype",
        category: "Permissions"
    )

    private let sampleRateHz: Int
    private let permissionProvider: PermissionProvider
    private let permissionRequester: PermissionRequester
    private let sessionFactory: SessionFactory
    private let temporaryFileURLFactory: TemporaryFileURLFactory?
    private let recoveryStore: RecoveryStore?
    private var persistenceTimer: Timer?
    private var persistenceFailure: String?
    private let fileManager: FileManager
    private var recorder: (any RecordingSessionControlling)?
    private var fileURL: URL?
    private var inputHealthMonitor = RecordingInputHealthMonitor()

    init(
        sampleRateHz: Int,
        permissionProvider: @escaping PermissionProvider = { microphonePermissionState() },
        permissionRequester: @escaping PermissionRequester = {
            if #available(macOS 14.0, *) {
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }

            return await AVCaptureDevice.requestAccess(for: .audio)
        },
        sessionFactory: @escaping SessionFactory = { url, settings in
            try AVAudioRecorderSession(url: url, settings: settings)
        },
        temporaryFileURLFactory: TemporaryFileURLFactory? = nil,
        recoveryStore: RecoveryStore? = nil,
        fileManager: FileManager = .default
    ) {
        self.sampleRateHz = sampleRateHz
        self.permissionProvider = permissionProvider
        self.permissionRequester = permissionRequester
        self.sessionFactory = sessionFactory
        self.temporaryFileURLFactory = temporaryFileURLFactory
        self.recoveryStore = recoveryStore ?? (temporaryFileURLFactory == nil ? RecoveryStore() : nil)
        self.fileManager = fileManager
    }

    nonisolated static func microphonePermissionState() -> MicrophonePermissionState {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .granted
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            @unknown default:
                return .denied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .undetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    nonisolated static func repairActions(for state: MicrophonePermissionState) -> [PermissionRepairAction] {
        guard state == .denied else {
            return []
        }

        return [
            PermissionRepairAction(
                title: "Open Microphone Settings",
                kind: .openSettings(.microphone),
                prominence: .secondary
            ),
        ]
    }

    nonisolated static func ensureMicrophoneAccess(
        permissionProvider: PermissionProvider = { microphonePermissionState() },
        requestPermission: @escaping PermissionRequester = {
            if #available(macOS 14.0, *) {
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }

            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) async throws {
        let status = permissionProvider()
        logger.info("Microphone access check started with status: \(String(describing: status), privacy: .public)")

        switch status {
        case .granted:
            logger.info("Microphone access already authorized")
            return
        case .undetermined:
            logger.info("Microphone access not determined; requesting system prompt")
            let granted = await requestPermission()
            logger.info("Microphone access request returned granted=\(granted, privacy: .public)")
            guard granted else {
                throw RecorderError.microphoneDenied
            }
        case .denied:
            logger.error("Microphone access unavailable with status: \(String(describing: status), privacy: .public)")
            throw RecorderError.microphoneDenied
        @unknown default:
            logger.error("Microphone access hit unknown authorization status")
            throw RecorderError.microphoneDenied
        }
    }

    func startRecording() async throws {
        try await Self.ensureMicrophoneAccess(
            permissionProvider: permissionProvider,
            requestPermission: permissionRequester
        )

        try Task.checkCancellation()
        let tempURL: URL
        do {
            if let recoveryStore {
                tempURL = try recoveryStore.beginRecording()
            } else if let temporaryFileURLFactory {
                tempURL = temporaryFileURLFactory()
                // Injectable test boundary; production always reserves a journaled file.
                if !fileManager.fileExists(atPath: tempURL.path) {
                    guard fileManager.createFile(atPath: tempURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
                try RecoveryStore.synchronize(tempURL)
            } else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            throw RecorderError.recordingStorageFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRateHz,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder = try sessionFactory(tempURL, settings)
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.recorderStartFailed
        }

        inputHealthMonitor = RecordingInputHealthMonitor()
        self.recorder = recorder
        self.fileURL = tempURL
        self.persistenceFailure = nil
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            try RecoveryStore.synchronize(tempURL)
        } catch {
            recorder.stop()
            self.recorder = nil
            self.fileURL = nil
            throw RecorderError.recordingStorageFailed(error.localizedDescription)
        }
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeActiveRecording() }
        }
    }

    func stopRecording() throws -> RecordedAudio {
        guard let recorder, let fileURL else {
            throw RecorderError.noActiveRecording
        }

        let durationMs = Int((recorder.currentTime * 1000).rounded())
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil

        let audio = RecordedAudio(fileURL: fileURL, durationMs: durationMs)
        do {
            try recoveryStore?.finishRecording(audio, outcome: "recorded")
            try RecoveryStore.synchronize(fileURL)
        } catch {
            throw RecorderError.recordingStorageFailed(error.localizedDescription)
        }
        if let persistenceFailure { throw RecorderError.recordingStorageFailed(persistenceFailure) }
        return audio
    }

    func cancelRecording() throws {
        let audio = try stopRecording()
        // Cancellation ends work, never ownership of the user's raw material.
        try recoveryStore?.finishRecording(audio, outcome: "cancelled")
    }

    private func synchronizeActiveRecording() {
        guard let fileURL, let recorder, persistenceFailure == nil else { return }
        do {
            try RecoveryStore.synchronize(fileURL)
        } catch {
            persistenceFailure = error.localizedDescription
            // Stop collection immediately rather than continuing without disk protection.
            recorder.stop()
            persistenceTimer?.invalidate()
            persistenceTimer = nil
        }
    }

    func currentLevel() -> CGFloat? {
        guard let recorder else {
            return nil
        }

        recorder.updateMeters()
        let powerDBFS = recorder.averagePower(forChannel: 0)
        inputHealthMonitor.observe(
            powerDBFS: powerDBFS,
            elapsedSeconds: recorder.currentTime
        )
        return WaveformNormalizer.normalizedLevel(
            fromAveragePower: powerDBFS
        )
    }

    func inputInterruptionDetected() -> Bool {
        inputHealthMonitor.interruptionDetected || persistenceFailure != nil
    }
}

private final class AVAudioRecorderSession: RecordingSessionControlling, @unchecked Sendable {
    private let recorder: AVAudioRecorder

    init(url: URL, settings: [String: Any]) throws {
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        self.recorder = recorder
    }

    func prepareToRecord() -> Bool {
        recorder.prepareToRecord()
    }

    func record() -> Bool {
        recorder.record()
    }

    func stop() {
        recorder.stop()
    }

    func updateMeters() {
        recorder.updateMeters()
    }

    func averagePower(forChannel channelNumber: Int) -> Float {
        recorder.averagePower(forChannel: channelNumber)
    }

    var currentTime: TimeInterval {
        recorder.currentTime
    }
}
