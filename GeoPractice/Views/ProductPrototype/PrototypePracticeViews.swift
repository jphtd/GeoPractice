import Charts
import SwiftUI

enum PrototypeMonthDayLabel {
    static func text(for date: Date, calendar: Calendar) -> String {
        calendar.component(.day, from: date).formatted()
    }
}

enum PrototypeWeeklyChartLayout {
    static let height: CGFloat = 90
    static let labelHeight: CGFloat = 16
    static let labelSpacing: CGFloat = 6
    static let minimumBarHeight: CGFloat = 8

    static func barHeight(
        count: Int,
        maximumCount: Int,
        availableHeight: CGFloat
    ) -> CGFloat {
        let plotHeight = max(0, availableHeight - labelHeight - labelSpacing)
        guard plotHeight > 0 else { return 0 }
        guard count > 0, maximumCount > 0 else {
            return min(minimumBarHeight, plotHeight)
        }

        let ratio = min(1, max(0, CGFloat(count) / CGFloat(maximumCount)))
        return min(plotHeight, max(minimumBarHeight, plotHeight * ratio))
    }
}

enum PrototypePracticeSectionsLayout {
    /// Keeps a long section list from taking over the song-detail page while
    /// still leaving enough room to compare several section goals at once.
    static let viewportHeight: CGFloat = 360
}

// MARK: - Practice browser

/// Persisted practice library presented with the approved prototype layout.
struct PrototypePracticeView: View {
    let onOpenMetronome: (PrototypePracticeLaunch) -> Void

    @ObservedObject private var store: PracticeLibraryStore
    @State private var query = ""
    @State private var showsSearch = false
    @State private var selectedFilter: PrototypePracticeFilter = .today
    @State private var showsNewSong = false
    @State private var showsArchive = false
    @State private var pendingDeletion: PracticeSongSnapshot?
    @State private var operationError: String?

