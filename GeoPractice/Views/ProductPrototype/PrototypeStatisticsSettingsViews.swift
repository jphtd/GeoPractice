import AVFoundation
import Combine
import CoreLocation
import MapKit
import Photos
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Statistics

/// Statistics and sharing over the persisted practice library.
///
/// `PracticeLibraryStore` publishes immutable projections of SwiftData attempts.
/// This view never manufactures history: deleting, adding or committing a
/// practice record in the library is immediately reflected here.
struct PrototypeStatisticsView: View {
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @ObservedObject var practiceStore: PracticeLibraryStore

    @State private var period: PrototypeStatisticsPeriod = .week
    @State private var anchorDate = Date.now
    @State private var handFilter: PrototypeStatisticsHandFilter = .all
    @State private var songID: UUID?
    @State private var sort: PrototypeStatisticsSort = .count
    @State private var isShowingSharePreview = false

    private let calendar = Calendar.autoupdatingCurrent

    private var records: [PracticeStatisticsDisplayRecord] {
        practiceStore.records.flatMap { snapshot -> [PracticeStatisticsDisplayRecord] in
            guard let eventID = snapshot.sourceEventID,
                  let songID = practiceStore.songID(forEventID: eventID)
            else { return [] }

            let songName = practiceStore.song(id: songID)?.name ?? "未命名曲目"
            let section = practiceStore.eventSnapshot(id: eventID)
            let sectionName = section?.name ?? snapshot.eventNameSnapshot

            return PrototypeStatisticsHand.allCases.compactMap { hand in
                let statistics = snapshot.stats(for: hand.practiceHand)
                guard statistics.count > 0 || statistics.durationMilliseconds > 0 else {
                    return nil
                }
                let preset = snapshot.preset(for: hand.practiceHand)
                    ?? section?.preset.normalized
                    ?? MetronomePreset.standard
                return PracticeStatisticsDisplayRecord(
                    attemptID: snapshot.id,
                    eventID: eventID,
                    songID: songID,
                    date: snapshot.finishedAt,
                    song: songName,
                    section: sectionName,
                    hand: hand,
                    bpm: preset.bpm,
                    note: PracticeStatisticsDisplayRecord.noteTitle(
                        subdivision: preset.subdivision
                    ),
                    duration: TimeInterval(statistics.durationMilliseconds) / 1_000,
                    count: statistics.count
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        actionBar
                        periodPicker
                        periodNavigator
                        handPicker
                        summary
                        timeline
                        songDurationDistributionCard
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(GeoTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $isShowingSharePreview) {
                PrototypeSharePreviewView(
                    periodTitle: periodTitle,
                    records: shareRecords,
                    completionPercentage: displayedCompletionPercentage,
                    allTimeCountOverrides: shareAllTimeCountOverrides,
                    allTimeSongOverrides: shareAllTimeSongOverrides,
                    allTimeTotalDurationOverride: shareAllTimeTotalDurationOverride
                )
            }
            .onChange(of: practiceStore.songs.map(\.id)) { _, liveSongIDs in
                if let songID, !liveSongIDs.contains(songID) {
                    self.songID = nil
                }
            }
        }
    }

    private var displayedCompletionPercentage: Int? {
        switch period {
        case .day, .week, .month:
            guard let interval = selectedPeriodInterval else { return nil }
            return practiceStore.completionPercentage(
                songID: songID,
                within: interval
            )
        case .year, .all:
            return practiceStore.completionPercentage(songID: songID)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Menu {
                Picker("排序依据", selection: $sort) {
                    ForEach(PrototypeStatisticsSort.allCases) { option in
                        Label(option.title, systemImage: option.symbol)
                            .tag(option)
                    }
                }
            } label: {
                PrototypeActionButton(
                    title: sort.shortTitle,
                    symbol: sort.symbol
                )
            }

            Menu {
                Button {
                    songID = nil
                } label: {
                    PrototypeMenuChoiceLabel(
                        title: "所有曲目",
                        isSelected: songID == nil
                    )
                }

                ForEach(practiceStore.songs) { song in
                    Button {
                        songID = song.id
                    } label: {
                        PrototypeMenuChoiceLabel(
                            title: song.name,
                            isSelected: songID == song.id
                        )
                    }
                }
            } label: {
                PrototypeActionButton(
                    title: selectedSong?.name ?? "曲目选择",
                    symbol: "music.note.list"
                )
            }

            Button {
                isShowingSharePreview = true
            } label: {
                PrototypeActionButton(title: "分享", symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
    }

    private var periodPicker: some View {
        GeoSegmentContainer {
            ForEach(PrototypeStatisticsPeriod.allCases) { option in
                GeoSegmentButton(
                    title: option.title,
                    symbol: nil,
                    isActive: period == option,
                    activeForeground: GeoTheme.controlAccent
                ) {
                    withAnimation(.snappy(duration: 0.20)) {
                        period = option
                        anchorDate = .now
                    }
                }
            }
        }
    }

    private var periodNavigator: some View {
        LiquidControlPanel(contentPadding: 4, cornerRadius: 18) {
            HStack(spacing: 4) {
                periodArrow(direction: -1)

                Button {
                    anchorDate = .now
                } label: {
                    VStack(spacing: 2) {
                        Text(periodTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GeoTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(period == .all ? "已包含全部练习记录" : "轻点返回当前周期")
                            .font(.caption2)
                            .foregroundStyle(GeoTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(period == .all)

                periodArrow(direction: 1)
            }
        }
    }

    private func periodArrow(direction: Int) -> some View {
        Button {
            shiftPeriod(direction)
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(period == .all ? GeoTheme.muted.opacity(0.35) : GeoTheme.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(period == .all)
        .accessibilityLabel(direction < 0 ? "上一个周期" : "下一个周期")
    }

    private var handPicker: some View {
        GeoSegmentContainer {
            ForEach(PrototypeStatisticsHandFilter.allCases) { option in
                GeoSegmentButton(
                    title: option.title,
                    symbol: nil,
                    isActive: handFilter == option,
                    activeForeground: GeoTheme.controlAccent
                ) {
                    withAnimation(.snappy(duration: 0.20)) {
                        handFilter = option
                    }
                }
            }
        }
    }

    private var summary: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible())
            ],
            spacing: 12
        ) {
            PrototypeMetricCard(
                title: "练习总次数",
                value: totalCount.formatted(),
                symbol: "repeat"
            )
            PrototypeMetricCard(
                title: "练习总天数",
                value: activeDayCount.formatted(),
                symbol: "calendar"
            )
            PrototypeMetricCard(
                title: period.completionTitle,
                value: displayedCompletionPercentage.map { "\($0)%" } ?? "—",
                symbol: "percent"
            )
            PrototypeMetricCard(
                title: period.durationTitle,
                value: prototypeDuration(totalDuration),
                symbol: "clock"
            )
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if groupedRecords.isEmpty {
            GeoCard(cornerRadius: 22) {
                ContentUnavailableView {
                    Label(
                        period == .all && totalCount > 0
                            ? "暂无可显示的时间明细"
                            : "暂无练习记录",
                        systemImage: "chart.bar.xaxis"
                    )
                } description: {
                    if period == .all && totalCount > 0 {
                        Text("旧版本保存的累计次数不含练习日期，已计入上方总次数，但无法放入时间线。")
                    } else {
                        Text("当前筛选条件下没有已保存记录，可以切换周期、曲目或练习方式。")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            LazyVStack(spacing: 14) {
                ForEach(groupedRecords, id: \.day) { group in
                    PrototypeTimelineDayCard(day: group.day, records: group.records)
                }
            }
        }
    }

    @ViewBuilder
    private var songDurationDistributionCard: some View {
        switch subscriptionStore.accessState {
        case .checking:
            GeoCard(cornerRadius: 22) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在核对专业版权益…")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            }
        case .notEntitled:
            GeoCard(cornerRadius: 22) {
                PrototypeProFeatureUpsell(
                    title: "曲目练习时长分布",
                    detail: "按曲目查看练习时间投入，解锁更完整的统计视角。",
                    systemImage: "chart.bar.fill"
                )
            }
        case .entitled:
            let distribution = songDurationDistribution
            if !distribution.isEmpty {
                GeoCard(cornerRadius: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("曲目练习时长分布", systemImage: "chart.bar.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(GeoTheme.text)

                        ForEach(distribution) { item in
                            PrototypeSongDurationRow(
                                item: item,
                                maximumDuration: distribution.first?.duration ?? item.duration
                            )
                        }
                    }
                }
            }
        }
    }

    private var songDurationDistribution: [PrototypeStatisticsSongDurationItem] {
        if period == .all {
            return PrototypeStatisticsSongDurationDistribution.resolveAllTime(
                songs: allTimeScopedSongs,
                handFilter: handFilter
            )
        }

        let songOrder = Dictionary(uniqueKeysWithValues: practiceStore.songs
            .enumerated()
            .map { ($0.element.id, $0.offset) })
        let contributions = periodAndSongScopedRecords.map { record in
            PrototypeStatisticsSongDurationContribution(
                songID: record.songID,
                songName: record.song,
                hand: record.hand,
                count: record.count,
                duration: record.duration,
                order: songOrder[record.songID] ?? Int.max
            )
        }
        return PrototypeStatisticsSongDurationDistribution.resolve(
            contributions: contributions,
            handFilter: handFilter
        )
    }

    private var selectedSong: PracticeSongSnapshot? {
        songID.flatMap { practiceStore.song(id: $0) }
    }

    private var periodAndSongScopedRecords: [PracticeStatisticsDisplayRecord] {
        records.filter { record in
            isIncludedInPeriod(record.date)
                && (songID == nil || record.songID == songID)
        }
    }

    private var filteredRecords: [PracticeStatisticsDisplayRecord] {
        periodAndSongScopedRecords.filter { handFilter.includes($0.hand) }
    }

    /// Sharing always needs every hand in the selected period/song scope so
    /// its receipt remains complete regardless of the screen-only hand filter.
    private var shareRecords: [PracticeStatisticsDisplayRecord] {
        periodAndSongScopedRecords
    }

    private var shareAllTimeCountOverrides: [PrototypeStatisticsHand: Int]? {
        guard period == .all else { return nil }
        return Dictionary(uniqueKeysWithValues: PrototypeStatisticsHand.allCases.map { option in
            (option, allTimeAggregateCount(for: option))
        })
    }

    private var shareAllTimeSongOverrides: [PrototypeShareSongAggregate]? {
        guard period == .all else { return nil }
        return allTimeScopedSongs.map { song in
            PrototypeShareSongAggregate(
                songID: song.id,
                name: song.name,
                count: song.sections
                    .map(\.counts.total)
                    .reduce(0, saturatedCountAdd),
                duration: song.sections.reduce(0) { partial, section in
                    partial + TimeInterval(max(0, section.durationMilliseconds)) / 1_000
                },
                latestDate: song.sections.compactMap(\.lastPracticed).max() ?? .distantPast,
                isArchived: song.isArchived
            )
        }
    }

    private var shareAllTimeTotalDurationOverride: TimeInterval? {
        shareAllTimeSongOverrides.map { aggregates in
            aggregates.reduce(0) { $0 + max(0, $1.duration) }
        }
    }

    private var groupedRecords: [(day: Date, records: [PracticeStatisticsDisplayRecord])] {
        Dictionary(grouping: filteredRecords) { record in
            calendar.startOfDay(for: record.date)
        }
        .map { day, values in
            let sortedValues: [PracticeStatisticsDisplayRecord]
            switch sort {
            case .count:
                sortedValues = values.sorted {
                    $0.count == $1.count ? $0.date > $1.date : $0.count > $1.count
                }
            case .duration:
                sortedValues = values.sorted {
                    $0.duration == $1.duration ? $0.date > $1.date : $0.duration > $1.duration
                }
            }
            return (day, sortedValues)
        }
        .sorted { $0.day > $1.day }
    }

    private var totalCount: Int {
        if period == .all {
            return allTimeMetrics.count
        }
        return filteredHandTotals.count
    }

    private var totalDuration: TimeInterval {
        if period == .all {
            return TimeInterval(allTimeMetrics.durationMilliseconds) / 1_000
        }
        return filteredHandTotals.duration
    }

    private var filteredHandTotals: PrototypeStatisticsHandTotals {
        handFilter.totals(
            in: periodAndSongScopedRecords.map {
                PrototypeStatisticsHandContribution(
                    hand: $0.hand,
                    count: $0.count,
                    duration: $0.duration
                )
            }
        )
    }

    /// `PracticeEvent` aggregates predate immutable attempt history. For
    /// all-time statistics they are authoritative and already include every
    /// later attempt, so adding projected records would double count.
    private var allTimeMetrics: PrototypeStatisticsAllTimeMetrics {
        PrototypeStatisticsAllTimeMetrics.resolve(
            songs: allTimeScopedSongs,
            handFilter: handFilter
        )
    }

    private func allTimeAggregateCount(for hand: PrototypeStatisticsHand) -> Int {
        allTimeScopedSongs
            .flatMap(\.sections)
            .map { $0.counts.value(for: hand.practiceHand) }
            .reduce(0, saturatedCountAdd)
    }

    private var allTimeScopedSongs: [PracticeSongSnapshot] {
        selectedSong.map { [$0] } ?? practiceStore.songs
    }

    private var activeDayCount: Int {
        Set(filteredRecords.map { calendar.startOfDay(for: $0.date) }).count
    }

    private var periodTitle: String {
        switch period {
        case .day:
            return anchorDate.formatted(.dateTime.year().month().day())
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: anchorDate) ?? anchorDate
            return "\(start.formatted(.dateTime.month(.twoDigits).day(.twoDigits))) – \(anchorDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))"
        case .month:
            return anchorDate.formatted(.dateTime.year().month(.wide))
        case .year:
            return anchorDate.formatted(.dateTime.year())
        case .all:
            return "所有时间"
        }
    }

    private func shiftPeriod(_ direction: Int) {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return
        }
        if let shifted = calendar.date(byAdding: component, value: direction, to: anchorDate) {
            withAnimation(.snappy(duration: 0.20)) {
                anchorDate = shifted
            }
        }
    }

    private func isIncludedInPeriod(_ date: Date) -> Bool {
        guard let interval = selectedPeriodInterval else { return true }
        return date >= interval.start && date < interval.end
    }

    /// A single half-open interval drives the timeline and its share receipt,
    /// preventing the displayed records and completion percentage from
    /// silently using different date boundaries.
    private var selectedPeriodInterval: DateInterval? {
        switch period {
        case .day:
            return calendar.dateInterval(of: .day, for: anchorDate)
        case .week:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchorDate)) ?? anchorDate
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? .distantPast
            return DateInterval(start: start, end: end)
        case .month:
            return calendar.dateInterval(of: .month, for: anchorDate)
        case .year:
            return calendar.dateInterval(of: .year, for: anchorDate)
        case .all:
            return nil
        }
    }

    private func saturatedCountAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }
}

enum PrototypeStatisticsPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        case .all: "所有"
        }
    }

    var completionTitle: String {
        switch self {
        case .day: "今日总完成度"
        case .week: "周总完成度"
        case .month: "月总完成度"
        case .year: "曲目总完成度"
        case .all: "曲目总完成度"
        }
    }

    var durationTitle: String {
        switch self {
        case .day: "今日练习时长"
        case .week: "本周练习时长"
        case .month: "本月练习时长"
        case .year: "本年练习时长"
        case .all: "练习总时长"
        }
    }
}

enum PrototypeStatisticsHand: String, CaseIterable, Identifiable {
    case left
    case together
    case right

    var id: Self { self }

    var title: String {
        switch self {
        case .left: "左"
        case .together: "合"
        case .right: "右"
        }
    }

    var practiceHand: PracticeHand {
        switch self {
        case .left: .left
        case .together: .both
        case .right: .right
        }
    }
}

/// Screen-only filter. `PrototypeStatisticsHand` remains a projection of one
/// real persisted hand contribution; selecting "all" simply includes those
/// three rows once each and never creates a fourth synthetic record.
enum PrototypeStatisticsHandFilter: String, CaseIterable, Identifiable {
    case all
    case left
    case together
    case right

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "所有"
        case .left: "左"
        case .together: "合"
        case .right: "右"
        }
    }

    var includedHands: [PrototypeStatisticsHand] {
        switch self {
        case .all: PrototypeStatisticsHand.allCases
        case .left: [.left]
        case .together: [.together]
        case .right: [.right]
        }
    }

    func includes(_ hand: PrototypeStatisticsHand) -> Bool {
        includedHands.contains(hand)
    }

    func totals(
        in contributions: [PrototypeStatisticsHandContribution]
    ) -> PrototypeStatisticsHandTotals {
        contributions.lazy
            .filter { includes($0.hand) }
            .reduce(PrototypeStatisticsHandTotals()) { partial, contribution in
                partial.adding(contribution)
            }
    }
}

struct PrototypeStatisticsHandContribution: Equatable {
    let hand: PrototypeStatisticsHand
    let count: Int
    let duration: TimeInterval
}

struct PrototypeStatisticsHandTotals: Equatable {
    let count: Int
    let duration: TimeInterval

