import SwiftData
import SwiftUI

/// A time-based browser over immutable, user-confirmed practice attempts.
///
/// The view deliberately owns no aggregation logic. Every number and activity
/// cell comes from `PracticeStatisticsEngine`, keeping date semantics identical
/// across iPhone, iPad and accessibility layouts.
struct StatisticsView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: [
        SortDescriptor(\PracticeAttempt.startedAt, order: .reverse),
        SortDescriptor(\PracticeAttempt.createdAt, order: .reverse)
    ]) private var attempts: [PracticeAttempt]
    @Query(sort: \PracticeEvent.updatedAt, order: .reverse)
    private var events: [PracticeEvent]

    @State private var period: StatisticsPeriod = .month
    @State private var anchorDate = Date.now

    private var calendar: Calendar {
        var calendar = environmentCalendar
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private var eventNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.name) })
    }

    private var snapshots: [PracticeHistoryRecordSnapshot] {
        attempts.map { attempt in
            attempt.makeStatisticsSnapshot(
                eventNameFallback: eventNames[attempt.eventID] ?? "未命名练习"
            )
        }
    }

    var body: some View {
        // Freeze one immutable input/result pair for this render pass. This
        // avoids repeating O(n) aggregation while SwiftUI evaluates sibling
        // sections and every per-event card.
        let snapshotValues = snapshots
        let traceableSummary = PracticeStatisticsEngine.summary(
            records: snapshotValues,
            calendar: calendar
        )
        // PracticeEvent aggregates predate immutable PracticeAttempt history.
        // Use the aggregate as the all-time count so an upgrade never turns a
        // user's existing total into zero. Calendar-based figures below remain
        // sourced only from dated attempts and are never fabricated.
        let overallSummary = PracticeStatisticsSummary(
            totalCount: allTimeCompletedCount,
            sessionCount: traceableSummary.sessionCount,
            activeDayCount: traceableSummary.activeDayCount,
            totalDurationMilliseconds: traceableSummary.totalDurationMilliseconds
        )
        let periodResult = PracticeStatisticsEngine.query(
            records: snapshotValues,
            period: period,
            anchorDate: anchorDate,
            calendar: calendar
        )
        let periodRecordsByEvent = Dictionary(
            grouping: periodResult.records,
            by: statisticsEventKey(for:)
        )

        return NavigationStack {
            ZStack {
                GeoBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        summarySection(overallSummary)
                        periodPicker
                        periodNavigator
                        periodSummary(periodResult)
                        periodContent(
                            result: periodResult,
                            recordsByEvent: periodRecordsByEvent
                        )
                        // Each period has a different information architecture.
                        // Give SwiftUI a fresh subtree instead of allowing a
                        // same-event `ForEach` to retain the previous card type.
                        .id(period)
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("统计")
            .toolbarBackground(GeoTheme.background.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .toolbar(.visible, for: .tabBar)
    }

    private func summarySection(
        _ allTimeSummary: PracticeStatisticsSummary
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                StatisticsMetricCard(
                    title: "总完成次数",
                    value: allTimeSummary.totalCount.formatted(),
                    detail: "已确认保存的所有练习"
                )
                StatisticsMetricCard(
                    title: "总练习天数",
                    value: allTimeSummary.activeDayCount.formatted(),
                    detail: "按本地自然日去重"
                )
            }

            VStack(spacing: 10) {
                StatisticsMetricCard(
                    title: "总完成次数",
                    value: allTimeSummary.totalCount.formatted(),
                    detail: "已确认保存的所有练习"
                )
                StatisticsMetricCard(
                    title: "总练习天数",
                    value: allTimeSummary.activeDayCount.formatted(),
                    detail: "按本地自然日去重"
                )
            }
        }
    }

    private var periodPicker: some View {
        GeoSegmentContainer {
            ForEach(StatisticsPeriod.allCases) { candidate in
                GeoSegmentButton(
                    title: candidate.title,
                    symbol: nil,
                    isActive: period == candidate
                ) {
                    withAnimation(.snappy(duration: 0.20)) {
                        period = candidate
                        anchorDate = .now
                    }
                }
                .accessibilityHint("切换到按\(candidate.title)统计")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("统计周期")
    }

    private var periodNavigator: some View {
        LiquidControlPanel(contentPadding: 5, cornerRadius: 18) {
            HStack(spacing: 8) {
                periodNavigationButton(direction: -1)

                Button {
                    anchorDate = .now
                } label: {
                    VStack(spacing: 2) {
                        Text(periodTitle)
                            .font(.headline)
                            .foregroundStyle(GeoTheme.text)
                            .multilineTextAlignment(.center)
                        Text("轻点返回当前周期")
                            .font(.caption2)
                            .foregroundStyle(GeoTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前统计周期，\(periodTitle)")
                .accessibilityHint("轻点返回当前周期")

                periodNavigationButton(direction: 1)
            }
        }
    }

    private func periodNavigationButton(direction: Int) -> some View {
        Button {
            anchorDate = PracticeStatisticsEngine.offsetAnchor(
                anchorDate,
                period: period,
                by: direction,
                calendar: calendar
            )
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.headline.weight(.semibold))
                .foregroundStyle(GeoTheme.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "上一个周期" : "下一个周期")
    }

    private func periodSummary(
        _ result: PracticeStatisticsResult
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "\(result.summary.totalCount) 次 · "
                            + "\(result.summary.sessionCount) 轮 · "
                            + "\(result.summary.activeDayCount) 天"
                    )
                    Text(practiceDurationString(milliseconds: result.summary.totalDurationMilliseconds))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Label("\(result.summary.totalCount) 次", systemImage: "checkmark.circle")
                    Text("·")
                    Label("\(result.summary.sessionCount) 轮", systemImage: "rectangle.stack")
                    Text("·")
                    Label("\(result.summary.activeDayCount) 天", systemImage: "calendar")
                    Spacer(minLength: 4)
                    Text(practiceDurationString(milliseconds: result.summary.totalDurationMilliseconds))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.60)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(GeoTheme.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "本周期完成 \(result.summary.totalCount) 次，"
                + "保存 \(result.summary.sessionCount) 轮，"
                + "练习 \(result.summary.activeDayCount) 天，"
                + "总时长 \(practiceDurationString(milliseconds: result.summary.totalDurationMilliseconds))"
        )
    }

    @ViewBuilder
    private func periodContent(
        result: PracticeStatisticsResult,
        recordsByEvent: [String: [PracticeHistoryRecordSnapshot]]
    ) -> some View {
        if result.records.isEmpty {
            StatisticsEmptyState(periodTitle: periodTitle)
        } else {
            switch period {
            case .day:
                DayStatisticsContent(
                    items: PracticeStatisticsEngine.dayTimeline(
                        records: result.records,
                        anchorDate: anchorDate,
                        calendar: calendar
                    )
                )
            case .week:
                LazyVStack(spacing: 16) {
                    ForEach(result.events) { event in
                        WeekStatisticsCard(
                            event: event,
                            buckets: PracticeStatisticsEngine.weekBuckets(
                                records: recordsByEvent[event.id, default: []],
                                week: anchorDate,
                                calendar: calendar
                            ),
                            calendar: calendar
                        )
                    }
                }
            case .month:
                LazyVStack(spacing: 16) {
                    ForEach(result.events) { event in
                        MonthStatisticsCard(
                            event: event,
                            days: PracticeStatisticsEngine.monthCalendar(
                                records: recordsByEvent[event.id, default: []],
                                month: anchorDate,
                                calendar: calendar
                            ),
                            calendar: calendar
                        )
                    }
                }
            case .year:
                LazyVStack(spacing: 16) {
                    ForEach(result.events) { event in
                        YearStatisticsCard(
                            event: event,
                            months: PracticeStatisticsEngine.yearBuckets(
                                records: recordsByEvent[event.id, default: []],
                                year: anchorDate,
                                calendar: calendar
                            )
                        )
                    }
                }
            }
        }
    }

    private func statisticsEventKey(
        for record: PracticeHistoryRecordSnapshot
    ) -> String {
        record.sourceEventID?.uuidString
            ?? "name:\(record.eventNameSnapshot)"
    }

    private var allTimeCompletedCount: Int {
        events.reduce(into: 0) { result, event in
            guard result < Int.max else { return }
            let (sum, overflow) = result.addingReportingOverflow(max(0, event.totalCount))
            result = overflow ? Int.max : sum
        }
    }

    private var periodTitle: String {
        StatisticsDateText.periodTitle(
            period: period,
            anchorDate: anchorDate,
            calendar: calendar
        )
    }
}

private struct StatisticsMetricCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let value: String
    let detail: String

    var body: some View {
        GeoCard(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GeoTheme.muted)
                Text(value)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(GeoTheme.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.55)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(GeoTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)。\(detail)")
    }
}

private struct StatisticsEmptyState: View {
    let periodTitle: String

    var body: some View {
        GeoCard(cornerRadius: 20) {
            ContentUnavailableView {
                Label("这个周期还没有练习", systemImage: "chart.bar.xaxis")
            } description: {
                Text("\(periodTitle)没有已确认保存的练习。完成并保存一次练习后，这里会生成时间统计。")
            }
            .frame(maxWidth: .infinity, minHeight: 210)
        }
    }
}

private struct DayStatisticsContent: View {
    let items: [PracticeDayTimelineItem]

    var body: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DayTimelineRow(
                        item: item,
                        drawsTopLine: index > 0,
                        drawsBottomLine: index < items.count - 1
                    )
                }
            }
        }
    }
}

