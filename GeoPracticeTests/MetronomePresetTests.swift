import XCTest
@testable import GeoPractice

final class MetronomePresetTests: XCTestCase {
    func testTempoNameBoundaries() {
        let cases: [(Int, String)] = [
            (30, "Largo"), (54, "Largo"),
            (55, "Adagio"), (75, "Adagio"),
            (76, "Andante"), (107, "Andante"),
            (108, "Moderato"), (119, "Moderato"),
            (120, "Allegro"), (167, "Allegro"),
            (168, "Presto"), (199, "Presto"),
            (200, "Prestissimo"), (240, "Prestissimo")
        ]

        for (bpm, expected) in cases {
            var preset = MetronomePreset.standard
            preset.bpm = bpm
            XCTAssertEqual(preset.tempoName, expected, "Unexpected marking at \(bpm) BPM")
        }
    }

    func testGroupingStartIndices() {
        var preset = MetronomePreset.standard
        preset.beats = 8
        preset.grouping = "3+3+2"
        XCTAssertEqual(preset.groupStartIndices, [0, 3, 6])

        preset.beats = 7
        preset.grouping = "2+3+2"
        XCTAssertEqual(preset.groupStartIndices, [0, 2, 5])
    }

    func testNormalizationClampsAndRepairsSettings() {
        let invalid = MetronomePreset(
            bpm: 999,
            beats: 7,
            subdivision: 3,
            direction: .clockwise,
            grouping: "4+4"
        ).normalized

        XCTAssertEqual(invalid.bpm, 240)
        XCTAssertEqual(invalid.beats, 7)
        XCTAssertEqual(invalid.subdivision, 1)
        XCTAssertEqual(invalid.grouping, "2+2+3")
        XCTAssertEqual(invalid.direction, .clockwise)
    }

    func testPracticeEventStoresPresetSnapshotAndCounts() {
        var source = MetronomePreset.standard
        source.bpm = 144
        source.beats = 5
        source.grouping = "3+2"

        let event = PracticeEvent(name: "音阶", leftCount: 2, preset: source)
        source.bpm = 72

        XCTAssertEqual(event.preset.bpm, 144)
        XCTAssertEqual(event.preset.grouping, "3+2")
        XCTAssertEqual(event.leftCount, 2)

        event.increment(.right)
        event.increment(.both)
        event.decrement(.left)
        XCTAssertEqual(event.leftCount, 1)
        XCTAssertEqual(event.rightCount, 1)
        XCTAssertEqual(event.bothCount, 1)
        XCTAssertEqual(event.totalCount, 3)
    }