    init(count: Int = 0, duration: TimeInterval = 0) {
        self.count = max(0, count)
        self.duration = Self.normalizedDuration(duration)
    }

    fileprivate func adding(
        _ contribution: PrototypeStatisticsHandContribution
    ) -> Self {
        let positiveCount = max(0, contribution.count)
        let (newCount, overflowed) = count.addingReportingOverflow(positiveCount)
        return Self(
            count: overflowed ? Int.max : newCount,
            duration: duration + Self.normalizedDuration(contribution.duration)
        )
    }

    fileprivate static func normalizedDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}

/// Authoritative all-time summary resolved only from section aggregates.
/// Attempt rows are intentionally not accepted by this API, which makes it
/// impossible for callers to accidentally add them a second time.
struct PrototypeStatisticsAllTimeMetrics: Equatable {
    let count: Int
    let durationMilliseconds: Int64

    static func resolve(
        songs: [PracticeSongSnapshot],
        handFilter: PrototypeStatisticsHandFilter
    ) -> Self {
        var count = 0
        var durationMilliseconds: Int64 = 0

        for section in songs.flatMap(\.sections) {
            for hand in handFilter.includedHands {
                count = saturatedAdd(
                    count,
                    section.counts.value(for: hand.practiceHand)
                )
                durationMilliseconds = saturatedAdd(
                    durationMilliseconds,
                    section.durationMilliseconds(for: hand.practiceHand)
                )
            }
        }

        return Self(count: count, durationMilliseconds: durationMilliseconds)
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int64.max : sum
    }
}

struct PrototypeStatisticsSongDurationContribution: Equatable {
    let songID: UUID
    let songName: String
    let hand: PrototypeStatisticsHand
    let count: Int
    let duration: TimeInterval
    let order: Int
}

struct PrototypeStatisticsSongDurationItem: Identifiable, Equatable {
    let songID: UUID
    let name: String
    let duration: TimeInterval
    let order: Int

    var id: UUID { songID }
}

enum PrototypeStatisticsSongDurationDistribution {
    static func resolve(
        contributions: [PrototypeStatisticsSongDurationContribution],
        handFilter: PrototypeStatisticsHandFilter
    ) -> [PrototypeStatisticsSongDurationItem] {
        struct Accumulator {
            var name: String
            var duration: TimeInterval
            var order: Int
            let firstIndex: Int
        }

        var values: [UUID: Accumulator] = [:]
        for (index, contribution) in contributions.enumerated()
        where handFilter.includes(contribution.hand) {
            let duration = PrototypeStatisticsHandTotals.normalizedDuration(
                contribution.duration
            )
            if var current = values[contribution.songID] {
                current.duration += duration
                current.order = min(current.order, contribution.order)
                values[contribution.songID] = current
            } else {
                values[contribution.songID] = Accumulator(
                    name: contribution.songName,
                    duration: duration,
                    order: contribution.order,
                    firstIndex: index
                )
            }
        }

        let rankedItems: [(
            item: PrototypeStatisticsSongDurationItem,
            firstIndex: Int
        )] = values.compactMap { entry in
            let songID = entry.key
            let value = entry.value
            guard value.duration > 0 else { return nil }
            return (
                item: PrototypeStatisticsSongDurationItem(
                    songID: songID,
                    name: value.name,
                    duration: value.duration,
                    order: value.order
                ),
                firstIndex: value.firstIndex
            )
        }

        return rankedItems.sorted { lhs, rhs in
            if lhs.item.duration != rhs.item.duration {
                return lhs.item.duration > rhs.item.duration
            }
            if lhs.item.order != rhs.item.order {
                return lhs.item.order < rhs.item.order
            }
            if lhs.firstIndex != rhs.firstIndex {
                return lhs.firstIndex < rhs.firstIndex
            }
            return lhs.item.songID.uuidString < rhs.item.songID.uuidString
        }
        .map(\.item)
    }

    static func resolveAllTime(
        songs: [PracticeSongSnapshot],
        handFilter: PrototypeStatisticsHandFilter
    ) -> [PrototypeStatisticsSongDurationItem] {
        let contributions = songs.enumerated().flatMap { offset, song in
            handFilter.includedHands.map { hand in
                let durationMilliseconds = song.sections.reduce(Int64(0)) {
                    saturatedAdd(
                        $0,
                        $1.durationMilliseconds(for: hand.practiceHand)
                    )
                }
                let count = song.sections.reduce(0) {
                    saturatedAdd($0, $1.counts.value(for: hand.practiceHand))
                }
                return PrototypeStatisticsSongDurationContribution(
                    songID: song.id,
                    songName: song.name,
                    hand: hand,
                    count: count,
                    duration: TimeInterval(durationMilliseconds) / 1_000,
                    order: offset
                )
            }
        }
        return resolve(contributions: contributions, handFilter: handFilter)
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int64.max : sum
    }
}

private enum PrototypeStatisticsSort: String, CaseIterable, Identifiable {
    case count
    case duration

    var id: Self { self }

    var title: String {
        switch self {
        case .count: "按次数排序"
        case .duration: "按时长排序"
        }
    }

    var shortTitle: String {
        switch self {
        case .count: "次数排序"
        case .duration: "时长排序"
        }
    }

    var symbol: String {
        switch self {
        case .count: "number"
        case .duration: "clock"
        }
    }
}

private struct PracticeStatisticsDisplayRecord: Identifiable {
    let attemptID: UUID
    let eventID: UUID
    let songID: UUID
    let date: Date
    let song: String
    let section: String
    let hand: PrototypeStatisticsHand
    let bpm: Int
    let note: String
    let duration: TimeInterval
    let count: Int

    var id: String {
        "\(attemptID.uuidString.lowercased())|\(hand.rawValue)"
    }

    static func noteTitle(subdivision: Int?) -> String {
        switch subdivision {
        case 0: "二分音符"
        case 1: "四分音符"
        case 2: "八分音符"
        case 4: "十六分音符"
        case .some(let value): "\(value) 细分"
        case nil: "未记录音符"
        }
    }
}

private extension PracticeStatisticsDisplayRecord {
    var receiptEntry: PrototypeShareReceiptEntry {
        PrototypeShareReceiptEntry(
            hand: hand.practiceHand,
            date: date,
            count: count,
            duration: duration
        )
    }

