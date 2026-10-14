import XCTest
import SwiftData
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
        bpm: Int? = 80,
        leftPreset: MetronomePreset? = nil,
        rightPreset: MetronomePreset? = nil,
        bothPreset: MetronomePreset? = nil,
        completionSamples: [PracticeCompletionSample] = [],
        activeIntervals: [PracticeDurationInterval]? = nil
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
            referenceNoteRaw: "quarter",
            leftPreset: leftPreset,
            rightPreset: rightPreset,
            bothPreset: bothPreset,
            completionSamples: completionSamples,
            activeIntervals: activeIntervals
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

    func testSavedZeroDurationAttemptIsVerifiedZeroNotAnActiveDay() {
        let record = snapshot(
            startedAt: date(2026, 8, 20, 9),
            leftCount: 0,
            rightCount: 0,
            bothCount: 0,
            leftDuration: 0,
            rightDuration: 0,
            bothDuration: 0,
            activeIntervals: []
        )
        let summary = PracticeStatisticsEngine.summary(
            records: [record],
            calendar: calendar
        )

        XCTAssertEqual(summary.totalCount, 0)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.activeDayCount, 0)
        XCTAssertEqual(summary.practiceDays.state, .verifiedZero)
        XCTAssertEqual(summary.practiceDays.exactDayCount, 0)
        XCTAssertEqual(summary.totalDurationMilliseconds, 0)
    }

    func testPracticeDaysSplitsVerifiedActiveIntervalAcrossLocalMidnight() throws {
        let start = date(2026, 8, 20, 23, 55)
        let finish = date(2026, 8, 21, 0, 5)
        let interval = try XCTUnwrap(
            PracticeDurationInterval(startedAt: start, finishedAt: finish)
        )
        let result = PracticeStatisticsEngine.practiceDays(
            records: [snapshot(
                startedAt: start,
                finishedAt: finish,
                bothDuration: 600_000,
                activeIntervals: [interval]
            )],
            calendar: calendar
        )

        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.exactDayCount, 2)
        XCTAssertEqual(result.verifiedDayCount, 2)
    }

    func testPracticeDaysUsesOnlyPositivePausedSegmentsAcrossMidnight() throws {
        let start = date(2026, 8, 20, 23, 50)
        let finish = date(2026, 8, 21, 0, 20)
        let beforeMidnight = try XCTUnwrap(PracticeDurationInterval(
            startedAt: start,
            finishedAt: date(2026, 8, 20, 23, 55)
        ))
        let result = PracticeStatisticsEngine.practiceDays(
            records: [snapshot(
                startedAt: start,
                finishedAt: finish,
                bothDuration: 300_000,
                activeIntervals: [beforeMidnight]
            )],
            calendar: calendar
        )

        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.exactDayCount, 1)
    }

    func testDayQueryCountsVerifiedCrossMidnightPracticeOnSecondDay() throws {
        let start = date(2026, 8, 20, 23, 55)
        let finish = date(2026, 8, 21, 0, 5)
        let interval = try XCTUnwrap(
            PracticeDurationInterval(startedAt: start, finishedAt: finish)
        )
        let result = PracticeStatisticsEngine.query(
            records: [snapshot(
                startedAt: start,
                finishedAt: finish,
                bothDuration: 600_000,
                activeIntervals: [interval]
            )],
            period: .day,
            anchorDate: finish,
            calendar: calendar
        )

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.summary.practiceDays.state, .verified)
        XCTAssertEqual(result.summary.practiceDays.exactDayCount, 1)
    }

    func testDayQueryIgnoresUnrelatedOldIncompleteRecord() throws {
        let target = date(2026, 8, 21, 12)
        let currentStart = date(2026, 8, 21, 9)
        let currentFinish = date(2026, 8, 21, 9, 10)
        let currentInterval = try XCTUnwrap(
            PracticeDurationInterval(startedAt: currentStart, finishedAt: currentFinish)
        )
        let result = PracticeStatisticsEngine.query(
            records: [
                snapshot(
                    startedAt: date(2026, 8, 1, 23, 55),
                    finishedAt: date(2026, 8, 2, 0, 5),
                    bothDuration: 300_000
                ),
                snapshot(
                    startedAt: currentStart,
                    finishedAt: currentFinish,
                    bothDuration: 600_000,
                    activeIntervals: [currentInterval]
                )
            ],
            period: .day,
            anchorDate: target,
            calendar: calendar
        )

        XCTAssertEqual(result.summary.practiceDays.state, .verified)
        XCTAssertEqual(result.summary.practiceDays.exactDayCount, 1)
        XCTAssertEqual(result.summary.practiceDays.incompleteRecordCount, 0)
    }

    func testDayQueryWithOnlyUnrelatedOldRecordsIsNoRecords() {
        let result = PracticeStatisticsEngine.query(
            records: [snapshot(
                startedAt: date(2026, 8, 1, 9),
                finishedAt: date(2026, 8, 1, 9, 10),
                bothDuration: 600_000
            )],
            period: .day,
            anchorDate: date(2026, 8, 21),
            calendar: calendar
        )

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.summary.practiceDays.state, .noRecords)
        XCTAssertNil(result.summary.practiceDays.exactDayCount)
    }

    func testDayQueryKeepsIncompleteRecordInsideRange() {
        let result = PracticeStatisticsEngine.query(
            records: [snapshot(
                startedAt: date(2026, 8, 21, 23, 55),
                finishedAt: date(2026, 8, 22, 0, 5),
                bothDuration: 300_000
            )],
            period: .day,
            anchorDate: date(2026, 8, 21),
            calendar: calendar
        )

        XCTAssertEqual(result.summary.practiceDays.state, .unverifiable)
        XCTAssertEqual(result.summary.practiceDays.incompleteRecordCount, 1)
    }

    func testLegacyCrossMidnightAggregateIsUnverifiable() {
        let result = PracticeStatisticsEngine.practiceDays(
            records: [snapshot(
                startedAt: date(2026, 8, 20, 23, 55),
                finishedAt: date(2026, 8, 21, 0, 5),
                bothDuration: 300_000
            )],
            calendar: calendar
        )

        XCTAssertEqual(result.state, .unverifiable)
        XCTAssertNil(result.exactDayCount)
        XCTAssertEqual(result.verifiedDayCount, 0)
        XCTAssertEqual(result.incompleteRecordCount, 1)
    }

    func testIncompleteHistoryPreservesVerifiedPracticeDays() {
        let result = PracticeStatisticsEngine.practiceDays(
            records: [
                snapshot(
                    startedAt: date(2026, 8, 19, 9),
                    finishedAt: date(2026, 8, 19, 9, 10),
                    bothDuration: 300_000
                ),
                snapshot(
                    startedAt: date(2026, 8, 20, 23, 55),
                    finishedAt: date(2026, 8, 21, 0, 5),
                    bothDuration: 300_000
                )
            ],
            calendar: calendar
        )

        XCTAssertEqual(result.state, .incomplete)
        XCTAssertNil(result.exactDayCount)
        XCTAssertEqual(result.verifiedDayCount, 1)
    }

    func testPracticeDaysDistinguishesNoRecordsFromVerifiedZero() {
        XCTAssertEqual(
            PracticeStatisticsEngine.practiceDays(records: []).state,
            .noRecords
        )
        let zero = PracticeStatisticsEngine.practiceDays(
            records: [snapshot(
                startedAt: date(2026, 8, 20, 9),
                finishedAt: date(2026, 8, 20, 9),
                bothCount: 0,
                bothDuration: 0,
                activeIntervals: []
            )],
            calendar: calendar
        )
        XCTAssertEqual(zero.state, .verifiedZero)
        XCTAssertEqual(zero.exactDayCount, 0)
    }

    func testGlobalDurationDeduplicatesIntervalsWithoutRemovingPieceAttribution() throws {
        let first = date(2026, 8, 20, 9)
        let second = date(2026, 8, 20, 9, 5)
        let end = date(2026, 8, 20, 9, 10)
        let records = [
            snapshot(eventID: UUID(), startedAt: first, finishedAt: end,
                     bothDuration: 600_000,
                     activeIntervals: [try XCTUnwrap(PracticeDurationInterval(
                        startedAt: first, finishedAt: end))]),
            snapshot(eventID: UUID(), startedAt: second, finishedAt: end,
                     bothDuration: 300_000,
                     activeIntervals: [try XCTUnwrap(PracticeDurationInterval(
                        startedAt: second, finishedAt: end))])
        ]
        let global = PracticeStatisticsEngine.globalDuration(records: records)
        XCTAssertEqual(global.state, .verified)
        XCTAssertEqual(global.exactMilliseconds, 600_000)
        XCTAssertEqual(global.removedOverlapMilliseconds, 300_000)
        XCTAssertEqual(PracticeStatisticsEngine.pieceDuration(records: [records[0]])
            .exactMilliseconds, 600_000)
        XCTAssertEqual(PracticeStatisticsEngine.pieceDuration(records: [records[1]])
            .exactMilliseconds, 300_000)
        XCTAssertEqual(PracticeStatisticsEngine.pieceDuration(records: records)
            .exactMilliseconds, 900_000)
    }

    func testGlobalDurationUsesSavedNonPausedIntervalsAcrossMidnight() throws {
        let before = try XCTUnwrap(PracticeDurationInterval(
            startedAt: date(2026, 8, 20, 23, 50),
            finishedAt: date(2026, 8, 20, 23, 55)))
        let after = try XCTUnwrap(PracticeDurationInterval(
            startedAt: date(2026, 8, 21, 0, 5),
            finishedAt: date(2026, 8, 21, 0, 10)))
        let overlap = try XCTUnwrap(PracticeDurationInterval(
            startedAt: date(2026, 8, 21, 0, 7),
            finishedAt: date(2026, 8, 21, 0, 12)))
        let result = PracticeStatisticsEngine.globalDuration(records: [
            snapshot(startedAt: before.startedAt, finishedAt: after.finishedAt,
                     bothDuration: 600_000, activeIntervals: [before, after]),
            snapshot(startedAt: overlap.startedAt, finishedAt: overlap.finishedAt,
                     bothDuration: 300_000, activeIntervals: [overlap])
        ])
        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.exactMilliseconds, 720_000)
        XCTAssertEqual(result.removedOverlapMilliseconds, 180_000)
    }

    func testGlobalDurationDoesNotClaimExactLegacyPausedOrCrossMidnightTime() throws {
        let start = date(2026, 8, 20, 9)
        let end = date(2026, 8, 20, 9, 10)
        let records = [
            snapshot(startedAt: start, finishedAt: end, bothDuration: 300_000),
            snapshot(startedAt: date(2026, 8, 20, 23, 55),
                     finishedAt: date(2026, 8, 21, 0, 5), bothDuration: 300_000),
            snapshot(startedAt: start, finishedAt: end, bothDuration: 600_000,
                     activeIntervals: [try XCTUnwrap(PracticeDurationInterval(
                        startedAt: start, finishedAt: end))])
        ]
        let global = PracticeStatisticsEngine.globalDuration(records: records)
        XCTAssertEqual(global.state, .incomplete)
        XCTAssertNil(global.exactMilliseconds)
        XCTAssertEqual(global.verifiedMilliseconds, 600_000)
        XCTAssertEqual(global.incompleteRecordCount, 2)
        XCTAssertEqual(PracticeStatisticsEngine.pieceDuration(records: [records[0]])
            .exactMilliseconds, 300_000)
    }

    func testGlobalDurationSeparatesNoRecordsAndSavedZero() {
        XCTAssertEqual(PracticeStatisticsEngine.globalDuration(records: []).state, .noRecords)
        let zero = snapshot(startedAt: date(2026, 8, 20, 9),
                            finishedAt: date(2026, 8, 20, 9),
                            bothCount: 0, bothDuration: 0, activeIntervals: [])
        XCTAssertEqual(PracticeStatisticsEngine.globalDuration(records: [zero]).state,
                       .verifiedZero)
        XCTAssertEqual(PracticeStatisticsEngine.pieceDuration(records: [zero]).state,
                       .verifiedZero)
    }

    func testPracticeSessionPersistsNonPausedTimingEvidence() throws {
        var session = PracticeSession()
        let start = date(2026, 8, 20, 23, 55)
        session.begin(at: start)
        session.pause(at: date(2026, 8, 20, 23, 58))
        session.resume(at: date(2026, 8, 21, 0, 2))
        let summary = try XCTUnwrap(session.finish(at: date(2026, 8, 21, 0, 5)))

        XCTAssertEqual(summary.activeIntervals?.count, 2)
        XCTAssertEqual(summary.totalDurationMilliseconds, 360_000)
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

    func testHistoryIntervalFormatterUsesOnlyLargestCompletedUnit() {
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: 36.9), "36s前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: 5 * 60 + 36), "5分钟前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: 7 * 3_600 + 5 * 60 + 36), "7h前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: 4 * 86_400 + 7 * 3_600), "4d前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: -8), "0s前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: .infinity), "0s前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: -.infinity), "0s前")
        XCTAssertEqual(PracticeHistoryIntervalFormatter.string(for: .nan), "0s前")
    }

    func testSectionBreakdownUsesRealSamplesForBPMRangesAndSeparateSignatures() throws {
        let eventID = UUID()
        let start = date(2026, 8, 31, 9)
        let quarter72 = MetronomePreset(
            bpm: 72,
            beats: 4,
            subdivision: 1,
            direction: .counterclockwise,
            grouping: "标准"
        )
        var quarter80 = quarter72
        quarter80.bpm = 80
        var eighth80 = quarter80
        eighth80.subdivision = 2
        let samples = [
            PracticeCompletionSample(hand: .left, preset: quarter80, completedAt: start.addingTimeInterval(30)),
            PracticeCompletionSample(hand: .both, preset: quarter72, completedAt: start.addingTimeInterval(20)),
            PracticeCompletionSample(hand: .left, preset: eighth80, completedAt: start.addingTimeInterval(40)),
            PracticeCompletionSample(hand: .left, preset: quarter72, completedAt: start.addingTimeInterval(10))
        ]
        let record = snapshot(
            eventID: eventID,
            startedAt: start,
            leftCount: 3,
            bothCount: 1,
            completionSamples: samples
        )

        let rows = PracticeSectionBreakdownStatistics.breakdowns(
            sectionID: eventID,
            records: [record],
            interval: DateInterval(
                start: start,
                end: start.addingTimeInterval(60)
            )
        )

        XCTAssertEqual(rows.count, 3)
        let leftQuarter = try XCTUnwrap(rows.first {
            $0.hand == .left && $0.subdivision == 1
        })
        XCTAssertEqual(leftQuarter.minimumBPM, 72)
        XCTAssertEqual(leftQuarter.maximumBPM, 80)
        XCTAssertEqual(leftQuarter.bpmRangeTitle, "72–80 BPM")
        XCTAssertEqual(leftQuarter.count, 2)
        XCTAssertFalse(leftQuarter.usedLegacyFallback)
        XCTAssertTrue(rows.contains {
            $0.hand == .left && $0.subdivision == 2 && $0.count == 1
        })
        XCTAssertEqual(rows.map(\.hand), [.left, .left, .both])
    }

    func testSectionBreakdownFallsBackTruthfullyForLegacyAggregateRecord() throws {
        let eventID = UUID()
        let start = date(2026, 8, 31, 9)
        let preset = MetronomePreset(
            bpm: 66,
            beats: 5,
            subdivision: 1,
            direction: .clockwise,
            grouping: "2+3"
        )
        let record = snapshot(
            eventID: eventID,
            startedAt: start,
            finishedAt: start.addingTimeInterval(300),
            leftCount: 4,
            bothCount: 0,
            leftDuration: 120_000,
            bothDuration: 0,
            bpm: nil,
            leftPreset: preset
        )

        let row = try XCTUnwrap(
            PracticeSectionBreakdownStatistics.breakdowns(
                sectionID: eventID,
                records: [record],
                interval: nil
            ).only
        )
        XCTAssertEqual(row.hand, .left)
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row.minimumBPM, 66)
        XCTAssertEqual(row.beats, 5)
        XCTAssertTrue(row.usedLegacyFallback)
    }

    func testHybridRecordPreservesAggregateRemainderWithoutInventingAttempts() throws {
        let eventID = UUID()
        let start = date(2026, 8, 31, 9)
        var preset72 = MetronomePreset.standard
        preset72.bpm = 72
        var preset80 = preset72
        preset80.bpm = 80
        let record = snapshot(
            eventID: eventID,
            startedAt: start,
            finishedAt: start.addingTimeInterval(60),
            leftCount: 5,
            bothCount: 0,
            leftPreset: preset80,
            completionSamples: [
                PracticeCompletionSample(
                    hand: .left,
                    preset: preset72,
                    completedAt: start.addingTimeInterval(10)
                ),
                PracticeCompletionSample(
                    hand: .left,
                    preset: preset80,
                    completedAt: start.addingTimeInterval(20)
                )
            ]
        )

        let report = PracticeSectionBreakdownStatistics.report(
            sectionID: eventID,
            records: [record],
            interval: nil
        )
        let row = try XCTUnwrap(report.configurations.only)
        XCTAssertEqual(row.count, 5)
        XCTAssertEqual(row.minimumBPM, 72)
        XCTAssertEqual(row.maximumBPM, 80)
        XCTAssertTrue(row.usedLegacyFallback)
        XCTAssertTrue(report.unavailableConfigurations.isEmpty)

        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(
                records: [record],
                hand: .left
            ).only
        )
        XCTAssertEqual(session.attempts.count, 2)
        XCTAssertEqual(session.unitemizedCompletions.count, 1)
        XCTAssertEqual(session.unitemizedCompletions.only?.count, 3)
        XCTAssertEqual(
            session.unitemizedCompletions.only?.reason,
            .legacyAggregate
        )
        XCTAssertEqual(session.unitemizedCount, 3)
        XCTAssertFalse(session.isSummaryOnly)
    }

    func testHybridRemainderWithoutPresetIsReportedAsConfigurationUnavailable() throws {
        let eventID = UUID()
        let start = date(2026, 8, 31, 9)
        let record = PracticeHistoryRecordSnapshot(
            id: UUID(),
            sourceEventID: eventID,
            eventNameSnapshot: "旧段落",
            startedAt: start,
            finishedAt: start.addingTimeInterval(60),
            leftCount: 2,
            rightCount: 0,
            bothCount: 0,
            leftDurationMilliseconds: 0,
            rightDurationMilliseconds: 0,
            bothDurationMilliseconds: 0
        )

        let report = PracticeSectionBreakdownStatistics.report(
            sectionID: eventID,
            records: [record],
            interval: nil
        )
        XCTAssertTrue(report.configurations.isEmpty)
        let unavailable = try XCTUnwrap(report.unavailableConfigurations.only)
        XCTAssertEqual(unavailable.hand, .left)
        XCTAssertEqual(unavailable.count, 2)
        XCTAssertEqual(unavailable.title, "配置不可用")
        XCTAssertEqual(report.totalCount, 2)

        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [record]).only
        )
        XCTAssertNil(session.unitemizedCompletions.only?.preset)
        XCTAssertEqual(
            session.unitemizedCompletions.only?.title,
            "旧记录 · 配置不可用"
        )
    }

    func testManualBackfillBatchStaysOnBoundaryAndIsNeverTapTimeline() throws {
        let eventID = UUID()
        let boundary = date(2026, 8, 31, 0)
        let samples = PracticeCompletionSample.manualBackfillBatch(
            hand: .left,
            preset: .standard,
            count: 3,
            completedAt: boundary
        )
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy {
            $0.completedAt == boundary && $0.source == .manualBackfill
        })

        let record = snapshot(
            eventID: eventID,
            startedAt: boundary,
            finishedAt: boundary,
            leftCount: 3,
            bothCount: 0,
            leftPreset: .standard,
            completionSamples: samples
        )
        let report = PracticeSectionBreakdownStatistics.report(
            sectionID: eventID,
            records: [record],
            interval: DateInterval(
                start: boundary,
                end: boundary.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(report.totalCount, 3)

        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(
                records: [record],
                hand: .left
            ).only
        )
        XCTAssertTrue(session.attempts.isEmpty)
        XCTAssertEqual(session.unitemizedCompletions.only?.count, 3)
        XCTAssertEqual(
            session.unitemizedCompletions.only?.reason,
            .manualBackfill
        )
        XCTAssertTrue(session.isSummaryOnly)
        XCTAssertFalse(session.isLegacySummaryOnly)
    }

    func testSingleManualBackfillIsStillAnAggregateRatherThanARealTap() throws {
        let timestamp = date(2026, 8, 31, 12)
        let sample = try XCTUnwrap(
            PracticeCompletionSample.manualBackfillBatch(
                hand: .both,
                preset: .standard,
                count: 1,
                completedAt: timestamp
            ).only
        )
        let record = snapshot(
            startedAt: timestamp,
            finishedAt: timestamp,
            bothCount: 1,
            completionSamples: [sample]
        )
        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [record]).only
        )
        XCTAssertTrue(session.attempts.isEmpty)
        XCTAssertEqual(session.unitemizedCompletions.only?.count, 1)
        XCTAssertEqual(
            session.unitemizedCompletions.only?.reason,
            .manualBackfill
        )
    }

    func testCompletionSourceDecodesOldPayloadAsLive() throws {
        let original = PracticeCompletionSample(
            hand: .right,
            preset: .standard,
            completedAt: date(2026, 8, 31, 12)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(original)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "source")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            PracticeCompletionSample.self,
            from: legacyData
        )
        XCTAssertEqual(decoded.source, .live)
        XCTAssertFalse(decoded.hasExplicitSource)
        XCTAssertEqual(decoded.id, original.id)
        let reencodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(decoded)
            ) as? [String: Any]
        )
        XCTAssertNil(reencodedObject["source"])
    }

    func testLegacyOneMillisecondBackfillBatchRemainsUnitemized() throws {
        let finish = date(2026, 8, 31, 12)

        func legacyDecodedSample(at completedAt: Date) throws -> PracticeCompletionSample {
            let value = PracticeCompletionSample(
                hand: .left,
                preset: .standard,
                completedAt: completedAt
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(value)
                ) as? [String: Any]
            )
            object.removeValue(forKey: "source")
            return try JSONDecoder().decode(
                PracticeCompletionSample.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        let legacyBatch = try [
            legacyDecodedSample(at: finish.addingTimeInterval(-0.002)),
            legacyDecodedSample(at: finish.addingTimeInterval(-0.001)),
            legacyDecodedSample(at: finish)
        ]
        XCTAssertTrue(legacyBatch.allSatisfy { !$0.hasExplicitSource })
        let record = snapshot(
            startedAt: finish.addingTimeInterval(-60),
            finishedAt: finish,
            leftCount: 3,
            bothCount: 0,
            leftPreset: .standard,
            completionSamples: legacyBatch
        )

        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(
                records: [record],
                hand: .left
            ).only
        )
        XCTAssertTrue(session.attempts.isEmpty)
        XCTAssertEqual(session.unitemizedCompletions.only?.count, 3)
        XCTAssertEqual(
            session.unitemizedCompletions.only?.reason,
            .manualBackfill
        )
    }

    func testLegacyBatchHeuristicDoesNotOverrideExplicitOrIrregularLiveData() throws {
        let finish = date(2026, 8, 31, 12)
        let explicit = [
            PracticeCompletionSample(
                hand: .left,
                preset: .standard,
                completedAt: finish.addingTimeInterval(-0.001)
            ),
            PracticeCompletionSample(
                hand: .left,
                preset: .standard,
                completedAt: finish
            )
        ]
        let explicitRecord = snapshot(
            startedAt: finish.addingTimeInterval(-60),
            finishedAt: finish,
            leftCount: 2,
            bothCount: 0,
            leftPreset: .standard,
            completionSamples: explicit
        )
        XCTAssertEqual(
            PracticeStatisticsEngine.historySessions(
                records: [explicitRecord],
                hand: .left
            ).only?.attempts.count,
            2
        )

        var legacyObjects = try explicit.map { value -> [String: Any] in
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(value)
                ) as? [String: Any]
            )
            object.removeValue(forKey: "source")
            return object
        }
        // Break the old-backfill signature without changing count or preset.
        let irregularTime = finish.addingTimeInterval(-0.005)
        legacyObjects[0]["completedAt"] = irregularTime.timeIntervalSinceReferenceDate
        let irregular = try legacyObjects.map {
            try JSONDecoder().decode(
                PracticeCompletionSample.self,
                from: JSONSerialization.data(withJSONObject: $0)
            )
        }
        let irregularRecord = snapshot(
            startedAt: finish.addingTimeInterval(-60),
            finishedAt: finish,
            leftCount: 2,
            bothCount: 0,
            leftPreset: .standard,
            completionSamples: irregular
        )
        XCTAssertEqual(
            PracticeStatisticsEngine.historySessions(
                records: [irregularRecord],
                hand: .left
            ).only?.attempts.count,
            2
        )
    }

    func testHistorySessionsKeepRealCompletionOrderAndAllHandDuration() throws {
        let start = date(2026, 8, 31, 12)
        var preset = MetronomePreset.standard
        preset.bpm = 84
        let earlyID = UUID()
        let lateID = UUID()
        let record = snapshot(
            startedAt: start,
            finishedAt: start.addingTimeInterval(400),
            leftCount: 1,
            rightCount: 1,
            bothCount: 0,
            leftDuration: 60_000,
            rightDuration: 90_000,
            bothDuration: 0,
            completionSamples: [
                PracticeCompletionSample(
                    id: lateID,
                    hand: .right,
                    preset: preset,
                    completedAt: start.addingTimeInterval(300)
                ),
                PracticeCompletionSample(
                    id: earlyID,
                    hand: .left,
                    preset: preset,
                    completedAt: start.addingTimeInterval(30)
                )
            ]
        )

        let all = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [record]).only
        )
        XCTAssertEqual(all.attempts.map(\.id), [earlyID, lateID])
        XCTAssertEqual(all.attempts.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(all.summaryStats.durationMilliseconds, 150_000)
        XCTAssertFalse(all.isLegacySummaryOnly)

        let right = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(
                records: [record],
                hand: .right
            ).only
        )
        XCTAssertEqual(right.attempts.map(\.id), [lateID])
        XCTAssertEqual(right.summaryStats.durationMilliseconds, 90_000)
    }
}

