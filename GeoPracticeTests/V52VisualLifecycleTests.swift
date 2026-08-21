import XCTest
@testable import GeoPractice

final class V52VisualLifecycleTests: XCTestCase {
    func testMotionModelCompletesExactlyOneTurnForQuarterEighthAndSixteenth() throws {
        let beats = 4

        for pulsesPerBeat in [1, 2, 4] {
            let eventsPerMeasure = beats * pulsesPerBeat
            for beat in 0..<beats {
                for subdivision in 0..<pulsesPerBeat {
                    let sample = try XCTUnwrap(BeatVisualMotionModel.sample(
                        beat: beat,
                        subdivision: subdivision,
                        elapsed: 0,
                        eventInterval: 0.125,
                        pulsesPerBeat: pulsesPerBeat,
                        eventsPerMeasure: eventsPerMeasure,
                        beats: beats
                    ))
                    let eventIndex = beat * pulsesPerBeat + subdivision
                    XCTAssertEqual(
                        sample.measurePhase,
                        Double(eventIndex) / Double(eventsPerMeasure),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        sample.perimeterPhase,
                        Double(beat) + Double(subdivision) / Double(pulsesPerBeat),
                        accuracy: 0.000_001
                    )
                }
            }

            let wrapped = try XCTUnwrap(BeatVisualMotionModel.sample(
                beat: beats - 1,
                subdivision: pulsesPerBeat - 1,
                elapsed: 0.125,
                eventInterval: 0.125,
                pulsesPerBeat: pulsesPerBeat,
                eventsPerMeasure: eventsPerMeasure,
                beats: beats
            ))
            XCTAssertEqual(wrapped.eventProgress, 1, accuracy: 0.000_001)
            XCTAssertEqual(wrapped.measurePhase, 0, accuracy: 0.000_001)
            XCTAssertEqual(wrapped.perimeterPhase, 0, accuracy: 0.000_001)
        }
    }

    func testMotionModelClampsNegativeAndOverlongElapsedTime() throws {
        let negative = try XCTUnwrap(BeatVisualMotionModel.sample(
            beat: 1,
            subdivision: 2,
            elapsed: -4,
            eventInterval: 0.25,
            pulsesPerBeat: 4,
            eventsPerMeasure: 16,
            beats: 4
        ))
        XCTAssertEqual(negative.eventProgress, 0)
        XCTAssertEqual(negative.perimeterPhase, 1.5, accuracy: 0.000_001)

        let overlong = try XCTUnwrap(BeatVisualMotionModel.sample(
            beat: 1,
            subdivision: 2,
            elapsed: 40,
            eventInterval: 0.25,
            pulsesPerBeat: 4,
            eventsPerMeasure: 16,
            beats: 4
        ))
        XCTAssertEqual(overlong.eventProgress, 1)
        XCTAssertEqual(overlong.perimeterPhase, 1.75, accuracy: 0.000_001)

        let infinite = try XCTUnwrap(BeatVisualMotionModel.sample(
            beat: 1,
            subdivision: 2,
            elapsed: .infinity,
            eventInterval: 0.25,
            pulsesPerBeat: 4,
            eventsPerMeasure: 16,
            beats: 4
        ))
        XCTAssertEqual(infinite, overlong)
    }

    func testMotionModelRejectsInconsistentSchedulerAddresses() {
        XCTAssertNil(BeatVisualMotionModel.sample(
            beat: 4,
            subdivision: 0,
            elapsed: 0,
            eventInterval: 1,
            pulsesPerBeat: 1,
            eventsPerMeasure: 4,
            beats: 4
        ))
        XCTAssertNil(BeatVisualMotionModel.sample(
            beat: 0,
            subdivision: 2,
            elapsed: 0,
            eventInterval: 1,
            pulsesPerBeat: 2,
            eventsPerMeasure: 8,
            beats: 4
        ))
        XCTAssertNil(BeatVisualMotionModel.sample(
            beat: 0,
            subdivision: 0,
            elapsed: 0,
            eventInterval: 1,
            pulsesPerBeat: 2,
            eventsPerMeasure: 7,
            beats: 4
        ))
    }

    func testSubdivisionMotionDoesNotChangeConstructedEdges() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        let initialEdges = lifecycle.visibleEdgeIndices

        var phases: [Double] = []
        for subdivision in 1..<4 {
            lifecycle.record(
                beat: 0,
                subdivision: subdivision,
                cycle: 0,
                beats: 4,
                pulsesPerBeat: 4
            )
            let sample = try XCTUnwrap(BeatVisualMotionModel.sample(
                beat: 0,
                subdivision: subdivision,
                elapsed: 0,
                eventInterval: 0.125,
                pulsesPerBeat: 4,
                eventsPerMeasure: 16,
                beats: 4
            ))
            phases.append(sample.perimeterPhase)
        }

