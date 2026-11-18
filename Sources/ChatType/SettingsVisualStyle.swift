import SwiftUI

enum SettingsTypography {
    static let pageTitle = Font.system(size: 28, weight: .semibold)
    static let pageSubtitle = Font.system(size: 14)
    static let sectionTitle = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let detail = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let nav = Font.system(size: 14, weight: .medium)
    static let control = Font.system(size: 13)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    static let value = Font.system(size: 13, weight: .semibold)
    static let monoValue = Font.system(size: 20, weight: .semibold, design: .monospaced)
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
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.10))
        .clipShape(Capsule())
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
