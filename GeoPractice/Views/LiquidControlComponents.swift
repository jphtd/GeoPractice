import SwiftUI

/// Visual and interaction treatments available to a liquid selector.
///
/// `fullTrack` keeps the original segmented control behavior. The other two
/// styles use the drag translation relative to the value at the start of the
/// gesture, so a compact control can still scrub through a long option list.
enum LiquidSelectorStyle: String, CaseIterable, Identifiable, Hashable {
    case fullTrack
    case singleValue
    case adjacentCarousel

    var id: Self { self }
}

/// Pure interaction math kept separate from the view so boundary and drag
/// behavior can be exercised without synthesizing SwiftUI gestures.
enum LiquidSelectorMath {
    static func clampedIndex(_ index: Int, optionCount: Int) -> Int {
        guard optionCount > 0 else { return 0 }
        return min(optionCount - 1, max(0, index))
    }

    static func relativeIndex(
        startIndex: Int,
        translation: CGFloat,
        pointsPerStep: CGFloat,
        optionCount: Int
    ) -> Int? {
        guard optionCount > 0, pointsPerStep > 0 else { return nil }
        let stepDelta = Int(
            (translation / pointsPerStep).rounded(.toNearestOrAwayFromZero)
        )
        return clampedIndex(startIndex + stepDelta, optionCount: optionCount)
    }
}

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
/// During a drag the nearest option is previewed locally; the full-track cursor
/// follows the finger while compact styles move their displayed labels. The
/// model is updated only when the gesture ends.
struct LiquidScrubSelector<Option: Hashable, Label: View>: View {
    let options: [Option]
    let selection: Option

    private let style: LiquidSelectorStyle
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
    @State private var dragTranslationX: CGFloat?
    @State private var dragStartIndex: Int?
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
        style: LiquidSelectorStyle = .fullTrack,
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
        self.style = style
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
        .onChange(of: style) { _, _ in
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
            labelsLayer(size: size)
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

            labelsLayer(size: size)
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

            labelsLayer(size: size)
        }
    }
