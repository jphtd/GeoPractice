import SwiftUI

/// A single restrained glass surface for a group of related controls.
/// On iOS 26 its container also lets descendant glass effects blend as one
/// system; iOS 17–25 use one continuous Material panel instead.
struct LiquidControlPanel<Content: View>: View {
    private let contentPadding: CGFloat
    private let spacing: CGFloat
    private let cornerRadius: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glassNamespace

    init(
        contentPadding: CGFloat = 8,
        spacing: CGFloat = 8,
        cornerRadius: CGFloat = 26,
        @ViewBuilder content: () -> Content
    ) {
        self.contentPadding = contentPadding
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        Group {
            if reduceTransparency {
                opaquePanel
            } else {
#if compiler(>=6.2)
                if #available(iOS 26.0, *) {
                    liquidGlassPanel
                } else {
                    materialPanel
                }
#else
                materialPanel
#endif
            }
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 9)
    }

    private var opaquePanel: some View {
        content
            .padding(contentPadding)
            .background(Color(white: 0.075), in: panelShape)
            .overlay {
                panelShape
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var materialPanel: some View {
        content
            .padding(contentPadding)
            .background(.ultraThinMaterial, in: panelShape)
            .background {
                panelShape
                    .fill(Color.black.opacity(0.12))
                    .allowsHitTesting(false)
            }
            .overlay {
                panelShape
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.white.opacity(0.012)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                panelShape
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var liquidGlassPanel: some View {
        GlassEffectContainer(spacing: spacing) {
            content
                .padding(contentPadding)
                .background {
                    panelShape
                        .fill(Color.white.opacity(0.012))
                        .glassEffect(
                            .regular.tint(Color.white.opacity(0.018)),
                            in: panelShape
                        )
                        .glassEffectID("liquid-control-panel", in: glassNamespace)
                }
        }
    }
#endif

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// A horizontally scrubbable selector for a small set of discrete values.
///
/// During a drag the glass cursor follows the finger continuously while the
/// nearest option is previewed locally. `onCommit` is called at most once when
/// the gesture ends, keeping model updates out of the drag sampling loop.
struct LiquidScrubSelector<Option: Hashable, Label: View>: View {
    let options: [Option]
    let selection: Option

    private let accessibilityLabelText: String
    private let accessibilityHintText: String
    private let accessibilityValueText: (Option) -> String
    private let controlHeight: CGFloat
    private let explicitlyEnabled: Bool
    private let onCommit: (Option) -> Void
    private let label: (Option) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var environmentEnabled

    @Namespace private var glassNamespace
    @State private var dragAxis: DragAxis?
    @State private var dragLocationX: CGFloat?
    @State private var previewIndex: Int?
    @State private var suppressTap = false
    @State private var suppressTapResetID: UUID?

    private enum DragAxis {
        case horizontal
        case vertical
    }

    init(
        options: [Option],
        selection: Option,
        accessibilityLabel: String,
        accessibilityHint: String = "左右滑动选择；VoiceOver 上下轻扫调整",
        accessibilityValue: @escaping (Option) -> String = { String(describing: $0) },
        controlHeight: CGFloat = 46,
        isEnabled: Bool = true,
        onCommit: @escaping (Option) -> Void,
        @ViewBuilder label: @escaping (Option) -> Label
    ) {
        self.options = options
        self.selection = selection
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityHintText = accessibilityHint
        self.accessibilityValueText = accessibilityValue
        self.controlHeight = max(44, controlHeight)
        self.explicitlyEnabled = isEnabled
        self.onCommit = onCommit
        self.label = label
    }

    var body: some View {
        GeometryReader { proxy in
            selectorSurface(size: proxy.size)
                .contentShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .simultaneousGesture(scrubGesture(size: proxy.size))
                .simultaneousGesture(tapGesture(size: proxy.size))
        }
        .frame(height: controlHeight)
        .opacity(isInteractive ? 1 : 0.48)
        .allowsHitTesting(isInteractive)
        .onDisappear(perform: cancelInteraction)
        .onChange(of: options) { _, _ in
            cancelInteraction()
        }
        .onChange(of: selection) { _, _ in
            cancelInteraction()
        }
        .onChange(of: isInteractive) { _, isInteractive in
            if !isInteractive { cancelInteraction() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueDescription)
        .accessibilityHint(accessibilityHintText)
        .accessibilityRespondsToUserInteraction(isInteractive)
        .accessibilityAdjustableAction(adjustAccessibilitySelection)
    }

    private var isInteractive: Bool {
        explicitlyEnabled && environmentEnabled && !options.isEmpty
    }

    private var cornerRadius: CGFloat {
        controlHeight / 2
    }

    private var committedIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    private var displayedIndex: Int {
        guard !options.isEmpty else { return 0 }
        return min(options.count - 1, max(0, previewIndex ?? committedIndex))
    }

    private var accessibilityValueDescription: String {
        guard options.indices.contains(displayedIndex) else { return "" }
        return accessibilityValueText(options[displayedIndex])
    }

    @ViewBuilder
    private func selectorSurface(size: CGSize) -> some View {
        if reduceTransparency {
            opaqueSurface(size: size)
        } else {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                liquidGlassSurface(size: size)
            } else {
                materialSurface(size: size)
            }
#else
            materialSurface(size: size)
#endif
        }
    }

    private func opaqueSurface(size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
            opaqueCursor(size: size)
            labelsLayer
        }
    }

    private func opaqueCursor(size: CGSize) -> some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.16))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .frame(width: cursorWidth(for: size), height: cursorHeight(for: size))
            .offset(x: cursorOffset(for: size))
            .animation(cursorAnimation, value: committedIndex)
    }

    private func materialSurface(size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.23), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                .frame(width: cursorWidth(for: size), height: cursorHeight(for: size))
                .offset(x: cursorOffset(for: size))
                .animation(cursorAnimation, value: committedIndex)

            labelsLayer
        }
    }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func liquidGlassSurface(size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                }

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.095))
                        .interactive(),
                    in: Capsule(style: .continuous)
                )
                .glassEffectID("liquid-scrub-cursor", in: glassNamespace)
                .frame(width: cursorWidth(for: size), height: cursorHeight(for: size))
                .offset(x: cursorOffset(for: size))
                .animation(cursorAnimation, value: committedIndex)

            labelsLayer
        }
    }