    var shareSongEntry: PrototypeShareSongEntry {
        PrototypeShareSongEntry(
            songID: songID,
            name: song,
            date: date,
            count: count,
            duration: duration
        )
    }
}

private struct PrototypeActionButton: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(GeoTheme.text)
        .frame(maxWidth: .infinity, minHeight: 46)
        .padding(.horizontal, 8)
        .prototypeGlassSurface(cornerRadius: 15)
    }
}

private struct PrototypeMenuChoiceLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private struct PrototypeMetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        GeoCard(cornerRadius: 20) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(GeoTheme.muted)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GeoTheme.muted)
                    Text(value)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(GeoTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 62)
        }
    }
}

private struct PrototypeSongDurationRow: View {
    let item: PrototypeStatisticsSongDurationItem
    let maximumDuration: TimeInterval

    private var fraction: CGFloat {
        guard maximumDuration > 0 else { return 0 }
        return min(1, max(0, item.duration / maximumDuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(prototypeDuration(item.duration))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(GeoTheme.muted)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(GeoTheme.panelRaised)
                    Capsule(style: .continuous)
                        .fill(GeoTheme.controlAccent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name)，练习时长 \(prototypeDuration(item.duration))")
    }
}

private struct PrototypeTimelineDayCard: View {
    let day: Date
    let records: [PracticeStatisticsDisplayRecord]

    var body: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text(day.formatted(.dateTime.month(.twoDigits).day(.twoDigits).weekday(.abbreviated)))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GeoTheme.text)

                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider().overlay(GeoTheme.surfaceInk.opacity(0.08))
                    }

                    HStack(alignment: .top, spacing: 13) {
                        Text(record.date, format: .dateTime.hour().minute())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                            .frame(width: 44, alignment: .leading)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(record.song) · \(record.section)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(GeoTheme.text)
                            Text("\(record.hand.title) · \(record.bpm) BPM · \(record.note)")
                                .font(.caption)
                                .foregroundStyle(GeoTheme.muted)
                            Text("\(prototypeDuration(record.duration)) · \(record.count) 次")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GeoTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Shareable practice summary

struct PrototypeShareReceiptEntry: Equatable {
    let hand: PracticeHand
    let date: Date
    let count: Int
    let duration: TimeInterval
}

/// A dated, real practice contribution used to build the receipt's song list.
///
/// Dated periods resolve from these immutable attempt contributions. All-time
/// receipts may instead provide authoritative per-song aggregates below.
struct PrototypeShareSongEntry: Equatable {
    let songID: UUID
    let name: String
    let date: Date
    let count: Int
    let duration: TimeInterval
}

/// Authoritative all-time values projected from the current song/section
/// aggregates. These aggregates already include both legacy counters and all
/// later attempts, so they replace (rather than add to) attempt-derived rows.
struct PrototypeShareSongAggregate: Equatable {
    let songID: UUID
    let name: String
    let count: Int
    let duration: TimeInterval
    let latestDate: Date
    let isArchived: Bool
}

struct PrototypeShareSongSummary: Identifiable, Equatable {
    let songID: UUID
    let name: String
    let count: Int
    let duration: TimeInterval
    let latestDate: Date

    var id: UUID { songID }

    static func resolve(
        records: [PrototypeShareSongEntry],
        allTimeOverrides: [PrototypeShareSongAggregate]? = nil
    ) -> [Self] {
        if let allTimeOverrides {
            return sorted(
                allTimeOverrides.compactMap { aggregate in
                    let count = max(0, aggregate.count)
                    let duration = max(0, aggregate.duration)
                    guard count > 0 || duration > 0 else { return nil }
                    return Self(
                        songID: aggregate.songID,
                        name: aggregate.name,
                        count: count,
                        duration: duration,
                        latestDate: aggregate.latestDate
                    )
                }
            )
        }

        let summaries = Dictionary(grouping: records, by: \.songID)
            .compactMap { songID, values -> Self? in
                let count = values.reduce(0) { partial, value in
                    saturatedAdd(partial, value.count)
                }
                let duration = values.reduce(0) { partial, value in
                    partial + max(0, value.duration)
                }
                guard count > 0 || duration > 0,
                      let latestDate = values.map(\.date).max(),
                      let name = values.lazy
                        .filter({ $0.date == latestDate })
                        .map(\.name)
                        .min()
                else { return nil }

                return Self(
                    songID: songID,
                    name: name,
                    count: count,
                    duration: duration,
                    latestDate: latestDate
                )
            }

        return sorted(summaries)
    }

    private static func sorted(_ summaries: [Self]) -> [Self] {
        summaries.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
                if lhs.latestDate != rhs.latestDate { return lhs.latestDate > rhs.latestDate }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.songID.uuidString < rhs.songID.uuidString
            }
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }
}

/// Export dimensions are deterministic so preview and ImageRenderer always
/// share the same canvas and every real song row increases the receipt height.
enum PrototypeShareReceiptLayout {
    static let width: CGFloat = 720
    static let baseHeight: CGFloat = 1_360
    static let additionalSongHeight: CGFloat = 94

    static func size(songCount: Int) -> CGSize {
        CGSize(
            width: width,
            height: baseHeight + CGFloat(max(0, songCount - 1)) * additionalSongHeight
        )
    }
}

struct PrototypeShareReceiptMetrics: Equatable {
    let totalCount: Int
    let totalDuration: TimeInterval
    let activeDayCount: Int

    static func resolve(
        entries: [PrototypeShareReceiptEntry],
        countOverrides: [PracticeHand: Int]? = nil,
        totalDurationOverride: TimeInterval? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        let totalCount = PracticeHand.controlOrder.reduce(0) { partial, hand in
            let handCount = countOverrides?[hand]
                ?? entries.lazy
                    .filter { $0.hand == hand }
                    .reduce(0) { saturatedAdd($0, $1.count) }
            return saturatedAdd(partial, handCount)
        }
        let totalDuration = totalDurationOverride.map { max(0, $0) }
            ?? entries.reduce(0) { $0 + max(0, $1.duration) }
        let activeDayCount = Set(entries.map { calendar.startOfDay(for: $0.date) }).count
        return Self(
            totalCount: totalCount,
            totalDuration: totalDuration,
            activeDayCount: activeDayCount
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }
}

/// The receipt preview and exported PNG are built from the same SwiftUI view,
/// so the resolved one-shot location is exactly what gets shared.
private struct PrototypeSharePreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let periodTitle: String
    let records: [PracticeStatisticsDisplayRecord]
    let completionPercentage: Int?
    let allTimeCountOverrides: [PrototypeStatisticsHand: Int]?
    let allTimeSongOverrides: [PrototypeShareSongAggregate]?
    let allTimeTotalDurationOverride: TimeInterval?

    @StateObject private var environmentProvider = PrototypeShareEnvironmentProvider()
    @State private var renderedImage: UIImage?
    @State private var environmentSnapshot: PrototypeShareEnvironmentSnapshot?
    @State private var saveState: PrototypePhotoSaveState = .idle
    @State private var generatedAt = Date.now

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        PrototypeNoticeBanner(
                            symbol: environmentSnapshot == nil ? "location.magnifyingglass" : "photo.on.rectangle.angled",
                            text: previewNotice
                        )

                        shareCard
                            .frame(maxWidth: 340)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(cardAccessibilityLabel)

                        shareActions

