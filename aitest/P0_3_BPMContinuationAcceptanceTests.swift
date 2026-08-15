import XCTest
@testable import GeoPractice

/// Quantitative acceptance coverage for P0-3.
///
/// Real-device judgments such as an audible click dropout or a visibly
/// distracting flash are intentionally kept in the issue's manual acceptance
/// section. This suite verifies the deterministic transport contract: cursor
/// continuity, subdivision continuity, measure rollover, and the interval that
/// becomes effective after every BPM change.
final class P0_3_BPMContinuationAcceptanceTests: XCTestCase {
    private let beats = 4
    private let pulsesPerBeat = 2

    func testChangingFrom60To70OnThirdBeatContinuesAtNextSubdivision() throws {
        let previousPlan = makePlan(bpm: 60)
        let nextPlan = makePlan(bpm: 70)
        let elapsedSinceLastPulse = 0.10

        let continuation = BeatPlaybackContinuation.next(
            currentBeat: 2,
            currentSubdivision: 0,
            currentCycle: 12,
            previousPlan: previousPlan,
            nextPlan: nextPlan,
            elapsedSinceLastPulse: elapsedSinceLastPulse
        )

        XCTAssertEqual(continuation.initialEventIndex, 5, "第三拍主拍之后应进入第三拍的八分细分")
        XCTAssertNotEqual(continuation.initialEventIndex, 0, "BPM 变化不得回到第一拍")
        XCTAssertEqual(continuation.initialCycle, 12, "未跨越小节边界时不得重置或增加小节")
        XCTAssertEqual(
            try XCTUnwrap(continuation.firstEventPresentationDelay),
            nextPlan.eventInterval - elapsedSinceLastPulse,
            accuracy: 0.000_001,
            "下一事件必须按 70 BPM 的新间隔计算"
        )
    }

    func testSequence60To70To80To65AdvancesExactlyOneEventPerChange() throws {
        var currentBeat = 2
        var currentSubdivision = 0
        var currentCycle = 12
        var previousPlan = makePlan(bpm: 60)

        let changes: [(bpm: Int, elapsed: TimeInterval)] = [
            (70, 0.10),
            (80, 0.08),
            (65, 0.12)
        ]
        let expectedEventIndices = [5, 6, 7]
        let expectedAddresses = [(2, 1), (3, 0), (3, 1)]

        for (offset, change) in changes.enumerated() {
            let nextPlan = makePlan(bpm: change.bpm)
            let continuation = BeatPlaybackContinuation.next(
                currentBeat: currentBeat,
                currentSubdivision: currentSubdivision,
                currentCycle: currentCycle,
                previousPlan: previousPlan,
                nextPlan: nextPlan,
                elapsedSinceLastPulse: change.elapsed
            )

            XCTAssertEqual(continuation.initialEventIndex, expectedEventIndices[offset])
            XCTAssertNotEqual(continuation.initialEventIndex, 0, "第 \(offset + 1) 次变速不应跳回第一拍")
            XCTAssertEqual(continuation.initialCycle, 12, "连续变速期间小节号必须保持")
            XCTAssertEqual(
                try XCTUnwrap(continuation.firstEventPresentationDelay),
                max(0, nextPlan.eventInterval - change.elapsed),
                accuracy: 0.000_001,
                "\(change.bpm) BPM 应从下一事件生效"
            )

            let address = address(for: continuation.initialEventIndex)
            XCTAssertEqual(address.beat, expectedAddresses[offset].0)
            XCTAssertEqual(address.subdivision, expectedAddresses[offset].1)

            // Simulate presentation of the scheduled event before the next
            // user adjustment. The next change must continue from this exact
            // beat/subdivision rather than reconstructing a downbeat cursor.
            currentBeat = address.beat
            currentSubdivision = address.subdivision
            currentCycle = continuation.initialCycle
            previousPlan = nextPlan
        }
    }

    func testRepeatedChangesBeforeNextPulseDoNotAdvanceCursorTwice() throws {
        let currentBeat = 1
        let currentSubdivision = 1
        let currentCycle = 7
        let previousPlan = makePlan(bpm: 60)

        for bpm in [70, 80, 65] {
            let nextPlan = makePlan(bpm: bpm)
            let continuation = BeatPlaybackContinuation.next(
                currentBeat: currentBeat,
                currentSubdivision: currentSubdivision,
                currentCycle: currentCycle,
                previousPlan: previousPlan,
                nextPlan: nextPlan,
                elapsedSinceLastPulse: 0.11
            )

            XCTAssertEqual(continuation.initialEventIndex, 4, "没有新脉冲时，多次变速不得重复推进游标")
            XCTAssertEqual(continuation.initialCycle, currentCycle)
            XCTAssertEqual(
                try XCTUnwrap(continuation.firstEventPresentationDelay),
                max(0, nextPlan.eventInterval - 0.11),
                accuracy: 0.000_001
            )
        }
    }

    func testMeasureAdvancesOnlyAfterFinalSubdivision() {
        let plan = makePlan(bpm: 65)
        let continuation = BeatPlaybackContinuation.next(
            currentBeat: 3,
            currentSubdivision: 1,
            currentCycle: 12,
            previousPlan: plan,
            nextPlan: plan,
            elapsedSinceLastPulse: 0.10
        )

        XCTAssertEqual(continuation.initialEventIndex, 0)
        XCTAssertEqual(continuation.initialCycle, 13, "只有完成第四拍最后一个细分后才允许进入下一小节")
    }

    func testBPMChangesKeepVisualPulseAddressesStable() throws {
        let expectedPhases = [2.0, 2.5, 3.0, 3.5]

        for bpm in [60, 70, 80, 65] {
            let plan = makePlan(bpm: bpm)
            XCTAssertEqual(plan.eventsPerMeasure, 8)
            XCTAssertEqual(plan.pulsesPerBeat, pulsesPerBeat)

            let addresses = try (4...7).map { eventIndex in
                let cursor = address(for: eventIndex)
                return try XCTUnwrap(BeatPulseVisualModel.address(
                    beat: cursor.beat,
                    subdivision: cursor.subdivision,
                    beats: beats,
                    pulsesPerBeat: pulsesPerBeat
                ))
            }

            XCTAssertEqual(addresses.map(\.phase), expectedPhases, "BPM 只能改变时间，不得改变视觉拍位")
        }
    }

    func testEveryTargetBPMProducesExactFollowingEventInterval() {
        let cases: [(bpm: Int, interval: TimeInterval)] = [
            (60, 0.5),
            (70, 60.0 / 70.0 / 2.0),
            (80, 0.375),
            (65, 60.0 / 65.0 / 2.0)
        ]

        for item in cases {
            XCTAssertEqual(
                makePlan(bpm: item.bpm).eventInterval,
                item.interval,
                accuracy: 0.000_001,
                "\(item.bpm) BPM 的后续八分事件间隔不正确"
            )
        }
    }

    private func makePlan(bpm: Int) -> MetronomePlaybackPlan {
        var preset = MetronomePreset.standard
        preset.bpm = bpm
        preset.beats = beats
        preset.subdivision = pulsesPerBeat
        preset.referenceNote = .quarter
        return preset.playbackPlan(
            semantics: .independentReference,
            referenceNote: .quarter
        )
    }

    private func address(for eventIndex: Int) -> (beat: Int, subdivision: Int) {
        (
            beat: eventIndex / pulsesPerBeat,
            subdivision: eventIndex % pulsesPerBeat
        )
    }
}