private struct DayTimelineRow: View {
    let item: PracticeDayTimelineItem
    let drawsTopLine: Bool
    let drawsBottomLine: Bool

    private var handDetails: String {
        PracticeHand.controlOrder.compactMap { hand in
            let stats = item.stats(for: hand)
            guard stats.count > 0 || stats.durationMilliseconds > 0 else { return nil }
            return "\(hand.title) \(stats.count) 次"
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(item.startedAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(drawsTopLine ? Color.white.opacity(0.18) : .clear)
                    .frame(width: 1, height: 8)
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(drawsBottomLine ? Color.white.opacity(0.18) : .clear)
                    .frame(width: 1)
            }
            .frame(width: 10)
            .frame(minHeight: 70)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(GeoTheme.text)
                Text(handDetails.isEmpty ? "本轮未记录完成次数" : handDetails)
                    .font(.subheadline)
                    .foregroundStyle(GeoTheme.muted)
                HStack(spacing: 7) {
                    Text(practiceDurationString(milliseconds: item.totalDurationMilliseconds))
                        .monospacedDigit()
                    if let bpm = item.bpm {
                        Text("·")
                        Text("\(bpm) BPM")
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [
            item.startedAt.formatted(date: .omitted, time: .shortened),
            item.name,
            handDetails.isEmpty ? "本轮未记录完成次数" : handDetails,
            "时长 \(practiceDurationString(milliseconds: item.totalDurationMilliseconds))"
        ]
        if let bpm = item.bpm { parts.append("\(bpm) BPM") }
        return parts.joined(separator: "，")
    }
}

private struct StatisticsEventHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let event: PracticeEventStatistics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                Spacer(minLength: 8)
                metrics
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                metrics
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(event.name)，完成 \(event.totalCount) 次，"
                + "练习 \(event.activeDayCount) 天，"
                + "时长 \(practiceDurationString(milliseconds: event.totalDurationMilliseconds))"
        )
    }