                        if saveState != .idle {
                            saveFeedback
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("分享练习总结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .toolbarBackground(GeoTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await prepareShareImageIfNeeded()
            }
            .onChange(of: saveState) { _, newState in
                guard newState != .idle else { return }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: newState.message
                )
            }
        }
    }

    private var shareCard: some View {
        makeShareCard(environment: environmentSnapshot ?? .loading)
    }

    private var receiptSize: CGSize {
        PrototypeShareReceiptLayout.size(
            songCount: songSummaries.count
        )
    }

    private var songSummaries: [PrototypeShareSongSummary] {
        PrototypeShareSongSummary.resolve(
            records: records.map(\.shareSongEntry),
            allTimeOverrides: allTimeSongOverrides
        )
    }

    private func makeShareCard(
        environment: PrototypeShareEnvironmentSnapshot
    ) -> PrototypePracticeSummaryCard {
        PrototypePracticeSummaryCard(
            periodTitle: periodTitle,
            records: records,
            completionPercentage: completionPercentage,
            allTimeCountOverrides: allTimeCountOverrides,
            allTimeSongOverrides: allTimeSongOverrides,
            allTimeTotalDurationOverride: allTimeTotalDurationOverride,
            environment: environment,
            generatedAt: generatedAt
        )
    }

    private var previewNotice: String {
        guard let environmentSnapshot else {
            return "正在获取本机当前位置；地点确认后会生成可分享的小票图片。"
        }
        return "小票汇总当前周期的全部手型数据，并显示英文地点：\(environmentSnapshot.locationText)。"
    }

    @ViewBuilder
    private var shareActions: some View {
        HStack(spacing: 10) {
            if let renderedImage {
                let transferableImage = Image(uiImage: renderedImage)

                ShareLink(
                    item: transferableImage,
                    subject: Text("GeoBeat 练习总结"),
                    message: Text(shareMessage),
                    preview: SharePreview(
                        "GeoBeat 练习总结",
                        image: transferableImage
                    )
                ) {
                    PrototypeShareActionLabel(
                        title: "分享图片",
                        symbol: "square.and.arrow.up"
                    )
                }
                .accessibilityLabel("分享练习总结图片")
            } else {
                PrototypeShareActionLabel(
                    title: "正在生成",
                    symbol: "hourglass"
                )
                .opacity(0.55)
                .accessibilityLabel("正在生成练习总结图片")
            }

            Button {
                saveToPhotoLibrary()
            } label: {
                PrototypeShareActionLabel(
                    title: saveState == .saving ? "保存中" : "保存到相册",
                    symbol: saveState == .saving ? "hourglass" : "square.and.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .disabled(renderedImage == nil || saveState == .saving)
            .accessibilityLabel(saveState == .saving ? "正在保存到相册" : "保存练习总结图片到相册")
        }
        .accessibilityElement(children: .contain)
    }

    private var saveFeedback: some View {
        LiquidControlPanel(contentPadding: 12, cornerRadius: 18) {
            HStack(spacing: 10) {
                if saveState == .saving {
                    ProgressView()
                        .tint(GeoTheme.text)
                } else {
                    Image(systemName: saveState.symbol)
                        .foregroundStyle(saveState.tint)
                }

                Text(saveState.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GeoTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(saveState.message)
    }

    private var totalCount: Int {
        receiptMetrics.totalCount
    }

    private var totalDuration: TimeInterval {
        receiptMetrics.totalDuration
    }

    private var activeDayCount: Int {
        receiptMetrics.activeDayCount
    }

    private var receiptMetrics: PrototypeShareReceiptMetrics {
        PrototypeShareReceiptMetrics.resolve(
            entries: records.map(\.receiptEntry),
            countOverrides: allTimeCountOverrides.map { overrides in
                Dictionary(uniqueKeysWithValues: PrototypeStatisticsHand.allCases.map { hand in
                    (hand.practiceHand, overrides[hand] ?? 0)
                })
            },
            totalDurationOverride: allTimeTotalDurationOverride
        )
    }

    private func count(for hand: PrototypeStatisticsHand) -> Int {
        if let override = allTimeCountOverrides?[hand] {
            return override
        }
        return records
            .filter { $0.hand == hand }
            .reduce(0) { $0 + $1.count }
    }

    private var cardAccessibilityLabel: String {
        let completion = completionPercentage.map { "，总曲目完成度百分之\($0)" } ?? "，没有设置练习目标的曲目"
        let environment = environmentSnapshot.map {
            "，地点 \($0.locationText)"
        } ?? "，正在获取位置"
        return "GeoBeat 练习总结，\(periodTitle)，全部手型共练习 \(totalCount) 次，共 \(activeDayCount) 天，总时长 \(prototypeDuration(totalDuration))\(completion)\(environment)"
    }

    private var shareMessage: String {
        let environment = environmentSnapshot.map {
            " · \($0.locationText)"
        } ?? ""
        if let completionPercentage {
            return "\(periodTitle) · 共练习 \(totalCount) 次 · 总时长 \(prototypeDuration(totalDuration)) · 总曲目完成度 \(completionPercentage)%\(environment)"
        }
        return "\(periodTitle) · 共练习 \(totalCount) 次 · 总时长 \(prototypeDuration(totalDuration))\(environment)"
    }

    @MainActor
    private func prepareShareImageIfNeeded() async {
        guard renderedImage == nil else { return }

        let snapshot = await environmentProvider.loadSnapshot()
        guard !Task.isCancelled else { return }
        environmentSnapshot = snapshot
        renderShareImageIfNeeded(environment: snapshot)
    }

    @MainActor
    private func renderShareImageIfNeeded(
        environment: PrototypeShareEnvironmentSnapshot
    ) {
        let renderer = ImageRenderer(
            content: makeShareCard(environment: environment)
                .frame(width: receiptSize.width, height: receiptSize.height)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        renderer.isOpaque = true

        if let image = renderer.uiImage {
            renderedImage = image
        } else {
            saveState = .failed("图片生成失败，请稍后重试。")
        }
    }

    private func saveToPhotoLibrary() {
        guard let imageData = renderedImage?.pngData() else {
            saveState = .failed("图片尚未生成，请稍后重试。")
            return
        }

        saveState = .saving

        Task { @MainActor in
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                saveState = .permissionDenied
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: imageData, options: nil)
                }
                saveState = .saved
            } catch {
                saveState = .failed("保存失败：\(error.localizedDescription)")
            }
        }
    }
}

private struct PrototypePracticeSummaryCard: View {
    let periodTitle: String
    let records: [PracticeStatisticsDisplayRecord]
    let completionPercentage: Int?
    let allTimeCountOverrides: [PrototypeStatisticsHand: Int]?
    let allTimeSongOverrides: [PrototypeShareSongAggregate]?
    let allTimeTotalDurationOverride: TimeInterval?
    let environment: PrototypeShareEnvironmentSnapshot
    let generatedAt: Date

    private var songSummaries: [PrototypeShareSongSummary] {
        PrototypeShareSongSummary.resolve(
            records: records.map(\.shareSongEntry),
            allTimeOverrides: allTimeSongOverrides
        )
    }

    private var referenceSize: CGSize {
        PrototypeShareReceiptLayout.size(songCount: songSummaries.count)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / referenceSize.width,
                geometry.size.height / referenceSize.height
            )

            receipt
                .frame(width: referenceSize.width, height: referenceSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
        }
        .aspectRatio(referenceSize.width / referenceSize.height, contentMode: .fit)
    }

    private var receipt: some View {
        VStack(spacing: 0) {
            receiptHeader
            receiptRule
                .padding(.vertical, 26)
            primaryTotal
            receiptRule
                .padding(.vertical, 26)
            metrics
            receiptRule
                .padding(.vertical, 28)
            practicedSongs
            receiptRule
                .padding(.vertical, 28)
            handBreakdown
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 48)
        .foregroundStyle(Color.black.opacity(0.9))
        .background(Color.white)
    }

    private var receiptHeader: some View {
        VStack(spacing: 10) {
            Group {
                if let appIcon = PrototypeAppIcon.image {
                    Image(uiImage: appIcon)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("AppIcon")
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 2)
            }

            Text("GEOBEAT PRACTICE RECEIPT")
                .font(.system(size: 36, weight: .black, design: .monospaced))
                .tracking(2.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("持续练习，听见变化")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .tracking(1.1)
            Text(periodTitle.uppercased())
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(generatedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .monospacedDigit()

            Text(environment.locationText)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
    }

    private var primaryTotal: some View {
        VStack(spacing: 8) {
            Text("TOTAL PRACTICE / 练习总次数")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .tracking(1.6)
            Text(totalCount.formatted())
                .font(.system(size: 78, weight: .black, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("TIMES / 次")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.78), lineWidth: 3)
        }
    }

    private var metrics: some View {
        VStack(spacing: 16) {
            PrototypeReceiptMetricRow(
                title: "总曲目完成度",
                value: completionPercentage.map { "\($0)%" } ?? "暂无目标"
            )
            PrototypeReceiptMetricRow(
                title: "练习天数",
                value: "\(activeDayCount) 天"
            )
            PrototypeReceiptMetricRow(
                title: "练习总时长",
                value: compactDuration(totalDuration)
            )
        }
    }

    private var practicedSongs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRACTICED SONGS / 练习曲目")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .tracking(1.1)

            if songSummaries.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("尚无练习记录")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                        Text("当前周期还没有可归属到曲目的练习")
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    }
                    Spacer(minLength: 12)
                    Text("—")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                }
                .frame(height: PrototypeShareReceiptLayout.additionalSongHeight)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(songSummaries.enumerated()), id: \.element.id) { index, song in
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(song.name)
                                    .font(.system(size: 25, weight: .black, design: .rounded))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.64)
                                Text("总时长 \(compactDuration(song.duration))")
                                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.66))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("×\(song.count)")
                                .font(.system(size: 32, weight: .black, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(height: PrototypeShareReceiptLayout.additionalSongHeight)
                        .overlay(alignment: .bottom) {
                            if index < songSummaries.count - 1 {
                                Rectangle()
                                    .fill(Color.black.opacity(0.18))
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var handBreakdown: some View {
        VStack(spacing: 14) {
            HStack {
                Text("HAND / 手型")
                Spacer()
                Text("FREQUENCY / 次数")
            }
            .font(.system(size: 17, weight: .black, design: .monospaced))

            ForEach(PrototypeStatisticsHand.allCases) { hand in
                HStack {
                    Text(hand.title)
                    Spacer()
                    Text("\(count(for: hand)) 次")
                        .monospacedDigit()
                }
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(0.2))
                        .frame(height: 1)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 13) {
            receiptBarcode
                .frame(width: 250, height: 2)
            Text("GEOBEAT")
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .tracking(2.2)
        }
        .frame(maxWidth: .infinity)
    }

    private var receiptBarcode: some View {
        Rectangle()
            .fill(Color.black.opacity(0.78))
        .accessibilityHidden(true)
    }

    private var receiptRule: some View {
        Rectangle()
            .fill(Color.black.opacity(0.78))
            .frame(height: 2)
    }

    private var totalCount: Int {
        receiptMetrics.totalCount
    }

    private var totalDuration: TimeInterval {
        receiptMetrics.totalDuration
    }

    private var activeDayCount: Int {
        receiptMetrics.activeDayCount
    }

    private var receiptMetrics: PrototypeShareReceiptMetrics {
        PrototypeShareReceiptMetrics.resolve(
            entries: records.map(\.receiptEntry),
            countOverrides: allTimeCountOverrides.map { overrides in
                Dictionary(uniqueKeysWithValues: PrototypeStatisticsHand.allCases.map { hand in
                    (hand.practiceHand, overrides[hand] ?? 0)
                })
            },
            totalDurationOverride: allTimeTotalDurationOverride
        )
    }

    private func count(for hand: PrototypeStatisticsHand) -> Int {
        if let override = allTimeCountOverrides?[hand] {
            return override
        }
        return records
            .filter { $0.hand == hand }
            .reduce(0) { $0 + $1.count }
    }

    private func compactDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        if totalSeconds >= 3_600 {
            let totalMinutes = totalSeconds / 60
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m"
        }
        return "\(totalSeconds)s"
    }
}

private struct PrototypeReceiptMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title)
            Spacer(minLength: 10)
            Text(value)
                .fontWeight(.black)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .font(.system(size: 22, weight: .semibold, design: .monospaced))
    }
}

private struct PrototypeShareActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(GeoTheme.text)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .prototypeGlassSurface(cornerRadius: 18, emphasized: true)
    }
}

private enum PrototypeAppIcon {
    static var image: UIImage? {
        let info = Bundle.main.infoDictionary
        let icons = info?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = primary?["CFBundleIconFiles"] as? [String]
        return names?.reversed().compactMap(UIImage.init(named:)).first
            ?? UIImage(named: "AppIcon")
    }
}

enum PrototypeShareLocationState: Equatable {
    case available(location: String)
    case denied
    case unavailable
}

/// A resolved one-shot location snapshot. Permission denial and lookup failure
/// still produce a final value, so exporting never depends on location access.
struct PrototypeShareEnvironmentSnapshot: Equatable {
    let locationText: String
    let sourceText: String

    static let loading = PrototypeShareEnvironmentSnapshot(
        locationText: "LOCATING…",
        sourceText: "正在获取本次分享所需的地点"
    )

    static func resolve(location: PrototypeShareLocationState) -> PrototypeShareEnvironmentSnapshot {
        switch location {
        case .denied:
            return PrototypeShareEnvironmentSnapshot(
                locationText: "LOCATION NOT SHARED",
                sourceText: "未获取定位 · 分享图片仍可生成"
            )
        case .unavailable:
            return PrototypeShareEnvironmentSnapshot(
                locationText: "LOCATION UNAVAILABLE",
                sourceText: "定位暂不可用 · 分享图片仍可生成"
            )
        case .available(let location):
            return PrototypeShareEnvironmentSnapshot(
                locationText: PrototypeShareEnglishLocationFormatter.normalized(location)
                    ?? "LOCATION UNAVAILABLE",
                sourceText: "位置仅用于生成本次分享图片"
            )
        }
    }
}

enum PrototypeShareEnglishLocationFormatter {
    static func formatted(city: String?, region: String?, country: String?) -> String? {
        let city = normalized(city)
        let region = normalized(region)
        let country = normalized(country)

        if let city, let region, city != region {
            return "\(city), \(region)"
        }
        return city ?? region ?? country
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "'", with: "’")
            .replacingOccurrences(of: "‘", with: "’")
            .replacingOccurrences(of: "ʼ", with: "’")
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

@MainActor
private final class PrototypeShareEnvironmentProvider: ObservableObject {
    private let locationProvider = PrototypeOneShotLocationProvider()
    private var cachedSnapshot: PrototypeShareEnvironmentSnapshot?

    func loadSnapshot() async -> PrototypeShareEnvironmentSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        let snapshot: PrototypeShareEnvironmentSnapshot
        switch await locationProvider.requestLocation() {
        case .denied:
            snapshot = .resolve(location: .denied)
        case .unavailable:
            snapshot = .resolve(location: .unavailable)
        case .location(let location):
            let resolvedLocation = await Self.locationName(for: location)
            snapshot = .resolve(
                location: resolvedLocation.map { .available(location: $0) }
                    ?? .unavailable
            )
        }

        cachedSnapshot = snapshot
        return snapshot
    }

    private static func locationName(for location: CLLocation) async -> String? {
        let resolver = PrototypeShareReverseGeocoder()
        return await withTaskCancellationHandler {
            await resolver.locationName(for: location)
        } onCancel: {
            Task { @MainActor in
                resolver.cancel()
            }
        }
    }
}

@MainActor
private final class PrototypeShareReverseGeocoder {
    private var continuation: CheckedContinuation<String?, Never>?
    private var activeRequest: AnyObject?
    private var timeoutTask: Task<Void, Never>?

    func locationName(for location: CLLocation) async -> String? {
        guard continuation == nil else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }

