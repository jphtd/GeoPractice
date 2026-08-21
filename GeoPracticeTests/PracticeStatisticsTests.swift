import XCTest
@testable import GeoPractice

final class PracticeStatisticsTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0,
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? self.calendar!
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func snapshot(
        id: UUID = UUID(),
        eventID: UUID? = UUID(),
        name: String = "音阶",
        startedAt: Date,
        finishedAt: Date? = nil,
        leftCount: Int = 0,
        rightCount: Int = 0,
        bothCount: Int = 1,
        leftDuration: Int64 = 0,
        rightDuration: Int64 = 0,
        bothDuration: Int64 = 60_000,
        bpm: Int? = 80
    ) -> PracticeHistoryRecordSnapshot {
        PracticeHistoryRecordSnapshot(
            id: id,
            sourceEventID: eventID,
            eventNameSnapshot: name,
            startedAt: startedAt,
            finishedAt: finishedAt ?? startedAt.addingTimeInterval(600),
            leftCount: leftCount,
            rightCount: rightCount,
            bothCount: bothCount,
            leftDurationMilliseconds: leftDuration,
            rightDurationMilliseconds: rightDuration,
            bothDurationMilliseconds: bothDuration,
            bpm: bpm,
            beats: 4,
            subdivision: 2,
            directionRawValue: "counterclockwise",
            grouping: "标准",
            referenceNoteRaw: "quarter"
        )
    }

    func testDayIntervalIsHalfOpenAndCrossMidnightUsesStartDate() {
        let anchor = date(2026, 8, 20)
        let start = calendar.startOfDay(for: anchor)
        let nextStart = calendar.date(byAdding: .day, value: 1, to: start)!
        let records = [
            snapshot(startedAt: start),
            snapshot(
                startedAt: date(2026, 8, 20, 23, 59),
                finishedAt: date(2026, 8, 21, 0, 10)
            ),
            snapshot(startedAt: nextStart)
        ]

        let result = PracticeStatisticsEngine.query(
            records: records,
            period: .day,
            anchorDate: anchor,
            calendar: calendar
        )

        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { $0.startedAt < nextStart })
        XCTAssertEqual(
            PracticeStatisticsEngine.query(
                records: records,
                period: .day,
                anchorDate: nextStart,
                calendar: calendar
            ).records.count,
            1
        )
    }

    func testWeekUsesSevenCalendarDaysAndConfiguredFirstWeekday() {
        let anchor = date(2026, 8, 20)
        let interval = PracticeStatisticsEngine.periodInterval(
            for: .week,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.weekday, from: interval.start), 2)

        let lastDay = calendar.date(byAdding: .day, value: 6, to: interval.start)!
        let outside = calendar.date(byAdding: .day, value: 7, to: interval.start)!
        let records = [
            snapshot(startedAt: interval.start),
            snapshot(startedAt: lastDay),
            snapshot(startedAt: outside)
        ]
        let result = PracticeStatisticsEngine.query(
            records: records,
            period: .week,
            anchorDate: anchor,
            calendar: calendar
        )
        let buckets = PracticeStatisticsEngine.weekBuckets(
            records: records,
            week: anchor,
            calendar: calendar
        )

        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets.first?.sessionCount, 1)
        XCTAssertEqual(buckets.last?.sessionCount, 1)
    }

    func testMonthAndYearBoundariesExcludeAdjacentPeriods() {
        let monthAnchor = date(2026, 8, 20)
        let monthRecords = [
            snapshot(startedAt: date(2026, 8, 1, 0, 0)),
            snapshot(startedAt: date(2026, 8, 31, 23, 59)),
            snapshot(startedAt: date(2026, 9, 1, 0, 0))
        ]
        XCTAssertEqual(
            PracticeStatisticsEngine.query(
                records: monthRecords,
                period: .month,
                anchorDate: monthAnchor,
                calendar: calendar
            ).records.count,
            2
        )

        let yearRecords = [
            snapshot(startedAt: date(2026, 1, 1, 0, 0)),
            snapshot(startedAt: date(2026, 12, 31, 23, 59)),
            snapshot(startedAt: date(2027, 1, 1, 0, 0))
        ]
        XCTAssertEqual(
            PracticeStatisticsEngine.query(
                records: yearRecords,
                period: .year,
                anchorDate: monthAnchor,
                calendar: calendar
            ).records.count,
            2
        )
    }

    func testSummarySeparatesActionsSessionsAndActiveDays() {
        let records = [
            snapshot(
                startedAt: date(2026, 8, 20, 9),
                leftCount: 2,
                rightCount: 3,
                bothCount: 4,
                leftDuration: 10_000,
                rightDuration: 20_000,
                bothDuration: 30_000
            ),
            snapshot(
                startedAt: date(2026, 8, 20, 18),
                bothCount: 5,
                bothDuration: 40_000
            ),
            snapshot(
                startedAt: date(2026, 8, 21, 9),
                bothCount: 6,
                bothDuration: 50_000
            )
        ]

        let summary = PracticeStatisticsEngine.summary(
            records: records,
            calendar: calendar
        )
        XCTAssertEqual(summary.totalCount, 20)
        XCTAssertEqual(summary.sessionCount, 3)
        XCTAssertEqual(summary.activeDayCount, 2)
        XCTAssertEqual(summary.totalDurationMilliseconds, 150_000)
    }

    func testSavedZeroActionAttemptStillCountsAsSessionAndActiveDay() {
        let record = snapshot(
            startedAt: date(2026, 8, 20, 9),
            leftCount: 0,
            rightCount: 0,
            bothCount: 0,
            leftDuration: 0,
            rightDuration: 0,
            bothDuration: 0
        )
        let summary = PracticeStatisticsEngine.summary(
            records: [record],
            calendar: calendar
        )

        XCTAssertEqual(summary.totalCount, 0)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.activeDayCount, 1)
        XCTAssertEqual(summary.totalDurationMilliseconds, 0)
    }

    func testTimelineDefaultsToNewestFirstAndPreservesAllHands() throws {
        let target = date(2026, 8, 20)
        let early = snapshot(
            name: "早练",
            startedAt: date(2026, 8, 20, 8),
            leftCount: 2,
            rightCount: 3,
            bothCount: 4,
            leftDuration: 1_000,
            rightDuration: 2_000,
            bothDuration: 3_000
        )
        let late = snapshot(
            name: "晚练",
            startedAt: date(2026, 8, 20, 19)
        )

        let newestFirst = PracticeStatisticsEngine.dayTimeline(
            records: [early, late],
            anchorDate: target,
            calendar: calendar
        )
        XCTAssertEqual(newestFirst.map(\.name), ["晚练", "早练"])
        let earlyItem = try XCTUnwrap(newestFirst.last)
        XCTAssertEqual(earlyItem.left.count, 2)
        XCTAssertEqual(earlyItem.right.count, 3)
        XCTAssertEqual(earlyItem.both.count, 4)
        XCTAssertEqual(earlyItem.totalCount, 9)
        XCTAssertEqual(earlyItem.totalDurationMilliseconds, 6_000)

        let oldestFirst = PracticeStatisticsEngine.dayTimeline(
            records: [early, late],
            anchorDate: target,
            calendar: calendar,
            order: .oldestFirst
        )
        XCTAssertEqual(oldestFirst.map(\.name), ["早练", "晚练"])
    }

    func testEventAggregationUsesActionCountsAndLatestSnapshotName() throws {
        let eventA = UUID()
        let eventB = UUID()
        let oldName = snapshot(
            eventID: eventA,
            name: "旧名称",
            startedAt: date(2026, 8, 20, 9),
            finishedAt: date(2026, 8, 20, 9, 10),
            bothCount: 2
        )
        let newName = snapshot(
            eventID: eventA,
            name: "新名称",
            startedAt: date(2026, 8, 20, 10),
            finishedAt: date(2026, 8, 20, 10, 10),
            bothCount: 3
        )
        let newestEvent = snapshot(
            eventID: eventB,
            name: "最近练习",
            startedAt: date(2026, 8, 20, 8),
            finishedAt: date(2026, 8, 20, 20),
            bothCount: 4
        )

        let events = PracticeStatisticsEngine.eventStatistics(
            records: [oldName, newName, newestEvent],
            period: .day,
            anchorDate: date(2026, 8, 20),
            calendar: calendar
        )
        XCTAssertEqual(events.map(\.eventID), [eventB, eventA])
        let event = try XCTUnwrap(events.first { $0.eventID == eventA })
        XCTAssertEqual(event.name, "新名称")
        XCTAssertEqual(event.totalCount, 5)
        XCTAssertEqual(event.sessionCount, 2)
        XCTAssertEqual(event.activeDayCount, 1)
        XCTAssertEqual(event.dailyCounts.count, 1)
        XCTAssertEqual(event.dailyCounts.values.first, 5)
        XCTAssertEqual(event.dailySessionCounts.values.first, 2)
    }

    func testOrphanEventsGroupByNameInsteadOfMergingUnrelatedNames() {
        let records = [
            snapshot(
                eventID: nil,
                name: "A",
                startedAt: date(2026, 8, 20, 9)
            ),
            snapshot(
                eventID: nil,
                name: "B",
                startedAt: date(2026, 8, 20, 10)
            ),
            snapshot(
                eventID: nil,
                name: "A",
                startedAt: date(2026, 8, 20, 11)
            )
        ]
        let events = PracticeStatisticsEngine.eventStatistics(
            records: records,
            period: .day,
            anchorDate: date(2026, 8, 20),
            calendar: calendar
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.name == "A" }?.sessionCount, 2)
        XCTAssertEqual(events.first { $0.name == "B" }?.sessionCount, 1)
    }

    func testMonthCalendarIsStableUniqueSixWeekGridWithPlaceholders() throws {
        let anchor = date(2026, 8, 20)
        let first = snapshot(
            startedAt: date(2026, 8, 15, 9),
            bothCount: 2
        )
        let second = snapshot(
            startedAt: date(2026, 8, 15, 18),
            bothCount: 3
        )
        let calendarDays = PracticeStatisticsEngine.monthCalendar(
            records: [first, second],
            month: anchor,
            calendar: calendar
        )

        XCTAssertEqual(calendarDays.count, 42)
        XCTAssertEqual(Set(calendarDays.map(\.date)).count, 42)
        XCTAssertTrue(calendarDays.contains { !$0.isInDisplayedMonth })
        let august15 = try XCTUnwrap(calendarDays.first {
            calendar.isDate($0.date, inSameDayAs: date(2026, 8, 15))
        })
        XCTAssertEqual(august15.sessionCount, 2)
        XCTAssertEqual(august15.totalCount, 5)
    }

    func testYearAlwaysProducesTwelveBucketsIncludingEmptyMonths() throws {
        let january = snapshot(
            startedAt: date(2026, 1, 5),
            bothCount: 2
        )
        let december = snapshot(
            startedAt: date(2026, 12, 5),
            bothCount: 3
        )
        let buckets = PracticeStatisticsEngine.yearBuckets(
            records: [january, december],
            year: date(2026, 8, 20),
            calendar: calendar
        )

        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.map(\.month), Array(1...12))
        XCTAssertEqual(try XCTUnwrap(buckets.first).totalCount, 2)
        XCTAssertEqual(try XCTUnwrap(buckets.last).totalCount, 3)
        XCTAssertEqual(buckets[1].sessionCount, 0)
    }

    func testNegativeDataClampsAndTotalsSaturateInsteadOfOverflowing() {
        let extreme = snapshot(
            startedAt: date(2026, 8, 20, 9),
            leftCount: Int.max,
            rightCount: 1,
            bothCount: -2,
            leftDuration: Int64.max,
            rightDuration: 1,
            bothDuration: -1
        )
        let another = snapshot(
            startedAt: date(2026, 8, 20, 10),
            bothCount: 1,
            bothDuration: 1
        )

        XCTAssertEqual(extreme.totalCount, Int.max)
        XCTAssertEqual(extreme.totalDurationMilliseconds, Int64.max)
        XCTAssertEqual(extreme.both.count, 0)
        XCTAssertEqual(extreme.both.durationMilliseconds, 0)
        let summary = PracticeStatisticsEngine.summary(
            records: [extreme, another],
            calendar: calendar
        )
        XCTAssertEqual(summary.totalCount, Int.max)
        XCTAssertEqual(summary.totalDurationMilliseconds, Int64.max)
    }

    func testDSTSpringDayUsesCalendarSemanticsInsteadOfFixed24Hours() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = date(2026, 3, 8, 12, calendar: dstCalendar)
        let interval = PracticeStatisticsEngine.periodInterval(
            for: .day,
            anchorDate: anchor,
            calendar: dstCalendar
        )

        XCTAssertEqual(interval.duration, 23 * 60 * 60, accuracy: 0.001)
        let late = snapshot(
            startedAt: date(2026, 3, 8, 23, 30, calendar: dstCalendar),
            finishedAt: date(2026, 3, 9, 0, 10, calendar: dstCalendar)
        )
        XCTAssertEqual(
            PracticeStatisticsEngine.query(
                records: [late],
                period: .day,
                anchorDate: anchor,
                calendar: dstCalendar
            ).records.count,
            1
        )
        XCTAssertTrue(dstCalendar.isDate(
            PracticeStatisticsEngine.offsetAnchor(
                anchor,
                period: .day,
                by: 1,
                calendar: dstCalendar
            ),
            inSameDayAs: date(2026, 3, 9, calendar: dstCalendar)
        ))
    }

    func testDSTFallDayCanContainTwentyFiveHours() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = date(2026, 11, 1, 12, calendar: dstCalendar)
        let interval = PracticeStatisticsEngine.periodInterval(
            for: .day,
            anchorDate: anchor,
            calendar: dstCalendar
        )

        XCTAssertEqual(interval.duration, 25 * 60 * 60, accuracy: 0.001)
    }

    func testQueryReturnsDeterministicNewestFirstRecords() {
        let tiedDate = date(2026, 8, 20, 10)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let early = snapshot(startedAt: date(2026, 8, 20, 9))
        let tiedHigh = snapshot(id: highID, startedAt: tiedDate)
        let tiedLow = snapshot(id: lowID, startedAt: tiedDate)

        let records = PracticeStatisticsEngine.query(
            records: [early, tiedHigh, tiedLow],
            period: .day,
            anchorDate: tiedDate,
            calendar: calendar
        ).records
        XCTAssertEqual(records.map(\.id), [lowID, highID, early.id])
    }
}
