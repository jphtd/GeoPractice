import Foundation

/// Immutable input consumed by the statistics engine.
///
/// Persisted models should be converted to this value before aggregation so
/// statistics stay independent from SwiftData and SwiftUI.
struct PracticeHistoryRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceEventID: UUID?
    let eventNameSnapshot: String
    let startedAt: Date
    let finishedAt: Date

    let leftCount: Int
    let rightCount: Int
    let bothCount: Int
    let leftDurationMilliseconds: Int64
    let rightDurationMilliseconds: Int64
    let bothDurationMilliseconds: Int64

    let bpm: Int?
    let beats: Int?
    let subdivision: Int?
    let directionRawValue: String?
    let grouping: String?
    let referenceNoteRaw: String?
    let sessionID: UUID?

    init(
        id: UUID,
        sourceEventID: UUID?,
        eventNameSnapshot: String,
        startedAt: Date,
        finishedAt: Date,
        leftCount: Int,
        rightCount: Int,
        bothCount: Int,
        leftDurationMilliseconds: Int64,
        rightDurationMilliseconds: Int64,
        bothDurationMilliseconds: Int64,
        bpm: Int? = nil,
        beats: Int? = nil,
        subdivision: Int? = nil,
        directionRawValue: String? = nil,
        grouping: String? = nil,
        referenceNoteRaw: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.eventNameSnapshot = eventNameSnapshot
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.bothCount = bothCount
        self.leftDurationMilliseconds = leftDurationMilliseconds
        self.rightDurationMilliseconds = rightDurationMilliseconds
        self.bothDurationMilliseconds = bothDurationMilliseconds
        self.bpm = bpm
        self.beats = beats
        self.subdivision = subdivision
        self.directionRawValue = directionRawValue
        self.grouping = grouping
        self.referenceNoteRaw = referenceNoteRaw
        self.sessionID = sessionID
    }

    var left: HandPracticeStats {
        HandPracticeStats(
            count: leftCount,
            durationMilliseconds: leftDurationMilliseconds
        )
    }

    var right: HandPracticeStats {
        HandPracticeStats(
            count: rightCount,
            durationMilliseconds: rightDurationMilliseconds
        )
    }

    var both: HandPracticeStats {
        HandPracticeStats(
            count: bothCount,
            durationMilliseconds: bothDurationMilliseconds
        )
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    var totalCount: Int {
        StatisticsMath.saturatedSum([
            max(0, leftCount),
            max(0, rightCount),
            max(0, bothCount)
        ])
    }

    var totalDurationMilliseconds: Int64 {
        StatisticsMath.saturatedSum([
            max(0, leftDurationMilliseconds),
            max(0, rightDurationMilliseconds),
            max(0, bothDurationMilliseconds)
        ])
    }
}

enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }
}

struct PracticeStatisticsQuery: Equatable, Sendable {
    var period: StatisticsPeriod
    var anchorDate: Date
    var calendar: Calendar

    init(
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) {
        self.period = period
        self.anchorDate = anchorDate
        self.calendar = calendar
    }
}

struct PracticeStatisticsSummary: Equatable, Sendable {
    let totalCount: Int
    let sessionCount: Int
    let activeDayCount: Int
    let totalDurationMilliseconds: Int64

    static let zero = PracticeStatisticsSummary(
        totalCount: 0,
        sessionCount: 0,
        activeDayCount: 0,
        totalDurationMilliseconds: 0
    )
}

struct PracticeEventStatistics: Identifiable, Equatable, Sendable {
    let eventID: UUID?
    let name: String
    let totalCount: Int
    let sessionCount: Int
    let activeDayCount: Int
    let totalDurationMilliseconds: Int64
    let dailyCounts: [Date: Int]
    let dailySessionCounts: [Date: Int]
    let latestFinishedAt: Date

    var id: String {
        eventID?.uuidString ?? "name:\(name)"
    }
}

struct PracticeDayTimelineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let eventID: UUID?
    let name: String
    let startedAt: Date
    let finishedAt: Date
    let left: HandPracticeStats
    let right: HandPracticeStats
    let both: HandPracticeStats
    let bpm: Int?
    let beats: Int?
    let subdivision: Int?

    var totalCount: Int {
        StatisticsMath.saturatedSum([left.count, right.count, both.count])
    }

    var totalDurationMilliseconds: Int64 {
        StatisticsMath.saturatedSum([
            left.durationMilliseconds,
            right.durationMilliseconds,
            both.durationMilliseconds
        ])
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }
}