            if #available(iOS 26.0, *) {
                startModernRequest(for: location)
            } else {
                startLegacyRequest(for: location)
            }
        }
    }

    func cancel() {
        finish(nil)
    }

    @available(iOS 26.0, *)
    private func startModernRequest(for location: CLLocation) {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            finish(nil)
            return
        }
        activeRequest = request
        request.preferredLocale = Locale(identifier: "en_US")
        request.getMapItems { [weak self] mapItems, _ in
            let representations = mapItems?.first?.addressRepresentations
            self?.finish(
                representations?.cityWithContext(.short)
                    ?? representations?.cityName
                    ?? representations?.regionName
            )
        }
    }

    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    private func startLegacyRequest(for location: CLLocation) {
        let geocoder = CLGeocoder()
        activeRequest = geocoder
        geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "en_US")
        ) { [weak self] placemarks, _ in
            let placemark = placemarks?.first
            let locationName = PrototypeShareEnglishLocationFormatter.formatted(
                city: placemark?.locality ?? placemark?.subAdministrativeArea,
                region: placemark?.administrativeArea,
                country: placemark?.country
            )
            Task { @MainActor in
                self?.finish(locationName)
            }
        }
    }

    private func finish(_ city: String?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if #available(iOS 26.0, *),
           let request = activeRequest as? MKReverseGeocodingRequest {
            request.cancel()
        } else if let geocoder = activeRequest as? CLGeocoder {
            geocoder.cancelGeocode()
        }
        activeRequest = nil
        continuation.resume(returning: city)
    }
}

enum PrototypeShareLocationCandidate {
    static let maximumAge: TimeInterval = 120
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 10_000

    static func best(
        from locations: [CLLocation],
        now: Date = .now
    ) -> CLLocation? {
        locations
            .filter { location in
                location.horizontalAccuracy >= 0
                    && location.horizontalAccuracy <= maximumHorizontalAccuracy
                    && abs(location.timestamp.timeIntervalSince(now)) <= maximumAge
            }
            .min { lhs, rhs in
                lhs.horizontalAccuracy < rhs.horizontalAccuracy
            }
    }
}

private enum PrototypeOneShotLocationResult {
    case location(CLLocation)
    case denied
    case unavailable
}

@MainActor
private final class PrototypeOneShotLocationProvider: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<PrototypeOneShotLocationResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasRequestedAuthorization = false
    private var hasRequestedLocation = false

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func requestLocation() async -> PrototypeOneShotLocationResult {
        guard continuation == nil else { return .unavailable }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(.unavailable)
            }
            handleAuthorization(manager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = PrototypeShareLocationCandidate.best(from: locations) else {
            finish(.unavailable)
            return
        }
        finish(.location(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.unavailable)
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !hasRequestedLocation else { return }
            hasRequestedLocation = true
            manager.requestLocation()
        case .notDetermined:
            guard !hasRequestedAuthorization else { return }
            hasRequestedAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.denied)
        @unknown default:
            finish(.unavailable)
        }
    }

    private func finish(_ result: PrototypeOneShotLocationResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        continuation.resume(returning: result)
    }
}

private enum PrototypePhotoSaveState: Equatable {
    case idle
    case saving
    case saved
    case permissionDenied
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return ""
        case .saving:
            return "正在保存练习总结图片…"
        case .saved:
            return "已保存到相册，可以直接从照片中分享。"
        case .permissionDenied:
            return "没有相册添加权限，请在系统设置中允许 GeoBeat 添加照片。"
        case .failed(let message):
            return message
        }
    }

    var symbol: String {
        switch self {
        case .saved:
            return "checkmark.circle.fill"
        case .permissionDenied:
            return "lock.trianglebadge.exclamationmark.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle, .saving:
            return "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .saved:
            return .green
        case .permissionDenied, .failed:
            return .orange
        case .idle, .saving:
            return GeoTheme.muted
        }
    }
}

// MARK: - Settings

