import SwiftData
import SwiftUI

struct MetronomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]

    @ObservedObject var engine: MetronomeEngine
    @ObservedObject var practiceSession: PracticeSessionController
    let finishPractice: () -> Void

    @AppStorage("confirmBeforeHandSwitch") private var confirmBeforeHandSwitch = true
    @State private var pendingHandSwitch: PracticeHand?
    @State private var reviewSummary: PracticeSessionSummary?
    @State private var persistenceError: String?
    @State private var isSavingSummary = false

    private var sourceEvent: PracticeEvent? {
        guard let id = practiceSession.session.sourceEventID else { return nil }
        return events.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            GeoBackground()

            VStack(spacing: 0) {
                header

                GeometryReader { geometry in
                    responsiveContent(width: geometry.size.width)
                }
            }
        }
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

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                GeoBrand()
                Spacer()
                statusLabel(showsText: true)
            }
            HStack {
                GeoBrand(compact: true)
                Spacer()
                statusLabel(showsText: false)
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    private func statusLabel(showsText: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.white.opacity(0.86))
                .frame(width: 7, height: 7)
                .shadow(color: .white.opacity(0.65), radius: 4.5)
            if showsText {
                Text("固定节点 · 同步脉冲")
                    .font(.system(size: 13))
                    .foregroundStyle(GeoTheme.muted)
            }
        }
    }

    @ViewBuilder
    private func responsiveContent(width: CGFloat) -> some View {
        if width > 900 {
            HStack(alignment: .top, spacing: 18) {
                metronomeStage(compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(spacing: 18) {
                        practiceCard
                        structureCard
                        tempoCard
                    }
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .frame(width: 340)
            }
            .padding(20)
        } else if width > 620 {
            ScrollView {
                VStack(spacing: 18) {
                    metronomeStage(compact: false)
                        .frame(minHeight: 650)
                    practiceCard
                        .frame(maxWidth: .infinity)
                    HStack(alignment: .top, spacing: 18) {
                        structureCard
                            .frame(maxWidth: .infinity)
                        tempoCard
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    metronomeStage(compact: true)
                        .frame(minHeight: 570)
                    practiceCard
                    structureCard
                    tempoCard
                }
                .padding(10)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func metronomeStage(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("STABLE SPATIAL RHYTHM")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.8)
                        .foregroundStyle(Color(white: 0.74))
                    Text("看见节拍")
                        .font(.system(size: compact ? 28 : 36, weight: .bold, design: .rounded))
                        .tracking(-1.1)
                    if !compact {
                        Text("固定节点 · 无边界线 · 爆闪与呼吸")
                            .font(.system(size: 13))
                            .foregroundStyle(GeoTheme.muted)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("速度术语")
                        .font(.system(size: 11))
                        .foregroundStyle(GeoTheme.muted)
                    Text(engine.preset.tempoDisplay)
                        .font(.system(size: compact ? 13 : 16, weight: .semibold))
                        .foregroundStyle(Color(white: 0.93))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, compact ? 20 : 26)
            .padding(.top, compact ? 20 : 24)

            MetronomeCanvas(
                preset: engine.preset,
                currentBeat: engine.currentBeat,
                currentSubdivision: engine.currentSubdivision,
                lastPulseDate: engine.lastPulseDate,
                isPlaying: engine.isPlaying,
                reduceMotion: reduceMotion
            )
            .aspectRatio(5 / 4, contentMode: .fit)
            .frame(maxWidth: 640, maxHeight: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("动态节拍多边形")
            .accessibilityValue("\(engine.preset.beats) 拍，\(engine.preset.tempoDisplay)")

            HStack(spacing: 12) {
                transportButton(symbol: "minus", label: "速度减一", size: 48) {
                    engine.nudgeBPM(by: -1)
                }
                transportButton(
                    symbol: engine.isPlaying ? "pause.fill" : "play.fill",
                    label: engine.isPlaying ? "暂停" : "播放",
                    size: 72,
                    primary: true
                ) {
                    engine.toggle()
                }
                transportButton(symbol: "plus", label: "速度加一", size: 48) {
                    engine.nudgeBPM(by: 1)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
        .foregroundStyle(GeoTheme.text)
        .background {
            RoundedRectangle(cornerRadius: compact ? 22 : 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.1).opacity(0.96), Color(white: 0.04).opacity(0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 22 : 28, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 30, y: 20)
        }
        .contentShape(RoundedRectangle(cornerRadius: compact ? 22 : 28, style: .continuous))
        .onTapGesture(count: 2) {
            engine.toggle()
        }
    }

    private func transportButton(
        symbol: String,
        label: String,
        size: CGFloat,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: primary ? 23 : 17, weight: .bold))
                .offset(x: symbol == "play.fill" ? 2 : 0)
                .frame(width: size, height: size)
                .foregroundStyle(primary ? Color(white: 0.04) : GeoTheme.text)
                .background {
                    Circle()
                        .fill(primary ? Color(white: engine.isPlaying ? 0.78 : 0.95) : Color.white.opacity(0.04))
                        .overlay {
                            if !primary {
                                Circle().stroke(GeoTheme.line, lineWidth: 1)
                            }
                        }
                        .shadow(color: primary ? .white.opacity(0.13) : .clear, radius: 15)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var structureCard: some View {
        GeoCard {
            VStack(spacing: 18) {
                CardTitle(title: "节拍结构", subtitle: "STRUCTURE")

                VStack(spacing: 10) {
                    ControlLabel(title: "每小节拍数", value: "\(engine.preset.beats) 拍")
                    HStack(spacing: 5) {
                        ForEach(2...8, id: \.self) { beats in
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
                                title: subdivision == 1 ? "4 分" : subdivision == 2 ? "8 分" : "16 分",
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
                    ControlLabel(title: "每分钟节拍", value: "\(engine.preset.bpm) BPM")
                    Slider(
                        value: Binding(
                            get: { Double(engine.preset.bpm) },
                            set: { engine.setBPM(Int($0.rounded()), reschedule: false) }
                        ),
                        in: 30...240,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                engine.commitTempoChange()
                            }
                        }
                    )
                    .tint(Color(white: 0.93))
                    .accessibilityLabel("每分钟节拍")
                    .accessibilityValue(engine.preset.tempoDisplay)
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
                        ForEach(PracticeHand.allCases) { hand in
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
                            ForEach(PracticeHand.allCases) { hand in
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
        reviewSummary = practiceSession.finish()
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
                                ForEach(PracticeHand.allCases) { hand in
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
    let lastPulseDate: Date
    let isPlaying: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.08 : nil, paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2 + min(12, size.height * 0.02))
                let radius = min(size.width, size.height) * 0.35
                let directionSign: CGFloat = preset.direction == .counterclockwise ? -1 : 1
                let step = CGFloat.pi * 2 / CGFloat(preset.beats)
                let elapsed = max(0, timeline.date.timeIntervalSince(lastPulseDate))
                let isMainBeat = currentSubdivision == 0
                let decay = isMainBeat ? 0.175 : 0.065
                let pulse = isPlaying ? exp(-elapsed / decay) : 0

                for index in 0..<preset.beats {
                    let angle = -CGFloat.pi / 2 + directionSign * CGFloat(index) * step
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                    drawBaseNode(at: point, in: &context)

                    guard isPlaying, index == currentBeat, pulse > 0.015 else { continue }
                    let isDownbeat = index == 0
                    let isGroupAccent = preset.groupStartIndices.contains(index) && !isDownbeat
                    let level = isMainBeat ? (isDownbeat ? 1.0 : isGroupAccent ? 0.78 : 0.58) : 0.28
                    let burst: CGFloat = isMainBeat ? (isDownbeat ? 34 : isGroupAccent ? 27 : 21) : 9
                    let visualPulse = reduceMotion ? min(1, pulse) * 0.35 : pulse
                    let activeRadius = 8 + visualPulse * burst
                    let alpha = max(0.12, pulse * level)
                    drawPulse(
                        at: point,
                        radius: activeRadius,
                        alpha: alpha,
                        pulse: pulse,
                        isMainBeat: isMainBeat,
                        showsRing: isMainBeat && !reduceMotion,
                        in: &context
                    )
                }
            }
        }
    }

    private func drawBaseNode(at point: CGPoint, in context: inout GraphicsContext) {
        let rect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        var layer = context
        layer.addFilter(.shadow(color: .white.opacity(0.12), radius: 9))
        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.13)))
    }

    private func drawPulse(
        at point: CGPoint,
        radius: CGFloat,
        alpha: Double,
        pulse: Double,
        isMainBeat: Bool,
        showsRing: Bool,
        in context: inout GraphicsContext
    ) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        var layer = context
        let shadowRadius = isMainBeat ? 34 + CGFloat(pulse) * 48 : 15
        layer.addFilter(.shadow(color: .white.opacity(min(0.9, alpha)), radius: shadowRadius))
        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))

        if showsRing {
            let ringRadius = radius + 12 + CGFloat(pulse) * 8
            let ring = CGRect(x: point.x - ringRadius, y: point.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(alpha * 0.22)), lineWidth: 2)
        }
    }
}