struct PracticeDailyBucket: Identifiable, Equatable, Sendable {
    let date: Date
    let totalCount: Int
    let sessionCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { date }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeCalendarDay: Identifiable, Equatable, Sendable {
    let date: Date
    let isInDisplayedMonth: Bool
    let totalCount: Int
    let sessionCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { date }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeMonthlyBucket: Identifiable, Equatable, Sendable {
    let month: Int
    let startDate: Date
    let totalCount: Int
    let sessionCount: Int
    let activeDayCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { startDate }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeStatisticsResult: Equatable, Sendable {
    let query: PracticeStatisticsQuery
    let interval: DateInterval
    let records: [PracticeHistoryRecordSnapshot]
    let summary: PracticeStatisticsSummary
    let events: [PracticeEventStatistics]
}

enum StatisticsTimelineOrder: Sendable {
    case newestFirst
    case oldestFirst
}

enum PracticeStatisticsEngine {
    static func query(
        records: [PracticeHistoryRecordSnapshot],
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> PracticeStatisticsResult {
        query(
            records: records,
            query: PracticeStatisticsQuery(
                period: period,
                anchorDate: anchorDate,
                calendar: calendar
            )
        )
    }

    static func query(
        records: [PracticeHistoryRecordSnapshot],
        query: PracticeStatisticsQuery
    ) -> PracticeStatisticsResult {
        let interval = periodInterval(
            for: query.period,
            anchorDate: query.anchorDate,
            calendar: query.calendar
        )
        let filtered = sortedNewestFirst(records.filter {
            interval.containsHalfOpen($0.startedAt)
        })
        return PracticeStatisticsResult(
            query: query,
            interval: interval,
            records: filtered,
            summary: summary(records: filtered, calendar: query.calendar),
            events: aggregateEvents(records: filtered, calendar: query.calendar)
        )
    }

    static func periodInterval(
        for period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }

        if let interval = calendar.dateInterval(of: component, for: anchorDate) {
            return interval
        }

        let start = calendar.startOfDay(for: anchorDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func offsetAnchor(
        _ anchorDate: Date,
        period: StatisticsPeriod,
        by value: Int,
        calendar: Calendar = .current
    ) -> Date {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(
            byAdding: component,
            value: value,
            to: anchorDate
        ) ?? anchorDate
    }

    static func summary(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar = .current
    ) -> PracticeStatisticsSummary {
        guard !records.isEmpty else { return .zero }

        let days = Set(records.map { calendar.startOfDay(for: $0.startedAt) })
        return PracticeStatisticsSummary(
            totalCount: StatisticsMath.saturatedSum(records.map(\.totalCount)),
            sessionCount: records.count,
            activeDayCount: days.count,
            totalDurationMilliseconds: StatisticsMath.saturatedSum(
                records.map(\.totalDurationMilliseconds)
            )
        )
    }

    static func eventStatistics(
        records: [PracticeHistoryRecordSnapshot],
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeEventStatistics] {
        query(
            records: records,
            period: period,
            anchorDate: anchorDate,
            calendar: calendar
        ).events
    }

    static func dayTimeline(
        records: [PracticeHistoryRecordSnapshot],
        anchorDate: Date,
        calendar: Calendar = .current,
        order: StatisticsTimelineOrder = .newestFirst
    ) -> [PracticeDayTimelineItem] {
        let dayRecords = query(
            records: records,
            period: .day,
            anchorDate: anchorDate,
            calendar: calendar
        ).records
        let items = dayRecords.map { record in
            PracticeDayTimelineItem(
                id: record.id,
                eventID: record.sourceEventID,
                name: record.eventNameSnapshot,
                startedAt: record.startedAt,
                finishedAt: record.finishedAt,
                left: record.left,
                right: record.right,
                both: record.both,
                bpm: record.bpm,
                beats: record.beats,
                subdivision: record.subdivision
            )
        }
        switch order {
        case .newestFirst:
            return items
        case .oldestFirst:
            return Array(items.reversed())
        }
    }

    static func weekBuckets(
        records: [PracticeHistoryRecordSnapshot],
        week anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeDailyBucket] {
        let interval = periodInterval(
            for: .week,
            anchorDate: anchorDate,
            calendar: calendar
        )
        let grouped = dailyRecords(records: records, calendar: calendar)
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: interval.start
            ) else { return nil }
            let day = calendar.startOfDay(for: date)
            let samples = grouped[day] ?? []
            return PracticeDailyBucket(
                date: day,
                totalCount: StatisticsMath.saturatedSum(samples.map(\.totalCount)),
                sessionCount: samples.count,
                totalDurationMilliseconds: StatisticsMath.saturatedSum(
                    samples.map(\.totalDurationMilliseconds)
                )
            )
        }
    }

    /// A stable six-week grid keeps the month UI from jumping between 5 and
    /// 6 rows and always includes leading/trailing placeholder days.
    static func monthCalendar(
        records: [PracticeHistoryRecordSnapshot],
        month anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeCalendarDay] {
        let monthInterval = periodInterval(
            for: .month,
            anchorDate: anchorDate,
            calendar: calendar
        )
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDays,
            to: monthInterval.start
        ) ?? monthInterval.start
        let grouped = dailyRecords(records: records, calendar: calendar)

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: gridStart
            ) else { return nil }
            let day = calendar.startOfDay(for: date)
            let samples = grouped[day] ?? []
            return PracticeCalendarDay(
                date: day,
                isInDisplayedMonth: monthInterval.containsHalfOpen(day),
                totalCount: StatisticsMath.saturatedSum(samples.map(\.totalCount)),
                sessionCount: samples.count,
                totalDurationMilliseconds: StatisticsMath.saturatedSum(
                    samples.map(\.totalDurationMilliseconds)
                )
            )
        }
    }

