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

    static func continuousIndex(
        startIndex: Int,
        translation: CGFloat,
        pointsPerStep: CGFloat,
        optionCount: Int
    ) -> CGFloat? {
        guard optionCount > 0, pointsPerStep > 0 else { return nil }
        return min(
            CGFloat(optionCount - 1),
            max(0, CGFloat(startIndex) + translation / pointsPerStep)
        )
    }

    /// Offset of an all-options strip inside a three-slot viewport. The first
    /// and last triplets pin to their respective edges; interior options pass
    /// continuously through the center slot.
    static func edgePinnedStripOffset(
        continuousIndex: CGFloat,
        optionCount: Int,
        slotWidth: CGFloat
    ) -> CGFloat {
        guard optionCount > 3, slotWidth > 0 else { return 0 }
        let lastIndex = CGFloat(optionCount - 1)
        let position = min(lastIndex, max(0, continuousIndex))
        let anchor: CGFloat
        if position < 1 {
            anchor = slotWidth / 2 + position * slotWidth
        } else if position > lastIndex - 1 {
            anchor = slotWidth * 1.5
                + (position - (lastIndex - 1)) * slotWidth
        } else {
            anchor = slotWidth * 1.5
        }
        return anchor - (position + 0.5) * slotWidth
    }

    static func clampedCenter(
        proposedCenter: CGFloat,
        scaledCursorWidth: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        let halfWidth = max(0, scaledCursorWidth) / 2
        let minimum = lowerBound + halfWidth
        let maximum = upperBound - halfWidth
        guard minimum <= maximum else {
            return (lowerBound + upperBound) / 2
        }
        return min(maximum, max(minimum, proposedCenter))
    }
}

/// A single restrained glass surface for a group of related controls.
/// The panel owns the only glass layer so labels and selectors stay crisp;
/// iOS 17–25 use one continuous Material panel instead.
struct LiquidControlPanel<Content: View>: View {
    private let contentPadding: CGFloat
    private let cornerRadius: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        contentPadding: CGFloat = 8,
        cornerRadius: CGFloat = 26,
        @ViewBuilder content: () -> Content
    ) {
        self.contentPadding = contentPadding
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
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
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
        content
            .padding(contentPadding)
            .background(Color.black.opacity(0.18), in: panelShape)
            .glassEffect(
                .regular.tint(Color.white.opacity(0.025)),
                in: panelShape
            )
            .overlay {
                panelShape
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.9)
                    .allowsHitTesting(false)
            }
    }