    private var title: some View {
        Text(event.name)
            .font(.headline)
            .foregroundStyle(GeoTheme.text)
            .lineLimit(2)
    }

    private var metrics: some View {
        Text("\(event.totalCount) 次 · \(event.activeDayCount) 天 · \(practiceDurationString(milliseconds: event.totalDurationMilliseconds))")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(GeoTheme.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.72)
    }
}

private struct WeekStatisticsCard: View {
    let event: PracticeEventStatistics
    let buckets: [PracticeDailyBucket]
    let calendar: Calendar

    private var maximum: Int { max(1, buckets.map(\.totalCount).max() ?? 1) }

    var body: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                StatisticsEventHeader(event: event)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(buckets) { bucket in
                        StatisticsActivityCell(
                            title: StatisticsDateText.weekday(bucket.date, calendar: calendar),
                            value: bucket.totalCount,
                            isActive: bucket.isActive,
                            intensity: Double(bucket.totalCount) / Double(maximum),
                            accessibilityText: StatisticsDateText.dayAccessibility(
                                bucket.date,
                                count: bucket.totalCount,
                                isActive: bucket.isActive,
                                calendar: calendar
                            )
                        )
                    }
                }
            }
        }
    }
}

private struct MonthStatisticsCard: View {
    let event: PracticeEventStatistics
    let days: [PracticeCalendarDay]
    let calendar: Calendar

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private var maximum: Int { max(1, days.map(\.totalCount).max() ?? 1) }

