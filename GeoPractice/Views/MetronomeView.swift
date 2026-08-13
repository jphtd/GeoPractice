import SwiftData
import SwiftUI

private enum MetronomePanel: String, Identifiable {
    case session
    case structure
    case tempo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "本次练习"
        case .structure: "节拍设置"
        case .tempo: "速度设置"
        }
    }
}

private struct BeatVisualPulseSnapshot: Equatable {
    let beat: Int
    let subdivision: Int
    let pulseDate: Date
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]

    @ObservedObject var engine: MetronomeEngine
    @ObservedObject var practiceSession: PracticeSessionController
    let leaveMetronome: () -> Void

    @AppStorage("confirmBeforeHandSwitch") private var confirmBeforeHandSwitch = true
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            practiceQuickDock
                .padding(.top, 8)
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
            synchronizeVisualSession()
            if reviewSummary == nil, visualFinish == nil {
                reviewSummary = practiceSession.session.reviewSummary
            }
        }
        .onChange(of: engine.preset) { _, preset in
            practiceSession.updatePreset(preset)
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
        let landscape = size.width > size.height && compactHeight

        return Group {
            if landscape {
                HStack(spacing: 14) {
                    VStack(spacing: 4) {
                        v4Header
                        v4Stage
                            .frame(maxHeight: .infinity)
                    }
                    v4PrimaryControls
                        .frame(width: 282)
                }
            } else {
                VStack(spacing: compactHeight ? 6 : 12) {
                    v4Header
                    v4Stage
                        .frame(maxHeight: .infinity)
                    v4PrimaryControls
                }
            }
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

            VStack(spacing: 2) {
                Text("GeoBeat")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                Text(sourceEvent?.name ?? "自由练习")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

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
        .frame(height: 54)
    }

    private var v4Stage: some View {
        Button {
            toggleMetronome()
        } label: {
            ZStack {
                MetronomeCanvas(
                    preset: engine.preset,
                    lifecycle: visualLifecycle,
                    pulse: visualPulse,
                    finishAnimation: visualFinish,
                    isPlaying: engine.isPlaying,
                    reduceMotion: reduceMotion,
                    dimFlashingLights: dimFlashingLights
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 680, maxHeight: 680)

                VStack {
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
                    .padding(.bottom, 2)
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

    private var v4PrimaryControls: some View {
        let canChangeTopology = visualLifecycle.phase == .origin

        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                GeoGlassCapsule {
                    Menu {
                        ForEach(3...9, id: \.self) { beats in
                            Button {
                                setBeatCountIfAllowed(beats)
                            } label: {
                                if engine.preset.beats == beats {
                                    Label("\(beats) 拍", systemImage: "checkmark")
                                } else {
                                    Text("\(beats) 拍")
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 0) {
                            Text("\(engine.preset.beats)")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                            Text("拍")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canChangeTopology)
                    .accessibilityLabel("选择拍数")
                    .accessibilityValue(
                        canChangeTopology
                            ? "\(engine.preset.beats) 拍"
                            : "\(engine.preset.beats) 拍，本次练习已锁定"
                    )
                }
                .frame(width: 58)

                GeoGlassCapsule {
                    TempoScrubber(
                        bpm: engine.preset.bpm,
                        compact: true,
                        onTap: {
                            activePanel = .tempo
                        },
                        onCommit: { bpm in
                            engine.setBPM(bpm)
                        }
                    )
                    .frame(width: 136, height: 58)
                }
                .frame(width: 136)

                GeoGlassCapsule {
                    Menu {
                        ForEach(MetronomePreset.supportedSubdivisions, id: \.self) { subdivision in
                            Button {
                                engine.setSubdivision(subdivision)
                            } label: {
                                let title = subdivisionTitle(for: subdivision)
                                if engine.preset.subdivision == subdivision {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "music.note")
                                .font(.system(size: 20, weight: .semibold))
                            Text(engine.preset.subdivisionShortTitle)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 58, height: 58)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择训练音符")
                    .accessibilityValue(engine.preset.subdivisionTitle)
                }
                .frame(width: 58)
            }

            let groupings = MetronomePreset.groupings(for: engine.preset.beats)
            if groupings.count > 1 {
                GeoGlassCapsule {
                    HStack(spacing: 4) {
                        ForEach(groupings, id: \.self) { grouping in
                            Button(grouping) {
                                engine.setGrouping(grouping)
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background {
                                if engine.preset.grouping == grouping {
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(grouping) 分组")
                            .accessibilityAddTraits(
                                engine.preset.grouping == grouping ? .isSelected : []
                            )
                        }
                    }
                    .padding(4)
                    .frame(width: 210)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: engine.preset.beats)
        .disabled(visualFinish != nil || practiceSession.session.phase == .finished)
    }

    private var practiceQuickDock: some View {
        let session = practiceSession.session
        let hand = session.currentHand
        let count = session.stats(for: hand, at: .now).count
        let canEdit = session.phase == .running || session.phase == .paused

        let incrementControl = GeoGlassCapsule {
            Button {
                practiceSession.adjustCount(for: hand, by: 1)
            } label: {
                ZStack {
                    Text("+1")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack {
                        Spacer()
                        Text("\(hand.shortTitle) · \(count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 18)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .accessibilityLabel("为当前\(hand.title)增加一次")
            .accessibilityValue("当前 \(count) 次")
        }

        let handControl = GeoGlassCapsule {
            HStack(spacing: 4) {
                ForEach(PracticeHand.controlOrder) { item in
                    Button {
                        requestHandSwitch(to: item)
                    } label: {
                        Text(item.shortTitle)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background {
                                if hand == item {
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.17))
                                        .overlay {
                                            Capsule(style: .continuous)
                                                .stroke(Color.white.opacity(0.30), lineWidth: 1)
                                        }
                                }
                            }
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEdit)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(hand == item ? "已选择" : "")
                    .accessibilityAddTraits(hand == item ? .isSelected : [])
                }
            }
            .padding(5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("练习手型")
        }

        return Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 10) {
                    incrementControl
                    handControl
                }
                .frame(maxWidth: 620)
            } else {
                VStack(spacing: 10) {
                    incrementControl
                    handControl
                }
                .frame(maxWidth: 460)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: hand)
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
        .presentationDetents([.medium, .large])
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

    private func setBeatCountIfAllowed(_ beats: Int) {
        guard visualLifecycle.phase == .origin,
              visualFinish == nil,
              practiceSession.session.phase != .finished
        else { return }
        engine.setBeats(beats)
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
                                setBeatCountIfAllowed(beats)
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
                            .disabled(visualLifecycle.phase != .origin)
                            .accessibilityAddTraits(engine.preset.beats == beats ? .isSelected : [])
                        }
                    }
                    if visualLifecycle.phase != .origin {
                        Text("节拍运行后，本次练习的拍数会保持不变")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(GeoTheme.muted)
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
            pulseDate: pulseDate
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

private struct MetronomeCanvas: View {
    let preset: MetronomePreset
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
            drawAnchor(
                at: points[index],
                opacity: 0.24,
                scale: effectScale,
                in: &context
            )
        }

        guard let pulse,
              let address = BeatPulseVisualModel.address(
                beat: pulse.beat,
                subdivision: pulse.subdivision,
                beats: preset.beats,
                pulsesPerBeat: preset.pulsesPerBeat
              ),
              let position = pulsePosition(for: address, points: points)
        else { return }

        let kind = BeatPulseVisualModel.kind(
            beat: pulse.beat,
            subdivision: pulse.subdivision,
            strongBeatIndices: preset.strongBeatIndices,
            secondaryAccentIndices: preset.secondaryAccentIndices
        )
        let style = BeatPulseVisualModel.style(
            for: kind,
            eventInterval: preset.eventInterval,
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
        in context: inout GraphicsContext
    ) {
        let radius = 3.5 * scale
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