final class PracticePieceAnalysisEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var now = Date.distantPast

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        self.calendar = calendar
        now = date(2026, 9, 4, 18)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func dayOffset(_ value: Int, hour: Int = 12) -> Date {
        let target = calendar.date(byAdding: .day, value: value, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: target)!
    }

    private func preset(
        bpm: Int,
        beats: Int = 5,
        subdivision: Int = 1,
        direction: RotationDirection = .counterclockwise,
        grouping: String = "2+3",
        referenceNote: TempoReferenceNote = .quarter
    ) -> MetronomePreset {
        MetronomePreset(
            bpm: bpm,
            beats: beats,
            subdivision: subdivision,
            direction: direction,
            grouping: grouping,
            referenceNoteRaw: referenceNote.rawValue
        )
    }

    private func sample(
        hand: PracticeHand,
        bpm: Int,
        at completedAt: Date,
        eventPreset: MetronomePreset? = nil
    ) -> PracticeCompletionSample {
        var value = eventPreset ?? preset(bpm: bpm)
        value.bpm = bpm
        return PracticeCompletionSample(
            hand: hand,
            preset: value,
            completedAt: completedAt
        )
    }

    private func record(
        id: UUID = UUID(),
        eventID: UUID,
        name: String = "练习段落",
        samples: [PracticeCompletionSample],
        finishedAt: Date? = nil,
        leftCount: Int? = nil,
        rightCount: Int? = nil,
        bothCount: Int? = nil,
        leftPreset: MetronomePreset? = nil,
        rightPreset: MetronomePreset? = nil,
        bothPreset: MetronomePreset? = nil
    ) -> PracticeHistoryRecordSnapshot {
        let resolvedFinish: Date = finishedAt
            ?? samples.map(\.completedAt).max()
            ?? now
        let resolvedStart: Date = samples.map(\.completedAt).min()
            ?? resolvedFinish
        return PracticeHistoryRecordSnapshot(
            id: id,
            sourceEventID: eventID,
            eventNameSnapshot: name,
            startedAt: resolvedStart,
            finishedAt: resolvedFinish,
            leftCount: leftCount
                ?? samples.filter { $0.hand == .left }.count,
            rightCount: rightCount
                ?? samples.filter { $0.hand == .right }.count,
            bothCount: bothCount
                ?? samples.filter { $0.hand == .both }.count,
            leftDurationMilliseconds: 0,
            rightDurationMilliseconds: 0,
            bothDurationMilliseconds: 0,
            bpm: nil,
            beats: nil,
            subdivision: nil,
            directionRawValue: nil,
            grouping: nil,
            referenceNoteRaw: nil,
            leftPreset: leftPreset,
            rightPreset: rightPreset,
            bothPreset: bothPreset,
            completionSamples: samples
        )
    }

    func testComparableKeySeparatesRhythmButMergesDirectionAndReferenceNote() throws {
        let focusEvent = UUID()
        let otherEvent = UUID()
        let base = preset(bpm: 80)

        var differentBeats = base
        differentBeats.beats = 4
        differentBeats.grouping = "标准"
        var differentTrainingNote = base
        differentTrainingNote.subdivision = 2
        var differentGrouping = base
        differentGrouping.grouping = "3+2"

        var differentDirection = base
        differentDirection.direction = .clockwise
        differentDirection.bpm = 90
        var differentReference = base
        differentReference.referenceNoteRaw = TempoReferenceNote.eighth.rawValue
        differentReference.bpm = 200 // quarter-note equivalent BPM is 100.

        let records = [
            record(
                eventID: focusEvent,
                name: "第 C 页",
                samples: [
                    sample(
                        hand: .left,
                        bpm: 80,
                        at: date(2026, 9, 4, 8),
                        eventPreset: base
                    ),
                    sample(
                        hand: .left,
                        bpm: 90,
                        at: date(2026, 9, 4, 9),
                        eventPreset: differentDirection
                    ),
                    sample(
                        hand: .left,
                        bpm: 200,
                        at: date(2026, 9, 4, 10),
                        eventPreset: differentReference
                    ),
                    sample(
                        hand: .left,
                        bpm: 220,
                        at: date(2026, 9, 4, 11),
                        eventPreset: differentBeats
                    ),
                    sample(
                        hand: .left,
                        bpm: 230,
                        at: date(2026, 9, 4, 12),
                        eventPreset: differentTrainingNote
                    ),
                    sample(
                        hand: .left,
                        bpm: 240,
                        at: date(2026, 9, 4, 13),
                        eventPreset: differentGrouping
                    )
                ]
            ),
            record(
                eventID: otherEvent,
                samples: [sample(
                    hand: .left,
                    bpm: 250,
                    at: date(2026, 9, 4, 14),
                    eventPreset: base
                )]
            )
        ]

        let result = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: PracticePieceAnalysisTarget(
                sectionID: focusEvent,
                preset: base
            ),
            range: .today,
            hand: .left,
            now: now,
            calendar: calendar
        )

        let context = try XCTUnwrap(result.context)
        XCTAssertEqual(context.configuration.sourceEventID, focusEvent)
        XCTAssertEqual(context.configuration.beats, 5)
        XCTAssertEqual(context.configuration.subdivision, 1)
        XCTAssertEqual(context.configuration.grouping, "2+3")
        XCTAssertEqual(context.focusHand, .left)
        XCTAssertEqual(context.eventName, "第 C 页")
        XCTAssertEqual(result.speedPerformance.completionCount, 3)
        XCTAssertEqual(result.speedPerformance.maximumBPM, 100)
        XCTAssertEqual(
            try XCTUnwrap(result.speedPerformance.weightedAverageBPM),
            90,
            accuracy: 0.000_1
        )
        XCTAssertEqual(result.trendPoints.map(\.maximumBPM), [80, 90, 100])
    }

    func testWeightedAverageAndStableSpeedUseLatestTenCompletionThreshold() throws {
        let eventID = UUID()
        // The older 200 BPM repetitions are inside the 30-day performance
        // window but deliberately outside the most recent ten completions.
        let bpms = [
            200, 200, 200,
            80, 80, 80,
            90, 90, 90,
            100, 100,
            120, 120
        ]
        let samples = bpms.enumerated().map { offset, bpm in
            sample(
                hand: .both,
                bpm: bpm,
                at: now.addingTimeInterval(Double(offset - bpms.count) * 60)
            )
        }
        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(eventID: eventID, samples: samples)],
            trendRange: .thirtyDays,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.speedPerformance.maximumBPM, 200)
        XCTAssertEqual(result.speedPerformance.completionCount, 13)
        XCTAssertEqual(
            try XCTUnwrap(result.speedPerformance.weightedAverageBPM),
            1_550.0 / 13,
            accuracy: 0.000_1
        )
        XCTAssertEqual(result.speedPerformance.stableBPM, 90)
        XCTAssertEqual(PracticePieceAnalysisEngine.stabilityRecentCompletionLimit, 10)
        XCTAssertEqual(PracticePieceAnalysisEngine.stabilityRequiredRepetitionCount, 3)

        let insufficient = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [80, 80, 90, 90].enumerated().map { offset, bpm in
                    sample(
                        hand: .both,
                        bpm: bpm,
                        at: now.addingTimeInterval(Double(offset) - 30)
                    )
                }
            )],
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertNil(insufficient.speedPerformance.stableBPM)
    }

    func testThirtyDayGrowthComparesSevenDayWindowsShiftedByThirtyDays() throws {
        let eventID = UUID()
        let samples = [
            sample(hand: .left, bpm: 120, at: dayOffset(-2)),
            sample(hand: .left, bpm: 110, at: dayOffset(-6)),
            sample(hand: .left, bpm: 210, at: dayOffset(-15)),
            sample(hand: .left, bpm: 100, at: dayOffset(-32)),
            sample(hand: .left, bpm: 90, at: dayOffset(-36)),
            sample(hand: .left, bpm: 230, at: dayOffset(-37))
        ]
        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(eventID: eventID, samples: samples)],
            trendRange: .ninetyDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.thirtyDayGrowth.currentMaximumBPM, 120)
        XCTAssertEqual(result.thirtyDayGrowth.comparisonMaximumBPM, 100)
        XCTAssertEqual(
            try XCTUnwrap(result.thirtyDayGrowth.percentage),
            20,
            accuracy: 0.000_1
        )

        let insufficient = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [sample(hand: .left, bpm: 120, at: dayOffset(-2))]
            )],
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(insufficient.thirtyDayGrowth.currentMaximumBPM, 120)
        XCTAssertNil(insufficient.thirtyDayGrowth.comparisonMaximumBPM)
        XCTAssertNil(insufficient.thirtyDayGrowth.percentage)
    }

    func testHandComparisonRequiresBothHandsAndExcludesCombinedHand() throws {
        let eventID = UUID()
        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [
                    sample(hand: .left, bpm: 120, at: dayOffset(-1)),
                    sample(hand: .right, bpm: 100, at: dayOffset(-1)),
                    sample(hand: .both, bpm: 220, at: dayOffset(-1))
                ]
            )],
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.handComparison.leftMaximumBPM, 120)
        XCTAssertEqual(result.handComparison.rightMaximumBPM, 100)
        XCTAssertEqual(result.handComparison.absoluteDifferenceBPM, 20)
        XCTAssertEqual(
            try XCTUnwrap(result.handComparison.differencePercentage),
            100.0 / 6,
            accuracy: 0.000_1
        )
        XCTAssertEqual(result.handComparison.slowerHand, .right)

        let singleHand = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [sample(hand: .left, bpm: 88, at: dayOffset(-1))]
            )],
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(singleHand.handComparison.leftMaximumBPM, 88)
        XCTAssertNil(singleHand.handComparison.rightMaximumBPM)
        XCTAssertNil(singleHand.handComparison.absoluteDifferenceBPM)
        XCTAssertNil(singleHand.handComparison.differencePercentage)
        XCTAssertNil(singleHand.handComparison.slowerHand)
    }

    func testTrendRangesUseRealDaysAndDailyMaximumWithoutFillingGaps() {
        let eventID = UUID()
        let samples = [
            sample(hand: .both, bpm: 90, at: dayOffset(0, hour: 9)),
            sample(hand: .both, bpm: 110, at: dayOffset(0, hour: 12)),
            sample(hand: .both, bpm: 100, at: dayOffset(-6)),
            sample(hand: .both, bpm: 130, at: dayOffset(-7)),
            sample(hand: .both, bpm: 140, at: dayOffset(-29)),
            sample(hand: .both, bpm: 150, at: dayOffset(-30)),
            sample(hand: .both, bpm: 160, at: dayOffset(-89)),
            sample(hand: .both, bpm: 170, at: dayOffset(-90))
        ]
        let records = [record(eventID: eventID, samples: samples)]

        let seven = PracticePieceAnalysisEngine.analyze(
            records: records,
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(seven.trendPoints.map(\.maximumBPM), [100, 110])
        XCTAssertEqual(seven.trendPoints.count, 2)

        let thirty = PracticePieceAnalysisEngine.analyze(
            records: records,
            trendRange: .thirtyDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(thirty.trendPoints.map(\.maximumBPM), [140, 130, 100, 110])

        let ninety = PracticePieceAnalysisEngine.analyze(
            records: records,
            trendRange: .ninetyDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(
            ninety.trendPoints.map(\.maximumBPM),
            [160, 150, 140, 130, 100, 110]
        )
        XCTAssertEqual(ninety.trendPoints.map(\.date), ninety.trendPoints.map(\.date).sorted())
    }

    func testLegacyResidualUsesSavedPresetAndIgnoresMissingConfiguration() throws {
        let eventID = UUID()
        let real = sample(hand: .left, bpm: 60, at: dayOffset(-1))
        let configured = record(
            eventID: eventID,
            samples: [real],
            finishedAt: dayOffset(0),
            leftCount: 3,
            leftPreset: preset(bpm: 90)
        )
        let unavailable = record(
            eventID: eventID,
            samples: [],
            finishedAt: dayOffset(0).addingTimeInterval(60),
            leftCount: 50,
            leftPreset: nil
        )

        let result = PracticePieceAnalysisEngine.analyze(
            records: [configured, unavailable],
            trendRange: .sevenDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result.speedPerformance.completionCount, 3)
        XCTAssertEqual(result.speedPerformance.maximumBPM, 90)
        XCTAssertEqual(
            try XCTUnwrap(result.speedPerformance.weightedAverageBPM),
            80,
            accuracy: 0.000_1
        )
        XCTAssertNil(result.speedPerformance.stableBPM)
    }

    func testSelectionFallsBackToAllHistoryWhenRecentNinetyDaysAreEmpty() throws {
        let eventID = UUID()
        let oldDate = dayOffset(-120)
        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [sample(hand: .right, bpm: 96, at: oldDate)]
            )],
            trendRange: .ninetyDays,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(try XCTUnwrap(result.context).focusHand, .right)
        XCTAssertNil(result.speedPerformance.maximumBPM)
        XCTAssertTrue(result.trendPoints.isEmpty)
    }

    func testExplicitSectionHandAndRangeDriveEveryMetric() throws {
        let selectedSectionID = UUID()
        let otherSectionID = UUID()
        let selectedSamples = [
            sample(hand: .left, bpm: 100, at: date(2026, 9, 4, 9)),
            sample(hand: .left, bpm: 120, at: date(2026, 9, 4, 16)),
            sample(hand: .right, bpm: 90, at: date(2026, 9, 4, 11)),
            sample(hand: .both, bpm: 80, at: date(2026, 9, 4, 13)),
            sample(hand: .left, bpm: 80, at: dayOffset(-1)),
            sample(hand: .right, bpm: 70, at: dayOffset(-1)),
            sample(hand: .left, bpm: 110, at: dayOffset(-6)),
            sample(hand: .left, bpm: 200, at: dayOffset(-7))
        ]
        let records = [
            record(
                eventID: selectedSectionID,
                name: "第 C 页",
                samples: selectedSamples
            ),
            record(
                eventID: otherSectionID,
                name: "其他页",
                samples: [sample(hand: .left, bpm: 240, at: now)]
            )
        ]
        let target = PracticePieceAnalysisTarget(
            sectionID: selectedSectionID
        )

        let today = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: target,
            range: .today,
            hand: .left,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(try XCTUnwrap(today.context).eventName, "第 C 页")
        XCTAssertEqual(try XCTUnwrap(today.context).focusHand, .left)
        XCTAssertEqual(today.speedPerformance.completionCount, 2)
        XCTAssertEqual(today.speedPerformance.maximumBPM, 120)
        XCTAssertEqual(
            try XCTUnwrap(today.speedPerformance.weightedAverageBPM),
            110,
            accuracy: 0.000_1
        )
        XCTAssertEqual(today.handComparison.leftMaximumBPM, 120)
        XCTAssertEqual(today.handComparison.rightMaximumBPM, 90)
        XCTAssertEqual(today.handComparison.absoluteDifferenceBPM, 30)
        XCTAssertEqual(today.growth.currentMaximumBPM, 120)
        XCTAssertEqual(today.growth.comparisonMaximumBPM, 80)
        XCTAssertEqual(today.growth.changeBPM, 40)
        XCTAssertEqual(
            try XCTUnwrap(today.growth.percentage),
            50,
            accuracy: 0.000_1
        )
        XCTAssertEqual(today.trendPoints.map(\.maximumBPM), [100, 120])
        XCTAssertEqual(
            today.trendPoints.map(\.date),
            [date(2026, 9, 4, 9), date(2026, 9, 4, 16)]
        )

        let sevenDays = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: target,
            range: .sevenDays,
            hand: .left,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sevenDays.speedPerformance.completionCount, 4)
        XCTAssertEqual(sevenDays.speedPerformance.maximumBPM, 120)
        XCTAssertEqual(sevenDays.growth.currentMaximumBPM, 120)
        XCTAssertEqual(sevenDays.growth.comparisonMaximumBPM, 200)
        XCTAssertEqual(sevenDays.growth.changeBPM, -80)
        XCTAssertEqual(
            try XCTUnwrap(sevenDays.growth.percentage),
            -40,
            accuracy: 0.000_1
        )
        XCTAssertEqual(sevenDays.trendPoints.map(\.maximumBPM), [110, 80, 120])

        let combined = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: target,
            range: .today,
            hand: .both,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(combined.speedPerformance.maximumBPM, 80)
        XCTAssertEqual(combined.trendPoints.map(\.maximumBPM), [80])
        // The focus-hand selector never removes the independent left/right
        // comparison for the same selected range.
        XCTAssertEqual(combined.handComparison.leftMaximumBPM, 120)
        XCTAssertEqual(combined.handComparison.rightMaximumBPM, 90)
    }

    func testQuarterNoteEquivalentBPMPreservesFractionalValues() throws {
        let eventID = UUID()
        let half = preset(bpm: 60, referenceNote: .half)
        let eighth = preset(bpm: 121, referenceNote: .eighth)
        let dottedQuarter = preset(bpm: 81, referenceNote: .dottedQuarter)
        var unknown = preset(bpm: 220)
        unknown.referenceNoteRaw = "future-note-value"
        let samples = [
            sample(hand: .left, bpm: 100, at: date(2026, 9, 4, 8)),
            sample(
                hand: .left,
                bpm: 60,
                at: date(2026, 9, 4, 9),
                eventPreset: half
            ),
            sample(
                hand: .left,
                bpm: 121,
                at: date(2026, 9, 4, 10),
                eventPreset: eighth
            ),
            sample(
                hand: .left,
                bpm: 121,
                at: date(2026, 9, 4, 11),
                eventPreset: eighth
            ),
            sample(
                hand: .left,
                bpm: 121,
                at: date(2026, 9, 4, 12),
                eventPreset: eighth
            ),
            sample(
                hand: .right,
                bpm: 81,
                at: date(2026, 9, 4, 13),
                eventPreset: dottedQuarter
            ),
            sample(
                hand: .left,
                bpm: 220,
                at: date(2026, 9, 4, 14),
                eventPreset: unknown
            )
        ]

        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(eventID: eventID, samples: samples)],
            target: PracticePieceAnalysisTarget(sectionID: eventID),
            range: .today,
            hand: .left,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.speedPerformance.completionCount, 5)
        XCTAssertEqual(result.speedPerformance.maximumBPM, 120)
        XCTAssertEqual(
            try XCTUnwrap(result.speedPerformance.weightedAverageBPM),
            80.3,
            accuracy: 0.000_1
        )
        XCTAssertEqual(result.speedPerformance.stableBPM, 60.5)
        XCTAssertEqual(result.handComparison.leftMaximumBPM, 120)
        XCTAssertEqual(result.handComparison.rightMaximumBPM, 121.5)
        XCTAssertEqual(result.handComparison.absoluteDifferenceBPM, 1.5)
        XCTAssertEqual(
            try XCTUnwrap(result.handComparison.differencePercentage),
            1.5 / 121.5 * 100,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            result.trendPoints.map(\.maximumBPM),
            [100, 120, 60.5, 60.5, 60.5]
        )
    }

    func testExplicitConfigurationCanNarrowOneSection() {
        let eventID = UUID()
        let selectedPreset = preset(bpm: 80)
        var otherPreset = selectedPreset
        otherPreset.beats = 4
        otherPreset.grouping = "标准"
        let records = [record(
            eventID: eventID,
            samples: [
                sample(
                    hand: .left,
                    bpm: 80,
                    at: date(2026, 9, 4, 9),
                    eventPreset: selectedPreset
                ),
                sample(
                    hand: .left,
                    bpm: 200,
                    at: date(2026, 9, 4, 10),
                    eventPreset: otherPreset
                )
            ]
        )]

        let dominantConfiguration = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: PracticePieceAnalysisTarget(sectionID: eventID),
            range: .today,
            hand: .left,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(dominantConfiguration.speedPerformance.completionCount, 1)
        XCTAssertEqual(dominantConfiguration.speedPerformance.maximumBPM, 200)

        let oneConfiguration = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: PracticePieceAnalysisTarget(
                sectionID: eventID,
                preset: selectedPreset
            ),
            range: .today,
            hand: .left,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(oneConfiguration.speedPerformance.completionCount, 1)
        XCTAssertEqual(oneConfiguration.speedPerformance.maximumBPM, 80)
    }

    func testExplicitTargetDoesNotFallBackOutsideSelectedRange() throws {
        let eventID = UUID()
        let result = PracticePieceAnalysisEngine.analyze(
            records: [record(
                eventID: eventID,
                samples: [sample(hand: .right, bpm: 96, at: dayOffset(-2))]
            )],
            target: PracticePieceAnalysisTarget(sectionID: eventID),
            range: .today,
            hand: .right,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(try XCTUnwrap(result.context).focusHand, .right)
        XCTAssertNil(result.speedPerformance.maximumBPM)
        XCTAssertNil(result.growth.currentMaximumBPM)
        XCTAssertNil(result.handComparison.rightMaximumBPM)
        XCTAssertTrue(result.trendPoints.isEmpty)
    }

    func testExplicitThirtyAndNinetyDayRangesRespectCalendarBoundaries() {
        let eventID = UUID()
        let records = [record(
            eventID: eventID,
            samples: [
                sample(hand: .right, bpm: 110, at: dayOffset(0)),
                sample(hand: .right, bpm: 130, at: dayOffset(-29)),
                sample(hand: .right, bpm: 140, at: dayOffset(-30)),
                sample(hand: .right, bpm: 150, at: dayOffset(-89)),
                sample(hand: .right, bpm: 160, at: dayOffset(-90))
            ]
        )]
        let target = PracticePieceAnalysisTarget(sectionID: eventID)

        let thirty = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: target,
            range: .thirtyDays,
            hand: .right,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(thirty.speedPerformance.completionCount, 2)
        XCTAssertEqual(thirty.speedPerformance.maximumBPM, 130)
        XCTAssertEqual(thirty.trendPoints.map(\.maximumBPM), [130, 110])

        let ninety = PracticePieceAnalysisEngine.analyze(
            records: records,
            target: target,
            range: .ninetyDays,
            hand: .right,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(ninety.speedPerformance.completionCount, 4)
        XCTAssertEqual(ninety.speedPerformance.maximumBPM, 150)
        XCTAssertEqual(
            ninety.trendPoints.map(\.maximumBPM),
            [150, 140, 130, 110]
        )
    }
}

final class PracticeHistoryMutationTests: XCTestCase {
    @MainActor
    func testEditingSingleHandRecordPersistsAndReconcilesEventStatistics() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        let songID = try store.saveSong(
            id: nil,
            name: "可编辑历史",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "第一段")],
            leftGoal: 10,
            rightGoal: 10,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let start = Date(timeIntervalSinceReferenceDate: 800_000)
        var preset = MetronomePreset.standard
        preset.bpm = 80
        let firstID = UUID()
        let secondID = UUID()
        _ = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: start,
            finishedAt: start.addingTimeInterval(120),
            left: HandPracticeStats(count: 2, durationMilliseconds: 120_000),
            completions: [
                PracticeCompletionSample(
                    id: firstID,
                    hand: .left,
                    preset: preset,
                    completedAt: start.addingTimeInterval(30)
                ),
                PracticeCompletionSample(
                    id: secondID,
                    hand: .left,
                    preset: preset,
                    completedAt: start.addingTimeInterval(90)
                )
            ],
            leftPreset: preset
        ))
        let original = try XCTUnwrap(store.records(for: songID).first)
        var draft = PracticeHistoryRecordEditDraft(record: original)
        draft.moveSingleHand(from: .left, to: .right)
        draft.update(hand: .right) {
            $0.count = 3
            $0.durationMilliseconds = 180_000
            $0.preset?.bpm = 92
        }
        draft.move(to: original.finishedAt.addingTimeInterval(3_600))

        try store.updateHistoryRecord(draft)

        let persisted = try XCTUnwrap(
            PracticeAttempt.find(id: original.id, in: context)
        )
        XCTAssertEqual(persisted.leftCount, 0)
        XCTAssertEqual(persisted.rightCount, 3)
        XCTAssertEqual(persisted.rightDurationMilliseconds, 180_000)
        XCTAssertEqual(persisted.finishedAt, draft.finishedAt)
        XCTAssertEqual(Set(persisted.completions.prefix(2).map(\.id)), [firstID, secondID])
        XCTAssertTrue(persisted.completions.allSatisfy { $0.hand == .right })
        XCTAssertEqual(persisted.completions.last?.source, .manualBackfill)
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 0)
        XCTAssertEqual(store.event(id: sectionID)?.rightCount, 3)
        XCTAssertEqual(store.event(id: sectionID)?.rightDurationMilliseconds, 180_000)

        let reloaded = try PracticeLibraryStore(modelContext: context)
        let reloadedRecord = try XCTUnwrap(reloaded.records(for: songID).first)
        XCTAssertEqual(reloadedRecord.rightCount, 3)
        XCTAssertEqual(reloadedRecord.preset(for: .right)?.bpm, 92)
        XCTAssertEqual(
            PracticeStatisticsEngine.summary(records: reloaded.records).totalCount,
            3
        )
    }

    @MainActor
    func testEditingLegacyAggregateDoesNotInventCompletionSamplesOrPreset() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        let songID = try store.saveSong(
            id: nil,
            name: "旧记录",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "汇总")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        _ = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: Date(timeIntervalSinceReferenceDate: 900_000),
            finishedAt: Date(timeIntervalSinceReferenceDate: 900_060),
            left: HandPracticeStats(count: 2, durationMilliseconds: 60_000)
        ))
        let original = try XCTUnwrap(store.records(for: songID).first)
        XCTAssertNil(original.preset(for: .left))
        var draft = PracticeHistoryRecordEditDraft(record: original)
        draft.update(hand: .left) { $0.count = 4 }

        try store.updateHistoryRecord(draft)

        let persisted = try XCTUnwrap(
            PracticeAttempt.find(id: original.id, in: context)
        )
        XCTAssertEqual(persisted.leftCount, 4)
        XCTAssertTrue(persisted.completions.isEmpty)
        XCTAssertNil(persisted.statisticsSnapshot.preset(for: .left))
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 4)
    }

    @MainActor
    func testCompletionEditAndConfirmedDeleteReconcileOnlyThatSample() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        _ = try store.saveSong(
            id: nil,
            name: "逐次记录",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "第一段")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let firstID = UUID()
        let secondID = UUID()
        let committed = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: start,
            finishedAt: start.addingTimeInterval(60),
            left: HandPracticeStats(count: 2),
            completions: [
                PracticeCompletionSample(
                    id: firstID,
                    hand: .left,
                    preset: .standard,
                    completedAt: start.addingTimeInterval(10)
                ),
                PracticeCompletionSample(
                    id: secondID,
                    hand: .left,
                    preset: .standard,
                    completedAt: start.addingTimeInterval(20)
                )
            ],
            leftPreset: .standard
        ))
        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: store.records).first
        )
        let first = try XCTUnwrap(session.attempts.first { $0.id == firstID })
        var edit = PracticeHistoryCompletionEditDraft(
            recordID: committed.attempt.id,
            completion: first
        )
        edit.hand = .both
        edit.preset.bpm = 144
        edit.completedAt = start.addingTimeInterval(-5)

        try store.updateHistoryCompletion(edit)

        var persisted = try XCTUnwrap(
            PracticeAttempt.find(id: committed.attempt.id, in: context)
        )
        XCTAssertEqual(persisted.leftCount, 1)
        XCTAssertEqual(persisted.bothCount, 1)
        XCTAssertEqual(persisted.completions.first { $0.id == firstID }?.hand, .both)
        XCTAssertEqual(persisted.completions.first { $0.id == firstID }?.preset.bpm, 144)
        XCTAssertEqual(persisted.startedAt, start.addingTimeInterval(-5))
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 1)
        XCTAssertEqual(store.event(id: sectionID)?.bothCount, 1)

        XCTAssertTrue(try store.deleteHistoryCompletion(
            recordID: committed.attempt.id,
            completionID: firstID
        ))
        persisted = try XCTUnwrap(
            PracticeAttempt.find(id: committed.attempt.id, in: context)
        )
        XCTAssertEqual(persisted.leftCount, 1)
        XCTAssertEqual(persisted.bothCount, 0)
        XCTAssertEqual(persisted.completions.map(\.id), [secondID])
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 1)
        XCTAssertEqual(store.event(id: sectionID)?.bothCount, 0)

        XCTAssertFalse(try store.deleteHistoryCompletion(
            recordID: committed.attempt.id,
            completionID: UUID()
        ))
        XCTAssertEqual(store.records.first?.totalCount, 1)
    }

    @MainActor
    func testDeletingWholeRecordRemovesDurableAttemptAndAggregateStatistics() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        _ = try store.saveSong(
            id: nil,
            name: "删除记录",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "段落")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let committed = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_100_000),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1_100_030),
            right: HandPracticeStats(count: 2, durationMilliseconds: 30_000)
        ))

        XCTAssertTrue(try store.deleteHistoryRecord(id: committed.attempt.id))

        XCTAssertNil(try PracticeAttempt.find(id: committed.attempt.id, in: context))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.event(id: sectionID)?.rightCount, 0)
        XCTAssertEqual(store.event(id: sectionID)?.rightDurationMilliseconds, 0)
        XCTAssertEqual(PracticeStatisticsEngine.summary(records: store.records).totalCount, 0)
    }

    @MainActor
    func testEditingAndDeletingManualSummaryDoesNotTouchNeighboringLiveCompletion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        let songID = try store.saveSong(
            id: nil,
            name: "混合历史",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "混合段落")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let start = Date(timeIntervalSinceReferenceDate: 1_200_000)
        let liveID = UUID()
        var manualPreset = MetronomePreset.standard
        manualPreset.bpm = 88
        let manual = PracticeCompletionSample.manualBackfillBatch(
            hand: .left,
            preset: manualPreset,
            count: 2,
            completedAt: start.addingTimeInterval(50)
        )
        let committed = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: start,
            finishedAt: start.addingTimeInterval(60),
            left: HandPracticeStats(count: 3, durationMilliseconds: 60_000),
            completions: [
                PracticeCompletionSample(
                    id: liveID,
                    hand: .left,
                    preset: .standard,
                    completedAt: start.addingTimeInterval(10)
                )
            ] + manual,
            leftPreset: manualPreset
        ))
        let originalRecord = try XCTUnwrap(store.records(for: songID).first)
        let originalSession = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [originalRecord]).only
        )
        let summary = try XCTUnwrap(
            originalSession.unitemizedCompletions.first {
                $0.reason == .manualBackfill
            }
        )
        var draft = PracticeHistoryUnitemizedEditDraft(
            record: originalRecord,
            summary: summary
        )
        draft.hand = .both
        draft.count = 3
        draft.preset?.bpm = 132

        try store.updateHistoryUnitemized(draft)

        var persisted = try XCTUnwrap(
            PracticeAttempt.find(id: committed.attempt.id, in: context)
        )
        let live = try XCTUnwrap(persisted.completions.first { $0.id == liveID })
        XCTAssertEqual(live.hand, .left)
        XCTAssertEqual(live.preset, MetronomePreset.standard)
        XCTAssertEqual(live.source, .live)
        XCTAssertEqual(persisted.leftCount, 1)
        XCTAssertEqual(persisted.bothCount, 3)
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 1)
        XCTAssertEqual(store.event(id: sectionID)?.bothCount, 3)

        let revisedRecord = try XCTUnwrap(store.records(for: songID).first)
        let revisedSession = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [revisedRecord]).only
        )
        let revisedSummary = try XCTUnwrap(
            revisedSession.unitemizedCompletions.first {
                $0.reason == .manualBackfill && $0.hand == .both
            }
        )
        let revisedDraft = PracticeHistoryUnitemizedEditDraft(
            record: revisedRecord,
            summary: revisedSummary
        )
        XCTAssertTrue(try store.deleteHistoryUnitemized(revisedDraft))

        persisted = try XCTUnwrap(
            PracticeAttempt.find(id: committed.attempt.id, in: context)
        )
        XCTAssertEqual(persisted.completions.map(\.id), [liveID])
        XCTAssertEqual(persisted.leftCount, 1)
        XCTAssertEqual(persisted.bothCount, 0)
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 1)
        XCTAssertEqual(store.event(id: sectionID)?.bothCount, 0)
    }

    @MainActor
    func testDeletingWholeManualSummaryRemovesItsDurationAndAttempt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        let songID = try store.saveSong(
            id: nil,
            name: "纯补录",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "补录段落")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_300_000)
        let samples = PracticeCompletionSample.manualBackfillBatch(
            hand: .right,
            preset: .standard,
            count: 2,
            completedAt: completedAt
        )
        let committed = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: completedAt.addingTimeInterval(-45),
            finishedAt: completedAt,
            right: HandPracticeStats(count: 2, durationMilliseconds: 45_000),
            completions: samples,
            rightPreset: .standard
        ))
        let record = try XCTUnwrap(store.records(for: songID).first)
        let session = try XCTUnwrap(
            PracticeStatisticsEngine.historySessions(records: [record]).only
        )
        let summary = try XCTUnwrap(session.unitemizedCompletions.only)
        let draft = PracticeHistoryUnitemizedEditDraft(record: record, summary: summary)

        XCTAssertTrue(try store.deleteHistoryUnitemized(draft))

        XCTAssertNil(try PracticeAttempt.find(id: committed.attempt.id, in: context))
        XCTAssertEqual(store.event(id: sectionID)?.rightCount, 0)
        XCTAssertEqual(store.event(id: sectionID)?.rightDurationMilliseconds, 0)
    }

    @MainActor
    func testDetachedEditDraftCancellationLeavesPersistedStateUnchanged() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = try PracticeLibraryStore(modelContext: context)
        let sectionID = UUID()
        _ = try store.saveSong(
            id: nil,
            name: "取消编辑",
            group: "测试",
            sections: [PracticeSectionDraft(id: sectionID, name: "段落")],
            leftGoal: 0,
            rightGoal: 0,
            bothGoal: 0,
            multiplier: 1,
            resetsDaily: false,
            endDate: .distantFuture,
            archived: false
        )
        let committed = try store.commit(summary: PracticeSessionSummary(
            sourceEventID: sectionID,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_400_000),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1_400_060),
            left: HandPracticeStats(count: 2, durationMilliseconds: 60_000)
        ))
        let original = committed.attempt.statisticsSnapshot
        var cancelledDraft = PracticeHistoryRecordEditDraft(record: original)
        cancelledDraft.update(hand: .left) {
            $0.count = 99
            $0.durationMilliseconds = 1
        }
        cancelledDraft.move(to: original.finishedAt.addingTimeInterval(86_400))
        // Mirroring the sheet's Cancel action: no store mutation is invoked.

        let persisted = try XCTUnwrap(
            PracticeAttempt.find(id: committed.attempt.id, in: context)
        )
        XCTAssertEqual(persisted.leftCount, 2)
        XCTAssertEqual(persisted.leftDurationMilliseconds, 60_000)
        XCTAssertEqual(persisted.finishedAt, original.finishedAt)
        XCTAssertEqual(store.event(id: sectionID)?.leftCount, 2)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            PracticeSong.self,
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