    func testPracticeSessionBeginsWithBothHandsAndLiveDurationSnapshot() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let sourceEventID = UUID()
        var session = PracticeSession()

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.currentHand, .both)
        XCTAssertFalse(session.isRunning)

        session.begin(sourceEventID: sourceEventID, at: start)
        session.begin(sourceEventID: UUID(), at: start.addingTimeInterval(10))

        XCTAssertEqual(session.phase, .running)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.sourceEventID, sourceEventID)
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(session.segmentStartedAt, start)
        XCTAssertEqual(session.currentSegmentMilliseconds(at: start.addingTimeInterval(1.234)), 1_234)
        XCTAssertEqual(
            session.stats(for: .both, at: start.addingTimeInterval(1.234)).durationMilliseconds,
            1_234
        )
        XCTAssertEqual(session.stats(for: .left, at: start.addingTimeInterval(10)).durationMilliseconds, 0)
    }

    func testPracticeSessionSwitchesHandsAndFinishIsIdempotent() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        let sourceEventID = UUID()
        var session = PracticeSession()
        session.begin(sourceEventID: sourceEventID, at: start)
        session.adjustCount(for: .both, by: 2)

        session.switchHand(to: .left, at: start.addingTimeInterval(1.5))
        session.switchHand(to: .left, at: start.addingTimeInterval(9))
        session.adjustCount(for: .left, by: 3)

        let first = session.finish(at: start.addingTimeInterval(4))
        let second = session.finish(at: start.addingTimeInterval(20))

        XCTAssertEqual(first, second)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.segmentStartedAt)
        XCTAssertEqual(first?.sourceEventID, sourceEventID)
        XCTAssertEqual(first?.stats(for: .both), HandPracticeStats(count: 2, durationMilliseconds: 1_500))
        XCTAssertEqual(first?.stats(for: .left), HandPracticeStats(count: 3, durationMilliseconds: 2_500))
        XCTAssertEqual(first?.stats(for: .right), HandPracticeStats())
        XCTAssertEqual(first?.totalCount, 5)
        XCTAssertEqual(first?.totalDurationMilliseconds, 4_000)
    }

    func testPracticeSessionPauseResumeAndPausedHandSwitch() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var session = PracticeSession()
        session.begin(at: start)

        session.pause(at: start.addingTimeInterval(1.2))
        session.pause(at: start.addingTimeInterval(5))
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(session.stats(for: .both, at: start.addingTimeInterval(10)).durationMilliseconds, 1_200)
        XCTAssertEqual(session.currentSegmentMilliseconds(at: start.addingTimeInterval(10)), 0)

        session.switchHand(to: .right, at: start.addingTimeInterval(1.5))
        XCTAssertEqual(session.currentHand, .right)
        XCTAssertEqual(session.phase, .paused)

        session.resume(at: start.addingTimeInterval(2))
        session.resume(at: start.addingTimeInterval(3))
        session.adjustCount(for: .right, by: 1)
        let summary = session.finish(at: start.addingTimeInterval(4))

        XCTAssertEqual(summary?.stats(for: .both).durationMilliseconds, 1_200)
        XCTAssertEqual(summary?.stats(for: .right), HandPracticeStats(count: 1, durationMilliseconds: 2_000))
        XCTAssertEqual(summary?.totalDurationMilliseconds, 3_200)
    }

    func testPracticeSessionCountsNeverBecomeNegativeAndResetClearsState() {
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        var session = PracticeSession()

        session.adjustCount(for: .both, by: 5)
        XCTAssertEqual(session.stats(for: .both, at: start).count, 0)

        session.begin(at: start)
        session.adjustCount(for: .both, by: -1)
        session.adjustCount(for: .left, by: 4)
        session.adjustCount(for: .left, by: -10)
        XCTAssertEqual(session.stats(for: .both, at: start).count, 0)
        XCTAssertEqual(session.stats(for: .left, at: start).count, 0)

        _ = session.finish(at: start)
        session.adjustCount(for: .both, by: 10)
        XCTAssertEqual(session.stats(for: .both, at: start).count, 0)

        session.reset()
        XCTAssertEqual(session, PracticeSession())
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.currentHand, .both)
    }

    func testPracticeSessionCanContinueAfterFinishedSummaryReview() {
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var session = PracticeSession()
        session.begin(at: start)

        let firstSummary = session.finish(at: start.addingTimeInterval(2))
        XCTAssertEqual(firstSummary?.stats(for: .both).durationMilliseconds, 2_000)
        XCTAssertEqual(
            session.stats(for: .both, at: start.addingTimeInterval(20)).durationMilliseconds,
            2_000,
            "Time spent reviewing a finished summary must not count as practice"
        )

        session.continueAfterReview(at: start.addingTimeInterval(20))
        session.continueAfterReview(at: start.addingTimeInterval(25))
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.segmentStartedAt, start.addingTimeInterval(20))

        let continuedSummary = session.finish(at: start.addingTimeInterval(23))
        XCTAssertEqual(continuedSummary?.stats(for: .both).durationMilliseconds, 5_000)
        XCTAssertEqual(continuedSummary?.startedAt, start)
    }

    func testPracticeEventAppendsSessionCountsAndDurations() {
        let event = PracticeEvent(
            name: "琶音",
            leftCount: 2,
            rightCount: 1,
            leftDurationMilliseconds: 500,
            rightDurationMilliseconds: nil,
            bothDurationMilliseconds: -100
        )
        let summary = PracticeSessionSummary(
            left: HandPracticeStats(count: 3, durationMilliseconds: 1_500),
            right: HandPracticeStats(count: 4, durationMilliseconds: 2_000),
            both: HandPracticeStats(count: 2, durationMilliseconds: 3_000)
        )

        event.append(summary: summary)

        XCTAssertEqual(event.leftCount, 5)
        XCTAssertEqual(event.rightCount, 5)
        XCTAssertEqual(event.bothCount, 2)
        XCTAssertEqual(event.durationMilliseconds(for: .left), 2_000)
        XCTAssertEqual(event.durationMilliseconds(for: .right), 2_000)
        XCTAssertEqual(event.durationMilliseconds(for: .both), 3_000)
        XCTAssertEqual(event.totalCount, 12)
        XCTAssertEqual(event.totalDurationMilliseconds, 7_000)
    }

    func testPracticeDurationFormattingBoundaries() {
        XCTAssertEqual(practiceDurationString(milliseconds: 0), "00:00")
        XCTAssertEqual(practiceDurationString(milliseconds: 59_999), "00:59")
        XCTAssertEqual(practiceDurationString(milliseconds: 60_000), "01:00")
        XCTAssertEqual(practiceDurationString(milliseconds: 3_600_000), "01:00:00")
        XCTAssertEqual(practiceDurationString(milliseconds: 3_661_000), "01:01:01")
    }

    func testActivePracticeSessionCanRoundTripAsDraft() throws {
        let start = Date(timeIntervalSinceReferenceDate: 6_000)
        var session = PracticeSession()
        session.begin(sourceEventID: UUID(), at: start)
        session.adjustCount(for: .both, by: 2)
        session.switchHand(to: .left, at: start.addingTimeInterval(4.25))
        session.adjustCount(for: .left, by: 1)

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(PracticeSession.self, from: data)

        XCTAssertEqual(restored, session)
        XCTAssertEqual(
            restored.stats(for: .both, at: start.addingTimeInterval(10)),
            HandPracticeStats(count: 2, durationMilliseconds: 4_250)
        )
        XCTAssertEqual(restored.currentHand, .left)
    }

    @MainActor
    func testControllerRestoresRunningDraftAsPausedWithPreset() {
        let suiteName = "GeoPracticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let start = Date(timeIntervalSinceReferenceDate: 7_000)
        let sourceID = UUID()
        var preset = MetronomePreset.standard
        preset.bpm = 168
        preset.beats = 7
        preset.grouping = "2+3+2"

        let original = PracticeSessionController(defaults: defaults)
        original.begin(sourceEventID: sourceID, preset: preset, at: start)
        original.switchHand(to: .left, at: start.addingTimeInterval(2))
        original.adjustCount(for: .left, by: 3)
        original.persistSnapshot(at: start.addingTimeInterval(5))

        let restored = PracticeSessionController(defaults: defaults)
        XCTAssertEqual(restored.session.phase, .paused)
        XCTAssertEqual(restored.session.sourceEventID, sourceID)
        XCTAssertEqual(restored.session.currentHand, .left)
        XCTAssertEqual(restored.session.stats(for: .both, at: start).durationMilliseconds, 2_000)
        XCTAssertEqual(restored.session.stats(for: .left, at: start).durationMilliseconds, 3_000)
        XCTAssertEqual(restored.session.stats(for: .left, at: start).count, 3)
        XCTAssertEqual(restored.sessionPreset, preset.normalized)
    }

    @MainActor
    func testControllerRestoresFinishedDraftForSummaryReview() {
        let suiteName = "GeoPracticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let start = Date(timeIntervalSinceReferenceDate: 8_000)
        var preset = MetronomePreset.standard
        preset.bpm = 72

        let original = PracticeSessionController(defaults: defaults)
        original.begin(preset: preset, at: start)
        original.adjustCount(for: .both, by: 4)
        _ = original.finish(at: start.addingTimeInterval(6))

        let restored = PracticeSessionController(defaults: defaults)
        XCTAssertEqual(restored.session.phase, .finished)
        XCTAssertEqual(restored.session.reviewSummary?.stats(for: .both).count, 4)
        XCTAssertEqual(
            restored.session.reviewSummary?.stats(for: .both).durationMilliseconds,
            6_000
        )
        XCTAssertEqual(restored.sessionPreset, preset.normalized)
    }
}
