import CoreGraphics
import Foundation

/// Pin placement through recording, processing and feedback; reset for a new recording.
struct OverlayPlacementSession {
    private var visibleFrame: CGRect?

    mutating func resolve(_ currentFrame: () -> CGRect) -> CGRect {
        if let visibleFrame { return visibleFrame }
        let frame = currentFrame()
        visibleFrame = frame
        return frame
    }

    mutating func reset() {
        visibleFrame = nil
    }

    static func appKitFrame(fromAccessibility frame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screenIndex(for windowFrame: CGRect, screens: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let intersection = screen.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }
}

struct OverlayStylePreset: Sendable, Equatable {
    let pillWidth: CGFloat
    let recordingPillWidth: CGFloat
    let pillHeight: CGFloat
    let errorPillWidth: CGFloat
    let topInset: CGFloat
    let cornerRadius: CGFloat
    let contentPaddingH: CGFloat
    let contentPaddingV: CGFloat
    let leadingVisualWidth: CGFloat
    let leadingVisualHeight: CGFloat
    let textGap: CGFloat
    let waveformBarCount: Int
    let waveformBarSpacing: CGFloat
    let waveformMinimumBarHeight: CGFloat
    let showsTranscriptPreview: Bool
    let recordingAutoHideDelay: TimeInterval?
    let processingAutoHideDelay: TimeInterval?
    let successAutoHideDelay: TimeInterval?
    let errorAutoHideDelay: TimeInterval?
    let inlineCancelControlSize: CGFloat
    let inlineControlGap: CGFloat
    let inlineControlReservedWidth: CGFloat
    let timerWidth: CGFloat
    let timerFontSize: CGFloat
    let timerOpacity: CGFloat

    static let typeWhisperIndicator = OverlayStylePreset(
        pillWidth: 196,
        recordingPillWidth: 224,
        pillHeight: 44,
        errorPillWidth: 286,
        topInset: 24,
        cornerRadius: 15,
        contentPaddingH: 10,
        contentPaddingV: 8,
        leadingVisualWidth: 54,
        leadingVisualHeight: 20,
        textGap: 7,
        waveformBarCount: 9,
        waveformBarSpacing: 3,
        waveformMinimumBarHeight: 6,
        showsTranscriptPreview: true,
        recordingAutoHideDelay: nil,
        processingAutoHideDelay: nil,
        successAutoHideDelay: 1.2,
        errorAutoHideDelay: 2.0,
        inlineCancelControlSize: 14,
        inlineControlGap: 5,
        inlineControlReservedWidth: 20,
        timerWidth: 34,
        timerFontSize: 10,
        timerOpacity: 0.72
    )

    func width(for state: OverlayVisualState) -> CGFloat {
        switch state {
        case .recording:
            return recordingPillWidth
        case .error, .retryableError:
            return errorPillWidth
        default:
            return pillWidth
        }
    }
}

enum OverlayLeadingVisual: Sendable, Equatable {
    case waveform
    case icon(symbolName: String)
}

enum OverlaySuccessKind: Sendable, Equatable {
    case pasted
    case copied

    var label: String {
        switch self {
        case .pasted:
            return "Pasted"
        case .copied:
            return "Copied"
        }
    }
}

enum OverlayVisualState: Sendable, Equatable {
    case recording(levels: [CGFloat], elapsedText: String)
    case processing
    case success(OverlaySuccessKind)
    case error(String)
    case retryableError(String)

    var label: String {
        switch self {
        case .recording:
            return "Listening"
        case .processing:
            return "Processing"
        case .success(let kind):
            return kind.label
        case .error, .retryableError:
            return "Error"
        }
    }

    var leadingVisual: OverlayLeadingVisual {
        switch self {
        case .recording:
            return .waveform
        case .processing:
            return .waveform
        case .success(let kind):
            return .icon(symbolName: kind == .pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
        case .error, .retryableError:
            return .icon(symbolName: "exclamationmark.triangle.fill")
        }
    }

    var allowsSupplementaryText: Bool {
        switch self {
        case .error, .retryableError:
            return true
        case .recording, .processing, .success:
            return false
        }
    }

    var showsCancelControl: Bool {
        switch self {
        case .recording, .processing, .error, .retryableError:
            return true
        case .success:
            return false
        }
    }

    var showsRetryControl: Bool {
        if case .retryableError = self {
            return true
        }
        return false
    }

    var trailingText: String? {
        switch self {
        case .recording(_, let elapsedText):
            return elapsedText
        case .processing, .success, .error, .retryableError:
            return nil
        }
    }

    var supplementaryText: String? {
        let message: String
        switch self {
        case .error(let value), .retryableError(let value):
            message = value
        case .recording, .processing, .success:
            return nil
        }
        return Self.collapseErrorMessage(message)
    }

    private static func collapseErrorMessage(_ message: String) -> String {
        let collapsed = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let characterLimit = 70
        guard collapsed.count > characterLimit else {
            return collapsed
        }

        let limitIndex = collapsed.index(collapsed.startIndex, offsetBy: characterLimit)
        let prefix = String(collapsed[..<limitIndex])
        let trimmed = prefix[..<(prefix.lastIndex(of: " ") ?? prefix.endIndex)]
        return String(trimmed) + "…"
    }
}

enum WaveformNormalizer {
    static let minimumVisibleLevel: CGFloat = 0.08
    static let maximumVisibleLevel: CGFloat = 1
    private static let silenceFloor: Float = -160
    private static let smoothingFactor: CGFloat = 0.34

    static func normalizedLevel(fromAveragePower averagePower: Float) -> CGFloat {
        if averagePower >= 0 {
            return maximumVisibleLevel
        }
        let clamped = max(silenceFloor, min(0, averagePower))
        let normalized = 1 - CGFloat(abs(clamped) / abs(silenceFloor))
        return min(maximumVisibleLevel, max(minimumVisibleLevel, normalized))
    }

    static func smoothedLevels(
        previous: [CGFloat],
        targetLevel: CGFloat,
        barCount: Int
    ) -> [CGFloat] {
        let seed = Array(previous.prefix(barCount))
        let padded = seed + Array(repeating: minimumVisibleLevel, count: max(0, barCount - seed.count))
        let target = min(maximumVisibleLevel, max(minimumVisibleLevel, targetLevel))

        let center = CGFloat(max(0, barCount - 1)) / 2
        let radius = max(center, 1)

        return padded.enumerated().map { index, prior in
            let distanceFromCenter = abs(CGFloat(index) - center) / radius
            let contour = pow(max(0, 1 - distanceFromCenter), 1.35)
            let weightedTarget = minimumVisibleLevel + ((target - minimumVisibleLevel) * (0.42 + (contour * 0.58)))
            let next = prior + ((weightedTarget - prior) * smoothingFactor)
            return min(maximumVisibleLevel, max(minimumVisibleLevel, next))
        }
    }

    static func processingPulseLevels(frame: Int, barCount: Int) -> [CGFloat] {
        let center = CGFloat(max(0, barCount - 1)) / 2
        let radius = max(center, 1)
        let phase = CGFloat(frame % max(1, barCount + 4)) - 2

        return (0..<barCount).map { index in
            let distanceFromCenter = abs(CGFloat(index) - center) / radius
            let contour = pow(max(0, 1 - distanceFromCenter), 1.25)
            let envelope = minimumVisibleLevel + (contour * 0.22)
            let pulseDistance = abs(CGFloat(index) - phase)
            let ridge = max(0, 1 - (pulseDistance / 2.2))
            let level = envelope + (ridge * 0.58)
            return min(maximumVisibleLevel, max(minimumVisibleLevel, level))
        }
    }
}
