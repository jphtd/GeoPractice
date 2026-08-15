import SwiftData
import SwiftUI

private enum MetronomePanel: String, Identifiable {
    case session
    case structure
    case tempo
#if DEBUG || CUSTOMER_PREVIEW
    case experiments
#endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "本次练习"
        case .structure: "节拍设置"
        case .tempo: "速度设置"
#if DEBUG || CUSTOMER_PREVIEW
        case .experiments: "体验设置"
#endif
        }
    }
}

private struct BeatVisualPulseSnapshot: Equatable {
    let beat: Int
    let subdivision: Int
    let pulseDate: Date
    let kind: BeatPulseKind
    let eventInterval: TimeInterval
}

private struct BeatVisualFinishAnimation: Equatable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let visibleBeatIndices: [Int]
}

struct MetronomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]

    @ObservedObject var engine: MetronomeEngine
    @ObservedObject var practiceSession: PracticeSessionController
    let leaveMetronome: () -> Void

    @AppStorage("confirmBeforeHandSwitch") private var confirmBeforeHandSwitch = true
#if DEBUG || CUSTOMER_PREVIEW
    @AppStorage("debug.experience.tempoMode.v2")
    private var debugTempoModeRaw = TempoSemantics.independentReference.rawValue
    @AppStorage("debug.experience.referenceNote.v2")
    private var debugReferenceNoteRaw = TempoReferenceNote.quarter.rawValue
    @AppStorage("debug.experience.selectorStyle.v2")
    private var debugSelectorStyleRaw = LiquidSelectorStyle.adjacentCarousel.rawValue
