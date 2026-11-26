import SwiftUI

enum SettingsTypography {
    static let pageTitleSize: CGFloat = 34
    static let pageSubtitleSize: CGFloat = 17
    static let sectionTitleSize: CGFloat = 22
    static let bodySize: CGFloat = 16
    static let detailSize: CGFloat = 15
    static let captionSize: CGFloat = 13
    static let rowTitleSize: CGFloat = 18
    static let monoValueSize: CGFloat = 26
    static let statusSize: CGFloat = 13.5

    static let pageTitle = Font.system(size: pageTitleSize, weight: .bold)
    static let pageSubtitle = Font.system(size: pageSubtitleSize)
    static let sectionTitle = Font.system(size: sectionTitleSize, weight: .semibold)
    static let body = Font.system(size: bodySize)
    static let bodyEmphasis = Font.system(size: bodySize, weight: .semibold)
    static let detail = Font.system(size: detailSize)
    static let caption = Font.system(size: captionSize)
    static let nav = Font.system(size: bodySize, weight: .medium)
    static let control = Font.system(size: bodySize)
    static let rowTitle = Font.system(size: rowTitleSize, weight: .semibold)
    static let value = Font.system(size: bodySize, weight: .semibold)
    static let monoValue = Font.system(size: monoValueSize, weight: .semibold, design: .monospaced)
    static let status = Font.system(size: statusSize, weight: .semibold)
}

enum SettingsLayout {
    static let pagePadding: CGFloat = 40
    static let pageTopPadding: CGFloat = 32
    static let contentMaxWidth: CGFloat = 980
    static let cardPadding: CGFloat = 24
    static let cardSpacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 30
    static let sidebarWidth: CGFloat = 240
    static let historyListWidth: CGFloat = 360
    static let cardCornerRadius: CGFloat = 20
    static let controlSpacing: CGFloat = 14
}

extension View {
    @ViewBuilder
    func settingsControlSize() -> some View {
        if #available(macOS 14.0, *) {
            controlSize(.extraLarge)
        } else {
            controlSize(.large)
        }
    }
}

enum SettingsStatusTone {
    case ready
    case attention
    case error
    case neutral
    case info

    var color: Color {
        switch self {
        case .ready: return .green
        case .attention: return .orange
        case .error: return .red
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        case .info: return .accentColor
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .neutral: return "circle"
        case .info: return "info.circle.fill"
        }
    }
}

struct SettingsStatusPill: View {
    let text: String
    let tone: SettingsStatusTone

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tone.symbol)
            Text(text)
        }
        .font(SettingsTypography.status)
        .foregroundStyle(tone.color)
        .fixedSize()
    }
}

struct SettingsIconBadge: View {
    let symbol: String
    let tone: SettingsStatusTone
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(tone.color.opacity(0.10))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tone.color)
        }
        .frame(width: size, height: size)
    }
}
