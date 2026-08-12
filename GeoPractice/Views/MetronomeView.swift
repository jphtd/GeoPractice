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

struct MetronomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]

    @ObservedObject var engine: MetronomeEngine
    @ObservedObject var practiceSession: PracticeSessionController
    let finishPractice: () -> Void

    @AppStorage("confirmBeforeHandSwitch") private var confirmBeforeHandSwitch = true
    @State private var pendingHandSwitch: PracticeHand?
    @State private var reviewSummary: PracticeSessionSummary?
    @State private var persistenceError: String?
    @State private var isSavingSummary = false
    @State private var activePanel: MetronomePanel?
    @State private var tempoDraftBPM: Double?

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
            if reviewSummary == nil {
                reviewSummary = practiceSession.session.reviewSummary
            }
        }
        .onChange(of: engine.preset) { _, preset in
            practiceSession.updatePreset(preset)
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
                        finishPractice()
                    } label: {
                        Label("打卡记录", systemImage: "checklist")
                    }

                    Divider()

                    Button {
                        engine.toggle()
                    } label: {
                        Label(
                            engine.isPlaying ? "暂停节拍器" : "开始节拍器",
                            systemImage: engine.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }

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
                              || practiceSession.session.phase == .finished)
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
            engine.toggle()
        } label: {
            ZStack {
                MetronomeCanvas(
                    preset: engine.preset,
                    currentBeat: engine.currentBeat,
                    currentSubdivision: engine.currentSubdivision,
                    currentCycle: engine.currentCycle,
                    lastPulseDate: engine.lastPulseDate,
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
                            .fill(engine.isPlaying ? Color.white : GeoTheme.muted)
                            .frame(width: 5, height: 5)
                        Text(engine.isPlaying ? "轻点暂停" : "轻点开始")
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
        .accessibilityLabel(engine.isPlaying ? "暂停节拍器" : "开始节拍器")
        .accessibilityValue("\(engine.preset.beats) 拍，\(engine.preset.tempoDisplay)，\(engine.preset.subdivisionTitle)")
    }

    private var v4PrimaryControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                GeoGlassCapsule {
                    Menu {
                        ForEach(3...9, id: \.self) { beats in
                            Button {
                                engine.setBeats(beats)
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
                    .accessibilityLabel("选择拍数")
                    .accessibilityValue("\(engine.preset.beats) 拍")
                }
                .frame(width: 58)

                GeoGlassCapsule {
                    Button {
                        activePanel = .tempo
                    } label: {
                        VStack(spacing: 0) {
                            Text(engine.preset.tempoName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(engine.preset.bpm)")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(width: 136, height: 58)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置速度")
                    .accessibilityValue(engine.preset.tempoDisplay)
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

    private var structureCard: some View {
        GeoCard {
            VStack(spacing: 18) {
                CardTitle(title: "节拍结构", subtitle: "STRUCTURE")

                VStack(spacing: 10) {
                    ControlLabel(title: "每小节拍数", value: "\(engine.preset.beats) 拍")
                    HStack(spacing: 5) {
                        ForEach(3...9, id: \.self) { beats in
                            Button {
                                engine.setBeats(beats)
                            } label: {
                                Text("\(beats)")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(engine.preset.beats == beats ? .white : GeoTheme.muted)
                                    .background {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(engine.preset.beats == beats ? Color.white.opacity(0.10) : Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .stroke(engine.preset.beats == beats ? Color.white.opacity(0.55) : GeoTheme.line, lineWidth: 1)
                                            }
                                    }
                            }
                            .buttonStyle(.plain)
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
                    ControlLabel(title: "运行方向", value: engine.preset.direction.title)
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
                VStack(spacing: 10) {
                    let displayedBPM = Int((tempoDraftBPM ?? Double(engine.preset.bpm)).rounded())
                    ControlLabel(title: "每分钟节拍", value: "\(displayedBPM) BPM")
                    Slider(
                        value: Binding(
                            get: { tempoDraftBPM ?? Double(engine.preset.bpm) },
                            set: { tempoDraftBPM = $0 }
                        ),
                        in: 30...240,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if isEditing {
                                if tempoDraftBPM == nil {
                                    tempoDraftBPM = Double(engine.preset.bpm)
                                }
                            } else if let draft = tempoDraftBPM {
                                tempoDraftBPM = nil
                                engine.setBPM(Int(draft.rounded()))
                            }
                        }
                    )
                    .tint(Color(white: 0.93))
                    .accessibilityLabel("每分钟节拍")
                    .accessibilityValue("\(displayedBPM) BPM")
                }
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
            Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255),
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

    private func finishCurrentSession() {
        engine.stop()
        activePanel = nil
        let summary = practiceSession.finish()
        Task { @MainActor in
            await Task.yield()
            reviewSummary = summary
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
            finishPractice()
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
        finishPractice()
    }

    private func continueSession() {
        guard !isSavingSummary else { return }
        persistenceError = nil
        reviewSummary = nil
        practiceSession.continueAfterReview()
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
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("这是一次自由练习，没有关联打卡事件。")
                                .font(.system(size: 12))
                                .foregroundStyle(GeoTheme.muted)
                        }

                        if let persistenceError {
                            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    Color.orange.opacity(0.10),
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
    let currentBeat: Int
    let currentSubdivision: Int
    let currentCycle: Int
    let lastPulseDate: Date
    let isPlaying: Bool
    let reduceMotion: Bool
    let dimFlashingLights: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: reduceMotion || dimFlashingLights ? 0.08 : nil,
            paused: !isPlaying
        )) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                guard isPlaying, lastPulseDate != .distantPast else {
                    drawOriginPoint(at: center, in: &context)
                    return
                }

                let shortestSide = min(size.width, size.height)
                let radius = shortestSide * 0.28
                let effectScale = min(1, shortestSide / 360)
                let directionSign: CGFloat = preset.direction == .counterclockwise ? -1 : 1
                let step = CGFloat.pi * 2 / CGFloat(preset.beats)
                let elapsed = max(0, timeline.date.timeIntervalSince(lastPulseDate))
                let eventInterval = 60 / Double(preset.bpm) / preset.eventDensity
                let points = (0..<preset.beats).map { index in
                    let angle = -CGFloat.pi / 2 + directionSign * CGFloat(index) * step
                    return CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                }

                let safeBeat = min(max(0, currentBeat), points.count - 1)
                let currentPoint = points[safeBeat]
                let nextPoint = points[(safeBeat + 1) % points.count]
                let liveProgress = (
                    Double(currentSubdivision) + min(1, elapsed / eventInterval)
                ) / Double(preset.pulsesPerBeat)
                let progress = reduceMotion
                    ? CGFloat(currentSubdivision) / CGFloat(preset.pulsesPerBeat)
                    : CGFloat(min(1, max(0, liveProgress)))

                if currentBeat == 0, currentCycle > 0 {
                    drawCycleTransition(
                        center: center,
                        points: points,
                        progress: CGFloat(min(1, max(0, liveProgress))),
                        eventProgress: CGFloat(currentSubdivision) / CGFloat(preset.pulsesPerBeat),
                        elapsed: elapsed,
                        effectScale: effectScale,
                        in: &context
                    )
                    return
                }

                if currentBeat == 0, currentCycle == 0 {
                    drawInitialLaunch(
                        center: center,
                        points: points,
                        progress: progress,
                        eventProgress: CGFloat(currentSubdivision) / CGFloat(preset.pulsesPerBeat),
                        elapsed: elapsed,
                        effectScale: effectScale,
                        in: &context
                    )
                    return
                }

                let movingPoint = CGPoint(
                    x: currentPoint.x + (nextPoint.x - currentPoint.x) * progress,
                    y: currentPoint.y + (nextPoint.y - currentPoint.y) * progress
                )

                drawGrowingPath(
                    points: points,
                    through: safeBeat,
                    movingPoint: movingPoint,
                    in: &context
                )

                for index in 0...safeBeat {
                    drawResidualNode(
                        at: points[index],
                        strength: accentStrength(for: index),
                        isCurrent: index == safeBeat,
                        in: &context
                    )
                }

                if progress > 0.015 {
                    drawMovingPoint(at: movingPoint, in: &context)
                }

                let isMainBeat = currentSubdivision == 0
                let pulse = exp(-elapsed / (isMainBeat ? 0.18 : 0.075))
                if pulse > 0.015, isMainBeat || !dimFlashingLights {
                    let eventProgress = CGFloat(currentSubdivision) / CGFloat(preset.pulsesPerBeat)
                    let pulsePoint = interpolate(from: currentPoint, to: nextPoint, progress: eventProgress)
                    drawPulse(
                        at: pulsePoint,
                        strength: accentStrength(for: safeBeat),
                        pulse: pulse,
                        isMainBeat: isMainBeat,
                        effectScale: effectScale,
                        in: &context
                    )
                }
            }
        }
    }

    private func accentStrength(for index: Int) -> Double {
        if preset.strongBeatIndices.contains(index) { return 1 }
        if preset.secondaryAccentIndices.contains(index) { return 0.72 }
        return 0.46
    }

    private func drawInitialLaunch(
        center: CGPoint,
        points: [CGPoint],
        progress: CGFloat,
        eventProgress: CGFloat,
        elapsed: TimeInterval,
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard let first = points.first else { return }
        let launchEnd: CGFloat = 0.20
        let visualProgress = min(1, max(0, progress))

        if visualProgress < launchEnd {
            let position = reduceMotion
                ? center
                : interpolate(from: center, to: first, progress: visualProgress / launchEnd)
            drawOriginPoint(at: position, in: &context)
        } else {
            let edgeProgress = reduceMotion ? 0 : (visualProgress - launchEnd) / (1 - launchEnd)
            let movingPoint = interpolate(from: first, to: points[1], progress: edgeProgress)
            drawGrowingPath(points: points, through: 0, movingPoint: movingPoint, in: &context)
            drawResidualNode(at: first, strength: 1, isCurrent: true, in: &context)
            if edgeProgress > 0.015 {
                drawMovingPoint(at: movingPoint, in: &context)
            }
        }

        let isMainBeat = currentSubdivision == 0
        let pulse = exp(-elapsed / (isMainBeat ? 0.18 : 0.075))
        guard pulse > 0.015, isMainBeat || !dimFlashingLights else { return }
        let pulsePoint: CGPoint
        if eventProgress < launchEnd {
            pulsePoint = reduceMotion
                ? center
                : interpolate(from: center, to: first, progress: eventProgress / launchEnd)
        } else {
            let edgeProgress = reduceMotion ? 0 : (eventProgress - launchEnd) / (1 - launchEnd)
            pulsePoint = interpolate(from: first, to: points[1], progress: edgeProgress)
        }
        drawPulse(
            at: pulsePoint,
            strength: 1,
            pulse: pulse,
            isMainBeat: isMainBeat,
            effectScale: effectScale,
            in: &context
        )
    }

    private func drawCycleTransition(
        center: CGPoint,
        points: [CGPoint],
        progress: CGFloat,
        eventProgress: CGFloat,
        elapsed: TimeInterval,
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard let first = points.first else { return }
        let fadeEnd: CGFloat = 0.46
        let pointEnd: CGFloat = 0.60
        let launchEnd: CGFloat = 0.74
        let visualProgress = min(1, max(0, progress))

        if visualProgress < fadeEnd {
            let fade = Double(1 - visualProgress / fadeEnd)
            drawCompletedShape(points: points, opacity: fade, in: &context)
        } else if visualProgress < pointEnd {
            drawOriginPoint(at: center, in: &context)
        } else if visualProgress < launchEnd {
            let launchProgress = (visualProgress - pointEnd) / (launchEnd - pointEnd)
            let position = reduceMotion
                ? center
                : interpolate(from: center, to: first, progress: launchProgress)
            drawOriginPoint(at: position, in: &context)
        } else {
            let edgeProgress = reduceMotion ? 0 : (visualProgress - launchEnd) / (1 - launchEnd)
            let movingPoint = interpolate(from: first, to: points[1], progress: edgeProgress)
            drawGrowingPath(points: points, through: 0, movingPoint: movingPoint, in: &context)
            drawResidualNode(at: first, strength: 1, isCurrent: true, in: &context)
            if edgeProgress > 0.015 {
                drawMovingPoint(at: movingPoint, in: &context)
            }
        }

        let isMainBeat = currentSubdivision == 0
        let pulse = exp(-elapsed / (isMainBeat ? 0.18 : 0.075))
        guard pulse > 0.015, isMainBeat || !dimFlashingLights else { return }
        let pulsePoint = transitionPoint(
            center: center,
            first: first,
            second: points[1],
            progress: eventProgress,
            fadeEnd: fadeEnd,
            pointEnd: pointEnd,
            launchEnd: launchEnd
        )
        drawPulse(
            at: pulsePoint,
            strength: 1,
            pulse: pulse,
            isMainBeat: isMainBeat,
            effectScale: effectScale,
            in: &context
        )
    }

    private func transitionPoint(
        center: CGPoint,
        first: CGPoint,
        second: CGPoint,
        progress: CGFloat,
        fadeEnd: CGFloat,
        pointEnd: CGFloat,
        launchEnd: CGFloat
    ) -> CGPoint {
        if progress < fadeEnd { return first }
        if progress < pointEnd { return center }
        if progress < launchEnd {
            return reduceMotion
                ? center
                : interpolate(
                    from: center,
                    to: first,
                    progress: (progress - pointEnd) / (launchEnd - pointEnd)
                )
        }
        let edgeProgress = reduceMotion ? 0 : (progress - launchEnd) / (1 - launchEnd)
        return interpolate(from: first, to: second, progress: edgeProgress)
    }

    private func interpolate(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        let progress = min(1, max(0, progress))
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func drawOriginPoint(at point: CGPoint, in context: inout GraphicsContext) {
        let radius: CGFloat = 9
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.42), radius: 18))
        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.92)))
    }

    private func drawGrowingPath(
        points: [CGPoint],
        through currentIndex: Int,
        movingPoint: CGPoint,
        in context: inout GraphicsContext
    ) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        if currentIndex > 0 {
            for index in 1...currentIndex {
                path.addLine(to: points[index])
            }
        }
        path.addLine(to: movingPoint)

        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.18), radius: 10))
        layer.stroke(
            path,
            with: .color(.white.opacity(0.27)),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawCompletedShape(
        points: [CGPoint],
        opacity: Double,
        in context: inout GraphicsContext
    ) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.24 * opacity), radius: 16))
        layer.stroke(
            path,
            with: .color(.white.opacity(0.38 * opacity)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )

        for point in points {
            let radius: CGFloat = 5.5
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.42 * opacity)))
        }
    }

    private func drawResidualNode(
        at point: CGPoint,
        strength: Double,
        isCurrent: Bool,
        in context: inout GraphicsContext
    ) {
        let radius: CGFloat = isCurrent ? 6.5 : 4.5 + CGFloat(strength) * 1.5
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.13 + strength * 0.12), radius: 9))
        layer.fill(
            Path(ellipseIn: rect),
            with: .color(.white.opacity(isCurrent ? 0.78 : 0.24 + strength * 0.18))
        )
    }

    private func drawMovingPoint(at point: CGPoint, in context: inout GraphicsContext) {
        let radius: CGFloat = 3.2
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.34), radius: 11))
        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.68)))
    }

    private func drawPulse(
        at point: CGPoint,
        strength: Double,
        pulse: Double,
        isMainBeat: Bool,
        effectScale: CGFloat,
        in context: inout GraphicsContext
    ) {
        let restrained = reduceMotion || dimFlashingLights
        let visualPulse = restrained ? min(1, pulse) * 0.20 : pulse
        let burst = (isMainBeat ? 24 + CGFloat(strength) * 18 : 8) * effectScale
        let radius = 7 * effectScale + CGFloat(visualPulse) * burst
        let alpha = dimFlashingLights
            ? pulse * 0.16 * strength
            : max(0.10, pulse * (isMainBeat ? strength : 0.26))
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        var layer = context
        if !dimFlashingLights {
            let shadowRadius = (isMainBeat ? 26 + CGFloat(pulse) * 42 : 12) * effectScale
            layer.addFilter(.shadow(color: .white.opacity(min(0.9, alpha)), radius: shadowRadius))
        }
        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))

        if isMainBeat, !restrained {
            let ringRadius = radius + (10 + CGFloat(pulse) * 7) * effectScale
            let ring = CGRect(x: point.x - ringRadius, y: point.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(alpha * 0.22)), lineWidth: 2)
        }
    }
}