#endif
    @State private var pendingHandSwitch: PracticeHand?
    @State private var reviewSummary: PracticeSessionSummary?
    @State private var persistenceError: String?
    @State private var isSavingSummary = false
    @State private var activePanel: MetronomePanel?
    @State private var visualLifecycle = BeatVisualLifecycle()
    @State private var visualPulse: BeatVisualPulseSnapshot?
    @State private var visualFinish: BeatVisualFinishAnimation?
    @State private var pendingReviewSummary: PracticeSessionSummary?
    @State private var visualSessionStartedAt: Date?

    private var sourceEvent: PracticeEvent? {
        guard let id = practiceSession.session.sourceEventID else { return nil }
        return events.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            GeoBackground()

            GeometryReader { geometry in
                v4Interface(size: geometry.size)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            liquidBottomControlPanel
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .tabBar)
        .confirmationDialog(
            "切换练习手型？",
            isPresented: Binding(
                get: { pendingHandSwitch != nil },
                set: { if !$0 { pendingHandSwitch = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let hand = pendingHandSwitch {
                Button("切换到\(hand.title)并重新计时") {
                    completeHandSwitch(to: hand)
                }
                Button("切换，今后不再提示") {
                    confirmBeforeHandSwitch = false
                    completeHandSwitch(to: hand)
                }
            }
            Button("取消", role: .cancel) {
                pendingHandSwitch = nil
            }
        } message: {
            if let hand = pendingHandSwitch {
                Text("\(practiceSession.session.currentHand.title)的当前计时段将结束，\(hand.title)将从 00:00 重新计时；已累计的时长不会丢失。")
            }
        }
        .sheet(isPresented: Binding(
            get: { reviewSummary != nil },
            set: { _ in }
        )) {
            if let summary = reviewSummary {
                let linkedEvent = summary.sourceEventID.flatMap { id in
                    events.first(where: { $0.id == id })
                }
                PracticeSessionSummaryView(
                    summary: summary,
                    sourceEventName: linkedEvent?.name,
                    persistenceError: persistenceError,
                    isSaving: isSavingSummary,
                    onAppend: linkedEvent == nil ? nil : {
                        append(summary, to: linkedEvent!)
                    },
                    onDiscard: {
                        completeSessionWithoutSaving()
                    },
                    onContinue: {
                        continueSession()
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        .sheet(item: $activePanel) { panel in
            settingsSheet(for: panel)
        }
        .alert("节拍器提示", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .onAppear {
#if DEBUG || CUSTOMER_PREVIEW
            synchronizeExperienceSettings()
#endif
            synchronizeVisualSession()
            if reviewSummary == nil, visualFinish == nil {
                reviewSummary = practiceSession.session.reviewSummary
            }
        }
#if DEBUG || CUSTOMER_PREVIEW
        .onChange(of: debugTempoModeRaw) { _, _ in
            synchronizeExperienceSettings()
        }
        .onChange(of: debugReferenceNoteRaw) { _, _ in
            synchronizeExperienceSettings()
        }
#endif
        .onChange(of: engine.preset) { _, preset in
            practiceSession.updatePreset(preset)
        }
        .onChange(of: engine.playbackPlan) { previousPlan, nextPlan in
            // An interval-only tempo change must not make the visible Hit or
            // the persistent current-beat locator blink out. Clear only when
            // the number/placement of events changes.
            if nextPlan.pulsesPerBeat != previousPlan.pulsesPerBeat
                || nextPlan.eventsPerMeasure != previousPlan.eventsPerMeasure {
                visualPulse = nil
                visualLifecycle.clearCurrentBeatLocation()
            }
        }
        .onChange(of: engine.preset.beats) { _, beats in
            visualLifecycle.reconfigure(beats: beats)
            visualPulse = nil
        }
        .onChange(of: engine.lastPulseDate) { _, pulseDate in
            recordVisualTick(pulseDate: pulseDate)
        }
        .onChange(of: engine.isPlaying) { wasPlaying, isPlaying in
            guard visualFinish == nil else { return }
            if isPlaying {
                visualLifecycle.resume()
            } else if wasPlaying {
                visualPulse = nil
                visualLifecycle.pause()
            }
        }
        .onChange(of: practiceSession.session.startedAt) { _, _ in
            synchronizeVisualSession()
        }
    }

    private func v4Interface(size: CGSize) -> some View {
        let compactHeight = size.height < 720
        let showsSupplementaryStageStatus = size.height >= 360

        return VStack(spacing: compactHeight ? 4 : 10) {
            v4Header
            v4Stage(showsSupplementaryStatus: showsSupplementaryStageStatus)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: min(880, max(0, size.width - 24)), maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, compactHeight ? 2 : 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var v4Header: some View {
        HStack(spacing: 12) {
            GeoGlassCapsule {
                Menu {
                    Button {
                        leaveMetronome()
                    } label: {
                        Label("打卡记录", systemImage: "checklist")
                    }

                    Divider()

                    Button {
                        toggleMetronome()
                    } label: {
                        Label(
                            engine.isPlaying ? "暂停节拍器" : "开始节拍器",
                            systemImage: engine.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                    .disabled(visualFinish != nil || practiceSession.session.phase == .finished)

                    Button {
                        activePanel = .session
                    } label: {
                        Label("本次练习详情", systemImage: "timer")
                    }

                    Button {
                        activePanel = .structure
                    } label: {
                        Label("完整节拍设置", systemImage: "slider.horizontal.3")
                    }

#if DEBUG || CUSTOMER_PREVIEW
                    Button {
                        activePanel = .experiments
                    } label: {
                        Label(
                            "体验设置 · \(experienceSummary)",
                            systemImage: "slider.horizontal.3"
                        )
                    }
#endif

                    Divider()

                    Button {
                        finishCurrentSession()
                    } label: {
                        Label("练习完毕", systemImage: "checkmark.circle")
                    }
                    .disabled(practiceSession.session.phase == .idle
                              || practiceSession.session.phase == .finished
                              || visualFinish != nil)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("菜单")
            }
            .frame(width: 48)
            .disabled(visualFinish != nil)

            Spacer(minLength: 0)

            headerIdentity

            Spacer(minLength: 0)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    Text("练习时长")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                    Text(practiceDurationString(
                        milliseconds: sessionTotalDuration(at: context.date)
                    ))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 64, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("本次练习总时长")
                .accessibilityValue(practiceDurationString(
                    milliseconds: sessionTotalDuration(at: context.date)
                ))
            }
        }
        .frame(height: 60)
    }

    private var headerIdentity: some View {
        VStack(spacing: 3) {
            Text("GeoBeat")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .tracking(-0.6)
            Text(practiceDisplayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: 220)
    }

    private var practiceDisplayName: String {
        sourceEvent?.name ?? "自由练习"
    }

    private func v4Stage(showsSupplementaryStatus: Bool) -> some View {
        Button {
            toggleMetronome()
        } label: {
            ZStack {
                MetronomeCanvas(
                    preset: engine.preset,
                    playbackPlan: engine.playbackPlan,
                    lifecycle: visualLifecycle,
                    pulse: visualPulse,
                    finishAnimation: visualFinish,
                    isPlaying: engine.isPlaying,
                    reduceMotion: reduceMotion,
                    dimFlashingLights: dimFlashingLights
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 680, maxHeight: 680)

                if showsSupplementaryStatus {
                    VStack {
                        stageTempoStatus
                            .padding(.top, 4)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(visualFinish != nil || engine.isPlaying ? Color.white : GeoTheme.muted)
                                .frame(width: 5, height: 5)
                            Text(
                                visualFinish != nil
                                    ? "正在结束练习"
                                    : (engine.isPlaying ? "轻点暂停" : "轻点开始")
                            )
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(visualFinish != nil || practiceSession.session.phase == .finished)
        .accessibilityLabel(
            visualFinish != nil
                ? "正在结束练习"
                : (engine.isPlaying ? "暂停节拍器" : "开始节拍器")
        )
        .accessibilityValue("\(engine.preset.beats) 拍，\(engine.preset.tempoDisplay)，\(engine.preset.subdivisionTitle)")
    }

    /// The geometry remains the primary visual object; this unboxed, compact
    /// readout gives tempo a stable second-level position outside the dense
    /// control panel.
    private var stageTempoStatus: some View {
        VStack(spacing: 0) {
            Text("BPM")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.42))
            Text("\(engine.preset.bpm)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.white.opacity(0.86))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前速度")
        .accessibilityValue("\(engine.preset.bpm) BPM")
    }

    private var liquidBottomControlPanel: some View {
        LiquidControlPanel(contentPadding: 8, cornerRadius: 26) {
            ViewThatFits(in: .horizontal) {
                wideLiquidControlLayout
                    .frame(minWidth: 660)
                shortWideLiquidControlLayout
                    .frame(minWidth: 570)
                compactLiquidControlLayout
                    .frame(minWidth: 330)
                ultraCompactLiquidControlLayout
            }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private var wideLiquidControlLayout: some View {
        HStack(spacing: 8) {
            beatLiquidControl
                .frame(minWidth: 120, maxWidth: 142)
            liquidDivider
            tempoLiquidControl
                .frame(minWidth: 204, maxWidth: 230)
            liquidDivider
            subdivisionLiquidControl
                .frame(minWidth: 84, maxWidth: 108)
            liquidDivider
            handLiquidControl
                .frame(minWidth: 108, maxWidth: 142)
            incrementLiquidControl
                .frame(minWidth: 74, maxWidth: 82)
        }
    }

    private var compactLiquidControlLayout: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                beatLiquidControl
                    .frame(maxWidth: .infinity)
                tempoLiquidControl
                    .frame(width: 204)
            }

            HStack(spacing: 6) {
                subdivisionLiquidControl
                    .frame(minWidth: 76, idealWidth: 88, maxWidth: 96)
                handLiquidControl
                    .frame(maxWidth: .infinity)
                incrementLiquidControl
                    .frame(width: 92)
            }
        }
    }

    /// A compressed single row for short iPhone landscape layouts. Removing
    /// decorative dividers keeps the panel shallow without hiding any control.
    private var shortWideLiquidControlLayout: some View {
        HStack(spacing: 4) {
            beatLiquidControl
                .frame(width: 132)
            tempoLiquidControl
                .frame(width: 190)
            subdivisionLiquidControl
                .frame(width: 72)
            handLiquidControl
                .frame(width: 90)
            incrementLiquidControl
                .frame(width: 64)
        }
    }

    /// At roughly 320 pt window width (for example an iPad narrow split or an
    /// iPhone SE portrait), fixed-width tempo content cannot share a row with
    /// the beat selector. Three compact rows prevent clipping or zero-width
    /// selectors while preserving every direct manipulation target.
    private var ultraCompactLiquidControlLayout: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                beatLiquidControl
                    .frame(maxWidth: .infinity)
                subdivisionLiquidControl
                    .frame(width: 78)
            }

            HStack(spacing: 6) {
                tempoLiquidControl
                    .frame(width: 204)
                incrementLiquidControl
                    .frame(maxWidth: .infinity)
            }

            handLiquidControl
                .frame(maxWidth: .infinity)
        }
    }

    private var activeSelectorStyle: LiquidSelectorStyle {
#if DEBUG || CUSTOMER_PREVIEW
        debugSelectorStyle
#else
        .fullTrack
#endif
    }

    private var beatLiquidControl: some View {
        let groupings = MetronomePreset.groupings(for: engine.preset.beats)

        return VStack(spacing: 2) {
            Text("拍子")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                LiquidScrubSelector(
                    options: Array(3...9),
                    selection: engine.preset.beats,
                    style: .adjacentCarousel,
                    accessibilityLabel: "拍子",
                    accessibilityValue: { "\($0) 拍" },
                    controlHeight: 44,
                    isEnabled: canEditLiquidControls,
                    onCommit: setBeatCount
                ) { beats in
                    Text("\(beats)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }

                if groupings.count > 1 {
                    BeatGroupingSwitch(
                        options: groupings,
                        selection: engine.preset.grouping,
                        isEnabled: canEditLiquidControls,
                        onCommit: { grouping in
                            guard canEditLiquidControls else { return }
                            engine.setGrouping(grouping)
                        }
                    )
                }
            }
        }
    }

    private var tempoLiquidControl: some View {
        HStack(alignment: .bottom, spacing: 3) {
            VStack(spacing: 2) {
                Text("基准音符")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)
                    .lineLimit(1)

                LiquidScrubSelector(
                    options: TempoReferenceNote.tempoReferenceOptions,
                    selection: engine.preset.referenceNote,
                    style: .adjacentCarousel,
                    accessibilityLabel: "BPM 基准音符",
                    accessibilityValue: { $0.title },
                    controlHeight: 44,
                    isEnabled: canEditLiquidControls,
                    onCommit: { note in
                        setTempoReferenceNote(note)
                    }
                ) { note in
                    SMuFLNoteGlyph(note: note)
                }
            }

            Text("=")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(GeoTheme.muted)
                .frame(width: 10, height: 44)
                .accessibilityHidden(true)

            TempoScrubber(
                bpm: engine.preset.bpm,
                compact: true,
                onTap: {
                    activePanel = .tempo
                },
                onCommit: { bpm in
                    guard canEditLiquidControls else { return }
                    engine.setBPM(bpm)
                }
            )
            .frame(width: 116, height: 52)
        }
        .opacity(canEditLiquidControls ? 1 : 0.48)
        .disabled(!canEditLiquidControls)
        .allowsHitTesting(canEditLiquidControls)
    }

    private var subdivisionLiquidControl: some View {
        VStack(spacing: 2) {
            Text("训练音符")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)

            LiquidScrubSelector(
                options: MetronomePreset.supportedSubdivisions,
                selection: engine.preset.subdivision,
                style: .adjacentCarousel,
                accessibilityLabel: "训练音符",
                accessibilityValue: subdivisionTitle,
                controlHeight: 44,
                isEnabled: canEditLiquidControls,
                onCommit: { subdivision in
                    guard canEditLiquidControls else { return }
                    engine.setSubdivision(subdivision)
                }
            ) { subdivision in
                SMuFLNoteGlyph(
                    note: TempoReferenceNote.trainingNote(for: subdivision)
                )
            }
        }
    }

    private var handLiquidControl: some View {
        let session = practiceSession.session
        let hand = session.currentHand
        let canEdit = session.phase == .running || session.phase == .paused

        return VStack(spacing: 2) {
            Text("手型 · \(hand.title)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)

            LiquidScrubSelector(
                options: PracticeHand.controlOrder,
                selection: hand,
                style: activeSelectorStyle,
                accessibilityLabel: "练习手型",
                accessibilityValue: { $0.title },
                controlHeight: 44,
                isEnabled: canEdit && visualFinish == nil,
                onCommit: requestHandSwitch
            ) { item in
                Text(item.shortTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
        }
    }

    private var incrementLiquidControl: some View {
        let session = practiceSession.session
        let hand = session.currentHand
        let count = session.stats(for: hand, at: .now).count
        let canEdit = session.phase == .running || session.phase == .paused

        return Button {
            practiceSession.adjustCount(for: hand, by: 1)
        } label: {
            VStack(spacing: 1) {
                Text("+1")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.82))
                Text("\(hand.shortTitle) · \(count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.018))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.055), lineWidth: 0.8)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LiquidPressButtonStyle())
        .disabled(!canEdit || visualFinish != nil)
        .accessibilityLabel("为当前\(hand.title)增加一次")
        .accessibilityValue("当前 \(count) 次")
    }

    private var canEditLiquidControls: Bool {
        visualFinish == nil && practiceSession.session.phase != .finished
    }

    private var liquidDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.8, height: 38)
            .accessibilityHidden(true)
    }

    private func settingsSheet(for panel: MetronomePanel) -> some View {
        NavigationStack {
            ZStack {
                GeoBackground()
                ScrollView {
                    Group {
                        switch panel {
                        case .session:
                            practiceCard
                        case .structure:
                            structureCard
                        case .tempo:
                            tempoCard
#if DEBUG || CUSTOMER_PREVIEW
                        case .experiments:
                            experienceSettingsCard
#endif
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        activePanel = nil
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
#if DEBUG || CUSTOMER_PREVIEW
        .presentationDetents(panel == .experiments ? [.large] : [.medium, .large])
#else
        .presentationDetents([.medium, .large])
#endif
        .presentationDragIndicator(.visible)
    }

    private func sessionTotalDuration(at date: Date) -> Int64 {
        PracticeHand.allCases.reduce(0) { total, hand in
            let duration = practiceSession.session.stats(for: hand, at: date).durationMilliseconds
            let (sum, overflowed) = total.addingReportingOverflow(duration)
            return overflowed ? Int64.max : sum
        }
    }

    private func subdivisionTitle(for subdivision: Int) -> String {
        var preset = engine.preset
        preset.subdivision = subdivision
        return preset.normalized.subdivisionTitle
    }

    private func setBeatCount(_ beats: Int) {
        guard canEditLiquidControls else { return }
        engine.setBeats(beats)
    }

    private func setTempoReferenceNote(_ note: TempoReferenceNote) {
        guard canEditLiquidControls else { return }
#if DEBUG || CUSTOMER_PREVIEW
        debugTempoModeRaw = TempoSemantics.independentReference.rawValue
        debugReferenceNoteRaw = note.rawValue
#endif
        engine.setTempoReferenceNote(note)
    }

    private var structureCard: some View {
        GeoCard {
            VStack(spacing: 18) {
                CardTitle(title: "节拍结构", subtitle: "STRUCTURE")

                VStack(spacing: 10) {
                    ControlLabel(title: "每小节拍数", value: "\(engine.preset.beats) 拍")
                    HStack(spacing: 5) {
                        ForEach(3...9, id: \.self) { beats in
                            Button {
                                setBeatCount(beats)
                            } label: {
                                Text("\(beats)")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(engine.preset.beats == beats ? .white : GeoTheme.muted)
                                    .background {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(engine.preset.beats == beats ? Color.white.opacity(0.10) : Color(white: 0.04))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .stroke(engine.preset.beats == beats ? Color.white.opacity(0.55) : GeoTheme.line, lineWidth: 1)
                                            }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEditLiquidControls)
                            .accessibilityAddTraits(engine.preset.beats == beats ? .isSelected : [])
                        }
                    }
                }

                let groupings = MetronomePreset.groupings(for: engine.preset.beats)
                if groupings.count > 1 {
                    VStack(spacing: 10) {
                        ControlLabel(title: "重音分组", value: engine.preset.grouping)
                        GeoSegmentContainer {
                            ForEach(groupings, id: \.self) { grouping in
                                GeoSegmentButton(
                                    title: grouping,
                                    isActive: engine.preset.grouping == grouping
                                ) {
                                    engine.setGrouping(grouping)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    ControlLabel(title: "细分", value: engine.preset.subdivisionTitle)
                    GeoSegmentContainer {
                        ForEach(MetronomePreset.supportedSubdivisions, id: \.self) { subdivision in
                            GeoSegmentButton(
                                title: subdivision == 0 ? "2 分" : subdivision == 1 ? "4 分" : subdivision == 2 ? "8 分" : "16 分",
                                isActive: engine.preset.subdivision == subdivision
                            ) {
                                engine.setSubdivision(subdivision)
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    ControlLabel(title: "闪烁顺序", value: engine.preset.direction.title)
                    GeoSegmentContainer {
                        ForEach(RotationDirection.allCases) { direction in
                            GeoSegmentButton(
                                title: direction.title,
                                symbol: direction.symbol,
                                isActive: engine.preset.direction == direction
                            ) {
                                engine.setDirection(direction)
                            }
                        }
                    }
                }
            }
        }
    }

    private var tempoCard: some View {
        GeoCard {
            VStack(spacing: 18) {
                CardTitle(title: "速度", subtitle: "TEMPO")
                TempoScrubber(
                    bpm: engine.preset.bpm,
                    onCommit: { bpm in
                        engine.setBPM(bpm)
                    }
                )
                GeoSegmentContainer {
                    ForEach(MetronomePreset.builtIns, id: \.bpm) { item in
                        GeoSegmentButton(
                            title: "\(item.name) \(item.bpm)",
                            isActive: engine.preset.bpm == item.bpm
                        ) {
                            engine.setBPM(item.bpm)
                        }
                    }
                }
            }
        }
    }

#if DEBUG || CUSTOMER_PREVIEW
    private var debugTempoMode: TempoSemantics {
        TempoSemantics(rawValue: debugTempoModeRaw) ?? .independentReference
    }

    private var debugReferenceNote: TempoReferenceNote {
        TempoReferenceNote(rawValue: debugReferenceNoteRaw) ?? .quarter
    }

    private var debugSelectorStyle: LiquidSelectorStyle {
        LiquidSelectorStyle(rawValue: debugSelectorStyleRaw) ?? .adjacentCarousel
    }

    private var experienceSummary: String {
        "\(tempoModeShortTitle(debugTempoMode)) · \(selectorStyleShortTitle(debugSelectorStyle))"
    }

    private var experienceSettingsCard: some View {
        let plan = engine.playbackPlan

        return VStack(spacing: 16) {
            GeoCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "节拍体验设置", subtitle: "选择后立即生效")

                    VStack(spacing: 8) {
                        experienceCurrentRow(
                            title: "BPM 含义",
                            value: tempoModeShortTitle(debugTempoMode)
                        )
                        experienceCurrentRow(
                            title: "控件样式",
                            value: selectorStyleShortTitle(debugSelectorStyle)
                        )
                    }
                    .padding(11)
                    .background(
                        Color.white.opacity(0.075),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    }

                    Label(
                        "点选任意设置即可直接试听。播放中若实际速度发生变化，会从首拍重新开始；速度相同时保持当前节拍。",
                        systemImage: "ear"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("BPM 如何解释")
                            .font(.system(size: 13, weight: .bold))

                        ForEach(TempoSemantics.allCases) { mode in
                            Button {
                                debugTempoModeRaw = mode.rawValue
                            } label: {
                                experienceChoiceRow(
                                    symbol: tempoModeSymbol(mode),
                                    title: mode.title,
                                    detail: mode.explanation,
                                    isSelected: debugTempoMode == mode
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(debugTempoMode == mode ? .isSelected : [])
                        }
                    }

                    if debugTempoMode == .independentReference {
                        VStack(alignment: .leading, spacing: 8) {
                            ControlLabel(
                                title: "BPM 基准音符",
                                value: debugReferenceNote.title
                            )
                            GeoSegmentContainer {
                                ForEach(TempoReferenceNote.tempoReferenceOptions) { note in
                                    GeoSegmentButton(
                                        title: note.shortTitle,
                                        isActive: debugReferenceNote == note
                                    ) {
                                        debugReferenceNoteRaw = note.rawValue
                                        engine.setTempoReferenceNote(note)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            GeoCard {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "底部控件样式", subtitle: "左右滑动即可切换")

                    ForEach(LiquidSelectorStyle.allCases) { style in
                        Button {
                            debugSelectorStyleRaw = style.rawValue
                        } label: {
                            experienceChoiceRow(
                                symbol: selectorStyleSymbol(style),
                                title: selectorStyleTitle(style),
                                detail: selectorStyleExplanation(style),
                                isSelected: debugSelectorStyle == style
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(debugSelectorStyle == style ? .isSelected : [])
                    }

                    Divider()
                        .overlay(GeoTheme.line)

                    VStack(alignment: .leading, spacing: 6) {
                        ControlLabel(title: "即时预览", value: "当前 \(engine.preset.beats) 拍")
                        LiquidScrubSelector(
                            options: Array(3...9),
                            selection: engine.preset.beats,
                            style: debugSelectorStyle,
                            accessibilityLabel: "拍子样式预览",
                            accessibilityValue: { "\($0) 拍" },
                            controlHeight: 48,
                            isEnabled: canEditLiquidControls,
                            onCommit: setBeatCount
                        ) { beats in
                            Text("\(beats)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        Text("这里与底部真实拍子控件同步，可直接试滑；松手后才提交一次。")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(GeoTheme.muted)
                    }
                }
            }

            GeoCard {
                VStack(spacing: 12) {
                    CardTitle(title: "当前效果", subtitle: experienceSummary)
                    experimentMetricRow(
                        title: "BPM 标记",
                        value: "\(plan.referenceNote.title) = \(plan.bpm)"
                    )
                    experimentMetricRow(title: "训练内容", value: engine.preset.subdivisionTitle)
                    experimentMetricRow(
                        title: "实际脉冲速度",
                        value: "\(formattedPulseRate(plan.actualPulsesPerMinute)) 次/分"
                    )
                    experimentMetricRow(
                        title: "脉冲间隔",
                        value: "\(plan.eventInterval.formatted(.number.precision(.fractionLength(3)))) 秒"
                    )
                    experimentMetricRow(title: "每小节", value: "\(plan.eventsPerMeasure) 次")
                    experimentMetricRow(
                        title: "小节时长",
                        value: "\(plan.measureDuration.formatted(.number.precision(.fractionLength(3)))) 秒"
                    )

                    if engine.preset.subdivision == 0 {
                        Text("二分音符沿用既有事件结构：每个主拍触发一次，音符时值用于计算事件间隔。")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(GeoTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        restoreDefaultExperienceSettings()
                    } label: {
                        Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func experienceChoiceRow(
        symbol: String,
        title: String,
        detail: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 11) {
            Text(symbol)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .frame(width: 36, height: 36)
                .background(
                    Color.white.opacity(isSelected ? 0.26 : 0.07),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GeoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)
            if isSelected {
                Text("当前")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Color.white, in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GeoTheme.muted)
            }
        }
        .padding(11)
        .background(
            Color.white.opacity(isSelected ? 0.16 : 0.025),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.62 : 0.09), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }

    private func experienceCurrentRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(GeoTheme.muted)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func experimentMetricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(GeoTheme.muted)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func tempoModeSymbol(_ mode: TempoSemantics) -> String {
        switch mode {
        case .legacyQuarterReference: "♩"
        case .trainingNoteReference: "♪"
        case .independentReference: "双"
        }
    }

    private func tempoModeShortTitle(_ mode: TempoSemantics) -> String {
        switch mode {
        case .legacyQuarterReference: "四分基准"
        case .trainingNoteReference: "训练音符基准"
        case .independentReference: "独立基准"
        }
    }

    private func selectorStyleSymbol(_ style: LiquidSelectorStyle) -> String {
        switch style {
        case .fullTrack: "全"
        case .singleValue: "单"
        case .adjacentCarousel: "邻"
        }
    }

    private func selectorStyleShortTitle(_ style: LiquidSelectorStyle) -> String {
        switch style {
        case .fullTrack: "全部平铺"
        case .singleValue: "只看当前"
        case .adjacentCarousel: "相邻预览"
        }
    }

    private func selectorStyleTitle(_ style: LiquidSelectorStyle) -> String {
        switch style {
        case .fullTrack: "平铺全部选项"
        case .singleValue: "只显示当前值"
        case .adjacentCarousel: "当前值与相邻预览"
        }
    }

    private func selectorStyleExplanation(_ style: LiquidSelectorStyle) -> String {
        switch style {
        case .fullTrack: "所有候选值同时出现，可点击或在整条轨道上滑动。"
        case .singleValue: "框中永远只显示一个结果，左右滑动逐项切换。"
        case .adjacentCarousel: "当前结果居中，前后选项淡化预览，左右滑动切换。"
        }
    }

    private func formattedPulseRate(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return Int(rounded).formatted()
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func synchronizeExperienceSettings() {
        let mode = debugTempoMode
        let reference = mode == .independentReference
            ? engine.preset.referenceNote
            : debugReferenceNote
        if debugTempoModeRaw != mode.rawValue {
            debugTempoModeRaw = mode.rawValue
        }
        if debugReferenceNoteRaw != reference.rawValue {
            debugReferenceNoteRaw = reference.rawValue
        }
        if debugSelectorStyleRaw != debugSelectorStyle.rawValue {
            debugSelectorStyleRaw = LiquidSelectorStyle.adjacentCarousel.rawValue
        }
        engine.setTempoExperiment(semantics: mode, referenceNote: reference)
    }

    private func restoreDefaultExperienceSettings() {
        debugTempoModeRaw = TempoSemantics.independentReference.rawValue
        debugReferenceNoteRaw = TempoReferenceNote.quarter.rawValue
        debugSelectorStyleRaw = LiquidSelectorStyle.adjacentCarousel.rawValue
        engine.setTempoReferenceNote(.quarter)
    }
#endif

    private var practiceCard: some View {
        GeoCard {
            VStack(spacing: 16) {
                CardTitle(title: "本次练习", subtitle: "PRACTICE SESSION")

                if practiceSession.session.phase == .idle {
                    VStack(spacing: 12) {
                        Image(systemName: "timer")
                            .font(.system(size: 28))
                            .foregroundStyle(GeoTheme.muted)
                        Text("开始后默认使用合手模式并自动计时")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GeoTheme.muted)
                        Button("开始练习") {
                            practiceSession.begin(preset: engine.preset)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: sourceEvent == nil ? "person.wave.2" : "music.note.list")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourceEvent.map { "练习：\($0.name)" } ?? "自由练习")
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                            Text(practiceSession.session.sourceEventID == nil
                                 ? "未关联打卡事件"
                                 : sourceEvent == nil ? "原打卡事件已被删除" : "结束后可追加到累计统计")
                                .font(.system(size: 10))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        Spacer()
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let session = practiceSession.session
                        let currentStats = session.stats(for: session.currentHand, at: context.date)
                        VStack(spacing: 5) {
                            Text("\(session.currentHand.title) · 本段计时")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(GeoTheme.muted)
                            Text(practiceDurationString(
                                milliseconds: session.currentSegmentMilliseconds(at: context.date)
                            ))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("本次\(session.currentHand.title)累计 \(practiceDurationString(milliseconds: currentStats.durationMilliseconds))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }

                    GeoSegmentContainer {
                        ForEach(PracticeHand.controlOrder) { hand in
                            GeoSegmentButton(
                                title: hand.title,
                                isActive: practiceSession.session.currentHand == hand
                            ) {
                                requestHandSwitch(to: hand)
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        Text("\(practiceSession.session.currentHand.title)次数")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button {
                            practiceSession.adjustCount(
                                for: practiceSession.session.currentHand,
                                by: -1
                            )
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            practiceSession.session.stats(
                                for: practiceSession.session.currentHand,
                                at: .now
                            ).count == 0
                        )

                        Text("\(practiceSession.session.stats(for: practiceSession.session.currentHand, at: .now).count)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 44)

                        Button {
                            practiceSession.adjustCount(
                                for: practiceSession.session.currentHand,
                                by: 1
                            )
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 8) {
                            ForEach(PracticeHand.controlOrder) { hand in
                                sessionStatCell(for: hand, at: context.date)
                            }
                        }
                    }

                    Toggle("切换手型前确认", isOn: $confirmBeforeHandSwitch)
                        .font(.system(size: 12, weight: .semibold))
                        .tint(.white)

                    Button {
                        finishCurrentSession()
                    } label: {
                        Label("练习完毕", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Color(white: 0.04))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(
                                Color(white: 0.94),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(practiceSession.session.phase == .finished)
                }
            }
        }
    }

    private func sessionStatCell(for hand: PracticeHand, at date: Date) -> some View {
        let stats = practiceSession.session.stats(for: hand, at: date)
        return VStack(spacing: 4) {
            Text(hand.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
            Text("\(stats.count) 次")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(practiceDurationString(milliseconds: stats.durationMilliseconds))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(GeoTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(
            Color(white: 0.04),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private func requestHandSwitch(to hand: PracticeHand) {
        guard hand != practiceSession.session.currentHand else { return }
        if confirmBeforeHandSwitch {
            pendingHandSwitch = hand
        } else {
            practiceSession.switchHand(to: hand)
        }
    }

    private func completeHandSwitch(to hand: PracticeHand) {
        practiceSession.switchHand(to: hand)
        pendingHandSwitch = nil
    }

    private func synchronizeVisualSession() {
        let startedAt = practiceSession.session.startedAt
        guard startedAt != visualSessionStartedAt
                || visualLifecycle.beatCount != engine.preset.beats
        else { return }

        visualSessionStartedAt = startedAt
        visualPulse = nil
        visualFinish = nil
        pendingReviewSummary = nil
        visualLifecycle.reset(beats: engine.preset.beats)
        if practiceSession.session.phase == .finished {
            visualLifecycle.settle()
        }
    }

    private func recordVisualTick(pulseDate: Date) {
        guard visualFinish == nil, pulseDate != .distantPast else { return }
        let snapshot = BeatVisualPulseSnapshot(
            beat: engine.currentBeat,
            subdivision: engine.currentSubdivision,
            pulseDate: pulseDate,
            kind: BeatPulseVisualModel.kind(
                beat: engine.currentBeat,
                subdivision: engine.currentSubdivision,
                strongBeatIndices: engine.preset.strongBeatIndices,
                secondaryAccentIndices: engine.preset.secondaryAccentIndices
            ),
            eventInterval: engine.playbackPlan.eventInterval
        )
        visualPulse = snapshot
        visualLifecycle.record(
            beat: snapshot.beat,
            subdivision: snapshot.subdivision,
            cycle: engine.currentCycle,
            beats: engine.preset.beats
        )
    }

    private func toggleMetronome() {
        guard visualFinish == nil,
              practiceSession.session.phase != .finished
        else { return }

        if engine.isPlaying {
            visualPulse = nil
            visualLifecycle.pause()
            engine.stop()
        } else {
            visualLifecycle.resume()
            engine.start()
        }
    }

    private func finishCurrentSession() {
        guard visualFinish == nil else { return }
        let now = Date.now
        guard let summary = practiceSession.finish(at: now) else { return }

        // A finish action is also available inside a settings sheet. Freeze the
        // exact practice instant immediately, then let the sheet leave before
        // beginning the visible collapse so the user can see it from frame one.
        let presentationDelay: TimeInterval = activePanel == nil ? 0 : 0.36
        activePanel = nil
        let duration: TimeInterval = reduceMotion ? 0.34 : 1.18
        let finish = BeatVisualFinishAnimation(
            id: UUID(),
            startedAt: now.addingTimeInterval(presentationDelay),
            duration: duration,
            visibleBeatIndices: visualLifecycle.visibleBeatIndices
        )

        visualPulse = nil
        visualLifecycle.beginFinishing()
        visualFinish = finish
        pendingReviewSummary = summary
        engine.stop()

        Task { @MainActor in
            let centerHold: TimeInterval = reduceMotion ? 0.08 : 0.16
            let nanoseconds = UInt64(
                (presentationDelay + duration + centerHold) * 1_000_000_000
            )
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard visualFinish?.id == finish.id else { return }
            visualLifecycle.settle()
            visualFinish = nil
            reviewSummary = pendingReviewSummary
            pendingReviewSummary = nil
        }
    }

    private func append(_ summary: PracticeSessionSummary, to event: PracticeEvent) {
        guard !isSavingSummary else { return }
        isSavingSummary = true
        event.append(summary: summary)
        do {
            try modelContext.save()
            isSavingSummary = false
            persistenceError = nil
            reviewSummary = nil
            practiceSession.reset()
            leaveMetronome()
        } catch {
            modelContext.rollback()
            isSavingSummary = false
            persistenceError = "无法追加练习记录：\(error.localizedDescription)"
        }
    }

    private func completeSessionWithoutSaving() {
        guard !isSavingSummary else { return }
        persistenceError = nil
        reviewSummary = nil
        practiceSession.reset()
        leaveMetronome()
    }

    private func continueSession() {
        guard !isSavingSummary else { return }
        persistenceError = nil
        reviewSummary = nil
        pendingReviewSummary = nil
        visualFinish = nil
        visualPulse = nil
        practiceSession.continueAfterReview()
        visualSessionStartedAt = practiceSession.session.startedAt
        visualLifecycle.reset(beats: engine.preset.beats)
    }
}

private struct PracticeSessionSummaryView: View {
    let summary: PracticeSessionSummary
    let sourceEventName: String?
    let persistenceError: String?
    let isSaving: Bool
    let onAppend: (() -> Void)?
    let onDiscard: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 42))
                            Text("本次练习完成")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                            Text(summary.sourceEventID == nil
                                 ? "三种手型的本次统计如下。"
                                 : "请确认本次统计是否追加到练习记录。")
                                .font(.system(size: 12))
                                .foregroundStyle(GeoTheme.muted)
                        }

                        GeoCard {
                            VStack(spacing: 15) {
                                CardTitle(title: "练习汇总", subtitle: "SESSION SUMMARY")
                                ForEach(PracticeHand.controlOrder) { hand in
                                    let stats = summary.stats(for: hand)
                                    HStack {
                                        Text(hand.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        Spacer()
                                        Text("\(stats.count) 次")
                                            .fontWeight(.bold)
                                            .monospacedDigit()
                                        Text(practiceDurationString(milliseconds: stats.durationMilliseconds))
                                            .monospacedDigit()
                                            .frame(minWidth: 78, alignment: .trailing)
                                            .foregroundStyle(GeoTheme.muted)
                                    }
                                    .font(.system(size: 13))
                                }
                                Divider()
                                    .overlay(GeoTheme.line)
                                HStack {
                                    Text("总计")
                                        .fontWeight(.bold)
                                    Spacer()
                                    Text("\(summary.totalCount) 次")
                                        .fontWeight(.bold)
                                        .monospacedDigit()
                                    Text(practiceDurationString(
                                        milliseconds: summary.totalDurationMilliseconds
                                    ))
                                        .fontWeight(.bold)
                                        .monospacedDigit()
                                        .frame(minWidth: 78, alignment: .trailing)
                                }
                                .font(.system(size: 14))
                            }
                        }

                        if let sourceEventName, let onAppend {
                            VStack(spacing: 8) {
                                Text("来源事件：\(sourceEventName)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(GeoTheme.muted)
                                Button(action: onAppend) {
                                    Label("追加并更新“\(sourceEventName)”", systemImage: "tray.and.arrow.down.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .foregroundStyle(.black)
                                .disabled(isSaving)
                            }
                        } else if summary.sourceEventID != nil {
                            Label("原练习记录已被删除，无法追加本次统计。", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.78))
                        } else {
                            Text("这是一次自由练习，没有关联打卡事件。")
                                .font(.system(size: 12))
                                .foregroundStyle(GeoTheme.muted)
                        }

                        if let persistenceError {
                            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.78))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }

                        Button(action: onContinue) {
                            Label("返回继续练习", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)

                        Button(
                            summary.sourceEventID == nil ? "完成" : "仅结束，不保存",
                            role: summary.sourceEventID == nil ? nil : .destructive,
                            action: onDiscard
                        )
                        .frame(minHeight: 44)
                        .disabled(isSaving)

                        if isSaving {
                            ProgressView("正在保存…")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(20)
                }
            }
            .navigationTitle("练习完毕")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A deliberately small two-choice liquid switch for asymmetric meters. Both
/// values stay visible, can be tapped directly, and share the same continuous
/// horizontal scrub behavior as the larger selectors below it.
private struct BeatGroupingSwitch: View {
    let options: [String]
    let selection: String
    let isEnabled: Bool
    let onCommit: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragAxis: DragAxis?
    @State private var dragStartIndex: Int?
    @State private var dragTranslationX: CGFloat?
    @State private var previewIndex: Int?
    @State private var settlingIndex: Int?
    @State private var suppressTap = false
    @State private var tapSuppressionResetID: UUID?
    @State private var settlingResetID: UUID?

    private enum DragAxis {
        case horizontal
        case vertical
    }

    private var selectedIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    private var restingIndex: Int {
        guard !options.isEmpty else { return 0 }
        return clampedIndex(settlingIndex ?? selectedIndex)
    }

    private var displayedIndex: Int {
        guard !options.isEmpty else { return 0 }
        return clampedIndex(previewIndex ?? restingIndex)
    }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 2
            let visualHeight: CGFloat = 20
            let availableWidth = max(0, proxy.size.width - inset * 2)
            let segmentWidth = options.isEmpty
                ? availableWidth
                : availableWidth / CGFloat(options.count)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                    }
                    .frame(height: visualHeight)

                if !options.isEmpty {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.15))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.24), lineWidth: 0.7)
                        }
                        .frame(width: segmentWidth, height: visualHeight - inset * 2)
                        .scaleEffect(
                            x: cursorStretchScale(width: proxy.size.width),
                            y: 1,
                            anchor: cursorStretchAnchor
                        )
                        .offset(
                            x: inset
                                + segmentWidth * continuousPosition(width: proxy.size.width)
                                + directionalOffset(width: proxy.size.width)
                        )
                        .animation(
                            reduceMotion ? nil : settleAnimation,
                            value: selectedIndex
                        )
                }

                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element) { index, grouping in
                        Text(grouping)
                            .font(.system(
                                size: 9,
                                weight: index == displayedIndex ? .bold : .semibold,
                                design: .rounded
                            ))
                            .foregroundStyle(
                                Color.white.opacity(index == displayedIndex ? 0.94 : 0.46)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(groupingDragGesture(width: proxy.size.width))
            .simultaneousGesture(groupingTapGesture(width: proxy.size.width))
        }
        .frame(width: 72, height: 44)
        .opacity(isEnabled ? 1 : 0.46)
        .allowsHitTesting(isEnabled && !options.isEmpty)
        .onDisappear {
            cancelInteraction(preserveTapSuppression: false)
        }
        .onChange(of: options) { _, _ in
            cancelInteraction()
        }
        .onChange(of: selection) { _, _ in
            cancelInteraction()
        }
        .onChange(of: isEnabled) { _, _ in
            cancelInteraction()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("重音分组")
        .accessibilityValue(
            options.indices.contains(selectedIndex) ? options[selectedIndex] : ""
        )
        .accessibilityHint("点按或左右滑动选择；VoiceOver 上下轻扫调整")
        .accessibilityRespondsToUserInteraction(isEnabled && !options.isEmpty)
        .accessibilityAdjustableAction(adjustAccessibilitySelection)
    }

    private func groupingDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard isEnabled, !options.isEmpty else {
                    cancelInteraction()
                    return
                }

                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                if dragAxis == nil {
                    // `SpatialTapGesture` can still recognize a short drag.
                    // Suppress it as soon as the drag gesture becomes active,
                    // including when the persistent lock resolves vertically.
                    tapSuppressionResetID = nil
                    suppressTap = true

                    if horizontal > vertical * 1.08 {
                        dragAxis = .horizontal
                        dragStartIndex = selectedIndex
                        settlingIndex = nil
                        settlingResetID = nil
                    } else if vertical > horizontal * 1.08 {
                        dragAxis = .vertical
                    } else {
                        return
                    }
                }

                guard dragAxis == .horizontal else { return }

                dragTranslationX = value.translation.width
                previewIndex = clampedIndex(
                    Int(
                        continuousPosition(width: width)
                            .rounded(.toNearestOrAwayFromZero)
                    )
                )
            }
            .onEnded { _ in
                guard isEnabled, dragAxis == .horizontal, !options.isEmpty else {
                    cancelInteraction()
                    return
                }

                let targetIndex = clampedIndex(previewIndex ?? selectedIndex)
                scheduleTapSuppressionReset()
                settleAndCommit(to: targetIndex)
            }
    }

    private func groupingTapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard isEnabled,
                      !options.isEmpty,
                      !suppressTap,
                      let targetIndex = tapIndex(at: value.location.x, width: width)
                else { return }
                settleAndCommit(to: targetIndex)
            }
    }

    private func continuousPosition(width: CGFloat) -> CGFloat {
        guard !options.isEmpty else { return 0 }
        let baseIndex = CGFloat(dragStartIndex ?? restingIndex)
        guard dragAxis == .horizontal, let dragTranslationX else {
            return CGFloat(restingIndex)
        }
        let rawPosition = baseIndex + dragTranslationX / pointsPerStep(width: width)
        return min(CGFloat(options.count - 1), max(0, rawPosition))
    }

    private func pointsPerStep(width: CGFloat) -> CGFloat {
        guard !options.isEmpty else { return 1 }
        let visualWidth = max(0, width - 4)
        return max(22, visualWidth / CGFloat(options.count))
    }

    private func cursorStretchPhase(width: CGFloat) -> CGFloat {
        guard !reduceMotion, dragAxis == .horizontal else { return 0 }
        let position = continuousPosition(width: width)
        let distanceFromRest = abs(position - position.rounded())
        return min(1, distanceFromRest * 2)
    }

    private func cursorStretchScale(width: CGFloat) -> CGFloat {
        1 + cursorStretchPhase(width: width) * 0.08
    }

    private var cursorStretchAnchor: UnitPoint {
        guard !reduceMotion,
              dragAxis == .horizontal,
              let dragTranslationX,
              abs(dragTranslationX) > 0.5
        else { return .center }
        return dragTranslationX > 0 ? .leading : .trailing
    }

    private func directionalOffset(width: CGFloat) -> CGFloat {
        guard !reduceMotion,
              let dragTranslationX,
              dragAxis == .horizontal
        else { return 0 }
        let direction: CGFloat = dragTranslationX >= 0 ? 1 : -1
        return direction * cursorStretchPhase(width: width) * 1.2
    }

    private func tapIndex(at x: CGFloat, width: CGFloat) -> Int? {
        guard !options.isEmpty else { return nil }
        let inset: CGFloat = 2
        let availableWidth = max(0, width - inset * 2)
        guard availableWidth > 0 else { return selectedIndex }
        let segmentWidth = availableWidth / CGFloat(options.count)
        let localX = min(availableWidth, max(0, x - inset))
        return clampedIndex(Int(localX / max(1, segmentWidth)))
    }

    private func settleAndCommit(to index: Int) {
        guard options.indices.contains(index) else { return }
        let applySettledState = {
            settlingIndex = index
            clearDragTracking()
        }

        if reduceMotion {
            applySettledState()
        } else {
            withAnimation(settleAnimation) {
                applySettledState()
            }
        }

        scheduleSettlingReset()
        if index != selectedIndex {
            onCommit(options[index])
        }
    }

    private func clearDragTracking() {
        dragAxis = nil
        dragStartIndex = nil
        dragTranslationX = nil
        previewIndex = nil
    }

    private func cancelInteraction(preserveTapSuppression: Bool = true) {
        clearDragTracking()
        settlingIndex = nil
        settlingResetID = nil

        if preserveTapSuppression, suppressTap {
            scheduleTapSuppressionReset()
        } else {
            suppressTap = false
            tapSuppressionResetID = nil
        }
    }

    private func scheduleTapSuppressionReset() {
        let interactionID = UUID()
        tapSuppressionResetID = interactionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard tapSuppressionResetID == interactionID else { return }
            suppressTap = false
            tapSuppressionResetID = nil
        }
    }

    private func scheduleSettlingReset() {
        let interactionID = UUID()
        settlingResetID = interactionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard settlingResetID == interactionID else { return }
            settlingResetID = nil
            if reduceMotion {
                settlingIndex = nil
            } else {
                withAnimation(settleAnimation) {
                    settlingIndex = nil
                }
            }
        }
    }

    private func adjustAccessibilitySelection(
        _ direction: AccessibilityAdjustmentDirection
    ) {
        guard isEnabled, !options.isEmpty else { return }
        let delta: Int
        switch direction {
        case .increment:
            delta = 1
        case .decrement:
            delta = -1
        @unknown default:
            return
        }
        settleAndCommit(to: clampedIndex(selectedIndex + delta))
    }

    private func clampedIndex(_ index: Int) -> Int {
        guard !options.isEmpty else { return 0 }
        return min(options.count - 1, max(0, index))
    }

    private var settleAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.78, blendDuration: 0.08)
    }
}

private struct MetronomeCanvas: View {
    let preset: MetronomePreset
    let playbackPlan: MetronomePlaybackPlan
    let lifecycle: BeatVisualLifecycle
    let pulse: BeatVisualPulseSnapshot?
    let finishAnimation: BeatVisualFinishAnimation?
    let isPlaying: Bool
    let reduceMotion: Bool
    let dimFlashingLights: Bool

    private var timelineIsPaused: Bool {
        if finishAnimation != nil || isPlaying { return false }
        switch lifecycle.phase {
        case .origin, .settled:
            return reduceMotion
        case .orbiting, .finishing:
            return true
        }
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 60,
            paused: timelineIsPaused
        )) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let shortestSide = min(size.width, size.height)
                let radius = shortestSide * 0.28
                let effectScale = min(1, shortestSide / 360)
                let points = polygonPoints(center: center, radius: radius)

                if let finishAnimation {
                    drawFinishAnimation(
                        finishAnimation,
                        at: timeline.date,
                        center: center,
                        points: points,
                        effectScale: effectScale,
                        in: &context
                    )
                } else if lifecycle.phase == .origin || lifecycle.phase == .settled {
                    drawWaitingPoint(
                        at: center,
                        date: timeline.date,
                        effectScale: effectScale,
                        in: &context
                    )
                } else {
                    drawPlayingGeometry(
                        pulse: isPlaying ? pulse : nil,
                        at: timeline.date,
                        points: points,
                        effectScale: effectScale,
                        in: &context
                    )
                }
            }
        }
    }

    private func polygonPoints(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        let directionSign: CGFloat = preset.direction == .counterclockwise ? -1 : 1
        let step = CGFloat.pi * 2 / CGFloat(preset.beats)
        return (0..<preset.beats).map { index in
            let angle = -CGFloat.pi / 2 + directionSign * CGFloat(index) * step
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
    }

    private func drawPlayingGeometry(
        pulse: BeatVisualPulseSnapshot?,
        at date: Date,
        points: [CGPoint],
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        for index in lifecycle.visibleBeatIndices where points.indices.contains(index) {
            let isCurrentMainBeat = lifecycle.currentBeatIndex == index
            drawAnchor(
                at: points[index],
                opacity: isCurrentMainBeat ? 0.42 : 0.20,
                scale: effectScale,
                radiusMultiplier: isCurrentMainBeat ? 1.18 : 1,
                in: &context
            )
        }

        guard let pulse,
              let address = BeatPulseVisualModel.address(
                beat: pulse.beat,
                subdivision: pulse.subdivision,
                beats: preset.beats,
                pulsesPerBeat: playbackPlan.pulsesPerBeat
              ),
              let position = pulsePosition(for: address, points: points)
        else { return }

        let style = BeatPulseVisualModel.style(
            for: pulse.kind,
            eventInterval: pulse.eventInterval,
            dimFlashingLights: dimFlashingLights
        )
        let age = max(0, date.timeIntervalSince(pulse.pulseDate))
        let envelope = BeatPulseVisualModel.envelope(age: age, duration: style.duration)
        guard envelope > 0 else { return }

        drawHit(
            at: position,
            style: style,
            envelope: envelope,
            effectScale: effectScale,
            in: &context
        )
    }

    private func pulsePosition(
        for address: BeatPulseAddress,
        points: [CGPoint]
    ) -> CGPoint? {
        guard points.indices.contains(address.beat) else { return nil }
        let next = (address.beat + 1) % points.count
        let fraction = CGFloat(address.phase - Double(address.beat))
        return interpolate(
            from: points[address.beat],
            to: points[next],
            progress: fraction
        )
    }

    private func drawAnchor(
        at point: CGPoint,
        opacity: Double,
        scale: CGFloat,
        radiusMultiplier: CGFloat = 1,
        in context: inout GraphicsContext
    ) {
        let radius = 3.5 * scale * radiusMultiplier
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }

    private func drawHit(
        at point: CGPoint,
        style: BeatPulseStyle,
        envelope: Double,
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        // A restrained drum-like Hit: immediate peak, then a fast monotonic
        // falloff. There is no glow ring, travelling head, trail, or breath.
        let radius = CGFloat(style.peakRadius * (0.58 + 0.42 * envelope)) * effectScale
        let opacity = style.peakOpacity * envelope
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }

    private func drawWaitingPoint(
        at point: CGPoint,
        date: Date,
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        let wave = reduceMotion
            ? 0.5
            : 0.5 + 0.5 * sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 2.8)
        let radius = (7.4 + CGFloat(wave) * 0.9) * effectScale
        let opacity = 0.52 + wave * 0.30
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }

    private func drawFinishAnimation(
        _ finish: BeatVisualFinishAnimation,
        at date: Date,
        center: CGPoint,
        points: [CGPoint],
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard !finish.visibleBeatIndices.isEmpty else {
            drawWaitingPoint(
                at: center,
                date: date,
                effectScale: effectScale,
                in: &context
            )
            return
        }

        let rawProgress = min(1, max(0, date.timeIntervalSince(finish.startedAt) / finish.duration))
        let progress = CGFloat(rawProgress)
        let eased = progress * progress * (3 - 2 * progress)
        let remaining = Double(pow(max(0, 1 - eased), 1.35))
        let visualScale = reduceMotion ? 1 : max(0.08, 1 - eased * 0.88)

        for index in finish.visibleBeatIndices where points.indices.contains(index) {
            let original = points[index]
            let position = reduceMotion
                ? original
                : interpolate(from: original, to: center, progress: eased)
            drawAnchor(
                at: position,
                opacity: 0.24 * remaining,
                scale: effectScale * visualScale,
                in: &context
            )
        }

        let centerProgress = min(1, max(0, (progress - 0.72) / 0.28))
        if centerProgress > 0 {
            drawOriginDisc(
                at: center,
                opacity: Double(centerProgress) * 0.72,
                scale: reduceMotion
                    ? effectScale
                    : effectScale * (0.72 + centerProgress * 0.28),
                in: &context
            )
        }
    }

    private func drawOriginDisc(
        at point: CGPoint,
        opacity: Double,
        scale: CGFloat,
        in context: inout GraphicsContext
    ) {
        let radius = 8.0 * scale
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }

    private func interpolate(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        let progress = min(1, max(0, progress))
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}
