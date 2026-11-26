import SwiftUI

enum SettingsTypography {
    static let pageTitle = Font.title.weight(.semibold)
    static let pageSubtitle = Font.body
    static let sectionTitle = Font.title3.weight(.semibold)
    static let body = Font.body
    static let bodyEmphasis = Font.body.weight(.medium)
    static let detail = Font.callout
    static let caption = Font.caption
    static let nav = Font.body.weight(.medium)
    static let control = Font.body
    static let rowTitle = Font.headline
    static let value = Font.body.weight(.medium)
    static let monoValue = Font.title2.monospaced().weight(.semibold)
}

enum SettingsLayout {
    static let pagePadding: CGFloat = 28
    static let cardPadding: CGFloat = 18
    static let cardSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let sidebarWidth: CGFloat = 212
    static let historyListWidth: CGFloat = 320
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
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .fixedSize()
    }
}

struct SettingsIconBadge: View {
    let symbol: String
    let tone: SettingsStatusTone
    var size: CGFloat = 32

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
