import SwiftUI
import UIKit

enum CorePalette {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
    static let canvas = color(0xF7F8FA, 0x0F1115)
    static let surface = color(0xFFFFFF, 0x15181D)
    static let subtle = color(0xF1F3F5, 0x1C2026)
    static let primary = color(0x111318, 0xF4F6F8)
    static let secondary = color(0x5F6672, 0xB4BBC6)
    static let border = color(0xD9DEE5, 0x2A3038)
    static let accent = color(0x4F46E5, 0x9B92FF)
    // Neutral recovery context is permitted; Foundation has no dark info pair.
    static let onAccent = color(0xFFFFFF, 0x111318)
}

enum CoreType {
    case titleLarge, titleMedium, titleSmall, body, label, tab, caption
    var metrics: (CGFloat, CGFloat, UIFont.Weight, UIFont.TextStyle) {
        switch self {
        case .titleLarge: (28, 34, .semibold, .title1)
        case .titleMedium: (22, 28, .semibold, .title2)
        case .titleSmall: (18, 24, .semibold, .headline)
        case .body: (15, 22, .regular, .body)
        case .label: (15, 20, .medium, .body)
        case .tab: (13, 18, .medium, .footnote)
        case .caption: (12, 16, .regular, .caption1)
        }
    }
}

private struct CoreTypography: ViewModifier {
    let token: CoreType
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func body(content: Content) -> some View {
        let m = token.metrics
        let traits = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiCategory)
        let font = UIFontMetrics(forTextStyle: m.3).scaledFont(for: .systemFont(ofSize: m.0, weight: m.2), compatibleWith: traits)
        let line = UIFontMetrics(forTextStyle: m.3).scaledValue(for: m.1, compatibleWith: traits)
        content.font(Font(font)).lineSpacing(max(0, line - font.lineHeight))
            .padding(.vertical, max(0, (line - font.lineHeight) / 2))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension DynamicTypeSize {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

extension View {
    func coreType(_ token: CoreType) -> some View { modifier(CoreTypography(token: token)) }
    func coreCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(CorePalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CorePalette.border, lineWidth: 1 / UIScreen.main.scale))
    }
}

struct CorePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct CoreButton: View {
    enum Kind { case primary, secondary, tertiary }
    let title: String
    var kind: Kind = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).coreType(.label).multilineTextAlignment(.center)
                .foregroundStyle(kind == .primary ? CorePalette.onAccent : kind == .tertiary ? CorePalette.accent : CorePalette.primary)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: kind == .tertiary ? nil : .infinity, minHeight: kind == .tertiary ? 44 : 52)
                .background(kind == .primary ? CorePalette.accent : kind == .secondary ? CorePalette.surface : .clear,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(CorePalette.border, lineWidth: 1 / UIScreen.main.scale)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(CorePressStyle())
    }
}

struct CoreIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(CorePressStyle()).accessibilityLabel(label)
    }
}

struct CorePageHeader: View {
    let title: String
    var back: (() -> Void)? = nil
    var trailing: String? = nil
    var trailingLabel = ""
    var action: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            if let back { CoreIconButton(symbol: "chevron.left", label: "返回", action: back) }
            Text(title).coreType(back == nil ? .titleLarge : .titleSmall)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing { CoreIconButton(symbol: trailing, label: trailingLabel, action: action) }
        }.frame(minHeight: 44).foregroundStyle(CorePalette.primary)
    }
}

struct CoreActionCard: View {
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).coreType(.titleSmall)
                    if let subtitle { Text(subtitle).coreType(.body).foregroundStyle(CorePalette.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 20)).accessibilityHidden(true)
            }.foregroundStyle(CorePalette.primary).coreCard().contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(CorePressStyle())
    }
}

struct CoreNavigationRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("查看分析").coreType(.label)
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(CorePressStyle())
    }
}

struct CoreEmptyState: View {
    let title: String
    let copy: String
    let button: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list").font(.system(size: 32)).foregroundStyle(CorePalette.secondary).accessibilityHidden(true)
            Text(title).coreType(.titleMedium)
            Text(copy).coreType(.body).foregroundStyle(CorePalette.secondary)
            CoreButton(title: button, action: action)
        }.multilineTextAlignment(.center).frame(maxWidth: 400).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
    }
}

struct CoreBottomNavigation: View {
    var activeSessionID: UUID? = nil
    var selectedTab = "Practice"
    var onPractice: () -> Void = {}
    let onRoute: (CoreRoute) -> Void
    var body: some View {
        HStack(spacing: 0) {
            item("Practice", symbol: "music.note.list", active: selectedTab == "Practice", action: onPractice)
            item("GeoBeat", symbol: "metronome", active: selectedTab == "GeoBeat") { onRoute(.geoBeat(activeSession: activeSessionID)) }
            item("Analyze", symbol: "chart.bar", active: selectedTab == "Analyze") { onRoute(.analyze(.overall)) }
        }.padding(.top, 4).frame(minHeight: 56)
            .background(CorePalette.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(CorePalette.border).frame(height: 1 / UIScreen.main.scale) }
    }
    private func item(_ label: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 24))
                Text(label).coreType(.tab)
                    // Persistent navigation follows the native tab-bar pattern:
                    // bounded label growth, with full-size Large Content Viewer.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(CorePressStyle())
            .foregroundStyle(active ? CorePalette.accent : CorePalette.secondary)
            .accessibilityAddTraits(active ? [.isSelected] : [])
            .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}