    var body: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                StatisticsEventHeader(event: event)
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(
                        Array(StatisticsDateText.weekdaySymbols(calendar: calendar).enumerated()),
                        id: \.offset
                    ) { _, symbol in
                        Text(symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GeoTheme.muted)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(days) { day in
                        CalendarActivityCell(
                            day: day,
                            intensity: Double(day.totalCount) / Double(maximum),
                            calendar: calendar
                        )
                    }
                }
            }
        }
    }
}

private struct YearStatisticsCard: View {
    let event: PracticeEventStatistics
    let months: [PracticeMonthlyBucket]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
    private var maximum: Int { max(1, months.map(\.totalCount).max() ?? 1) }

    var body: some View {
        GeoCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 16) {
                StatisticsEventHeader(event: event)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(months) { month in
                        StatisticsActivityCell(
                            title: String(format: "%02d", month.month),
                            value: month.totalCount,
                            isActive: month.isActive,
                            intensity: Double(month.totalCount) / Double(maximum),
                            accessibilityText: "\(month.month) 月，完成 \(month.totalCount) 次，练习 \(month.activeDayCount) 天"
                        )
                    }
                }
            }
        }
    }
}

private struct StatisticsActivityCell: View {
    let title: String
    let value: Int
    let isActive: Bool
    let intensity: Double
    let accessibilityText: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GeoTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activityColor)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if value > 0 {
                        Text(value.formatted())
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(GeoTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(2)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(isActive ? 0.18 : 0.06), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var activityColor: Color {
        guard isActive else { return Color.white.opacity(0.025) }
        return Color.white.opacity(0.16 + min(max(intensity, 0), 1) * 0.38)
    }
}

private struct CalendarActivityCell: View {
    let day: PracticeCalendarDay
    let intensity: Double
    let calendar: Calendar

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(activityColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(day.isActive ? 0.16 : 0.045), lineWidth: 1)
                }
            VStack(spacing: 1) {
                Text(calendar.component(.day, from: day.date).formatted())
                    .font(.caption2.monospacedDigit().weight(day.isActive ? .bold : .medium))
                if day.totalCount > 0 {
                    Text(day.totalCount.formatted())
                        .font(.caption2.monospacedDigit().weight(.bold))
                }
            }
            .foregroundStyle(
                day.isInDisplayedMonth
                    ? GeoTheme.text.opacity(day.isActive ? 1 : 0.66)
                    : GeoTheme.muted.opacity(0.34)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            StatisticsDateText.dayAccessibility(
                day.date,
                count: day.totalCount,
                isActive: day.isActive,
                calendar: calendar
            )
        )
        .accessibilityHidden(!day.isInDisplayedMonth)
    }

    private var activityColor: Color {
        guard day.isActive else { return Color.white.opacity(0.02) }
        return Color.white.opacity(0.14 + min(max(intensity, 0), 1) * 0.40)
    }
}

private enum StatisticsDateText {
    static func periodTitle(
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar
    ) -> String {
        switch period {
        case .day:
            let components = calendar.dateComponents([.year, .month, .day], from: anchorDate)
            return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日 "
                + fullWeekday(anchorDate, calendar: calendar)
        case .week:
            let interval = PracticeStatisticsEngine.periodInterval(
                for: .week,
                anchorDate: anchorDate,
                calendar: calendar
            )
            let lastDay = calendar.date(byAdding: .day, value: 6, to: interval.start)
                ?? interval.end
            return dayText(interval.start, calendar: calendar)
                + " – "
                + dayText(lastDay, calendar: calendar)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: anchorDate)
            return "\(components.year ?? 0)年\(components.month ?? 0)月"
        case .year:
            return "\(calendar.component(.year, from: anchorDate))年"
        }
    }

    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let symbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let offset = min(max(calendar.firstWeekday - 1, 0), 6)
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    static func dayAccessibility(
        _ date: Date,
        count: Int,
        isActive: Bool,
        calendar: Calendar
    ) -> String {
        let dateText = dayText(date, calendar: calendar)
        return isActive
            ? "\(dateText)，有练习，完成 \(count) 次"
            : "\(dateText)，无练习"
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    private static func fullWeekday(_ date: Date, calendar: Calendar) -> String {
        let symbols = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }
}
