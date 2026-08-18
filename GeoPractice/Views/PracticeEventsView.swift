import SwiftData
import SwiftUI

struct PracticeEventsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse) private var events: [PracticeEvent]
    @Query(sort: [
        SortDescriptor(\PracticeAttempt.finishedAt, order: .reverse),
        SortDescriptor(\PracticeAttempt.createdAt, order: .reverse)
    ]) private var attempts: [PracticeAttempt]

    @ObservedObject var metronome: MetronomeEngine
    let protectedEventID: UUID?
    let openMetronome: (PracticeEvent, MetronomePreset) -> Void

    @State private var showsNewEvent = false
    @State private var pendingDelete: PracticeEvent?
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                if events.isEmpty {
                    ContentUnavailableView {
                        Label("还没有打卡事件", systemImage: "music.note.list")
                    } description: {
                        Text("新建一个练习项目，并继承当前节拍器预设。")
                    } actions: {
                        Button("新建事件") {
                            showsNewEvent = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }
                } else {
                    List {
                        Section {
                            ForEach(events, id: \.id) { event in
                                NavigationLink(value: event.id) {
                                    PracticeEventRow(event: event)
                                }
                                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button("删除", role: .destructive) {
                                        pendingDelete = event
                                    }
                                    .disabled(event.id == protectedEventID)
                                    .accessibilityHint(
                                        event.id == protectedEventID
                                        ? "请先在节拍器中结束当前练习"
                                        : ""
                                    )
                                }
                            }
                        } header: {
                            Text("\(events.count) 个练习项目")
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("练习打卡")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsNewEvent = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建打卡事件")
                }
            }
            .toolbarBackground(GeoTheme.background.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let event = events.first(where: { $0.id == id }) {
                    PracticeEventDetailView(
                        event: event,
                        attempts: attempts.filter { $0.eventID == event.id },
                        metronome: metronome,
                        openMetronome: openMetronome
                    )
                } else {
                    ContentUnavailableView("事件不存在", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(isPresented: $showsNewEvent) {
            PracticeEventEditorView(currentPreset: metronome.preset)
        }
        .alert("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
            Button("删除", role: .destructive) {
                if let event = pendingDelete {
                    do {
                        try PracticeAttempt.deleteHistory(
                            for: event.id,
                            in: modelContext
                        )
                        modelContext.delete(event)
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        deleteError = error.localizedDescription
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("此操作会删除名称、累计次数、练习时长、速度历史和保存的节拍器预设。")
        }
        .alert("无法删除", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) {
                deleteError = nil
            }
        } message: {
            Text(deleteError ?? "请稍后重试。")
        }
    }
}

private struct PracticeEventRow: View {
    let event: PracticeEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(1)
                Spacer()
                Text("\(event.totalCount) 次 · \(practiceDurationString(milliseconds: event.totalDurationMilliseconds))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GeoTheme.muted)
                    .monospacedDigit()
            }
            PresetSummary(preset: event.preset)
            HStack(spacing: 8) {
                CountBadge(title: "左手", count: event.leftCount)
                CountBadge(title: "右手", count: event.rightCount)
                CountBadge(title: "合手", count: event.bothCount)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.105).opacity(0.96), Color(white: 0.05).opacity(0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 1)
                }
        }
    }
}

private struct PracticeEventDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let event: PracticeEvent
    let attempts: [PracticeAttempt]
    @ObservedObject var metronome: MetronomeEngine
    let openMetronome: (PracticeEvent, MetronomePreset) -> Void

    @State private var showsEditor = false

    var body: some View {
        ZStack {
            GeoBackground()
            ScrollView {
                VStack(spacing: 18) {
                    eventHero

                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 18) {
                            statisticsCard
                            VStack(spacing: 18) {
                                speedHistoryCard
                                presetCard
                            }
                        }
                    } else {
                        statisticsCard
                        speedHistoryCard
                        presetCard
                    }
                }
                .padding(16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") {
                    showsEditor = true
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            PracticeEventEditorView(event: event, currentPreset: metronome.preset)
        }
    }

    private var eventHero: some View {
        GeoCard(cornerRadius: 26) {
            VStack(alignment: .leading, spacing: 16) {
                Text("PRACTICE EVENT")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(Color(white: 0.74))
                Text(event.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                HStack {
                    Label("\(event.totalCount) 次", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Label(
                        practiceDurationString(milliseconds: event.totalDurationMilliseconds),
                        systemImage: "timer"
                    )
                    Spacer()
                    Text(event.updatedAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
            }
        }
    }

    private var statisticsCard: some View {
        GeoCard {
            VStack(spacing: 16) {
                CardTitle(title: "累计练习", subtitle: "STATISTICS")
                ForEach(PracticeHand.controlOrder) { hand in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hand.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text("练习统计")
                                .font(.system(size: 10))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(event.count(for: hand)) 次")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(practiceDurationString(milliseconds: event.durationMilliseconds(for: hand)))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var speedHistoryCard: some View {
        GeoCard {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "速度记录", subtitle: "TEMPO HISTORY")

                ForEach(PracticeHand.controlOrder) { hand in
                    speedSummaryRow(for: hand)
                    if hand != PracticeHand.controlOrder.last {
                        Divider()
                            .overlay(GeoTheme.line)
                    }
                }

                if attempts.isEmpty {
                    Text("完成练习并追加后，这里会保留每次的速度记录。")
                        .font(.system(size: 11))
                        .foregroundStyle(GeoTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(attempts) { attempt in
                                attemptHistoryRow(attempt)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("查看全部 \(attempts.count) 次练习记录")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func speedSummaryRow(for hand: PracticeHand) -> some View {
        let latest = latestAttempt(for: hand)

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(hand.title)
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 8)
                if let latest {
                    Text(latest.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                        .lineLimit(1)
                } else {
                    Text("暂无记录")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GeoTheme.muted)
                }
            }

            if let latest {
                let speed = latest.speedSummary(for: hand)
                HStack(spacing: 8) {
                    speedValue(
                        title: "练习最多",
                        bpm: speed.mostPracticed?.bpm
                    )
                    speedValue(
                        title: "最大尝试",
                        bpm: speed.maximumAttempt?.bpm
                    )
                }

                if let preset = latest.mostPracticedPreset(for: hand) {
                    Button {
                        openMetronome(event, preset)
                    } label: {
                        Label("继承\(hand.title)上次设置并开始", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("继承基准音符、速度、训练音符、拍数、分组和方向")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func speedValue(title: String, bpm: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(GeoTheme.muted)
            Text(bpm.map(String.init) ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 11)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func attemptHistoryRow(_ attempt: PracticeAttempt) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(attempt.finishedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .bold))
            ForEach(PracticeHand.controlOrder) { hand in
                if attempt.stats(for: hand).count > 0 {
                    let speed = attempt.speedSummary(for: hand)
                    Text("\(hand.title)　练习最多：\(speed.mostPracticed?.bpm.description ?? "—")　最大尝试：\(speed.maximumAttempt?.bpm.description ?? "—")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(GeoTheme.muted)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func latestAttempt(for hand: PracticeHand) -> PracticeAttempt? {
        attempts.first { $0.speedSummary(for: hand).mostPracticed != nil }
    }

    private var presetCard: some View {
        GeoCard {
            VStack(alignment: .leading, spacing: 16) {
                CardTitle(title: "节拍器预设", subtitle: "PRESET")
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.preset.tempoDisplay)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Label("\(event.preset.beats) 拍 · \(event.preset.grouping)", systemImage: "circle.grid.cross")
                    Label(event.preset.subdivisionTitle, systemImage: "music.note")
                    Label(event.preset.direction.title, systemImage: event.preset.direction.symbol)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GeoTheme.text)

                Button {
                    openMetronome(event, event.preset)
                } label: {
                    Label("载入并开始练习", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