#endif

    @ViewBuilder
    private func labelsLayer(size: CGSize) -> some View {
        switch style {
        case .fullTrack:
            fullTrackLabels
        case .singleValue:
            singleValueLabels(size: size)
        case .adjacentCarousel:
            adjacentCarouselLabels(size: size)
        }
    }

    private var fullTrackLabels: some View {
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

    @ViewBuilder
    private func singleValueLabels(size: CGSize) -> some View {
        if options.indices.contains(displayedIndex) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        Color.white.opacity(displayedIndex > 0 ? 0.34 : 0.10)
                    )
                    .frame(width: 34)
                    .frame(maxHeight: .infinity)

                label(options[displayedIndex])
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white.opacity(0.96))
                    .scaleEffect(1.035)
                    .offset(x: relativeContentOffset(for: size, visualStep: 42))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(compactLabelAnimation, value: displayedIndex)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        Color.white.opacity(displayedIndex < options.count - 1 ? 0.34 : 0.10)
                    )
                    .frame(width: 34)
                    .frame(maxHeight: .infinity)
            }
            .padding(trackInset)
            .allowsHitTesting(false)
        }
    }

    private func adjacentCarouselLabels(size: CGSize) -> some View {
        HStack(spacing: 0) {
            carouselLabel(at: displayedIndex - 1, isCurrent: false)
            carouselLabel(at: displayedIndex, isCurrent: true)
            carouselLabel(at: displayedIndex + 1, isCurrent: false)
        }
        .offset(
            x: relativeContentOffset(
                for: size,
                visualStep: max(0, size.width - (trackInset * 2)) / 3
            )
        )
        .padding(trackInset)
        .clipped()
        .allowsHitTesting(false)
        .animation(compactLabelAnimation, value: displayedIndex)
    }

    @ViewBuilder
    private func carouselLabel(at index: Int, isCurrent: Bool) -> some View {
        if options.indices.contains(index) {
            label(options[index])
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fontWeight(isCurrent ? .semibold : .medium)
                .foregroundStyle(Color.white.opacity(isCurrent ? 0.96 : 0.30))
                .scaleEffect(isCurrent ? 1.035 : 0.92)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var trackInset: CGFloat {
        4
    }

    private func segmentWidth(for size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        return max(0, size.width - (trackInset * 2)) / CGFloat(options.count)
    }

    private func cursorWidth(for size: CGSize) -> CGFloat {
        switch style {
        case .fullTrack:
            return max(0, segmentWidth(for: size) - 4)
        case .singleValue:
            return max(0, size.width - (trackInset * 2) - 60)
        case .adjacentCarousel:
            return max(0, (size.width - (trackInset * 2)) / 3 - 4)
        }
    }

    private func cursorHeight(for size: CGSize) -> CGFloat {
        max(0, size.height - (trackInset * 2))
    }

    private func cursorOffset(for size: CGSize) -> CGFloat {
        let width = cursorWidth(for: size)
        let center: CGFloat
        switch style {
        case .fullTrack:
            center = dragLocationX ?? centerX(for: displayedIndex, size: size)
        case .singleValue, .adjacentCarousel:
            center = size.width / 2
        }
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

    private func relativeStepDistance(for size: CGSize) -> CGFloat {
        switch style {
        case .fullTrack:
            return max(1, segmentWidth(for: size))
        case .singleValue:
            return max(36, min(64, size.width * 0.30))
        case .adjacentCarousel:
            return max(32, min(64, size.width / 3))
        }
    }

    private func relativeOptionIndex(translation: CGFloat, size: CGSize) -> Int? {
        LiquidSelectorMath.relativeIndex(
            startIndex: dragStartIndex ?? committedIndex,
            translation: translation,
            pointsPerStep: relativeStepDistance(for: size),
            optionCount: options.count
        )
    }

    private func relativeContentOffset(for size: CGSize, visualStep: CGFloat) -> CGFloat {
        guard style != .fullTrack,
              dragAxis == .horizontal,
              let translation = dragTranslationX,
              let startIndex = dragStartIndex else { return 0 }

        let interactionStep = relativeStepDistance(for: size)
        guard interactionStep > 0 else { return 0 }
        let selectedDelta = displayedIndex - startIndex
        let residual = translation - (CGFloat(selectedDelta) * interactionStep)
        let normalizedResidual = min(0.5, max(-0.5, residual / interactionStep))
        // The labels travel against the finger so the next value on the
        // right slides into the centered selection as the user drags right.
        return -normalizedResidual * visualStep
    }

    private func tapOptionIndex(at x: CGFloat, size: CGSize) -> Int? {
        switch style {
        case .fullTrack:
            return optionIndex(at: x, size: size)
        case .singleValue, .adjacentCarousel:
            let delta: Int
            if x < size.width / 3 {
                delta = -1
            } else if x > size.width * 2 / 3 {
                delta = 1
            } else {
                delta = 0
            }
            return LiquidSelectorMath.clampedIndex(
                committedIndex + delta,
                optionCount: options.count
            )
        }
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
                if dragStartIndex == nil {
                    // A new drag supersedes any delayed reset left by the
                    // previous gesture. Invalidate it before tracking starts.
                    suppressTapResetID = nil
                    dragStartIndex = committedIndex
                }
                dragTranslationX = value.translation.width

                switch style {
                case .fullTrack:
                    dragLocationX = clampedCenterX(value.location.x, size: size)
                    previewIndex = optionIndex(at: value.location.x, size: size)
                case .singleValue, .adjacentCarousel:
                    dragLocationX = nil
                    previewIndex = relativeOptionIndex(
                        translation: value.translation.width,
                        size: size
                    )
                }
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
                      let index = tapOptionIndex(at: value.location.x, size: size),
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
        dragTranslationX = nil
        dragStartIndex = nil
        previewIndex = nil
        scheduleTapSuppressionReset()
    }

    private func scheduleTapSuppressionReset() {
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
        dragTranslationX = nil
        dragStartIndex = nil
        previewIndex = nil
        if suppressTap {
            // Keep the synthetic tap generated at the end of a drag suppressed
            // even when the committed selection immediately invalidates state.
            scheduleTapSuppressionReset()
        } else {
            suppressTapResetID = nil
        }
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

    /// While scrubbing, the compact labels are already positioned directly
    /// from finger translation. Animating an index threshold change on top of
    /// that would briefly move them against the gesture. Snap animation is
    /// retained for taps and external selection changes.
    private var compactLabelAnimation: Animation? {
        dragAxis == .horizontal ? nil : labelAnimation
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