    init(
        store: PracticeLibraryStore,
        onOpenMetronome: @escaping (PrototypePracticeLaunch) -> Void = { _ in }
    ) {
        self.store = store
        self.onOpenMetronome = onOpenMetronome
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                List {
                    prototypeNotice
                        .prototypePracticeListRow(top: 10, bottom: 6)

                    filterStrip
                        .prototypePracticeListRow(top: 0, bottom: 6)

                    if showsSearch {
                        searchField
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .prototypePracticeListRow(top: 0, bottom: 6)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(sectionTitle)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("\(visibleSections.count) 个练习段落")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                    }
                    .prototypePracticeListRow(top: 0, bottom: 2)

                    if visibleSections.isEmpty {
                        emptyState
                            .prototypePracticeListRow(top: 4, bottom: 24)
                    } else {
                        ForEach(visibleSections) { item in
                            PrototypePracticeSectionCard(
                                song: item.song,
                                section: item.section,
                                onStart: {
                                    onOpenMetronome(store.launch(song: item.song, section: item.section))
                                }
                            )
                            .prototypePracticeListRow(top: 4, bottom: 8)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Do not give this pre-confirmation action a
                                // destructive role. SwiftUI otherwise removes
                                // the List row optimistically before the alert
                                // has been confirmed, leaving the UI out of sync
                                // when the user cancels.
                                Button {
                                    pendingDeletion = item.song
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(.red)

                                Button {
                                    archive(item.song)
                                } label: {
                                    Label("归档", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                            .accessibilityActions {
                                Button("归档曲目") { archive(item.song) }
                                Button("删除曲目") {
                                    pendingDeletion = item.song
                                }
                            }
                        }

                        Color.clear
                            .frame(height: 16)
                            .prototypePracticeListRow(top: 0, bottom: 0)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            }
            .navigationTitle("打卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsSearch.toggle() }
                    } label: {
                        GeoToolbarIconLabel(symbol: "magnifyingglass")
                    }
                    .buttonStyle(LiquidPressButtonStyle())
                    .accessibilityLabel(showsSearch ? "收起搜索" : "搜索曲目和段落")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsArchive = true
                    } label: {
                        GeoToolbarIconLabel(symbol: "archivebox")
                    }
                    .buttonStyle(LiquidPressButtonStyle())
                    .accessibilityLabel("已归档曲目")

                    Button {
                        showsNewSong = true
                    } label: {
                        GeoToolbarIconLabel(symbol: "plus")
                    }
                    .buttonStyle(LiquidPressButtonStyle())
                    .accessibilityLabel("新建曲目")
                }
            }
            .toolbarBackground(GeoTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showsNewSong) {
                PrototypeSongEditorView(store: store, songID: nil)
            }
            .sheet(isPresented: $showsArchive) {
                PrototypeArchiveView(store: store)
            }
            .prototypeSongDeletionAlert(song: $pendingDeletion) { song in
                delete(song)
            }
            .alert("操作未完成", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
            .onChange(of: store.activeSongs.map(\.id)) { _, liveSongIDs in
                if case .song(let selectedID) = selectedFilter,
                   !liveSongIDs.contains(selectedID) {
                    selectedFilter = .all
                }
            }
        }
        .environmentObject(store)
    }

    private func archive(_ song: PracticeSongSnapshot) {
        do {
            guard try store.setArchived(song.id, true) else { return }
            resetFilterIfNeeded(afterRemoving: song.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func delete(_ song: PracticeSongSnapshot) {
        do {
            guard try store.deleteSong(song.id) else { return }
            resetFilterIfNeeded(afterRemoving: song.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func resetFilterIfNeeded(afterRemoving songID: UUID) {
        if case .song(let selectedID) = selectedFilter, selectedID == songID {
            selectedFilter = .all
        }
    }

    private var prototypeNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
            Text("曲目、段落、补录与练习历史都会保存在本机。")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(GeoTheme.muted)
        .padding(13)
        .geoCardSurface(cornerRadius: 16)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filterButton(.today, title: "今日完成")
                filterButton(.all, title: "所有曲目")

                ForEach(store.activeSongs) { song in
                    filterButton(.song(song.id), title: song.name)
                }

                Button {
                    showsNewSong = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GeoTheme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 42)
                        .background(
                            GeoTheme.panel,
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(GeoTheme.surfaceInk.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(LiquidPressButtonStyle())
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func filterButton(_ filter: PrototypePracticeFilter, title: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { selectedFilter = filter }
        } label: {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(
                    selectedFilter == filter
                        ? GeoTheme.selectionText
                        : GeoTheme.text
                )
                .padding(.horizontal, 15)
                .frame(minHeight: 42)
                .background(
                    selectedFilter == filter
                        ? GeoTheme.selectionFill
                        : GeoTheme.panel,
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(GeoTheme.surfaceInk.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(LiquidPressButtonStyle())
        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GeoTheme.muted)
            TextField("搜索曲目、分组或段落", text: $query)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GeoTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .prototypeGlassSurface(cornerRadius: 16)
    }

    private var visibleSections: [PrototypeSongSectionItem] {
        store.activeSongs.flatMap { song in
            song.sections.map { PrototypeSongSectionItem(song: song, section: $0) }
        }
        .filter { item in
            let filterMatches: Bool
            switch selectedFilter {
            case .today:
                filterMatches = store.hasAttemptToday(eventID: item.section.id)
            case .all:
                filterMatches = true
            case .song(let id):
                filterMatches = item.song.id == id
            }

            guard filterMatches else { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            return item.song.name.localizedCaseInsensitiveContains(needle)
                || item.song.group.localizedCaseInsensitiveContains(needle)
                || item.section.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private var sectionTitle: String {
        switch selectedFilter {
        case .today: "今日练习"
        case .all: "全部练习"
        case .song(let id): store.song(id: id)?.name ?? "曲目"
        }
    }

    private var emptyState: some View {
        return GeoCard(cornerRadius: 22) {
            ContentUnavailableView {
                Label("没有匹配的练习", systemImage: "music.note.list")
            } description: {
                Text("尝试切换筛选或创建一首新的曲目。")
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }
}

private struct PrototypePracticeSectionCard: View {
    let song: PracticeSongSnapshot
    let section: PracticeSectionSnapshot
    let onStart: () -> Void

    var body: some View {
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.name)
                            .font(.headline.weight(.bold))
                        Text("\(song.name) · \(song.group)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                        if let lastPracticed = section.lastPracticed {
                            Text("上次练习 \(lastPracticed.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(GeoTheme.muted)
                        } else {
                            Text("尚未练习")
                                .font(.caption2)
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(section.target.map { "\(section.completedCount)/\($0)" } ?? "\(section.completedCount) 次")
                        .font(.headline.monospacedDigit().weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actionButtons }
                    VStack(spacing: 10) { actionButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        NavigationLink {
            PrototypeSongDetailView(songID: song.id)
        } label: {
            Label("详情", systemImage: "doc.text.magnifyingglass")
                .prototypeActionLabel()
        }
        .buttonStyle(.plain)

        Button(action: onStart) {
            Label("进入练习", systemImage: "play.fill")
                .prototypeActionLabel(prominent: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Song detail

private struct PrototypeSongDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PracticeLibraryStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    let songID: UUID
    @State private var showsEditor = false
    @State private var showsBackfill = false
    @State private var pendingDeletion: PracticeSongSnapshot?
    @State private var operationError: String?
    @State private var analysisSectionID: UUID?
    @State private var analysisRange: PracticePieceAnalysisRange = .thirtyDays
    @State private var analysisHand: PracticeHand = .both

    var body: some View {
        ZStack {
            GeoBackground()

            if let song = store.song(id: songID) {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        detailHeader(song)
                        actionGrid
                        overview(song)
                        weekCard(song)
                        monthCard(song)
                        yearCard(song)
                        sectionsCard(song)
                        analysisCard(song)
                        deleteButton(song)
                    }
                    .frame(maxWidth: 760)
                    .padding(16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .navigationTitle(song.name)
                .sheet(isPresented: $showsEditor) {
                    PrototypeSongEditorView(store: store, songID: songID)
                }
                .sheet(isPresented: $showsBackfill) {
                    PrototypeBackfillView(store: store, songID: songID)
                }
            } else {
                ContentUnavailableView("曲目不存在", systemImage: "music.note")
            }
        }
        .prototypeSongDeletionAlert(song: $pendingDeletion) { song in
            do {
                guard try store.deleteSong(song.id) else { return }
                dismiss()
            } catch {
                operationError = error.localizedDescription
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    private func deleteButton(_ song: PracticeSongSnapshot) -> some View {
        Button(role: .destructive) {
            pendingDeletion = song
        } label: {
            Label("删除曲目", systemImage: "trash")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Rectangle())
                .prototypeGlassSurface(cornerRadius: 18)
        }
        .buttonStyle(LiquidPressButtonStyle())
        .accessibilityHint("删除前会再次要求确认")
    }

    private func detailHeader(_ song: PracticeSongSnapshot) -> some View {
        VStack(spacing: 5) {
            Text(song.name)
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text("\(song.group) · 建立 \(song.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { detailActions }
            VStack(spacing: 10) { detailActions }
        }
    }

    @ViewBuilder
    private var detailActions: some View {
        Button { showsEditor = true } label: {
            Label("编辑", systemImage: "pencil").prototypeActionLabel()
        }
        .buttonStyle(.plain)

        NavigationLink {
            PrototypeSongHistoryView(songID: songID)
        } label: {
            Label("历史记录", systemImage: "clock.arrow.circlepath").prototypeActionLabel()
        }
        .buttonStyle(.plain)

        Button { showsBackfill = true } label: {
            Label("补录", systemImage: "plus.rectangle.on.rectangle").prototypeActionLabel(prominent: true)
        }
        .buttonStyle(.plain)
    }

    private func overview(_ song: PracticeSongSnapshot) -> some View {
        let records = store.records(for: song.id)
        let count = records.reduce(0) { $0 + $1.totalCount }
        let durationMilliseconds = records.reduce(Int64(0)) { partial, record in
            let (sum, overflowed) = partial.addingReportingOverflow(record.totalDurationMilliseconds)
            return overflowed ? Int64.max : sum
        }
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("总览").font(.headline.weight(.bold))
                HStack(spacing: 8) {
                    PrototypeDetailMetric(title: "练习次数", value: count.formatted())
                    PrototypeDetailMetric(title: "练习天数", value: store.activeDays(for: song.id).formatted())
                    PrototypeDetailMetric(
                        title: "总时长",
                        value: prototypePracticeDuration(Double(durationMilliseconds) / 1_000)
                    )
                }
            }
        }
    }

    private func weekCard(_ song: PracticeSongSnapshot) -> some View {
        let counts = store.weekCounts(for: song.id)
        let maximumCount = counts.max() ?? 0
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Text("周统计 · 最近 7 天").font(.headline.weight(.bold))
                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 9) {
                        ForEach(Array(counts.enumerated()), id: \.offset) { index, value in
                            VStack(spacing: PrototypeWeeklyChartLayout.labelSpacing) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(GeoTheme.surfaceInk.opacity(value > 0 ? 0.82 : 0.10))
                                    .frame(height: PrototypeWeeklyChartLayout.barHeight(
                                        count: value,
                                        maximumCount: maximumCount,
                                        availableHeight: proxy.size.height
                                    ))
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(GeoTheme.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(height: PrototypeWeeklyChartLayout.labelHeight)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    .clipped()
                }
                .frame(height: PrototypeWeeklyChartLayout.height)
            }
        }
    }

    private func monthCard(_ song: PracticeSongSnapshot) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let days = PracticeStatisticsEngine.monthCalendar(
            records: store.records(for: song.id),
            month: .now,
            calendar: calendar
        )
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("月统计 · \(Date.now.formatted(.dateTime.month(.wide)))")
                    .font(.headline.weight(.bold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(days) { day in
                        Text(PrototypeMonthDayLabel.text(for: day.date, calendar: calendar))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(
                                day.isActive ? GeoTheme.background : GeoTheme.muted
                            )
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(
                                GeoTheme.surfaceInk.opacity(day.isActive ? 0.84 : 0.05),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .opacity(day.isInDisplayedMonth ? 1 : 0.34)
                    }
                }
            }
        }
    }

    private func yearCard(_ song: PracticeSongSnapshot) -> some View {
        let buckets = PracticeStatisticsEngine.yearBuckets(
            records: store.records(for: song.id),
            year: .now,
            calendar: .autoupdatingCurrent
        )
        let maximum = max(1, buckets.map(\.totalCount).max() ?? 1)
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("年统计 · \(Date.now.formatted(.dateTime.year()))")
                    .font(.headline.weight(.bold))
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(buckets) { month in
                        VStack(spacing: 5) {
                            Capsule()
                                .fill(GeoTheme.surfaceInk.opacity(month.isActive ? 0.78 : 0.12))
                                .frame(height: max(8, CGFloat(month.totalCount) / CGFloat(maximum) * 62))
                            Text("\(month.month)")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 86, alignment: .bottom)
            }
        }
    }

    private func sectionsCard(_ song: PracticeSongSnapshot) -> some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Text("练习段落").font(.headline.weight(.bold))
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(song.sections) { section in
                            let isSelected = selectedAnalysisSection(in: song)?.id == section.id
                            let report = PracticeSectionBreakdownStatistics.report(
                                section: section,
                                song: song,
                                records: store.records(forEventID: section.id)
                            )

                            Button {
                                withAnimation(.snappy(duration: 0.22)) {
                                    analysisSectionID = section.id
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(
                                                isSelected ? GeoTheme.controlAccent : GeoTheme.muted
                                            )
                                        Text(section.name)
                                            .font(.subheadline.weight(.bold))
                                        Spacer(minLength: 8)
                                        sectionProgress(section)
                                    }

                                    if report.totalCount == 0 {
                                        Text("本周期尚未练习")
                                            .font(.caption)
                                            .foregroundStyle(GeoTheme.muted)
                                    } else {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(report.configurations.enumerated()), id: \.element.id) { index, breakdown in
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                        Text("\(index + 1). \(PrototypePracticeHand(breakdown.hand).title)")
                                                            .fontWeight(.bold)
                                                        Spacer(minLength: 8)
                                                        Text("\(breakdown.bpmRangeTitle) · \(breakdown.count) 次")
                                                            .monospacedDigit()
                                                    }
                                                    Text("\(breakdown.beats) 拍 · \(breakdown.subdivisionTitle)")
                                                        .foregroundStyle(GeoTheme.muted)
                                                }
                                                .font(.caption)
                                            }

                                            ForEach(Array(report.unavailableConfigurations.enumerated()), id: \.element.id) { index, unavailable in
                                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                    Text("\(report.configurations.count + index + 1). \(PrototypePracticeHand(unavailable.hand).title)")
                                                        .fontWeight(.bold)
                                                    Spacer(minLength: 8)
                                                    Text("\(unavailable.title) · \(unavailable.count) 次")
                                                        .monospacedDigit()
                                                        .foregroundStyle(GeoTheme.muted)
                                                }
                                                .font(.caption)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .background(
                                    isSelected ? GeoTheme.panelRaised.opacity(0.72) : .clear,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityHint("选择后查看该段落的曲目分析")

                            if section.id != song.sections.last?.id {
                                Divider().overlay(GeoTheme.surfaceInk.opacity(0.12))
                            }
                        }
                    }
                }
                .frame(height: PrototypePracticeSectionsLayout.viewportHeight)
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("practice-sections-scroll")
            }
        }
    }

    private func analysisCard(_ song: PracticeSongSnapshot) -> some View {
        return GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 18) {
                switch subscriptionStore.accessState {
                case .checking:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在核对专业版权益…")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                case .notEntitled:
                    PrototypeProFeatureUpsell(
                        title: "曲目分析",
                        detail: "解锁速度表现、成长趋势和左右手对比。",
                        systemImage: "chart.xyaxis.line"
                    )
                case .entitled:
                    if let section = selectedAnalysisSection(in: song) {
                        let analysis = PracticePieceAnalysisEngine.analyze(
                            records: store.records(forEventID: section.id),
                            target: PracticePieceAnalysisTarget(
                                sectionID: section.id,
                                preset: section.preset
                            ),
                            range: analysisRange,
                            hand: analysisHand
                        )

                        Label("曲目分析", systemImage: "chart.xyaxis.line")
                            .font(.headline.weight(.bold))
                        Text(section.name)
                            .font(.title3.weight(.black))
                            .foregroundStyle(GeoTheme.controlAccent)
                            .lineLimit(1)

                        analysisRangePicker
                        analysisHandPicker
                        analysisSpeedPerformance(analysis.speedPerformance)
                        Divider().overlay(GeoTheme.surfaceInk.opacity(0.10))
                        analysisHands(analysis.handComparison)
                        Divider().overlay(GeoTheme.surfaceInk.opacity(0.10))
                        analysisTrendAndGrowth(analysis)

                        Label(
                            "说明：速度数据均按四分音符等效 BPM 换算",
                            systemImage: "info.circle"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GeoTheme.muted)
                    } else {
                        Label("暂无练习段落", systemImage: "music.note.list")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 84)
                    }
                }
            }
        }
    }

    private func selectedAnalysisSection(
        in song: PracticeSongSnapshot
    ) -> PracticeSectionSnapshot? {
        if let analysisSectionID,
           let selected = song.sections.first(where: { $0.id == analysisSectionID }) {
            return selected
        }
        return song.sections.first
    }

    private var analysisRangePicker: some View {
        GeoSegmentContainer {
            ForEach(PracticePieceAnalysisTrendRange.allCases) { range in
                GeoSegmentButton(
                    title: range.title.replacingOccurrences(of: " ", with: ""),
                    isActive: analysisRange == range,
                    activeForeground: GeoTheme.controlAccent
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        analysisRange = range
                    }
                }
            }
        }
    }

    private var analysisHandPicker: some View {
        GeoSegmentContainer {
            ForEach(PracticeHand.controlOrder) { hand in
                GeoSegmentButton(
                    title: hand.title,
                    isActive: analysisHand == hand,
                    activeForeground: GeoTheme.controlAccent
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        analysisHand = hand
                    }
                }
            }
        }
    }

    private func analysisSpeedPerformance(
        _ performance: PracticePieceAnalysisSpeedPerformance
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("速度表现")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 8) {
                PrototypeAnalysisMetric(
                    title: "最高速度",
                    value: analysisBPMText(performance.maximumBPM)
                )
                PrototypeAnalysisMetric(
                    title: "平均速度",
                    value: analysisAverageBPMText(performance.weightedAverageBPM)
                )
                PrototypeAnalysisMetric(
                    title: "稳定速度",
                    value: analysisBPMText(performance.stableBPM)
                )
            }
        }
    }

    private func analysisHands(
        _ comparison: PracticePieceAnalysisHandComparison
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("左右手分析")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if let slowerHand = comparison.slowerHand {
                    Text("较慢侧 · \(PrototypePracticeHand(slowerHand).title)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GeoTheme.muted)
                }
            }

            HStack(spacing: 8) {
                PrototypeAnalysisMetric(
                    title: "左手速度",
                    value: analysisBPMText(comparison.leftMaximumBPM)
                )
                PrototypeAnalysisMetric(
                    title: "右手速度",
                    value: analysisBPMText(comparison.rightMaximumBPM)
                )
                PrototypeAnalysisMetric(
                    title: "左右手差值",
                    value: analysisDifferenceText(comparison)
                )
            }
        }
    }

    private func analysisTrendAndGrowth(_ analysis: PracticePieceAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("速度趋势与成长")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 12) {
                Image(systemName: analysisGrowthSymbol(analysis.growth.percentage))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(
                        analysis.growth.percentage == nil
                            ? GeoTheme.muted
                            : GeoTheme.controlAccent
                    )
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("成长/变化")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GeoTheme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(analysisChangeText(analysis.growth.changeBPM))
                            .font(.title3.monospacedDigit().weight(.black))
                        if analysis.growth.changeBPM != nil,
                           let percentage = analysis.growth.percentage {
                            Text(analysisGrowthText(percentage))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    if let current = analysis.growth.currentMaximumBPM,
                       let previous = analysis.growth.comparisonMaximumBPM {
                        Text(
                            "本周期 \(analysisBPMText(current)) · 上一周期 \(analysisBPMText(previous))"
                        )
                        .font(.caption)
                        .foregroundStyle(GeoTheme.muted)
                    } else {
                        Text("暂无上一周期可比较数据")
                            .font(.caption)
                            .foregroundStyle(GeoTheme.muted)
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeoTheme.panelRaised.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            Text("趋势折线图")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
            PrototypePieceSpeedTrendChart(points: analysis.trendPoints)
        }
    }

    private func analysisBPMText(_ value: Double?) -> String {
        value.map { "\(analysisNumberText($0)) BPM" } ?? "—"
    }

    private func analysisAverageBPMText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f BPM", value)
    }

    private func analysisGrowthText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.1f%%", value)
    }

    private func analysisChangeText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let prefix = value > 0 ? "+" : ""
        return "\(prefix)\(analysisNumberText(value)) BPM"
    }

    private func analysisGrowthSymbol(_ value: Double?) -> String {
        guard let value else { return "minus" }
        if value > 0 { return "arrow.up.right" }
        if value < 0 { return "arrow.down.right" }
        return "arrow.right"
    }

    private func analysisDifferenceText(
        _ comparison: PracticePieceAnalysisHandComparison
    ) -> String {
        guard let difference = comparison.absoluteDifferenceBPM,
              let percentage = comparison.differencePercentage,
              percentage.isFinite
        else { return "—" }
        return String(
            format: "%@ BPM · %.1f%%",
            analysisNumberText(difference),
            percentage
        )
    }

    private func analysisNumberText(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        if rounded * 10 == (rounded * 10).rounded() {
            return String(format: "%.1f", rounded)
        }
        return String(format: "%.2f", rounded)
    }

    @ViewBuilder
    private func sectionProgress(_ section: PracticeSectionSnapshot) -> some View {
        if let progress = section.goalProgress {
            let target = progress.targets.total
            let completed = progress.completed.total
            let percentage = min(100, max(0, Int((progress.completionRate * 100).rounded())))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("完成 \(percentage)%")
                        .foregroundStyle(GeoTheme.muted)
                    Text("\(completed)/\(target)")
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("完成 \(percentage)%")
                        .foregroundStyle(GeoTheme.muted)
                    Text("\(completed)/\(target)")
                }
            }
            .font(.subheadline.monospacedDigit().weight(.black))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "完成度百分之\(percentage)，已完成\(completed)，目标\(target)"
            )
        } else {
            Text("\(section.completedCount) 次")
                .font(.subheadline.monospacedDigit().weight(.black))
                .accessibilityLabel("已完成 \(section.completedCount) 次，未设置目标")
        }
    }
}