#endif

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// A horizontally scrubbable selector for a small set of discrete values.
///
/// During a drag the nearest option is previewed locally while one continuous
/// glass cursor follows the finger. Carousel content scrolls beneath that
/// cursor, and every style commits to the model only when the gesture ends.
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

    @State private var dragAxis: DragAxis?
    @State private var dragTranslationX: CGFloat?
    @State private var dragStartIndex: Int?
    @State private var previewIndex: Int?
    /// Keeps the released value visually stable until the parent binding has
    /// acknowledged it. This is deliberately short-lived: hand changes can
    /// open a confirmation alert and may never update `selection`.
    @State private var settlingIndex: Int?
    @State private var settlingResetID: UUID?
    @State private var suppressTap = false
    @State private var suppressTapResetID: UUID?

    private enum DragAxis {
        case horizontal
        case vertical
    }

    private struct CursorAnimationState: Equatable {
        let offset: CGFloat
        let horizontalScale: CGFloat
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
        .onChange(of: selection) { _, newSelection in
            reconcileExternalSelection(newSelection)
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
        return min(
            options.count - 1,
            max(0, previewIndex ?? settlingIndex ?? committedIndex)
        )
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
            .scaleEffect(
                x: cursorHorizontalScale(for: size),
                y: 1
            )
            .offset(x: cursorOffset(for: size))
            .animation(cursorAnimation, value: cursorAnimationState(for: size))
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
                .scaleEffect(
                    x: cursorHorizontalScale(for: size),
                    y: 1
                )
                .offset(x: cursorOffset(for: size))
                .animation(cursorAnimation, value: cursorAnimationState(for: size))

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
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                }
                .frame(width: cursorWidth(for: size), height: cursorHeight(for: size))
                .scaleEffect(
                    x: cursorHorizontalScale(for: size),
                    y: 1
                )
                .offset(x: cursorOffset(for: size))
                .animation(cursorAnimation, value: cursorAnimationState(for: size))

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
        let slotWidth = adjacentSlotWidth(for: size)
        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    label(option)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .fontWeight(index == displayedIndex ? .semibold : .medium)
                        .foregroundStyle(
                            Color.white.opacity(index == displayedIndex ? 0.96 : 0.52)
                        )
                        .scaleEffect(index == displayedIndex ? 1.035 : 0.92)
                        .frame(width: slotWidth)
                        .frame(maxHeight: .infinity)
                        .animation(compactLabelAnimation, value: displayedIndex)
                }
            }
            .frame(
                width: slotWidth * CGFloat(options.count),
                alignment: .leading
            )
            .offset(x: trackInset + adjacentContentOffset(for: size))
            .animation(cursorAnimation, value: adjacentContentOffset(for: size))
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
    }

    private var trackInset: CGFloat {
        4
    }

    private func segmentWidth(for size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        return availableTrackWidth(for: size) / CGFloat(options.count)
    }

    private func availableTrackWidth(for size: CGSize) -> CGFloat {
        max(0, size.width - (trackInset * 2))
    }

    private func adjacentSlotCount() -> Int {
        min(3, max(1, options.count))
    }

    private func adjacentSlotWidth(for size: CGSize) -> CGFloat {
        availableTrackWidth(for: size) / CGFloat(adjacentSlotCount())
    }

    private func cursorWidth(for size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        let availableWidth = availableTrackWidth(for: size)
        switch style {
        case .fullTrack:
            let segment = segmentWidth(for: size)
            return min(segment, max(4, segment - 4))
        case .singleValue:
            return min(availableWidth, max(18, availableWidth - 60))
        case .adjacentCarousel:
            let slot = adjacentSlotWidth(for: size)
            return min(slot, max(8, slot - 4))
        }
    }

    private func cursorHeight(for size: CGSize) -> CGFloat {
        max(0, size.height - (trackInset * 2))
    }

    private func cursorOffset(for size: CGSize) -> CGFloat {
        let width = cursorWidth(for: size)
        return cursorCenter(for: size) - (width / 2)
    }

    private func cursorCenter(for size: CGSize) -> CGFloat {
        let width = cursorWidth(for: size)
        let scale = cursorHorizontalScale(for: size)
        let restingIndex = dragStartIndex ?? displayedIndex
        let restingCenter = cursorRestingCenter(for: restingIndex, size: size)
        let proposedCenter: CGFloat
        if dragAxis == .horizontal, let translation = dragTranslationX {
            proposedCenter = restingCenter + translation
        } else {
            proposedCenter = cursorRestingCenter(for: displayedIndex, size: size)
        }
        let center = LiquidSelectorMath.clampedCenter(
            proposedCenter: proposedCenter,
            scaledCursorWidth: width * scale,
            lowerBound: trackInset,
            upperBound: size.width - trackInset
        )
        return center
    }

    private func centerX(for index: Int, size: CGSize) -> CGFloat {
        trackInset + (segmentWidth(for: size) * (CGFloat(index) + 0.5))
    }

    private func cursorRestingCenter(for index: Int, size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return size.width / 2 }
        let safeIndex = LiquidSelectorMath.clampedIndex(index, optionCount: options.count)
        switch style {
        case .fullTrack:
            return centerX(for: safeIndex, size: size)
        case .singleValue:
            return size.width / 2
        case .adjacentCarousel:
            if options.count <= 3 {
                return trackInset
                    + adjacentSlotWidth(for: size) * (CGFloat(safeIndex) + 0.5)
            }
            if safeIndex == 0 {
                return trackInset + adjacentSlotWidth(for: size) / 2
            }
            if safeIndex == options.count - 1 {
                return size.width - trackInset - adjacentSlotWidth(for: size) / 2
            }
            return size.width / 2
        }
    }

    private func cursorHorizontalScale(for size: CGSize) -> CGFloat {
        let desiredScale = 1 + cursorStretchPhase(for: size) * 0.08
        let width = cursorWidth(for: size)
        guard width > 0 else { return 1 }
        let boundarySafeScale = max(1, availableTrackWidth(for: size) / width)
        return min(desiredScale, boundarySafeScale)
    }

    private func cursorStretchPhase(for size: CGSize) -> CGFloat {
        guard !reduceMotion, dragAxis == .horizontal else { return 0 }
        let position = continuousOptionPosition(for: size)
        let distanceFromOptionCenter = abs(position - position.rounded())
        return min(1, distanceFromOptionCenter * 2)
    }

    private func cursorAnimationState(for size: CGSize) -> CursorAnimationState {
        CursorAnimationState(
            offset: cursorOffset(for: size),
            horizontalScale: cursorHorizontalScale(for: size)
        )
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
            // One logical step is exactly one visible option slot, so the
            // preview changes only as the cursor crosses the next center.
            return max(1, adjacentSlotWidth(for: size))
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

    private func continuousOptionPosition(for size: CGSize) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        if dragAxis == .horizontal,
           let translation = dragTranslationX,
           let startIndex = dragStartIndex {
            return LiquidSelectorMath.continuousIndex(
                startIndex: startIndex,
                translation: translation,
                pointsPerStep: relativeStepDistance(for: size),
                optionCount: options.count
            ) ?? CGFloat(displayedIndex)
        }
        return CGFloat(displayedIndex)
    }

    /// Offset for a virtual strip containing every option. At the first and
    /// last values the strip is pinned to the corresponding edge; throughout
    /// the middle range the active value occupies the center slot. Rendering
    /// the real options instead of placeholder slots keeps edge transitions
    /// continuous and guarantees there is never a blank carousel cell.
    private func adjacentContentOffset(for size: CGSize) -> CGFloat {
        guard options.count > 3 else { return 0 }
        let slot = adjacentSlotWidth(for: size)
        let position = continuousOptionPosition(for: size)
        // Keep the continuous option position directly beneath the glass
        // cursor. The strip stays still while the cursor has room to travel;
        // once the cursor reaches an edge, further dragging scrolls the real
        // option strip instead. This avoids the cursor and labels moving away
        // from one another during a long scrub.
        return cursorCenter(for: size)
            - trackInset
            - (position + 0.5) * slot
    }

    private func tapOptionIndex(at x: CGFloat, size: CGSize) -> Int? {
        switch style {
        case .fullTrack:
            return optionIndex(at: x, size: size)
        case .singleValue:
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
        case .adjacentCarousel:
            guard !options.isEmpty else { return nil }
            let slot = adjacentSlotWidth(for: size)
            guard slot > 0 else { return nil }
            let stripOffset = adjacentContentOffsetAtRest(
                index: committedIndex,
                size: size
            )
            let localX = x - trackInset - stripOffset
            return LiquidSelectorMath.clampedIndex(
                Int(floor(localX / slot)),
                optionCount: options.count
            )
        }
    }

    private func adjacentContentOffsetAtRest(index: Int, size: CGSize) -> CGFloat {
        guard options.count > 3 else { return 0 }
        let slot = adjacentSlotWidth(for: size)
        let safeIndex = LiquidSelectorMath.clampedIndex(index, optionCount: options.count)
        return LiquidSelectorMath.edgePinnedStripOffset(
            continuousIndex: CGFloat(safeIndex),
            optionCount: options.count,
            slotWidth: slot
        )
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
                    // Once the drag recognizer becomes active, suppress the
                    // simultaneous SpatialTap even if the gesture ultimately
                    // locks vertically or remains diagonal. Otherwise a short
                    // scroll can be misread as a selector tap on release.
                    suppressTapResetID = nil
                    suppressTap = true

                    if horizontalDistance > verticalDistance * 1.15 {
                        dragAxis = .horizontal
                    } else if verticalDistance > horizontalDistance * 1.15 {
                        dragAxis = .vertical
                    } else {
                        return
                    }
                }

                guard dragAxis == .horizontal else { return }
                if dragStartIndex == nil {
                    // A new drag supersedes any delayed reset left by the
                    // previous gesture. Invalidate it before tracking starts.
                    suppressTapResetID = nil
                    settlingResetID = nil
                    settlingIndex = nil
                    dragStartIndex = committedIndex
                }
                dragTranslationX = value.translation.width
                previewIndex = relativeOptionIndex(
                    translation: value.translation.width,
                    size: size
                )
            }
            .onEnded { _ in
                guard isInteractive, dragAxis == .horizontal else {
                    cancelInteraction()
                    return
                }

                let option = previewIndex.flatMap { index in
                    options.indices.contains(index) ? options[index] : nil
                }
                if let option,
                   let index = options.firstIndex(of: option) {
                    settleInteraction(to: index)
                    if option != selection {
                        onCommit(option)
                    }
                } else {
                    settleInteraction(to: committedIndex)
                }
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
                    settleInteraction(to: index)
                    onCommit(option)
                }
            }
    }

    private func settleInteraction(to index: Int) {
        dragAxis = nil
        dragTranslationX = nil
        dragStartIndex = nil
        previewIndex = nil
        settlingIndex = LiquidSelectorMath.clampedIndex(
            index,
            optionCount: options.count
        )
        if suppressTap {
            scheduleTapSuppressionReset()
        }
        scheduleSettlementReset()
    }

    private func scheduleSettlementReset() {
        let interactionID = UUID()
        settlingResetID = interactionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard settlingResetID == interactionID else { return }
            settlingIndex = nil
            settlingResetID = nil
        }
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
        dragTranslationX = nil
        dragStartIndex = nil
        previewIndex = nil
        settlingIndex = nil
        settlingResetID = nil
        if suppressTap {
            // Keep the synthetic tap generated at the end of a drag suppressed
            // even when the committed selection immediately invalidates state.
            scheduleTapSuppressionReset()
        } else {
            suppressTapResetID = nil
        }
    }

    private func reconcileExternalSelection(_: Option) {
        dragAxis = nil
        dragTranslationX = nil
        dragStartIndex = nil
        previewIndex = nil
        settlingResetID = nil
        settlingIndex = nil

        if suppressTap {
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
            settleInteraction(to: nextIndex)
            onCommit(option)
        }
    }

    private var cursorAnimation: Animation? {
        reduceMotion || dragAxis == .horizontal
            ? nil
            : .snappy(duration: 0.22, extraBounce: 0.055)
    }

    private var labelAnimation: Animation? {
        reduceMotion || dragAxis == .horizontal
            ? nil
            : .easeOut(duration: 0.12)
    }

    /// While scrubbing, the carousel strip and cursor are positioned directly
    /// from finger translation. Animating an index threshold change on top of
    /// that would briefly move them against the gesture. Snap animation is
    /// retained for taps and external selection changes.
    private var compactLabelAnimation: Animation? {
        reduceMotion || dragAxis == .horizontal
            ? nil
            : .snappy(duration: 0.22, extraBounce: 0.035)
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