        XCTAssertEqual(lifecycle.visibleEdgeIndices, initialEdges)
        XCTAssertEqual(phases, [0.25, 0.5, 0.75])
    }

    func testPauseContinuationAdvancesToTheNextSubdivision() {
        var preset = MetronomePreset.standard
        preset.beats = 4
        preset.subdivision = 2
        let plan = preset.playbackPlan()

        let continuation = BeatPlaybackContinuation(
            afterBeat: 2,
            subdivision: 0,
            cycle: 7,
            plan: plan
        )

        XCTAssertEqual(continuation.eventIndex, 5)
        XCTAssertEqual(continuation.cycle, 7)
        var frontier = continuation.frontier
        let event = frontier.takeNext(plan: plan, sampleRate: 44_100)
        XCTAssertEqual(event.beat, 2)
        XCTAssertEqual(event.subdivision, 1)
        XCTAssertEqual(event.cycle, 7)
    }

    func testPauseContinuationWrapsOnlyAfterTheFinalEvent() {
        var preset = MetronomePreset.standard
        preset.beats = 4
        preset.subdivision = 2
        let plan = preset.playbackPlan()

        let continuation = BeatPlaybackContinuation(
            afterBeat: 3,
            subdivision: 1,
            cycle: 9,
            plan: plan
        )

        XCTAssertEqual(continuation.eventIndex, 0)
        XCTAssertEqual(continuation.cycle, 10)
        var frontier = continuation.frontier
        let event = frontier.takeNext(plan: plan, sampleRate: 44_100)
        XCTAssertEqual(event.beat, 0)
        XCTAssertEqual(event.subdivision, 0)
        XCTAssertEqual(event.cycle, 10)
    }

    func testBeatCountIsNormalizedAcrossSupportedPolygonRange() {
        XCTAssertEqual(BeatVisualLifecycle(beats: 1).beatCount, 3)
        XCTAssertEqual(BeatVisualLifecycle(beats: 3).beatCount, 3)
        XCTAssertEqual(BeatVisualLifecycle(beats: 9).beatCount, 9)
        XCTAssertEqual(BeatVisualLifecycle(beats: 24).beatCount, 9)
    }

    func testSubdivisionMovesBallButNeverBuildsAnEdge() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.resume()

        lifecycle.record(
            beat: 1,
            subdivision: 1,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 2
        )

        XCTAssertEqual(lifecycle.phase, .origin)
        XCTAssertEqual(lifecycle.builtEdgeCount, 0)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [])
        XCTAssertEqual(lifecycle.visibleBeatIndices, [])
        XCTAssertEqual(lifecycle.currentBeatIndex, 1)
        XCTAssertEqual(
            try XCTUnwrap(lifecycle.ballPhase),
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(lifecycle.ballIsAtOrigin)
    }

    func testEveryMainBeatBuildsExactlyOneMissingEdgeThenPolygonPersists() {
        var lifecycle = BeatVisualLifecycle(beats: 4)

        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        XCTAssertEqual(lifecycle.phase, .building)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0])
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1])

        lifecycle.record(beat: 0, subdivision: 1, cycle: 1, beats: 4)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0])

        // A repeated scheduler address is idempotent and cannot fabricate the
        // next musical edge.
        lifecycle.record(beat: 0, subdivision: 0, cycle: 1, beats: 4)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0])

        for beat in 1..<4 {
            lifecycle.record(beat: beat, subdivision: 0, cycle: 1, beats: 4)
        }

        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0, 1, 2, 3])
        XCTAssertEqual(lifecycle.builtEdgeCount, 4)
        XCTAssertEqual(lifecycle.latestBuiltEdgeIndex, 3)
        XCTAssertTrue(lifecycle.hasEstablishedStructure)

        for cycle in 2...20 {
            for beat in 0..<4 {
                lifecycle.record(beat: beat, subdivision: 0, cycle: cycle, beats: 4)
            }
        }

        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0, 1, 2, 3])
    }

    func testAllSupportedPolygonsCompleteAfterNMainBeats() {
        for beats in 3...9 {
            var lifecycle = BeatVisualLifecycle(beats: beats)
            for beat in 0..<beats {
                lifecycle.record(
                    beat: beat,
                    subdivision: 0,
                    cycle: 0,
                    beats: beats
                )
            }

            XCTAssertEqual(lifecycle.phase, .orbiting, "Failed for \(beats) beats")
            XCTAssertEqual(lifecycle.builtEdgeCount, beats)
            XCTAssertEqual(lifecycle.visibleEdgeIndices, Array(0..<beats))
        }
    }

    func testPauseFreezesGeometryBallAndCurrentBeat() {
        var lifecycle = BeatVisualLifecycle(beats: 5)
        lifecycle.record(
            beat: 2,
            subdivision: 1,
            cycle: 0,
            beats: 5,
            pulsesPerBeat: 4
        )
        lifecycle.record(beat: 2, subdivision: 0, cycle: 0, beats: 5)
        let beforePause = lifecycle

        lifecycle.pause()

        XCTAssertTrue(lifecycle.isPaused)
        XCTAssertEqual(lifecycle.phase, beforePause.phase)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, beforePause.visibleEdgeIndices)
        XCTAssertEqual(lifecycle.ballPhase, beforePause.ballPhase)
        XCTAssertEqual(lifecycle.currentBeatIndex, beforePause.currentBeatIndex)

        lifecycle.resume()
        XCTAssertFalse(lifecycle.isPaused)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, beforePause.visibleEdgeIndices)
    }

    func testSameTopologyRevisionDoesNotResetConstructionOrBall() {
        var lifecycle = BeatVisualLifecycle(beats: 7)
        lifecycle.record(
            beat: 3,
            subdivision: 1,
            cycle: 8,
            beats: 7,
            pulsesPerBeat: 2
        )
        lifecycle.record(beat: 3, subdivision: 0, cycle: 8, beats: 7)
        let beforeRevision = lifecycle

        // BPM is deliberately absent from this model. A tempo-only revision
        // therefore presents the same topology and is a strict no-op here.
        lifecycle.reconfigure(beats: 7)

        XCTAssertEqual(lifecycle, beforeRevision)
    }

    func testChangedTopologyStartsANewBuildLifecycleWithoutStoppingPlayback() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        XCTAssertFalse(lifecycle.isPaused)

        lifecycle.reconfigure(beats: 7)

        XCTAssertEqual(lifecycle.phase, .origin)
        XCTAssertEqual(lifecycle.beatCount, 7)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [])
        XCTAssertNil(lifecycle.currentBeatIndex)
        XCTAssertNil(lifecycle.ballPhase)
        XCTAssertFalse(lifecycle.isPaused)
    }

    func testFinishReturnsBallBeforeReverseDismantling() throws {
        var lifecycle = completedLifecycle(beats: 4)
        lifecycle.record(
            beat: 2,
            subdivision: 1,
            cycle: 1,
            beats: 4,
            pulsesPerBeat: 2
        )

        lifecycle.beginFinishing()

        XCTAssertEqual(lifecycle.phase, .finishing)
        XCTAssertEqual(
            try XCTUnwrap(lifecycle.returnStartBallPhase),
            2.5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(lifecycle.ballIsAtOrigin)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0, 1, 2, 3])
        XCTAssertEqual(lifecycle.dismantlingOrder, [3, 2, 1, 0])
        XCTAssertNil(lifecycle.removeNextDismantlingEdge())

        lifecycle.completeCenterReturn()
        XCTAssertEqual(lifecycle.phase, .dismantling)
        XCTAssertTrue(lifecycle.ballIsAtOrigin)
        XCTAssertNil(lifecycle.ballPhase)
        XCTAssertEqual(lifecycle.nextEdgeToDismantle, 3)

        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 3)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 2)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 1)
        XCTAssertEqual(lifecycle.phase, .dismantling)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 0)

        XCTAssertEqual(lifecycle.phase, .settled)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [])
        XCTAssertTrue(lifecycle.ballIsAtOrigin)
    }

    func testStoppingDuringBuildDismantlesOnlyConstructedEdges() {
        var lifecycle = BeatVisualLifecycle(beats: 6)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 4, beats: 6)
        lifecycle.record(beat: 3, subdivision: 0, cycle: 4, beats: 6)
        lifecycle.record(beat: 4, subdivision: 1, cycle: 4, beats: 6)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [2, 3])

        lifecycle.beginFinishing()
        XCTAssertEqual(lifecycle.dismantlingOrder, [3, 2])
        lifecycle.completeCenterReturn()

        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 3)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 2)
        XCTAssertEqual(lifecycle.phase, .settled)
        XCTAssertNil(lifecycle.removeNextDismantlingEdge())
    }

    func testReducedMotionKeepsTheSameSemanticOutroStages() {
        var standard = completedLifecycle(beats: 3)
        var reducedMotion = standard

        // Presentation code may wait different durations before these calls;
        // neither path is allowed to skip the return-before-teardown contract.
        standard.beginFinishing()
        reducedMotion.beginFinishing()
        XCTAssertEqual(standard, reducedMotion)

        standard.completeCenterReturn()
        reducedMotion.completeCenterReturn()
        XCTAssertEqual(standard.phase, .dismantling)
        XCTAssertEqual(reducedMotion.phase, .dismantling)

        while standard.phase == .dismantling {
            XCTAssertEqual(
                standard.removeNextDismantlingEdge(),
                reducedMotion.removeNextDismantlingEdge()
            )
        }

        XCTAssertEqual(standard, reducedMotion)
        XCTAssertEqual(reducedMotion.phase, .settled)
    }

    func testGlanceStatusRemainsFinishingDuringDismantling() {
        var lifecycle = completedLifecycle(beats: 4)
        lifecycle.beginFinishing()
        lifecycle.completeCenterReturn()

        let status = MetronomeGlanceStatus(
            preset: .standard,
            hand: .both,
            lifecycle: lifecycle,
            isPlaying: false
        )

        XCTAssertEqual(status.state, .finishing)
    }

    private func completedLifecycle(beats: Int) -> BeatVisualLifecycle {
        var lifecycle = BeatVisualLifecycle(beats: beats)
        for beat in 0..<beats {
            lifecycle.record(
                beat: beat,
                subdivision: 0,
                cycle: 0,
                beats: beats
            )
        }
        return lifecycle
    }
}
