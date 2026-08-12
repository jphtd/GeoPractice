import Foundation
import SwiftUI

enum GeoTheme {
    static let background = Color(red: 8 / 255, green: 10 / 255, blue: 15 / 255)
    static let backgroundEnd = Color(red: 5 / 255, green: 5 / 255, blue: 5 / 255)
    static let panel = Color(red: 17 / 255, green: 20 / 255, blue: 28 / 255)
    static let panelRaised = Color(red: 23 / 255, green: 27 / 255, blue: 37 / 255)
    static let line = Color(red: 43 / 255, green: 49 / 255, blue: 64 / 255)
    static let text = Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
    static let muted = Color(red: 133 / 255, green: 133 / 255, blue: 133 / 255)
}

struct GeoBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255), GeoTheme.backgroundEnd],
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

struct GeoBrand: View {
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(45))
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .white.opacity(0.8), radius: 7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("节拍打卡")
                    .font(.system(size: compact ? 15 : 17, weight: .bold, design: .rounded))
                    .tracking(0.3)
                if !compact {
                    Text("PULSE LOG")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(GeoTheme.muted)
                }
            }
        }
        .foregroundStyle(GeoTheme.text)
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

struct CardTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color(red: 220 / 255, green: 225 / 255, blue: 235 / 255))
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
                .fill(Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255))
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
                .fill(Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255))
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