private struct PrototypeAnalysisMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .lineLimit(2)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(GeoTheme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            GeoTheme.panelRaised.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct PrototypePieceSpeedTrendChart: View {
    let points: [PracticePieceAnalysisTrendPoint]

    var body: some View {
        if points.isEmpty {
            Text("该范围内暂无速度记录")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 132)
        } else {
            Chart(points, id: \.date) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("速度", point.maximumBPM)
                )
                .foregroundStyle(GeoTheme.controlAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("日期", point.date),
                    y: .value("速度", point.maximumBPM)
                )
                .foregroundStyle(GeoTheme.controlAccent)
                .symbolSize(28)
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(GeoTheme.surfaceInk.opacity(0.08))
                    AxisValueLabel()
                        .foregroundStyle(GeoTheme.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(GeoTheme.surfaceInk.opacity(0.08))
                    AxisValueLabel()
                        .foregroundStyle(GeoTheme.muted)
                }
            }
            .frame(height: 160)
            .accessibilityLabel("速度趋势")
        }
    }
}

// MARK: - Editor

private struct PrototypeSongEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    let songID: UUID?

    @AppStorage(PracticePreferenceKeys.defaultBPM)
    private var defaultBPM = PracticePreferencePolicy.defaultBPM
    @AppStorage(PracticePreferenceKeys.defaultBeats)
    private var defaultBeats = PracticePreferencePolicy.defaultBeats

    @State private var name = ""
    @State private var group = "未分组"
    @State private var sectionDrafts: [PracticeSectionDraft] = [
        PracticeSectionDraft(name: "第一段")
    ]
    @State private var leftGoal = 10
    @State private var rightGoal = 10
    @State private var bothGoal = 10
    @State private var resetsDaily = true
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var archived = false
    @State private var didLoad = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("曲目信息") {
                    TextField("曲目名", text: $name)
                    TextField("分组", text: $group)
                }

                Section("练习段落") {
                    ForEach($sectionDrafts) { $draft in
                        HStack {
                            TextField("段落名称", text: $draft.name)
                            if sectionDrafts.count > 1 {
                                Button(role: .destructive) {
                                    sectionDrafts.removeAll { $0.id == draft.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除段落 \(draft.name)")
                            }
                        }
                    }
                    Button {
                        sectionDrafts.append(
                            PracticeSectionDraft(name: "第\(sectionDrafts.count + 1)段")
                        )
                    } label: {
                        Label("增加段落", systemImage: "plus")
                    }
                }

                Section("目标") {
                    Stepper("左手目标 \(leftGoal)", value: $leftGoal, in: 0...999)
                    Stepper("右手目标 \(rightGoal)", value: $rightGoal, in: 0...999)
                    Stepper("合手目标 \(bothGoal)", value: $bothGoal, in: 0...999)
                }

                Section("周期") {
                    Toggle("每日重置", isOn: $resetsDaily)
                        .tint(GeoTheme.controlAccent)
                    DatePicker("结束日期", selection: $endDate, displayedComponents: .date)
                }

                if songID != nil {
                    Section {
                        Toggle("归档曲目", isOn: $archived)
                            .tint(GeoTheme.controlAccent)
                    } footer: {
                        Text("归档后不会出现在打卡首页，可从归档入口恢复。")
                    }
                }

                Section {
                    Text("段落改名会保留原有练习历史；删除段落会同时清除该段落的历史与目标。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GeoTheme.background)
            .navigationTitle(songID == nil ? "新建曲目" : "编辑曲目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear(perform: loadIfNeeded)
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        do {
            _ = try store.saveSong(
                id: songID,
                name: name,
                group: group,
                sections: sectionDrafts,
                leftGoal: leftGoal,
                rightGoal: rightGoal,
                bothGoal: bothGoal,
                multiplier: 1,
                resetsDaily: resetsDaily,
                endDate: endDate,
                archived: archived,
                newSectionPreset: MetronomePreset(
                    bpm: PracticePreferencePolicy.normalizedBPM(defaultBPM),
                    beats: PracticePreferencePolicy.normalizedBeats(defaultBeats),
                    subdivision: MetronomePreset.standard.subdivision,
                    direction: MetronomePreset.standard.direction,
                    grouping: MetronomePreset.standard.grouping,
                    referenceNoteRaw: MetronomePreset.standard.referenceNoteRaw
                ).normalized
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let songID, let song = store.song(id: songID) else { return }
        name = song.name
        group = song.group
        sectionDrafts = song.sections.map {
            PracticeSectionDraft(id: $0.id, name: $0.name)
        }
        leftGoal = song.leftGoal
        rightGoal = song.rightGoal
        bothGoal = song.bothGoal
        resetsDaily = song.resetsDaily
        endDate = song.endDate
        archived = song.isArchived
    }
}

// MARK: - History and backfill

private enum PrototypeHistoryEditTarget: Identifiable {
    enum ID: Hashable {
        case record(UUID)
        case completion(UUID)
        case unitemized(PracticeHistoryUnitemizedCompletionSummary.ID)
    }

    case record(PracticeHistoryRecordSnapshot)
    case completion(
        record: PracticeHistoryRecordSnapshot,
        completion: PracticeHistoryCompletionEntry
    )
    case unitemized(
        record: PracticeHistoryRecordSnapshot,
        summary: PracticeHistoryUnitemizedCompletionSummary
    )

    var id: ID {
        switch self {
        case .record(let record): .record(record.id)
        case .completion(_, let completion): .completion(completion.id)
        case .unitemized(_, let summary): .unitemized(summary.id)
        }
    }
}

struct PrototypeSongHistoryView: View {
    @EnvironmentObject private var store: PracticeLibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    let songID: UUID

    @State private var period: PrototypeHistoryPeriod = .week
    @State private var anchorDate = Date.now
    @State private var hand: PrototypeHistoryHandFilter = .all
    @State private var editTarget: PrototypeHistoryEditTarget?
    @State private var showsBackfill = false
    @State private var operationError: String?

    var body: some View {
        ZStack {
            GeoBackground()
            ScrollView {
                LazyVStack(spacing: 14) {
                    GeoCard(cornerRadius: 20) {
                        VStack(spacing: 12) {
                            periodControl
                            dateControl
                            handControl
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)

                    let eventIDs = Set(store.song(id: songID)?.sections.map(\.id) ?? [])
                    let deleted = store.recentlyDeletedHistory.filter { eventIDs.contains($0.eventID) }
                    if !deleted.isEmpty {
                        GeoCard(cornerRadius: 20) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近删除").font(.headline)
                                ForEach(deleted) { record in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(record.title)
                                            Text("保留至 \(record.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("恢复") {
                                            do { _ = try store.restoreHistoryRecord(id: record.id) }
                                            catch { operationError = error.localizedDescription }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if groupedSessions.isEmpty {
                        GeoCard(cornerRadius: 20) {
                            ContentUnavailableView {
                                Label("该范围暂无记录", systemImage: "clock")
                            } description: {
                                Text("切换时间范围或手型可查看其他练习记录。")
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(groupedSessions, id: \.day) { group in
                            GeoCard(cornerRadius: 20) {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(group.day.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                                        .font(.headline.weight(.bold))
                                    ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                        if index > 0 {
                                            Divider().overlay(GeoTheme.surfaceInk.opacity(0.12))
                                        }
                                        historySession(session)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("补录") { showsBackfill = true } }
        .sheet(isPresented: $showsBackfill) {
            PrototypeBackfillView(store: store, songID: songID)
        }
        .sheet(item: $editTarget) { target in
            switch target {
            case .record(let record):
                PrototypeHistoryRecordEditor(store: store, record: record)
            case .completion(let record, let completion):
                PrototypeHistoryCompletionEditor(
                    store: store,
                    record: record,
                    completion: completion
                )
            case .unitemized(let record, let summary):
                PrototypeHistoryUnitemizedEditor(
                    store: store,
                    record: record,
                    summary: summary
                )
            }
        }
        .alert("操作失败", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(operationError ?? "") }
    }

    private var periodControl: some View {
        GeoSegmentContainer {
            ForEach(PrototypeHistoryPeriod.allCases) { value in
                GeoSegmentButton(
                    title: value.title,
                    symbol: nil,
                    isActive: period == value
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        period = value
                    }
                }
            }
        }
    }

    private var dateControl: some View {
        HStack(spacing: 8) {
            Button { shiftPeriod(-1) } label: {
                GeoGlassCapsule {
                    Image(systemName: "chevron.left").frame(width: 40, height: 40)
                }
            }
            .buttonStyle(LiquidPressButtonStyle())
            .disabled(period == .all)
            Text(period.rangeTitle(anchor: anchorDate))
                .font(.caption.monospacedDigit().weight(.bold))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            Button { shiftPeriod(1) } label: {
                GeoGlassCapsule {
                    Image(systemName: "chevron.right").frame(width: 40, height: 40)
                }
            }
            .buttonStyle(LiquidPressButtonStyle())
            .disabled(period == .all)
        }
        .foregroundStyle(GeoTheme.text)
    }

    private var handControl: some View {
        GeoSegmentContainer {
            ForEach(PrototypeHistoryHandFilter.allCases) { value in
                GeoSegmentButton(
                    title: value.title,
                    symbol: nil,
                    isActive: hand == value
                ) {
                    hand = value
                }
            }
        }
    }

    private var filteredRecords: [PracticeHistoryRecordSnapshot] {
        store.records(for: songID)
            .filter { record in
                guard let interval = period.dateInterval(anchor: anchorDate) else { return true }
                return record.startedAt >= interval.start && record.startedAt < interval.end
            }
    }

    private var historySessions: [PracticeHistorySessionDetail] {
        PracticeStatisticsEngine.historySessions(
            records: filteredRecords,
            hand: hand.practiceHand,
            order: .newestFirst
        )
    }

    private var groupedSessions: [(day: Date, sessions: [PracticeHistorySessionDetail])] {
        Dictionary(grouping: historySessions) {
            Calendar.autoupdatingCurrent.startOfDay(for: $0.startedAt)
        }
        .map { day, sessions in
            (day, sessions.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            })
        }
        .sorted { $0.day > $1.day }
    }

    private func shiftPeriod(_ offset: Int) {
        guard let component = period.calendarComponent,
              let shifted = Calendar.autoupdatingCurrent.date(byAdding: component, value: offset, to: anchorDate)
        else { return }
        anchorDate = shifted
    }

    @ViewBuilder
    private func historySession(_ session: PracticeHistorySessionDetail) -> some View {
        let durationText = prototypePracticeDuration(
            Double(session.summaryStats.durationMilliseconds) / 1_000
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.eventName)
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 8)
                Text("\(session.summaryStats.count) 次")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(GeoTheme.muted)
            }

            Text("开始 \(session.startedAt.formatted(.dateTime.hour().minute())) · 有效时长 \(durationText)")
                .font(.caption)
                .foregroundStyle(GeoTheme.muted)

            if !session.attempts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(session.attempts.enumerated()), id: \.element.id) { index, attempt in
                        if index > 0 {
                            let intervalText = PracticeHistoryIntervalFormatter.string(
                                since: session.attempts[index - 1].completedAt,
                                to: attempt.completedAt
                            )
                            Text("间隔 \(intervalText)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(GeoTheme.muted)
                        }
                        historyAttempt(attempt, record: session.record)
                    }
                }
            }

            if !session.unitemizedCompletions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.unitemizedCompletions) { summary in
                        Button {
                            if session.record.completionSamples.isEmpty {
                                editTarget = .record(session.record)
                            } else {
                                editTarget = .unitemized(
                                    record: session.record,
                                    summary: summary
                                )
                            }
                        } label: {
                            HStack(spacing: 10) {
                                historyUnitemizedSummary(summary)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(GeoTheme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            session.record.completionSamples.isEmpty
                                ? "打开后可编辑或删除这场旧记录"
                                : "打开后只编辑或删除这条汇总，不影响逐次完成"
                        )
                    }
                }
            }

            if session.attempts.isEmpty && session.unitemizedCompletions.isEmpty {
                Button {
                    editTarget = .record(session.record)
                } label: {
                    HStack(spacing: 10) {
                        historySessionSummary(session)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GeoTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开后可编辑或删除这条汇总记录")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyAttempt(
        _ attempt: PracticeHistoryCompletionEntry,
        record: PracticeHistoryRecordSnapshot
    ) -> some View {
        Button {
            editTarget = .completion(record: record, completion: attempt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(attempt.sequenceNumber).")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(GeoTheme.muted)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(attempt.completedAt, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                        if hand == .all {
                            Text(PrototypePracticeHand(attempt.hand).title)
                        }
                    }
                    .font(.caption.weight(.bold))

                    Text("\(attempt.preset.bpm) BPM · \(attempt.preset.subdivisionTitle) · \(attempt.preset.beats) 拍")
                        .font(.caption)
                        .foregroundStyle(GeoTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GeoTheme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开后可编辑或删除这次完成")
    }

    private func historyUnitemizedSummary(
        _ summary: PracticeHistoryUnitemizedCompletionSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(summary.title) · \(PrototypePracticeHand(summary.hand).title)")
                    .fontWeight(.bold)
                Spacer(minLength: 8)
                Text("\(summary.count) 次")
                    .monospacedDigit()
            }
            if let preset = summary.preset {
                Text("\(preset.bpm) BPM · \(preset.subdivisionTitle) · \(preset.beats) 拍")
                    .foregroundStyle(GeoTheme.muted)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func historySessionSummary(_ session: PracticeHistorySessionDetail) -> some View {
        let visibleHands = hand.practiceHand.map { [$0] } ?? PracticeHand.controlOrder
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleHands, id: \.self) { practiceHand in
                let stats = session.record.stats(for: practiceHand)
                if stats.count > 0 || stats.durationMilliseconds > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if hand == .all {
                            Text(PrototypePracticeHand(practiceHand).title)
                                .fontWeight(.bold)
                        }
                        Text(historyAggregateSummary(
                            record: session.record,
                            hand: practiceHand,
                            count: stats.count
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(GeoTheme.muted)
                }
            }
        }
    }

    private func historyAggregateSummary(
        record: PracticeHistoryRecordSnapshot,
        hand: PracticeHand,
        count: Int
    ) -> String {
        guard let preset = record.preset(for: hand) else {
            return "\(count) 次"
        }
        return "\(preset.bpm) BPM · \(preset.subdivisionTitle) · \(preset.beats) 拍 · \(count) 次"
    }
}

private struct PrototypeHistoryRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    let record: PracticeHistoryRecordSnapshot

    @State private var draft: PracticeHistoryRecordEditDraft
    @State private var selectedHand: PracticeHand
    @State private var showsDeleteConfirmation = false
    @State private var operationError: String?

    init(store: PracticeLibraryStore, record: PracticeHistoryRecordSnapshot) {
        self.store = store
        self.record = record
        let initialDraft = PracticeHistoryRecordEditDraft(record: record)
        _draft = State(initialValue: initialDraft)
        _selectedHand = State(
            initialValue: initialDraft.populatedHands.first ?? .left
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记录") {
                    LabeledContent("记录时间", value: record.finishedAt.formatted(.dateTime.year().month().day().hour().minute()))
                    Text("系统时间受保护；如需纠正，请删除后重新补录。")
                        .font(.footnote).foregroundStyle(GeoTheme.muted)
                    LabeledContent("练习段落", value: record.eventNameSnapshot)
                }

                Section("手型与完成") {
                    if draft.populatedHands.count <= 1 {
                        Picker(
                            "手型",
                            selection: Binding(
                                get: { selectedHand },
                                set: { newHand in
                                    let oldHand = selectedHand
                                    draft.moveSingleHand(from: oldHand, to: newHand)
                                    selectedHand = newHand
                                }
                            )
                        ) {
                            ForEach(PracticeHand.controlOrder) { value in
                                Text(value.title).tag(value)
                            }
                        }
                    } else {
                        Picker("正在编辑", selection: $selectedHand) {
                            ForEach(PracticeHand.controlOrder) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        Text("这条记录包含多个手型；可逐项切换并修改，已有手型不会被覆盖。")
                            .font(.footnote)
                            .foregroundStyle(GeoTheme.muted)
                    }

                    Stepper(
                        "完成 \(selectedValue.count) 次",
                        value: countBinding,
                        in: 0...9_999
                    )
                    Stepper(
                        "有效时长 \(durationMinutes) 分钟",
                        value: durationMinutesBinding,
                        in: 0...1_440
                    )
                    Stepper(
                        "附加秒数 \(durationSecondsRemainder) 秒",
                        value: durationSecondsBinding,
                        in: 0...59
                    )
                }

                Section("练习配置") {
                    if selectedValue.preset != nil {
                        Stepper(
                            "速度 \(selectedValue.preset?.bpm ?? 0) BPM",
                            value: presetIntegerBinding(\.bpm),
                            in: 30...240
                        )
                        Stepper(
                            "拍数 \(selectedValue.preset?.beats ?? 0) 拍",
                            value: presetIntegerBinding(\.beats),
                            in: 3...9
                        )
                        Picker("训练音符", selection: presetIntegerBinding(\.subdivision)) {
                            ForEach(MetronomePreset.supportedSubdivisions, id: \.self) { value in
                                Text(subdivisionTitle(for: value)).tag(value)
                            }
                        }
                        if let preset = selectedValue.preset,
                           MetronomePreset.groupings(for: preset.beats).count > 1 {
                            Picker("拍组", selection: groupingBinding) {
                                ForEach(MetronomePreset.groupings(for: preset.beats), id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                        }
                    } else {
                        LabeledContent("配置", value: "旧记录未保存")
                        Text("这里只保留原记录中真实存在的字段，不会自动套用当前节拍器参数。")
                            .font(.footnote)
                            .foregroundStyle(GeoTheme.muted)
                    }
                }

                Section {
                    Button("删除这条记录", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GeoTheme.background)
            .navigationTitle("编辑历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .confirmationDialog(
                "删除这条历史记录？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { deleteConfirmed() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确认后才会删除；相关次数、时长和统计会同步更新。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
        }
    }

    private var selectedValue: PracticeHistoryHandEditDraft {
        draft.value(for: selectedHand)
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { selectedValue.count },
            set: { value in
                draft.update(hand: selectedHand) { $0.count = value }
            }
        )
    }

    private var durationMinutes: Int {
        Int(min(Int64(Int.max), selectedValue.durationMilliseconds / 60_000))
    }

    private var durationSecondsRemainder: Int {
        Int((selectedValue.durationMilliseconds / 1_000) % 60)
    }

    private var durationMinutesBinding: Binding<Int> {
        Binding(
            get: { durationMinutes },
            set: { minutes in
                let milliseconds = Int64(minutes) * 60_000
                    + Int64(durationSecondsRemainder) * 1_000
                draft.update(hand: selectedHand) {
                    $0.durationMilliseconds = milliseconds
                }
            }
        )
    }

    private var durationSecondsBinding: Binding<Int> {
        Binding(
            get: { durationSecondsRemainder },
            set: { seconds in
                let milliseconds = Int64(durationMinutes) * 60_000
                    + Int64(seconds) * 1_000
                draft.update(hand: selectedHand) {
                    $0.durationMilliseconds = milliseconds
                }
            }
        )
    }

    private func presetIntegerBinding(
        _ keyPath: WritableKeyPath<MetronomePreset, Int>
    ) -> Binding<Int> {
        Binding(
            get: { selectedValue.preset?[keyPath: keyPath] ?? 0 },
            set: { value in
                draft.update(hand: selectedHand) { hand in
                    guard var preset = hand.preset else { return }
                    preset[keyPath: keyPath] = value
                    hand.preset = preset.normalized
                }
            }
        )
    }

    private var groupingBinding: Binding<String> {
        Binding(
            get: { selectedValue.preset?.grouping ?? "标准" },
            set: { value in
                draft.update(hand: selectedHand) { hand in
                    guard var preset = hand.preset else { return }
                    preset.grouping = value
                    hand.preset = preset.normalized
                }
            }
        )
    }

    private func subdivisionTitle(for value: Int) -> String {
        var preset = MetronomePreset.standard
        preset.subdivision = value
        return preset.subdivisionTitle
    }

    private func save() {
        do {
            try store.updateHistoryRecord(draft)
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteConfirmed() {
        do {
            guard try store.deleteHistoryRecord(id: record.id) else {
                throw PracticeLibraryStoreError.historyRecordNotFound
            }
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

private struct PrototypeHistoryUnitemizedEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    let record: PracticeHistoryRecordSnapshot
    let summary: PracticeHistoryUnitemizedCompletionSummary

    @State private var draft: PracticeHistoryUnitemizedEditDraft
    @State private var showsDeleteConfirmation = false
    @State private var operationError: String?

    init(
        store: PracticeLibraryStore,
        record: PracticeHistoryRecordSnapshot,
        summary: PracticeHistoryUnitemizedCompletionSummary
    ) {
        self.store = store
        self.record = record
        self.summary = summary
        _draft = State(initialValue: PracticeHistoryUnitemizedEditDraft(
            record: record,
            summary: summary
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("汇总记录") {
                    LabeledContent("类型", value: summary.title)
                    LabeledContent("练习段落", value: record.eventNameSnapshot)
                    if draft.completedAt != nil {
                        LabeledContent("记录时间", value: draft.completedAt!.formatted(.dateTime.year().month().day().hour().minute().second()))
                        Text("实际发生时间已锁定；如需纠正，请删除后重新补录。")
                            .font(.footnote).foregroundStyle(GeoTheme.muted)
                    } else {
                        LabeledContent(
                            "场次时间",
                            value: record.finishedAt.formatted(
                                .dateTime.year().month().day().hour().minute()
                            )
                        )
                        Text("旧版汇总没有保存单次时间，因此不会伪造一个可编辑的时间。")
                            .font(.footnote)
                            .foregroundStyle(GeoTheme.muted)
                    }
                }

                Section("手型与完成") {
                    Picker("手型", selection: $draft.hand) {
                        ForEach(PracticeHand.controlOrder) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    Stepper(
                        "完成 \(draft.count) 次",
                        value: $draft.count,
                        in: 1...9_999
                    )
                    if draft.durationMilliseconds != nil {
                        Stepper(
                            "有效时长 \(durationMinutes) 分钟",
                            value: durationMinutesBinding,
                            in: 0...1_440
                        )
                        Stepper(
                            "附加秒数 \(durationSecondsRemainder) 秒",
                            value: durationSecondsBinding,
                            in: 0...59
                        )
                    }
                }

                Section("练习配置") {
                    if draft.preset != nil {
                        Stepper(
                            "速度 \(draft.preset?.bpm ?? 0) BPM",
                            value: presetIntegerBinding(\.bpm),
                            in: 30...240
                        )
                        Stepper(
                            "拍数 \(draft.preset?.beats ?? 0) 拍",
                            value: presetIntegerBinding(\.beats),
                            in: 3...9
                        )
                        Picker("训练音符", selection: presetIntegerBinding(\.subdivision)) {
                            ForEach(MetronomePreset.supportedSubdivisions, id: \.self) { value in
                                Text(subdivisionTitle(for: value)).tag(value)
                            }
                        }
                        if let preset = draft.preset,
                           MetronomePreset.groupings(for: preset.beats).count > 1 {
                            Picker("拍组", selection: groupingBinding) {
                                ForEach(MetronomePreset.groupings(for: preset.beats), id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                        }
                    } else {
                        LabeledContent("配置", value: "旧记录未保存")
                        Text("不会用当前节拍器参数填补旧数据。")
                            .font(.footnote)
                            .foregroundStyle(GeoTheme.muted)
                    }
                }

                Section {
                    Button("删除这条汇总", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GeoTheme.background)
            .navigationTitle("编辑汇总记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .confirmationDialog(
                "删除这条汇总？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { deleteConfirmed() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确认后才会删除；同一场中的逐次完成不会被提前移除。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
        }
    }

    private var completedAtBinding: Binding<Date> {
        Binding(
            get: { draft.completedAt ?? record.finishedAt },
            set: { draft.completedAt = $0 }
        )
    }

    private var secondComponent: Int {
        Calendar.autoupdatingCurrent.component(.second, from: completedAtBinding.wrappedValue)
    }

    private var secondBinding: Binding<Int> {
        Binding(
            get: { secondComponent },
            set: { value in
                if let revised = Calendar.autoupdatingCurrent.date(
                    bySetting: .second,
                    value: value,
                    of: completedAtBinding.wrappedValue
                ) {
                    draft.completedAt = revised
                }
            }
        )
    }

    private var durationMinutes: Int {
        Int(min(Int64(Int.max), (draft.durationMilliseconds ?? 0) / 60_000))
    }

    private var durationSecondsRemainder: Int {
        Int(((draft.durationMilliseconds ?? 0) / 1_000) % 60)
    }

    private var durationMinutesBinding: Binding<Int> {
        Binding(
            get: { durationMinutes },
            set: { minutes in
                draft.durationMilliseconds = Int64(minutes) * 60_000
                    + Int64(durationSecondsRemainder) * 1_000
            }
        )
    }

    private var durationSecondsBinding: Binding<Int> {
        Binding(
            get: { durationSecondsRemainder },
            set: { seconds in
                draft.durationMilliseconds = Int64(durationMinutes) * 60_000
                    + Int64(seconds) * 1_000
            }
        )
    }

    private func presetIntegerBinding(
        _ keyPath: WritableKeyPath<MetronomePreset, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draft.preset?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var preset = draft.preset else { return }
                preset[keyPath: keyPath] = value
                draft.preset = preset.normalized
            }
        )
    }

    private var groupingBinding: Binding<String> {
        Binding(
            get: { draft.preset?.grouping ?? "标准" },
            set: { value in
                guard var preset = draft.preset else { return }
                preset.grouping = value
                draft.preset = preset.normalized
            }
        )
    }

    private func subdivisionTitle(for value: Int) -> String {
        var preset = MetronomePreset.standard
        preset.subdivision = value
        return preset.subdivisionTitle
    }

    private func save() {
        do {
            try store.updateHistoryUnitemized(draft)
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteConfirmed() {
        do {
            guard try store.deleteHistoryUnitemized(draft) else {
                throw PracticeLibraryStoreError.historySummaryNotFound
            }
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

private struct PrototypeHistoryCompletionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    let record: PracticeHistoryRecordSnapshot
    let completion: PracticeHistoryCompletionEntry

    @State private var draft: PracticeHistoryCompletionEditDraft
    @State private var showsDeleteConfirmation = false
    @State private var operationError: String?

    init(
        store: PracticeLibraryStore,
        record: PracticeHistoryRecordSnapshot,
        completion: PracticeHistoryCompletionEntry
    ) {
        self.store = store
        self.record = record
        self.completion = completion
        _draft = State(initialValue: PracticeHistoryCompletionEditDraft(
            recordID: record.id,
            completion: completion
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("完成记录") {
                    LabeledContent("完成时间", value: draft.completedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
                    Text("实际发生时间已锁定；如需纠正，请删除后重新补录。")
                        .font(.footnote).foregroundStyle(GeoTheme.muted)
                    Picker("手型", selection: $draft.hand) {
                        ForEach(PracticeHand.controlOrder) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    LabeledContent("完成次数", value: "1 次")
                    LabeledContent("练习段落", value: record.eventNameSnapshot)
                }

                Section("练习配置") {
                    Stepper(
                        "速度 \(draft.preset.bpm) BPM",
                        value: presetIntegerBinding(\.bpm),
                        in: 30...240
                    )
                    Stepper(
                        "拍数 \(draft.preset.beats) 拍",
                        value: presetIntegerBinding(\.beats),
                        in: 3...9
                    )
                    Picker("训练音符", selection: presetIntegerBinding(\.subdivision)) {
                        ForEach(MetronomePreset.supportedSubdivisions, id: \.self) { value in
                            Text(subdivisionTitle(for: value)).tag(value)
                        }
                    }
                    if MetronomePreset.groupings(for: draft.preset.beats).count > 1 {
                        Picker("拍组", selection: $draft.preset.grouping) {
                            ForEach(MetronomePreset.groupings(for: draft.preset.beats), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                }

                Section {
                    Button("删除这次完成", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GeoTheme.background)
            .navigationTitle("编辑完成记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .confirmationDialog(
                "删除这次完成？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { deleteConfirmed() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确认后才会删除，并同步更新对应的次数和统计。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
        }
    }

    private var secondComponent: Int {
        Calendar.autoupdatingCurrent.component(.second, from: draft.completedAt)
    }

    private var secondBinding: Binding<Int> {
        Binding(
            get: { secondComponent },
            set: { value in
                if let revised = Calendar.autoupdatingCurrent.date(
                    bySetting: .second,
                    value: value,
                    of: draft.completedAt
                ) {
                    draft.completedAt = revised
                }
            }
        )
    }

    private func presetIntegerBinding(
        _ keyPath: WritableKeyPath<MetronomePreset, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draft.preset[keyPath: keyPath] },
            set: { value in
                draft.preset[keyPath: keyPath] = value
                draft.preset = draft.preset.normalized
            }
        )
    }

    private func subdivisionTitle(for value: Int) -> String {
        var preset = MetronomePreset.standard
        preset.subdivision = value
        return preset.subdivisionTitle
    }

    private func save() {
        do {
            try store.updateHistoryCompletion(draft)
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteConfirmed() {
        do {
            guard try store.deleteHistoryCompletion(
                recordID: record.id,
                completionID: completion.id
            ) else {
                throw PracticeLibraryStoreError.historyCompletionNotFound
            }
            dismiss()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

private enum PrototypeHistoryHandFilter: String, CaseIterable, Identifiable {
    case all
    case left
    case both
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "所有"
        case .left: "左手"
        case .both: "合手"
        case .right: "右手"
        }
    }

    var practiceHand: PracticeHand? {
        switch self {
        case .all: nil
        case .left: .left
        case .both: .both
        case .right: .right
        }
    }
}

private enum PrototypeHistoryPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "周"
        case .month: "月"
        case .year: "年"
        case .all: "所有"
        }
    }

    var calendarComponent: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: nil
        }
    }

    func dateInterval(anchor: Date) -> DateInterval? {
        switch self {
        case .week: Calendar.autoupdatingCurrent.dateInterval(of: .weekOfYear, for: anchor)
        case .month: Calendar.autoupdatingCurrent.dateInterval(of: .month, for: anchor)
        case .year: Calendar.autoupdatingCurrent.dateInterval(of: .year, for: anchor)
        case .all: nil
        }
    }

    func rangeTitle(anchor: Date) -> String {
        guard let interval = dateInterval(anchor: anchor) else { return "所有时间" }
        switch self {
        case .week:
            let end = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.month(.twoDigits).day(.twoDigits))) – \(end.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))"
        case .month:
            return anchor.formatted(.dateTime.year().month(.wide))
        case .year:
            return anchor.formatted(.dateTime.year())
        case .all:
            return "所有时间"
        }
    }
}

private struct PrototypeBackfillView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    let songID: UUID

    @State private var date = Date.now
    @State private var recordID: UUID?
    @State private var hand: PrototypePracticeHand = .left
    @State private var bpm = 80
    @State private var note = "八分音符"
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("补录") {
                    Picker("所属练习会话", selection: $recordID) {
                        ForEach(eligibleRecords) { record in
                            Text("\(record.eventNameSnapshot) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .tag(Optional(record.id))
                        }
                    }
                    if let record = selectedRecord {
                        DatePicker("实际发生时间", selection: $date,
                                   in: record.startedAt...record.finishedAt)
                    }
                    Picker("手型", selection: $hand) {
                        ForEach(PrototypePracticeHand.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    Stepper("速度 \(bpm) BPM", value: $bpm, in: 30...240)
                    Picker("训练音符", selection: $note) {
                        ForEach(["四分音符", "八分音符", "十六分音符"], id: \.self) { Text($0) }
                    }
                }

                Section {
                    Text("每次只补录已有练习会话中漏记的一条记录；发生时间与录入时间会分别保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GeoTheme.background)
            .navigationTitle("补录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(recordID == nil)
                }
            }
        }
        .onAppear {
            if recordID == nil, let first = eligibleRecords.first {
                recordID = first.id
                date = first.finishedAt
            }
        }
        .alert("补录失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        do {
            guard let recordID else { throw PracticeLibraryStoreError.historyRecordNotFound }
            var preset = MetronomePreset.standard
            preset.bpm = bpm
            preset.subdivision = note.contains("十六") ? 4 : note.contains("八") ? 2 : 1
            _ = try store.addHistoryCompletion(recordID: recordID, occurredAt: date,
                                               hand: hand.practiceHand, preset: preset)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var eligibleRecords: [PracticeHistoryRecordSnapshot] {
        let eventIDs = Set(store.song(id: songID)?.sections.map(\.id) ?? [])
        return store.records.filter { $0.sourceEventID.map(eventIDs.contains) == true }
    }

    private var selectedRecord: PracticeHistoryRecordSnapshot? {
        eligibleRecords.first { $0.id == recordID }
    }
}

private struct PrototypeArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PracticeLibraryStore
    @State private var restoreError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()
                if store.archivedSongs.isEmpty {
                    ContentUnavailableView("暂无归档曲目", systemImage: "archivebox")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.archivedSongs) { song in
                                GeoCard(cornerRadius: 18) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(song.name).font(.headline)
                                            Text("\(song.group) · \(song.sections.count) 个段落")
                                                .font(.caption)
                                                .foregroundStyle(GeoTheme.muted)
                                        }
                                        Spacer()
                                        Button { restore(song.id) } label: {
                                            Text("恢复")
                                                .font(.caption.weight(.bold))
                                                .padding(.horizontal, 14)
                                                .frame(minHeight: 40)
                                                .prototypeGlassSurface(cornerRadius: 13)
                                        }
                                        .buttonStyle(LiquidPressButtonStyle())
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("已归档")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("恢复失败", isPresented: Binding(
            get: { restoreError != nil },
            set: { if !$0 { restoreError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    private func restore(_ songID: UUID) {
        do {
            _ = try store.setArchived(songID, false)
        } catch {
            restoreError = error.localizedDescription
        }
    }
}

private struct PrototypeSongDeletionAlertModifier: ViewModifier {
    @Binding var song: PracticeSongSnapshot?
    let onDelete: (PracticeSongSnapshot) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "删除曲目？",
            isPresented: Binding(
                get: { song != nil },
                set: { isPresented in
                    if !isPresented { song = nil }
                }
            ),
            presenting: song
        ) { candidate in
            Button("取消", role: .cancel) {
                song = nil
            }
            Button("删除", role: .destructive) {
                song = nil
                onDelete(candidate)
            }
        } message: { _ in
            Text(PrototypeSongDeletionCopy.message)
        }
    }
}

private extension View {
    func prototypePracticeListRow(
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .listRowInsets(
                EdgeInsets(
                    top: top,
                    leading: 16,
                    bottom: bottom,
                    trailing: 16
                )
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func prototypeSongDeletionAlert(
        song: Binding<PracticeSongSnapshot?>,
        onDelete: @escaping (PracticeSongSnapshot) -> Void
    ) -> some View {
        modifier(
            PrototypeSongDeletionAlertModifier(
                song: song,
                onDelete: onDelete
            )
        )
    }
}

private enum PrototypePracticeFilter: Hashable {
    case today
    case all
    case song(UUID)
}

private struct PrototypeSongSectionItem: Identifiable {
    var id: String { "\(song.id.uuidString)-\(section.id.uuidString)" }
    let song: PracticeSongSnapshot
    let section: PracticeSectionSnapshot
}

private struct PrototypeDetailMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .geoCardSurface(cornerRadius: 13)
    }
}

private extension View {
    func prototypeActionLabel(prominent: Bool = false) -> some View {
        font(.caption.weight(.bold))
            .foregroundStyle(GeoTheme.text)
            .frame(maxWidth: .infinity, minHeight: 46)
            .prototypeGlassSurface(cornerRadius: 14, emphasized: prominent)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func prototypePracticeDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    let hours = seconds / 3_600
    let minutes = seconds % 3_600 / 60
    let remainder = seconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
    return String(format: "%02d:%02d", minutes, remainder)
}