/// Persistent application settings and system-service entry points.
struct PrototypeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @ObservedObject private var cloudSync = ICloudSyncService.shared

    private let onOpenCurrentApp: (() -> Void)?
    private let practiceStore: PracticeLibraryStore?

    @AppStorage(PracticePreferenceKeys.defaultBPM)
    private var defaultBPM = PracticePreferencePolicy.defaultBPM
    @AppStorage(PracticePreferenceKeys.defaultBeats)
    private var defaultBeats = PracticePreferencePolicy.defaultBeats
    @AppStorage(PracticePreferenceKeys.metronomeSound)
    private var sound = PracticeMetronomeSound.penetratingWoodblock
    @AppStorage(PracticePreferenceKeys.continueAudioInBackground)
    private var backgroundPlayback = true
    @AppStorage(PracticePreferenceKeys.keepScreenAwake)
    private var keepScreenAwake = false
    @AppStorage(PracticePreferenceKeys.restReminderEnabled)
    private var restReminderEnabled = false
    @AppStorage(PracticePreferenceKeys.restReminderMinutes)
    private var restMinutes = PracticePreferencePolicy.defaultRestReminderMinutes
    @AppStorage(PracticePreferenceKeys.dailyReminderEnabled)
    private var dailyReminderEnabled = false
    @AppStorage(PracticePreferenceKeys.dailyReminderHour)
    private var dailyReminderHour = PracticePreferencePolicy.defaultDailyReminderHour
    @AppStorage(PracticePreferenceKeys.dailyReminderMinute)
    private var dailyReminderMinute = PracticePreferencePolicy.defaultDailyReminderMinute
    @AppStorage(PracticePreferenceKeys.appearanceMode)
    private var appearance = PracticeAppearanceMode.dark
    @AppStorage(PracticePreferenceKeys.buttonHapticsEnabled)
    private var buttonHaptics = true
    @AppStorage(PracticePreferenceKeys.beatVibrationEnabled)
    private var beatVibration = false

    @State private var isDefaultParameterScrubbing = false
    @State private var isShowingSoundPicker = false
    @State private var activeAlert: PrototypeSettingsAlert?
    @State private var reminderStatus = PrototypeReminderStatus.unknown

    init(
        practiceStore: PracticeLibraryStore? = nil,
        onOpenCurrentApp: (() -> Void)? = nil
    ) {
        self.onOpenCurrentApp = onOpenCurrentApp
        self.practiceStore = practiceStore
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        proCard
                        metronomeCard
                        remindersCard
                        appearanceCard
                        dataCard
                        aboutCard
                        if onOpenCurrentApp != nil {
                            currentAppButton
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(isDefaultParameterScrubbing)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .toolbarBackground(GeoTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert(item: $activeAlert, content: settingsAlert)
            .sheet(isPresented: $isShowingSoundPicker) {
                PrototypeSoundPickerSheet(
                    selection: $sound,
                    hapticsEnabled: buttonHaptics
                )
            }
            .task {
                normalizePersistedPreferences()
                await refreshReminderStatusAndScheduleIfNeeded()
            }
            .onChange(of: dailyReminderHour) { _, _ in
                rescheduleDailyReminderIfNeeded()
            }
            .onChange(of: dailyReminderMinute) { _, _ in
                rescheduleDailyReminderIfNeeded()
            }
        }
        // A presented sheet owns a separate presentation environment and does
        // not reliably inherit a dynamically changed color-scheme preference
        // from the view behind it. Apply the persisted mode to this window as
        // well so the currently visible settings hierarchy updates immediately.
        .preferredColorScheme(settingsColorScheme)
    }

    private var settingsColorScheme: ColorScheme? {
        switch appearance {
        case .followSystem:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var proCard: some View {
        NavigationLink {
            PrototypeProView()
        } label: {
            HStack(spacing: 15) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(GeoTheme.text)
                    .frame(width: 48, height: 48)
                    .geoCardSurface(cornerRadius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("GeoBeat PRO")
                        .font(.title3.weight(.black))
                        .foregroundStyle(GeoTheme.text)
                    Text(proCardSubtitle)
                        .font(.caption)
                        .foregroundStyle(GeoTheme.muted)
                }
                Spacer()
                if subscriptionStore.isPro {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(GeoTheme.controlAccent)
                        .accessibilityLabel("已订阅")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GeoTheme.muted)
            }
            .padding(20)
            .geoCardSurface(cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }

    private var proCardSubtitle: String {
        switch subscriptionStore.accessState {
        case .checking:
            "正在核对订阅状态"
        case .entitled:
            "专业版功能已启用"
        case .notEntitled:
            if let product = subscriptionStore.products.first {
                prototypeSubscriptionPriceLine(product)
            } else {
                "查看订阅方案"
            }
        }
    }

    private var metronomeCard: some View {
        PrototypeSettingsCard(title: "设置默认节拍器参数", symbol: "metronome") {
            LazyVGrid(
                columns: metronomeGridColumns,
                spacing: 10
            ) {
                PrototypeVerticalSettingTile(
                    title: "默认 BPM",
                    symbol: "speedometer",
                    value: $defaultBPM,
                    range: 30...240,
                    pointsPerStep: 3,
                    accessibilityUnit: "BPM",
                    hapticsEnabled: buttonHaptics,
                    onScrubbingChanged: { isDefaultParameterScrubbing = $0 }
                )

                PrototypeVerticalSettingTile(
                    title: "默认拍数",
                    symbol: "music.note",
                    value: $defaultBeats,
                    range: 3...9,
                    pointsPerStep: 18,
                    accessibilityUnit: "拍",
                    hapticsEnabled: buttonHaptics,
                    onScrubbingChanged: { isDefaultParameterScrubbing = $0 }
                )

                PrototypeSoundSettingTile(sound: sound.title) {
                    isShowingSoundPicker = true
                }

                PrototypeBackgroundPlaybackTile(
                    isEnabled: $backgroundPlayback,
                    hapticsEnabled: buttonHaptics
                )
            }

            PrototypeSettingsDivider()

            Toggle(isOn: $keepScreenAwake) {
                PrototypeSettingsRowLabel(
                    title: "练习时保持屏幕常亮",
                    detail: keepScreenAwake ? "节拍器播放时不自动锁屏" : "遵循系统自动锁屏设置",
                    symbol: "sun.max"
                )
            }
            .tint(GeoTheme.controlAccent)

            Text("在 BPM 或拍数卡片上向上、向下滑动即可调节")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    private var metronomeGridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var remindersCard: some View {
        PrototypeSettingsCard(title: "健康与习惯", symbol: "heart") {
            Toggle(isOn: $restReminderEnabled) {
                PrototypeSettingsRowLabel(
                    title: "默认休息提醒",
                    detail: restReminderEnabled ? "每 \(restMinutes) 分钟" : "关闭",
                    symbol: "cup.and.saucer"
                )
            }
            .tint(GeoTheme.controlAccent)

            PrototypeSettingsDivider()

            Toggle(isOn: dailyReminderBinding) {
                PrototypeSettingsRowLabel(
                    title: "每日打卡提醒",
                    detail: dailyReminderEnabled
                        ? String(format: "%02d:%02d · %@", dailyReminderHour, dailyReminderMinute, reminderStatus.shortTitle)
                        : "关闭",
                    symbol: "alarm"
                )
            }
            .tint(GeoTheme.controlAccent)

            NavigationLink {
                PrototypeReminderSettingsView(
                    restEnabled: $restReminderEnabled,
                    restMinutes: $restMinutes,
                    dailyEnabled: dailyReminderBinding,
                    dailyHour: $dailyReminderHour,
                    dailyMinute: $dailyReminderMinute,
                    reminderStatus: reminderStatus
                )
            } label: {
                PrototypeDisclosureRow(title: "调整提醒时间", symbol: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
        }
    }

    private var appearanceCard: some View {
        PrototypeSettingsCard(title: "外观与交互", symbol: "circle.lefthalf.filled") {
            NavigationLink {
                PrototypeAppearanceSettingsView(
                    appearance: $appearance,
                    buttonHaptics: $buttonHaptics,
                    beatVibration: $beatVibration
                )
            } label: {
                PrototypeSettingsRowLabel(
                    title: "显示模式",
                    detail: appearance.title,
                    symbol: "paintbrush"
                )
            }
            .buttonStyle(.plain)

            PrototypeSettingsDivider()

            Toggle(isOn: $buttonHaptics) {
                PrototypeSettingsRowLabel(
                    title: "按键触感",
                    detail: buttonHaptics ? "开启" : "关闭",
                    symbol: "hand.tap"
                )
            }
            .tint(GeoTheme.controlAccent)

            PrototypeSettingsDivider()

            Toggle(isOn: $beatVibration) {
                PrototypeSettingsRowLabel(
                    title: "节拍震动",
                    detail: beatVibration ? "开启" : "关闭",
                    symbol: "iphone.radiowaves.left.and.right"
                )
            }
            .tint(GeoTheme.controlAccent)
        }
    }

    private var dataCard: some View {
        PrototypeSettingsCard(title: "数据管理", symbol: "externaldrive") {
            Button(action: cloudSync.retryNow) {
                HStack(spacing: 10) {
                    PrototypeSettingsRowLabel(
                        title: "iCloud 同步",
                        detail: cloudSync.status.detail,
                        symbol: "icloud"
                    )
                    Text(cloudSync.status.badgeTitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(
                            cloudSync.status.isAvailable
                                ? GeoTheme.controlAccent
                                : GeoTheme.muted
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(GeoTheme.surfaceInk.opacity(0.06), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("轻点立即重试同步")

            PrototypeSettingsDivider()

            NavigationLink {
                PrototypeBackupRestoreView(practiceStore: practiceStore)
            } label: {
                PrototypeDisclosureRow(title: "备份与恢复", symbol: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutCard: some View {
        PrototypeSettingsCard(title: "关于我们", symbol: "info.circle") {
            Button {
                openFeedback()
            } label: {
                PrototypeDisclosureRow(title: "意见反馈", symbol: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.plain)

            PrototypeSettingsDivider()

            Button {
                PrototypeAppReviewService.requestReview()
            } label: {
                PrototypeDisclosureRow(title: "App Store 评分", symbol: "star")
            }
            .buttonStyle(.plain)

            PrototypeSettingsDivider()

            NavigationLink {
                PrototypeLegalView()
            } label: {
                PrototypeDisclosureRow(title: "隐私政策与协议", symbol: "hand.raised")
            }
            .buttonStyle(.plain)
        }
    }

    private var currentAppButton: some View {
        Button(action: { onOpenCurrentApp?() }) {
            Label("查看当前正式功能", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GeoTheme.text)
                .frame(maxWidth: .infinity, minHeight: 50)
                .geoCardSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var dailyReminderBinding: Binding<Bool> {
        Binding(
            get: { dailyReminderEnabled },
            set: { setDailyReminderEnabled($0) }
        )
    }

    private func normalizePersistedPreferences() {
        defaultBPM = PracticePreferencePolicy.normalizedBPM(defaultBPM)
        defaultBeats = PracticePreferencePolicy.normalizedBeats(defaultBeats)
        restMinutes = PracticePreferencePolicy
            .normalizedRestReminderMinutes(restMinutes)
        dailyReminderHour = PracticePreferencePolicy
            .normalizedReminderHour(dailyReminderHour)
        dailyReminderMinute = PracticePreferencePolicy
            .normalizedReminderMinute(dailyReminderMinute)
    }

    private func setDailyReminderEnabled(_ enabled: Bool) {
        if !enabled {
            dailyReminderEnabled = false
            reminderStatus = .disabled
            let request = PracticeDailyReminderService.register(
                enabled: false,
                hour: dailyReminderHour,
                minute: dailyReminderMinute,
                requestAuthorization: false
            )
            Task { @MainActor in
                let result = await PracticeDailyReminderService.apply(request)
                applyReminderResult(result)
            }
            return
        }

        reminderStatus = .requesting
        let request = PracticeDailyReminderService.register(
            enabled: true,
            hour: dailyReminderHour,
            minute: dailyReminderMinute,
            requestAuthorization: true
        )
        Task { @MainActor in
            let result = await PracticeDailyReminderService.apply(request)
            applyReminderResult(result)
        }
    }

    private func refreshReminderStatusAndScheduleIfNeeded() async {
        guard dailyReminderEnabled else {
            reminderStatus = .disabled
            let request = PracticeDailyReminderService.register(
                enabled: false,
                hour: dailyReminderHour,
                minute: dailyReminderMinute,
                requestAuthorization: false
            )
            _ = await PracticeDailyReminderService.apply(request)
            return
        }

        let request = PracticeDailyReminderService.register(
            enabled: true,
            hour: dailyReminderHour,
            minute: dailyReminderMinute,
            requestAuthorization: false
        )
        let result = await PracticeDailyReminderService.apply(request)
        applyReminderResult(result)
    }

    private func rescheduleDailyReminderIfNeeded() {
        dailyReminderHour = PracticePreferencePolicy
            .normalizedReminderHour(dailyReminderHour)
        dailyReminderMinute = PracticePreferencePolicy
            .normalizedReminderMinute(dailyReminderMinute)
        guard dailyReminderEnabled else { return }

        let request = PracticeDailyReminderService.register(
            enabled: true,
            hour: dailyReminderHour,
            minute: dailyReminderMinute,
            requestAuthorization: false
        )
        Task { @MainActor in
            let result = await PracticeDailyReminderService.apply(request)
            applyReminderResult(result)
        }
    }

    private func applyReminderResult(_ result: PracticeDailyReminderResult) {
        switch result {
        case .scheduled:
            dailyReminderEnabled = true
            reminderStatus = .scheduled
        case .disabled:
            dailyReminderEnabled = false
            reminderStatus = .disabled
        case .authorizationNotRequested:
            dailyReminderEnabled = false
            reminderStatus = .notRequested
        case .authorizationDenied:
            dailyReminderEnabled = false
            reminderStatus = .denied
            activeAlert = .notificationPermissionDenied
        case .failed(let message):
            dailyReminderEnabled = false
            reminderStatus = .failed
            activeAlert = .init(
                title: "提醒设置失败",
                message: message,
                offersSystemSettings: false
            )
        case .superseded:
            // A newer toggle or time change owns the final UI and system state.
            break
        }
    }

    private func openFeedback() {
        guard let address = Bundle.main.object(
            forInfoDictionaryKey: "GeoBeatFeedbackEmail"
        ) as? String,
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            activeAlert = .init(
                title: "反馈渠道暂不可用",
                message: "当前构建没有配置反馈邮箱。请通过邀请此测试版本的联系人提交反馈。",
                offersSystemSettings: false
            )
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: "GeoBeat 使用反馈")
        ]
        guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
            activeAlert = .init(
                title: "无法打开邮件应用",
                message: "设备上没有可处理邮件的应用。反馈邮箱：\(address)",
                offersSystemSettings: false
            )
            return
        }

        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            Task { @MainActor in
                activeAlert = .init(
                    title: "无法打开邮件应用",
                    message: "请手动发送邮件至 \(address)。",
                    offersSystemSettings: false
                )
            }
        }
    }

    private func settingsAlert(_ alert: PrototypeSettingsAlert) -> Alert {
        if alert.offersSystemSettings {
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("打开系统设置")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        return
                    }
                    UIApplication.shared.open(url)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text("知道了"))
        )
    }
}

private enum PrototypeReminderStatus: Equatable {
    case unknown
    case disabled
    case requesting
    case notRequested
    case scheduled
    case denied
    case failed

    var shortTitle: String {
        switch self {
        case .unknown: "正在检查"
        case .disabled: "未启用"
        case .requesting: "正在请求权限"
        case .notRequested: "等待授权"
        case .scheduled: "已安排"
        case .denied: "权限被拒绝"
        case .failed: "安排失败"
        }
    }
}

private struct PrototypeSettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersSystemSettings: Bool

    static let notificationPermissionDenied = PrototypeSettingsAlert(
        title: "通知权限未开启",
        message: "每日打卡提醒需要通知权限。可以前往系统设置允许 GeoBeat 发送通知。",
        offersSystemSettings: true
    )
}

private enum PracticeDailyReminderResult: Equatable {
    case scheduled
    case disabled
    case authorizationNotRequested
    case authorizationDenied
    case failed(String)
    case superseded
}

@MainActor
private enum PracticeDailyReminderService {
    private static let requestIdentifier = "geobeat.daily-practice-reminder.v1"
    struct DesiredState: Equatable {
        var enabled: Bool
        var hour: Int
        var minute: Int
        var requestAuthorization: Bool
    }

    struct Request {
        let token: Int
        let state: DesiredState
    }

    private static var generation = 0
    private static var desired = DesiredState(
        enabled: false,
        hour: PracticePreferencePolicy.defaultDailyReminderHour,
        minute: PracticePreferencePolicy.defaultDailyReminderMinute,
        requestAuthorization: false
    )

    /// Registers intent synchronously from the UI event. Work is launched in
    /// an unstructured task afterwards, so assigning the token here preserves
    /// the user's action order even if those tasks begin out of order.
    static func register(
        enabled: Bool,
        hour: Int,
        minute: Int,
        requestAuthorization: Bool
    ) -> Request {
        generation &+= 1
        desired = DesiredState(
            enabled: enabled,
            hour: PracticePreferencePolicy.normalizedReminderHour(hour),
            minute: PracticePreferencePolicy.normalizedReminderMinute(minute),
            requestAuthorization: requestAuthorization
        )
        return Request(token: generation, state: desired)
    }

    /// Applies the latest registered intent. Notification-center calls can
    /// suspend while permission UI is visible, so an older request can never
    /// recreate a reminder after a newer disable or time selection.
    static func apply(
        _ request: Request
    ) async -> PracticeDailyReminderResult {
        guard request.token == generation else { return .superseded }

        guard request.state.enabled else {
            removePendingRequest()
            return request.token == generation ? .disabled : .superseded
        }

        let result = await schedule(
            hour: request.state.hour,
            minute: request.state.minute,
            requestAuthorization: request.state.requestAuthorization
        )
        guard request.token == generation else {
            await reconcileLatestDesiredState()
            return .superseded
        }
        if result != .scheduled {
            desired.enabled = false
        }
        return result
    }

    private static func schedule(
        hour: Int,
        minute: Int,
        requestAuthorization: Bool
    ) async -> PracticeDailyReminderResult {
        let center = UNUserNotificationCenter.current()

        do {
            var authorization = await center.notificationSettings().authorizationStatus
            if authorization == .notDetermined {
                guard requestAuthorization else {
                    return .authorizationNotRequested
                }
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound]
                )
                guard granted else {
                    center.removePendingNotificationRequests(
                        withIdentifiers: [requestIdentifier]
                    )
                    return .authorizationDenied
                }
                authorization = await center.notificationSettings().authorizationStatus
            }

            switch authorization {
            case .authorized, .provisional, .ephemeral:
                break
            case .denied:
                center.removePendingNotificationRequests(
                    withIdentifiers: [requestIdentifier]
                )
                return .authorizationDenied
            case .notDetermined:
                return .authorizationNotRequested
            @unknown default:
                return .failed("系统返回了无法识别的通知授权状态。")
            }

            let normalizedHour = PracticePreferencePolicy
                .normalizedReminderHour(hour)
            let normalizedMinute = PracticePreferencePolicy
                .normalizedReminderMinute(minute)
            let content = UNMutableNotificationContent()
            content.title = "今天练琴了吗？"
            content.body = "打开 GeoBeat，记录今天的节拍练习。"
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(
                    hour: normalizedHour,
                    minute: normalizedMinute
                ),
                repeats: true
            )
            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: content,
                trigger: trigger
            )
            center.removePendingNotificationRequests(
                withIdentifiers: [requestIdentifier]
            )
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A stale operation may finish after a newer one. Reconcile in a loop so
    /// even another state change during the repair still converges to the
    /// latest desired state.
    private static func reconcileLatestDesiredState() async {
        while true {
            let token = generation
            let latest = desired
            if !latest.enabled {
                removePendingRequest()
            } else {
                _ = await schedule(
                    hour: latest.hour,
                    minute: latest.minute,
                    requestAuthorization: latest.requestAuthorization
                )
            }
            if token == generation { return }
        }
    }

    private static func removePendingRequest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [requestIdentifier]
        )
    }
}

@MainActor
private enum PrototypeAppReviewService {
    static func requestReview() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            if let url = URL(
                string: "itms-apps://itunes.apple.com/app/id6800982324?action=write-review"
            ) {
                UIApplication.shared.open(url)
            }
            return
        }
        AppStore.requestReview(in: scene)
    }
}

private struct PrototypeSettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline.weight(.bold))
                .foregroundStyle(GeoTheme.text)
            content
        }
        .padding(20)
        .geoCardSurface(cornerRadius: 22)
    }
}

private struct PrototypeVerticalSettingTile: View {
    let title: String
    let symbol: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let pointsPerStep: CGFloat
    let accessibilityUnit: String
    let hapticsEnabled: Bool
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @State private var draftValue: Int?
    @State private var dragStartValue: Int?
    @State private var isScrubbing = false

    private var displayedValue: Int {
        draftValue ?? value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.and.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(GeoTheme.muted)

            Text(displayedValue.formatted())
                .font(.system(size: 31, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(GeoTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .lineLimit(1)
        }
        .prototypeMetronomeTileSurface()
        .contentShape(Rectangle())
        .highPriorityGesture(scrubGesture)
        .onDisappear { resetScrub() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(displayedValue) \(accessibilityUnit)")
        .accessibilityHint("向上滑增加，向下滑减少")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = clamped(value + 1)
            case .decrement:
                value = clamped(value - 1)
            @unknown default:
                return
            }
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { gesture in
                setScrubbing(true)
                guard abs(gesture.translation.height) >= 4 else { return }

                if dragStartValue == nil {
                    dragStartValue = value
                    draftValue = value
                }
                guard let dragStartValue else { return }

                let steps = Int(
                    (-gesture.translation.height / pointsPerStep)
                        .rounded(.towardZero)
                )
                draftValue = clamped(dragStartValue + steps)
            }
            .onEnded { _ in
                if let draftValue, draftValue != value {
                    value = draftValue
                    if hapticsEnabled {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                resetScrub()
            }
    }

    private func clamped(_ proposedValue: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, proposedValue))
    }

    private func setScrubbing(_ active: Bool) {
        guard isScrubbing != active else { return }
        isScrubbing = active
        onScrubbingChanged(active)
    }

    private func resetScrub() {
        draftValue = nil
        dragStartValue = nil
        setScrubbing(false)
    }
}

private struct PrototypeSoundSettingTile: View {
    let sound: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(GeoTheme.muted)

                Text(sound)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text("节拍音色")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GeoTheme.muted)
            }
            .prototypeMetronomeTileSurface()
        }
        .buttonStyle(PrototypeMetronomeTilePressStyle())
        .accessibilityLabel("节拍音色")
        .accessibilityValue(sound)
        .accessibilityHint("打开可试听的音色列表")
    }
}