#endif

    private var labelsLayer: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                label(option)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fontWeight(index == displayedIndex ? .semibold : .medium)
                    .foregroundStyle(
                        Color.white.opacity(index == displayedIndex ? 0.96 : 0.50)
                    )
                    .scaleEffect(index == displayedIndex ? 1.035 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .animation(labelAnimation, value: displayedIndex)
            }
        }
        .padding(trackInset)
        .allowsHitTesting(false)
    }

    private var trackInset: CGFloat {
        4
    }

    private func segmentWidth(for size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        return max(0, size.width - (trackInset * 2)) / CGFloat(options.count)
    }

    private func cursorWidth(for size: CGSize) -> CGFloat {
        max(0, segmentWidth(for: size) - 4)
    }

    private func cursorHeight(for size: CGSize) -> CGFloat {
        max(0, size.height - (trackInset * 2))
    }

    private func cursorOffset(for size: CGSize) -> CGFloat {
        let width = cursorWidth(for: size)
        let center = dragLocationX ?? centerX(for: displayedIndex, size: size)
        return center - (width / 2)
    }

    private func centerX(for index: Int, size: CGSize) -> CGFloat {
        trackInset + (segmentWidth(for: size) * (CGFloat(index) + 0.5))
    }

    private func clampedCenterX(_ x: CGFloat, size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return size.width / 2 }
        let halfSegment = segmentWidth(for: size) / 2
        return min(size.width - trackInset - halfSegment, max(trackInset + halfSegment, x))
    }

    private func optionIndex(at x: CGFloat, size: CGSize) -> Int? {
        guard !options.isEmpty else { return nil }
        let width = segmentWidth(for: size)
        guard width > 0 else { return nil }
        let relativeX = min(
            size.width - trackInset,
            max(trackInset, x)
        ) - trackInset
        return min(options.count - 1, max(0, Int(relativeX / width)))
    }

    private func scrubGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 7, coordinateSpace: .local)
            .onChanged { value in
                guard isInteractive else {
                    cancelInteraction()
                    return
                }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)

                if dragAxis == nil {
                    if horizontalDistance > verticalDistance * 1.15 {
                        dragAxis = .horizontal
                    } else if verticalDistance > horizontalDistance * 1.15 {
                        dragAxis = .vertical
                    } else {
                        return
                    }
                }

                guard dragAxis == .horizontal else { return }
                suppressTap = true
                dragLocationX = clampedCenterX(value.location.x, size: size)
                previewIndex = optionIndex(at: value.location.x, size: size)
            }
            .onEnded { _ in
                guard isInteractive, dragAxis == .horizontal else {
                    cancelInteraction()
                    return
                }

                let option = previewIndex.flatMap { index in
                    options.indices.contains(index) ? options[index] : nil
                }
                if let option, option != selection {
                    onCommit(option)
                }
                finishHorizontalInteraction()
            }
    }

    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard isInteractive,
                      !suppressTap,
                      let index = optionIndex(at: value.location.x, size: size),
                      options.indices.contains(index) else { return }
                let option = options[index]
                if option != selection {
                    onCommit(option)
                }
            }
    }

    private func finishHorizontalInteraction() {
        dragAxis = nil
        dragLocationX = nil
        previewIndex = nil
        let interactionID = UUID()
        suppressTapResetID = interactionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard suppressTapResetID == interactionID else { return }
            suppressTap = false
            suppressTapResetID = nil
        }
    }

    private func cancelInteraction() {
        dragAxis = nil
        dragLocationX = nil
        previewIndex = nil
        suppressTap = false
        suppressTapResetID = nil
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        guard isInteractive, !options.isEmpty else { return }

        let delta: Int
        switch direction {
        case .increment:
            delta = 1
        case .decrement:
            delta = -1
        @unknown default:
            return
        }

        let nextIndex = min(options.count - 1, max(0, committedIndex + delta))
        let option = options[nextIndex]
        if option != selection {
            onCommit(option)
        }
    }

    private var cursorAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.20, extraBounce: 0.02)
    }

    private var labelAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

/// Restrained press feedback for the one non-scrubbable action in the panel.
/// It deliberately avoids a bright flash or a colored highlight.
struct LiquidPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}
