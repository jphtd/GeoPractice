import Foundation
import SwiftUI

enum GeoTheme {
    static let background = Color(white: 0.025)
    static let backgroundEnd = Color(white: 0.012)
    static let panel = Color(white: 0.065)
    static let panelRaised = Color(white: 0.10)
    static let line = Color(white: 0.22)
    static let text = Color(white: 0.97)
    static let muted = Color(white: 0.54)
}

struct GeoBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.045), GeoTheme.backgroundEnd],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.white.opacity(0.055), .clear],
                center: UnitPoint(x: 0.5, y: 0.05),
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

struct GeoCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.1).opacity(0.96), Color(white: 0.045).opacity(0.98)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.075), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 20)
            }
    }
}

/// A restrained glass capsule that uses the current Liquid Glass rendering on
/// new systems and an iOS 17 Material fallback. The fallback is intentionally
/// translucent: the dark shapes in the V4 sketch describe glass, not black ink.
struct GeoGlassCapsule<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if reduceTransparency {
                content
                    .background(GeoTheme.panelRaised, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    }
            } else {
                translucentGlass
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }

    /// Older Swift compilers do not expose Liquid Glass symbols, so they
    /// compile only the Material implementation.
    @ViewBuilder
    private var translucentGlass: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.035))
                        .interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            materialGlass
        }
#else
        materialGlass
#endif
    }

    private var materialGlass: some View {
        content
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

struct CardTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color(white: 0.88))
            Spacer()
            Text(subtitle)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(GeoTheme.muted)
        }
    }
}

struct ControlLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(GeoTheme.muted)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(GeoTheme.text)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct GeoSegmentButton: View {
    let title: String
    var symbol: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isActive ? GeoTheme.text : GeoTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? GeoTheme.panelRaised : .clear)
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        }
                    }
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct GeoSegmentContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
        )
    }
}

struct CountBadge: View {
    let title: String
    let count: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(GeoTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(white: 0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.055), lineWidth: 1)
                }
        )
        .foregroundStyle(GeoTheme.text)
    }
}

struct PresetSummary: View {
    let preset: MetronomePreset

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "metronome")
            Text(preset.compactSummary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(GeoTheme.muted)
    }
}

func practiceDurationString(milliseconds: Int64) -> String {
    let totalSeconds = max(0, milliseconds) / 1_000
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
    }
    return String(format: "%02lld:%02lld", minutes, seconds)
}