private struct PrototypeBackgroundPlaybackTile: View {
    @Binding var isEnabled: Bool
    let hapticsEnabled: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.20)) {
                isEnabled.toggle()
            }
            if hapticsEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: "waveform")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GeoTheme.muted)
                    Spacer(minLength: 8)
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(
                            isEnabled ? GeoTheme.controlAccent : GeoTheme.muted
                        )
                }

                Text(isEnabled ? "开启" : "关闭")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(GeoTheme.text)

                Text("后台运行")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GeoTheme.muted)
            }
            .prototypeMetronomeTileSurface()
        }
        .buttonStyle(PrototypeMetronomeTilePressStyle())
        .accessibilityLabel("后台运行")
        .accessibilityValue(isEnabled ? "开启" : "关闭")
        .accessibilityHint("双击切换锁屏后是否继续播放")
    }
}

private struct PrototypeMetronomeTileSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(14)
            .geoCardSurface(cornerRadius: 17)
    }
}

/// Gives these setting tiles a brief glass-like bloom while the finger is down,
/// then lets the highlight recede instead of dimming the tile abruptly.
private struct PrototypeMetronomeTilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let isPressed = configuration.isPressed

        configuration.label
            .brightness(isPressed ? (colorScheme == .dark ? 0.045 : -0.045) : 0)
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                GeoTheme.surfaceInk.opacity(0.14),
                                GeoTheme.surfaceInk.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && !reduceMotion ? 0.992 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : (isPressed
                        ? .easeOut(duration: 0.08)
                        : .easeOut(duration: 0.30)),
                value: isPressed
            )
    }
}

private extension View {
    func prototypeMetronomeTileSurface() -> some View {
        modifier(PrototypeMetronomeTileSurface())
    }
}

private struct PrototypeSoundPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: PracticeMetronomeSound
    let hapticsEnabled: Bool
    @StateObject private var previewPlayer = PrototypeMetronomeSoundPreviewPlayer()

    var body: some View {
        NavigationStack {
            ZStack {
                GeoBackground()

                ScrollView {
                    VStack(spacing: 12) {
                        Text("点击音色名称会保存选择并播放一次真实节拍；右侧播放键可以重复试听。试听与正式节拍器使用完全相同的音色波形。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let errorMessage = previewPlayer.errorMessage {
                            PrototypeNoticeBanner(
                                symbol: "exclamationmark.triangle",
                                text: errorMessage
                            )
                        }

                        ForEach(PracticeMetronomeSound.allCases) { option in
                            soundRow(option)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("选择节拍音色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .toolbarBackground(GeoTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            previewPlayer.stop()
        }
    }

    private func soundRow(_ option: PracticeMetronomeSound) -> some View {
        HStack(spacing: 10) {
            Button {
                selection = option
                previewPlayer.play(option)
                if hapticsEnabled {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection == option
                        ? "checkmark.circle.fill"
                        : "speaker.wave.2")
                        .font(.headline)
                        .frame(width: 26)
                    Text(option.title)
                        .font(.body.weight(.bold))
                    Spacer(minLength: 8)
                }
                .foregroundStyle(GeoTheme.text)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择\(option.title)")
            .accessibilityValue(selection == option ? "已选择" : "未选择")
            .accessibilityHint("选择并试听")

            Button { previewPlayer.play(option) } label: {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GeoTheme.text)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(LiquidPressButtonStyle())
            .prototypeGlassSurface(cornerRadius: 16, emphasized: true)
            .accessibilityLabel("试听\(option.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .geoCardSurface(cornerRadius: 18)
    }
}

/// Plays one real downbeat through the exact procedural profile used by the
/// shipping metronome. This graph is kept alive for the sound picker's lifetime
/// so repeated previews do not rebuild audio hardware state.
@MainActor
private final class PrototypeMetronomeSoundPreviewPlayer: ObservableObject {
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!
    private var playbackToken = UUID()

    init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
    }

    func play(_ sound: PracticeMetronomeSound) {
        playbackToken = UUID()
        let token = playbackToken
        playerNode.stop()
        playerNode.reset()

        do {
            try prepareSharedAudioSession()
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }

            let samples = MetronomeClickWaveform.samples(
                for: .downbeat,
                sound: sound,
                sampleRate: format.sampleRate
            )
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                  ),
                  let channel = buffer.floatChannelData?[0]
            else {
                throw PrototypeSoundPreviewError.cannotRender
            }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                channel[index] = sample
            }

            playerNode.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackToken == token else { return }
                    self.playerNode.stop()
                    if self.audioEngine.isRunning {
                        self.audioEngine.pause()
                    }
                }
            }
            playerNode.play()
            errorMessage = nil
        } catch {
            playerNode.stop()
            if audioEngine.isRunning {
                audioEngine.pause()
            }
            errorMessage = "无法试听节拍音色：\(error.localizedDescription)"
        }
    }

    func stop() {
        playbackToken = UUID()
        playerNode.stop()
        playerNode.reset()
        if audioEngine.isRunning {
            audioEngine.pause()
        }
    }

    private func prepareSharedAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let requiredOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if session.category != .playback
            || session.mode != .default
            || !session.categoryOptions.contains(requiredOptions) {
            try session.setCategory(
                .playback,
                mode: .default,
                options: requiredOptions
            )
        }
        try session.setActive(true)

        // AVAudioSession is process-wide. Do not deactivate it when a preview
        // finishes: the live metronome may own the same session concurrently.
        // Stopping only this private graph cannot interrupt active practice.
    }
}

private enum PrototypeSoundPreviewError: LocalizedError {
    case cannotRender

    var errorDescription: String? {
        switch self {
        case .cannotRender:
            "无法生成节拍波形。"
        }
    }
}

private struct PrototypeSettingsRowLabel: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(GeoTheme.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GeoTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(GeoTheme.muted)
            }
            Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
    }
}

private struct PrototypeDisclosureRow: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(GeoTheme.muted)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GeoTheme.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(GeoTheme.muted)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct PrototypeSettingsDivider: View {
    var body: some View {
        Divider().overlay(GeoTheme.surfaceInk.opacity(0.08))
    }
}

private struct PrototypeNoticeBanner: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(GeoTheme.text)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(GeoTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .geoCardSurface(cornerRadius: 16)
    }
}

// MARK: Settings destinations