    static func yearBuckets(
        records: [PracticeHistoryRecordSnapshot],
        year anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeMonthlyBucket] {
        let yearInterval = periodInterval(
            for: .year,
            anchorDate: anchorDate,
            calendar: calendar
        )
        return (0..<12).compactMap { offset in
            guard let monthStart = calendar.date(
                byAdding: .month,
                value: offset,
                to: yearInterval.start
            ) else { return nil }
            let interval = periodInterval(
                for: .month,
                anchorDate: monthStart,
                calendar: calendar
            )
            let samples = records.filter {
                interval.containsHalfOpen($0.startedAt)
            }
            let month = calendar.component(.month, from: monthStart)
            let monthSummary = summary(records: samples, calendar: calendar)
            return PracticeMonthlyBucket(
                month: month,
                startDate: monthStart,
                totalCount: monthSummary.totalCount,
                sessionCount: monthSummary.sessionCount,
                activeDayCount: monthSummary.activeDayCount,
                totalDurationMilliseconds: monthSummary.totalDurationMilliseconds
            )
        }
    }

    private enum EventGroupKey: Hashable {
        case event(UUID)
        case name(String)
    }

    private static func aggregateEvents(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar
    ) -> [PracticeEventStatistics] {
        let grouped = Dictionary(grouping: records) { record in
            if let eventID = record.sourceEventID {
                return EventGroupKey.event(eventID)
            }
            return EventGroupKey.name(record.eventNameSnapshot)
        }

        return grouped.compactMap { key, records in
            guard let latest = sortedLatestFinishedFirst(records).first else { return nil }
            var dailyCounts: [Date: Int] = [:]
            var dailySessionCounts: [Date: Int] = [:]
            for record in records {
                let day = calendar.startOfDay(for: record.startedAt)
                dailyCounts[day] = StatisticsMath.saturatedAdd(
                    dailyCounts[day] ?? 0,
                    record.totalCount
                )
                dailySessionCounts[day] = StatisticsMath.saturatedAdd(
                    dailySessionCounts[day] ?? 0,
                    1
                )
            }
            let aggregate = summary(records: records, calendar: calendar)
            let eventID: UUID?
            switch key {
            case let .event(id): eventID = id
            case .name: eventID = nil
            }
            return PracticeEventStatistics(
                eventID: eventID,
                name: latest.eventNameSnapshot,
                totalCount: aggregate.totalCount,
                sessionCount: aggregate.sessionCount,
                activeDayCount: aggregate.activeDayCount,
                totalDurationMilliseconds: aggregate.totalDurationMilliseconds,
                dailyCounts: dailyCounts,
                dailySessionCounts: dailySessionCounts,
                latestFinishedAt: latest.finishedAt
            )
        }.sorted { lhs, rhs in
            if lhs.latestFinishedAt != rhs.latestFinishedAt {
                return lhs.latestFinishedAt > rhs.latestFinishedAt
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }

    private static func dailyRecords(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar
    ) -> [Date: [PracticeHistoryRecordSnapshot]] {
        Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.startedAt)
        }
    }

    private static func sortedNewestFirst(
        _ records: [PracticeHistoryRecordSnapshot]
    ) -> [PracticeHistoryRecordSnapshot] {
        records.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func sortedLatestFinishedFirst(
        _ records: [PracticeHistoryRecordSnapshot]
    ) -> [PracticeHistoryRecordSnapshot] {
        records.sorted { lhs, rhs in
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private enum StatisticsMath {
    static func saturatedAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? T.max : result
    }

    static func saturatedSum<T: FixedWidthInteger>(_ values: [T]) -> T {
        values.reduce(0, saturatedAdd)
    }
}

private extension DateInterval {
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
