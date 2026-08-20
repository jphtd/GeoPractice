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

/// A compact SMuFL note value. Bravura Text's augmentation dot is intentionally
/// tiny at selector sizes, so it is kept as a real SMuFL glyph but rendered at
/// a larger size and with explicit spacing from the note.
struct SMuFLNoteGlyph: View {
    let note: TempoReferenceNote
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: note.isDotted ? 1.5 : 0) {
            Text(note.undottedNote.symbol)
                .font(.custom("BravuraText", fixedSize: size))

            if note.isDotted {
                Text(TempoReferenceNote.augmentationDotSymbol)
                    .font(.custom("BravuraText", fixedSize: size * 1.29))
            }
        }
        .fixedSize()
    }
}

/// A number-first tempo control. The selected primary axis maps to exact BPM
/// steps; the model is committed only when the gesture ends, so a playing
/// metronome is rescheduled once instead of on every drag sample.
struct TempoScrubber: View {
    let bpm: Int
    var compact = false
    var direction: TempoScrubDirection = .horizontal
    var onTap: (() -> Void)?
    var onScrubbingChanged: (Bool) -> Void = { _ in }
    let onCommit: (Int) -> Void

    @State private var draftBPM: Int?
    @State private var dragStartBPM: Int?
    @State private var isScrubbing = false
    @State private var didDrag = false
    @State private var isWaitingForSecondTap = false
    @State private var pendingSingleTapTask: Task<Void, Never>?
    @State private var isShowingDirectEntry = false
    @State private var directEntryText = ""

    private var displayedBPM: Int {
        draftBPM ?? bpm
    }

    private var displayedTempoName: String {
        var preset = MetronomePreset.standard
        preset.bpm = displayedBPM
        return preset.tempoName
    }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    Text("BPM · \(displayedTempoName)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    scrubTarget(compact: true)
                }
            } else {
                VStack(spacing: 8) {
                    Text(displayedTempoName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(GeoTheme.muted)
                    scrubTarget(compact: false)
                    Text("\(direction.detail) · 双击直接输入")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 128)
                .background(
                    Color(white: 0.04),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(draftBPM == nil ? 0.08 : 0.26), lineWidth: 1)
                }
            }
        }
        .onDisappear {
            cancelPendingTap()
            cancelDraft()
            isShowingDirectEntry = false
        }
        .alert("输入 BPM", isPresented: $isShowingDirectEntry) {
            TextField("当前 \(bpm)", text: $directEntryText)
                .keyboardType(.numberPad)
            Button("取消", role: .cancel) {}
            Button("确定") {
                commitDirectEntry()
            }
            .disabled(validatedDirectEntry == nil)
        } message: {
            Text("请输入 30 至 240 之间的整数。确认后速度只更新一次。")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("速度")
        .accessibilityValue("\(displayedTempoName)，\(displayedBPM) BPM")
        .accessibilityHint("\(direction.accessibilityHint)；VoiceOver 上下轻扫每次调整 1 BPM")
        .accessibilityAction(named: "直接输入 BPM") {
            beginDirectEntry()
        }
        .accessibilityAdjustableAction { direction in
            let delta: Int
            switch direction {
            case .increment: delta = 1
            case .decrement: delta = -1
            @unknown default: return
            }
            let next = clamped(bpm + delta)
            if next != bpm { onCommit(next) }
        }
    }

    private func scrubTarget(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 8) {
            tempoStepButton(delta: -1, compact: compact)

            Text("\(displayedBPM)")
                .font(.system(
                    size: compact ? 23 : 58,
                    weight: .bold,
                    design: .rounded
                ))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: compact ? 48 : 96, minHeight: compact ? 44 : 76)
                .contentShape(Rectangle())
                .highPriorityGesture(scrubGesture)

            tempoStepButton(delta: 1, compact: compact)
        }
        .foregroundStyle(GeoTheme.text)
        .frame(minWidth: compact ? 116 : 220, minHeight: compact ? 42 : 76)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if draftBPM != nil {
                Capsule()
                    .fill(Color.white.opacity(0.62))
                    .frame(width: compact ? 26 : 48, height: 1.5)
            }
        }
    }

    private func tempoStepButton(delta: Int, compact: Bool) -> some View {
        let isAvailable = delta < 0
            ? displayedBPM > TempoScrubModel.minimumBPM
            : displayedBPM < TempoScrubModel.maximumBPM

        return Button {
            nudge(by: delta)
        } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: compact ? 10 : 15, weight: .bold))
                .frame(width: compact ? 28 : 44)
                .frame(minHeight: compact ? 44 : 76)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 0.72 : 0.16)
        .disabled(!isAvailable)
        .accessibilityLabel(delta < 0 ? "速度减一" : "速度加一")
    }

    private var scrubGesture: some Gesture {
        // A zero-distance high-priority gesture reserves only the number area
        // from touch-down. The editor can therefore disable its Form before
        // the parent scroll view consumes the first few points of a BPM drag;
        // beginning a scroll anywhere outside the number remains unchanged.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                setScrubbing(true)
                let travelled = hypot(
                    value.translation.width,
                    value.translation.height
                )
                guard travelled >= 4 else { return }

                didDrag = true
                if dragStartBPM == nil {
                    dragStartBPM = bpm
                    draftBPM = bpm
                }
                guard let dragStartBPM else { return }
                let primaryTranslation = direction.primaryTranslation(
                    horizontal: value.translation.width,
                    vertical: value.translation.height
                )
                draftBPM = TempoScrubModel.bpm(
                    start: dragStartBPM,
                    primaryTranslation: Double(primaryTranslation)
                )
            }
            .onEnded { _ in
                let completedDrag = didDrag
                let committed = draftBPM
                cancelDraft()
                if completedDrag, let committed, committed != bpm {
                    onCommit(committed)
                } else if !completedDrag {
                    registerTap()
                }
            }
    }

    private func registerTap() {
        if isWaitingForSecondTap {
            cancelPendingTap()
            beginDirectEntry()
            return
        }

        isWaitingForSecondTap = true
        pendingSingleTapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            isWaitingForSecondTap = false
            pendingSingleTapTask = nil
            onTap?()
        }
    }

    private func cancelPendingTap() {
        pendingSingleTapTask?.cancel()
        pendingSingleTapTask = nil
        isWaitingForSecondTap = false
    }

    private var validatedDirectEntry: Int? {
        TempoScrubModel.validatedBPMInput(directEntryText)
    }

    private func beginDirectEntry() {
        cancelPendingTap()
        cancelDraft()
        directEntryText = ""
        isShowingDirectEntry = true
    }

    private func commitDirectEntry() {
        guard let enteredBPM = validatedDirectEntry else { return }
        if enteredBPM != bpm {
            onCommit(enteredBPM)
        }
    }

    private func nudge(by delta: Int) {
        cancelDraft()
        let next = clamped(bpm + delta)
        if next != bpm {
            onCommit(next)
        }
    }

    private func clamped(_ value: Int) -> Int {
        min(TempoScrubModel.maximumBPM, max(TempoScrubModel.minimumBPM, value))
    }

    private func cancelDraft() {
        draftBPM = nil
        dragStartBPM = nil
        didDrag = false
        setScrubbing(false)
    }

    private func setScrubbing(_ active: Bool) {
        guard active != isScrubbing else { return }
        isScrubbing = active
        onScrubbingChanged(active)
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