struct PrototypeProView: View {
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    var body: some View {
        ZStack {
            GeoBackground()
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(GeoTheme.controlAccent)
                    Text("GeoBeat PRO")
                        .font(.largeTitle.weight(.black))
                    Text(subscriptionStore.isPro ? "专业版功能已启用" : "解锁更完整的练习洞察")
                        .font(.body)
                        .foregroundStyle(GeoTheme.muted)
                        .multilineTextAlignment(.center)

                    if subscriptionStore.accessState == .checking {
                        GeoCard(cornerRadius: 22) {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("正在核对 App Store 订阅状态…")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if subscriptionStore.isPro {
                        GeoCard(cornerRadius: 22) {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("GeoBeat PRO 已启用", systemImage: "checkmark.seal.fill")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(GeoTheme.controlAccent)
                                Text("你的专业版权益已通过 App Store 验证。")
                                    .foregroundStyle(GeoTheme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        benefitsCard

                        switch subscriptionStore.productLoadState {
                        case .idle, .loading:
                            GeoCard(cornerRadius: 22) {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("正在读取 App Store 订阅方案…")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 72)
                            }
                        case .failed:
                            GeoCard(cornerRadius: 22) {
                                VStack(spacing: 12) {
                                    Text("暂时无法读取订阅方案")
                                        .font(.headline)
                                    Text("请检查网络后重新加载。")
                                        .font(.subheadline)
                                        .foregroundStyle(GeoTheme.muted)
                                    Button("重新加载") {
                                        Task { await subscriptionStore.prepare() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(GeoTheme.controlAccent)
                                    .disabled(subscriptionStore.isBusy || subscriptionStore.productLoadState == .loading)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        case .loaded, .partial:
                            ForEach(subscriptionStore.products) { product in
                                subscriptionProductCard(product)
                            }
                        }
                    }

                    if let message = subscriptionStore.message {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(GeoTheme.controlAccent)
                            Text(message)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                subscriptionStore.clearMessage()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭提示")
                        }
                        .padding(14)
                        .geoCardSurface(cornerRadius: 16)
                    }

                    Button {
                        Task { await subscriptionStore.restorePurchases() }
                    } label: {
                        Label("恢复购买", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(subscriptionStore.isBusy)

                    if let manageSubscriptionsURL {
                        Link(destination: manageSubscriptionsURL) {
                            Label("管理 App Store 订阅", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(spacing: 10) {
                        Text("订阅会自动续订，除非在当前订阅周期结束至少 24 小时前取消。购买与续订费用由 App Store 账户收取，可随时在账户设置中管理。")
                            .font(.caption2)
                            .foregroundStyle(GeoTheme.muted)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 18) {
                            if let privacyPolicyURL {
                                Link("隐私政策", destination: privacyPolicyURL)
                            }
                            if let termsURL {
                                Link("使用条款", destination: termsURL)
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(GeoTheme.text)
                .frame(maxWidth: 560)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("GeoBeat PRO")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await subscriptionStore.prepare()
        }
    }

    private var benefitsCard: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Label("深度曲目分析与速度趋势", systemImage: "chart.xyaxis.line")
                Label("左右手表现对比", systemImage: "hand.raised.fingers.spread")
                Label("曲目练习时长分布", systemImage: "chart.bar.xaxis")
                Label("独立选择 BPM 基准音符", systemImage: "metronome")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subscriptionProductCard(_ product: Product) -> some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.displayName)
                            .font(.title3.weight(.bold))
                        if !product.description.isEmpty {
                            Text(product.description)
                                .font(.subheadline)
                                .foregroundStyle(GeoTheme.muted)
                        }
                    }
                    Spacer(minLength: 16)
                    Text(prototypeSubscriptionPriceLine(product))
                        .font(.headline.weight(.black))
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    Task { await subscriptionStore.purchase(product) }
                } label: {
                    Group {
                        if subscriptionStore.isBusy {
                            ProgressView()
                        } else {
                            Text("订阅 GeoBeat PRO")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(GeoTheme.controlAccent)
                .disabled(subscriptionStore.isBusy || !subscriptionStore.canMakePayments)

                if !subscriptionStore.canMakePayments {
                    Text("此设备当前已限制 App Store 购买。")
                        .font(.caption)
                        .foregroundStyle(GeoTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private var termsURL: URL? {
        URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }

    private var privacyPolicyURL: URL? {
        URL(string: "https://geobeatpractice.com/privacy/")
    }
}

struct PrototypeProFeatureUpsell: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(GeoTheme.muted)
            NavigationLink {
                PrototypeProView()
            } label: {
                Label("解锁 GeoBeat PRO", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(GeoTheme.controlAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func prototypeSubscriptionPriceLine(_ product: Product) -> String {
    guard let period = product.subscription?.subscriptionPeriod else {
        return product.displayPrice
    }

    let unit: String
    switch period.unit {
    case .day:
        unit = "天"
    case .week:
        unit = "周"
    case .month:
        unit = "月"
    case .year:
        unit = "年"
    @unknown default:
        return product.displayPrice
    }
    let periodText = period.value == 1 ? unit : "\(period.value)\(unit)"
    return "\(product.displayPrice) / \(periodText)"
}

private struct PrototypeReminderSettingsView: View {
    @Binding var restEnabled: Bool
    @Binding var restMinutes: Int
    @Binding var dailyEnabled: Bool
    @Binding var dailyHour: Int
    @Binding var dailyMinute: Int
    let reminderStatus: PrototypeReminderStatus

    var body: some View {
        PrototypeSettingsDestination(title: "提醒设置") {
            PrototypeSettingsCard(title: "休息提醒", symbol: "cup.and.saucer") {
                Toggle("开启休息提醒", isOn: $restEnabled)
                    .tint(GeoTheme.controlAccent)
                if restEnabled {
                    Stepper("每 \(restMinutes) 分钟提醒", value: $restMinutes, in: 10...120, step: 5)
                }
            }

            PrototypeSettingsCard(title: "每日打卡", symbol: "alarm") {
                Toggle("开启每日提醒", isOn: $dailyEnabled)
                    .tint(GeoTheme.controlAccent)
                if dailyEnabled {
                    Stepper(
                        String(format: "每天 %02d:%02d", dailyHour, dailyMinute),
                        value: $dailyHour,
                        in: 0...23
                    )
                    Stepper(
                        "分钟 \(String(format: "%02d", dailyMinute))",
                        value: $dailyMinute,
                        in: 0...55,
                        step: 5
                    )
                }
                Text("系统状态：\(reminderStatus.shortTitle)")
                    .font(.caption)
                    .foregroundStyle(GeoTheme.muted)
            }
        }
    }
}

private struct PrototypeAppearanceSettingsView: View {
    @Binding var appearance: PracticeAppearanceMode
    @Binding var buttonHaptics: Bool
    @Binding var beatVibration: Bool

    var body: some View {
        PrototypeSettingsDestination(title: "外观与交互") {
            PrototypeSettingsCard(title: "显示模式", symbol: "circle.lefthalf.filled") {
                ForEach(PracticeAppearanceMode.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            appearance = option
                        }
                    } label: {
                        HStack {
                            Label(option.title, systemImage: option.symbol)
                            Spacer()
                            if appearance == option {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .foregroundStyle(GeoTheme.text)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if option != PracticeAppearanceMode.allCases.last {
                        PrototypeSettingsDivider()
                    }
                }
            }

            PrototypeSettingsCard(title: "触感", symbol: "hand.tap") {
                Toggle("按键触感", isOn: $buttonHaptics)
                    .tint(GeoTheme.controlAccent)
                PrototypeSettingsDivider()
                Toggle("节拍震动", isOn: $beatVibration)
                    .tint(GeoTheme.controlAccent)
            }
        }
    }
}

struct PrototypeBackupRestoreView: View {
    let practiceStore: PracticeLibraryStore?

    @State private var exportDocument: GeoBeatBackupFile?
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var pendingRestoreData: Data?
    @State private var isConfirmingRestore = false
    @State private var operationState: GeoBeatBackupOperationState?

    var body: some View {
        PrototypeSettingsDestination(title: "备份与恢复") {
            PrototypeNoticeBanner(
                symbol: "externaldrive.badge.exclamationmark",
                text: practiceStore == nil
                    ? "当前运行入口尚未连接练习资料库，备份操作不可用。"
                    : "备份包含曲目、段落、练习历史、目标和目录。恢复会用所选文件完整替换当前练习资料，并在执行前再次确认。"
            )

            PrototypeSettingsCard(title: "本地数据", symbol: "externaldrive") {
                Button(action: prepareExport) {
                    PrototypeDisclosureRow(title: "导出备份", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.backup.export")
                .disabled(practiceStore == nil)
                .opacity(practiceStore == nil ? 0.45 : 1)

                PrototypeSettingsDivider()

                Button(action: beginImport) {
                    PrototypeDisclosureRow(title: "从备份恢复", symbol: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.backup.import")
                .disabled(practiceStore == nil)
                .opacity(practiceStore == nil ? 0.45 : 1)
            }

            if let operationState {
                PrototypeNoticeBanner(
                    symbol: operationState.symbol,
                    text: operationState.message
                )
            }
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: backupFilename,
            onCompletion: finishExport
        )
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: loadRestoreCandidate
        )
        .confirmationDialog(
            "确认恢复备份？",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("覆盖当前练习资料", role: .destructive, action: restorePendingBackup)
                .accessibilityIdentifier("settings.backup.confirmRestore")
            Button("取消", role: .cancel) {
                pendingRestoreData = nil
            }
        } message: {
            Text("当前曲目、段落、练习历史、目标和目录将由备份文件替换。此操作无法在应用内撤销。")
        }
    }

    private func prepareExport() {
        guard let practiceStore else { return }
        do {
            exportDocument = GeoBeatBackupFile(
                data: try practiceStore.makeBackupData()
            )
            operationState = nil
            isShowingExporter = true
        } catch {
            operationState = .failed("无法生成备份：\(error.localizedDescription)")
        }
    }

    private func finishExport(_ result: Result<URL, Error>) {
        exportDocument = nil
        switch result {
        case .success:
            operationState = .succeeded("备份文件已导出。")
        case .failure(let error):
            operationState = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    private func beginImport() {
        guard let practiceStore else { return }
        guard practiceStore.protectedEventID == nil else {
            operationState = .failed("当前有尚未处理完的练习，请先完成或放弃本轮练习再恢复备份。")
            return
        }
        operationState = nil
        isShowingImporter = true
    }

    private func loadRestoreCandidate(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                operationState = .failed("没有选择备份文件。")
                return
            }
            let receivedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if receivedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                pendingRestoreData = try Data(contentsOf: url)
                isConfirmingRestore = true
            } catch {
                operationState = .failed("无法读取备份：\(error.localizedDescription)")
            }
        case .failure(let error):
            operationState = .failed("选择文件失败：\(error.localizedDescription)")
        }
    }

    private func restorePendingBackup() {
        defer { pendingRestoreData = nil }
        guard let practiceStore, let pendingRestoreData else {
            operationState = .failed("备份文件已不可用，请重新选择。")
            return
        }
        guard practiceStore.protectedEventID == nil else {
            operationState = .failed("当前有尚未处理完的练习，未执行恢复。")
            return
        }
        do {
            try practiceStore.restoreBackup(from: pendingRestoreData)
            operationState = .succeeded("备份恢复完成，练习资料已重新载入。")
        } catch {
            operationState = .failed("恢复失败：\(error.localizedDescription)")
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "GeoBeat-Backup-\(formatter.string(from: .now))"
    }
}

private struct GeoBeatBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum GeoBeatBackupOperationState: Equatable {
    case succeeded(String)
    case failed(String)

    var message: String {
        switch self {
        case .succeeded(let message), .failed(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct PrototypeLegalView: View {
    var body: some View {
        PrototypeSettingsDestination(title: "隐私政策与协议") {
            PrototypeSettingsCard(title: "隐私说明", symbol: "hand.raised") {
                Text("GeoBeat 的练习项目与练习记录会先保存在此设备，并通过你的私人 iCloud 空间自动同步。断网或 iCloud 不可用时仍可正常使用，恢复连接后会合并数据；这些内容不会用于广告追踪。")
                    .font(.body)
                    .foregroundStyle(GeoTheme.muted)
                Text("只有在你主动打开分享小票时，应用才会请求使用期间定位，用于在小票上显示英文城市与地区；定位结果只用于生成本次分享图片，不会写入练习记录。只有在你选择“保存到相册”时，应用才会请求照片添加权限。每日提醒仅使用设备本地通知。")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GeoTheme.text)
                Text("练习资料会保留到你在应用内删除相应曲目或记录；本机副本也会在卸载应用时移除。已同步到私人 iCloud 的副本会随应用内删除继续同步，你也可以在系统的 iCloud 储存空间中移除。定位、照片和通知权限可随时在系统设置中撤回。")
                    .font(.body)
                    .foregroundStyle(GeoTheme.muted)
                Text("订阅购买、续订与退款由 Apple 处理，GeoBeat 不会取得你的银行卡或完整付款资料，只读取经 Apple 验证的商品与权益状态。私人 iCloud 同步和系统地理编码同样由 Apple 的平台服务处理；应用不会把这些资料提供给广告商或数据经纪商。")
                    .font(.body)
                    .foregroundStyle(GeoTheme.muted)
            }

            PrototypeSettingsCard(title: "应用信息", symbol: "info.circle") {
                PrototypeSettingsRowLabel(
                    title: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "GeoBeat",
                    detail: "版本 \(appVersion)",
                    symbol: "app"
                )
                PrototypeSettingsDivider()
                PrototypeSettingsRowLabel(
                    title: "Bundle Identifier",
                    detail: Bundle.main.bundleIdentifier ?? "未知",
                    symbol: "number"
                )
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct PrototypeSettingsDestination<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            GeoBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    content
                }
                .frame(maxWidth: 680)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(GeoTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private func prototypeDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

#Preview("Prototype Statistics") {
    PrototypeStatisticsView(practiceStore: PracticeLibraryStore())
        .environmentObject(SubscriptionStore(observesTransactions: false))
}

#Preview("Prototype Settings") {
    PrototypeSettingsView()
        .environmentObject(SubscriptionStore(observesTransactions: false))
}
