import XCTest
@testable import GeoPractice

final class V52VisualLifecycleTests: XCTestCase {
    func testApprovedGeoBeatDurationsAndAudioClockMapping() {
        XCTAssertEqual(GeoBeatAnimation.startMorphDuration, 1.1)
        XCTAssertEqual(GeoBeatAnimation.shapeMorphDuration, 0.7)
        XCTAssertEqual(GeoBeatAnimation.rapidMorphDuration, 0.28)
        XCTAssertEqual(GeoBeatAnimation.rapidChangeWindow, 0.65)
        XCTAssertEqual(GeoBeatAnimation.stopMorphDuration, 1.5)

        let presentedAt = Date(timeIntervalSinceReferenceDate: 100)
        let pulse = BeatPlaybackPulse(
            beat: 1,
            subdivision: 1,
            cycle: 0,
            sequence: 4,
            kind: .subdivision,
            eventInterval: 0.5,
            presentedAt: presentedAt
        )
        XCTAssertEqual(
            GeoBeatAnimation.beat(
                pulse: pulse,
                pulsesPerBeat: 2,
                at: presentedAt.addingTimeInterval(0.25)
            ),
            1.75,
            accuracy: 0.000_001
        )
    }

    func testApprovedTwoBeatBallsUseOpposedVerticalTracksAndAlignedDots() {
        let start = GeoBeatAnimation.twoBeatBalls(beat: 0, reduceMotion: false)
        let nextBeat = GeoBeatAnimation.twoBeatBalls(beat: 1, reduceMotion: false)

        XCTAssertEqual(start[0].position.x, -0.31, accuracy: 0.000_001)
        XCTAssertEqual(start[1].position.x, 0.31, accuracy: 0.000_001)
        XCTAssertEqual(start[0].position.y, 0.39, accuracy: 0.000_001)
        XCTAssertEqual(start[1].position.y, -0.39, accuracy: 0.000_001)
        XCTAssertEqual(nextBeat[0].position.y, -0.39, accuracy: 0.000_001)
        XCTAssertEqual(nextBeat[1].position.y, 0.39, accuracy: 0.000_001)
        XCTAssertEqual(start[0].diameterScale, 0.49, accuracy: 0.000_001)
        XCTAssertEqual(start[1].diameterScale, 0.43, accuracy: 0.000_001)
        XCTAssertEqual(GeoBeatAnimation.beatDotX(index: 0, beats: 2), start[0].position.x, accuracy: 0.000_001)
        XCTAssertEqual(GeoBeatAnimation.beatDotX(index: 1, beats: 2), start[1].position.x, accuracy: 0.000_001)
    }

    func testTwoBeatStopMergesAndPolygonStopStaysOnItsRadialRay() {
        let source = GeoBeatAnimation.twoBeatBalls(beat: 0.25, reduceMotion: false)
        let stopped = GeoBeatAnimation.stoppingTwoBeatBalls(source, progress: 1)
        for ball in stopped {
            XCTAssertEqual(ball.position.x, 0, accuracy: 0.000_001)
            XCTAssertEqual(ball.position.y, 0, accuracy: 0.000_001)
            XCTAssertEqual(ball.diameterScale, 0.8, accuracy: 0.000_001)
        }

        let sourcePoint = CGPoint(x: 0.3, y: -0.4)
        let target = GeoBeatAnimation.radialCirclePoint(sourcePoint)
        XCTAssertEqual(hypot(target.x, target.y), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(sourcePoint.x * target.y, sourcePoint.y * target.x, accuracy: 0.000_001)
    }

    func testReduceMotionKeepsBeatIdentityButRemovesTwoBallTravel() {
        let firstBeat = GeoBeatAnimation.twoBeatBalls(beat: 0, reduceMotion: true)
        let withinFirstBeat = GeoBeatAnimation.twoBeatBalls(beat: 0.75, reduceMotion: true)
        let secondBeat = GeoBeatAnimation.twoBeatBalls(beat: 1, reduceMotion: true)

        XCTAssertEqual(firstBeat[0].position.y, 0.39, accuracy: 0.000_001)
        XCTAssertEqual(firstBeat[1].position.y, -0.39, accuracy: 0.000_001)
        XCTAssertEqual(withinFirstBeat[0].position.y, 0.39, accuracy: 0.000_001)
        XCTAssertEqual(withinFirstBeat[1].position.y, -0.39, accuracy: 0.000_001)
        XCTAssertEqual(secondBeat[0].position.y, -0.39, accuracy: 0.000_001)
        XCTAssertEqual(secondBeat[1].position.y, 0.39, accuracy: 0.000_001)
        XCTAssertEqual(firstBeat[0].diameterScale, 0.49, accuracy: 0.000_001)
        XCTAssertEqual(secondBeat[1].diameterScale, 0.49, accuracy: 0.000_001)
    }

    func testTwoBeatIdleAndCompletedStopUseOnlyTheCentralBall() {
        XCTAssertFalse(GeoBeatAnimation.showsTwoBeatBalls(
            beats: 2, isPlaying: false, isStarting: false, hasPulse: false, isStopping: false
        ))
        XCTAssertTrue(GeoBeatAnimation.showsTwoBeatBalls(
            beats: 2, isPlaying: false, isStarting: true, hasPulse: false, isStopping: false
        ))
        XCTAssertTrue(GeoBeatAnimation.showsTwoBeatBalls(
            beats: 2, isPlaying: true, isStarting: false, hasPulse: true, isStopping: false
        ))
        XCTAssertTrue(GeoBeatAnimation.showsTwoBeatBalls(
            beats: 2, isPlaying: false, isStarting: false, hasPulse: false, isStopping: true
        ))
        XCTAssertFalse(GeoBeatAnimation.showsTwoBeatBalls(
            beats: 2, isPlaying: false, isStarting: false, hasPulse: false, isStopping: false
        ))
    }

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
        let initialRevision = lifecycle.geometryRevision

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
        XCTAssertEqual(lifecycle.geometryRevision, initialRevision)
        XCTAssertEqual(phases, [0.25, 0.5, 0.75])
    }

    func testBounceTargetsUseTheStrengthOfTheNextEvent() throws {
        let strong = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 3,
            subdivision: 3,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertEqual(strong.beat, 0)
        XCTAssertEqual(strong.subdivision, 0)
        XCTAssertEqual(strong.kind, .strong)
        XCTAssertEqual(strong.heightTier, .strong)
        XCTAssertTrue(strong.wrapsToNextMeasure)

        let ordinaryMainBeat = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 0,
            subdivision: 3,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertEqual(ordinaryMainBeat.beat, 1)
        XCTAssertEqual(ordinaryMainBeat.heightTier, .main)

        let secondary = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 1,
            subdivision: 3,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertEqual(secondary.beat, 2)
        XCTAssertEqual(secondary.heightTier, .secondary)

        let subdivision = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 0,
            subdivision: 0,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertEqual(subdivision.subdivision, 1)
        XCTAssertEqual(subdivision.heightTier, .subdivision)
    }

    func testBounceHeightHierarchyAndBoundaryConditions() {
        let tiers: [BeatBounceHeightTier] = [
            .strong, .secondary, .main, .subdivision
        ]
        let peaks = tiers.map {
            BeatBounceMotionModel.normalizedArcHeight(
                eventProgress: 0.5,
                tier: $0
            )
        }
        for pair in zip(peaks, peaks.dropFirst()) {
            XCTAssertGreaterThan(pair.0, pair.1)
        }
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedArcHeight(
                eventProgress: -1,
                tier: .strong
            ),
            0
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedArcHeight(
                eventProgress: 2,
                tier: .strong
            ),
            0
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedInitialDescentHeight(
                eventProgress: 0
            ),
            1
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedInitialDescentHeight(
                eventProgress: 1
            ),
            0
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0,
                toward: .strong,
                startsFromOrigin: false
            ),
            0
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0.5,
                toward: .strong,
                startsFromOrigin: false
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 1,
                toward: .strong,
                startsFromOrigin: false
            ),
            0
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0.5,
                toward: .strong,
                startsFromOrigin: false,
                motionScale: 0.32
            ),
            0.32,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0,
                toward: .strong,
                startsFromOrigin: true,
                motionScale: 0.32
            ),
            0.32,
            accuracy: 0.000_001,
            "降低动态效果也必须缩小首次从中心落下的位移"
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedArcHeight(
                eventProgress: 0.25,
                tier: .strong
            ),
            sqrt(0.5),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedArcHeight(
                eventProgress: 0.75,
                tier: .strong
            ),
            sqrt(0.5),
            accuracy: 0.000_001
        )
    }

    func testEveryPostLaunchTrainingPulseLandsIncludingMeasureBoundary() throws {
        let initialTarget = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 0,
            subdivision: 0,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0,
                toward: initialTarget.heightTier,
                startsFromOrigin: true
            ),
            1
        )
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 1,
                toward: initialTarget.heightTier,
                startsFromOrigin: true
            ),
            0
        )

        for event in 1..<32 {
            let eventInMeasure = event % 16
            let beat = eventInMeasure / 4
            let subdivision = eventInMeasure % 4
            let target = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
                afterBeat: beat,
                subdivision: subdivision,
                beats: 4,
                pulsesPerBeat: 4,
                strongBeatIndices: [0],
                secondaryAccentIndices: [2]
            ))
            for progress in [0.0, 1.0] {
                XCTAssertEqual(
                    BeatBounceMotionModel.normalizedEventHeight(
                        eventProgress: progress,
                        toward: target.heightTier,
                        startsFromOrigin: false
                    ),
                    0,
                    accuracy: 0.000_001,
                    "event \(event) must contact once per training interval"
                )
            }
        }

        let wrapTarget = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
            afterBeat: 3,
            subdivision: 3,
            beats: 4,
            pulsesPerBeat: 4,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        ))
        XCTAssertTrue(wrapTarget.wrapsToNextMeasure)
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 0.5,
                toward: wrapTarget.heightTier,
                startsFromOrigin: false
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testScheduleTopologyResetAcceptsRestartedCycleZeroImmediately() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.resume()
        for beat in 0..<4 {
            lifecycle.record(
                beat: beat,
                subdivision: 0,
                cycle: 0,
                beats: 4,
                pulsesPerBeat: 4
            )
        }
        lifecycle.record(
            beat: 3,
            subdivision: 3,
            cycle: 7,
            beats: 4,
            pulsesPerBeat: 4
        )
        let establishedPlacements = lifecycle.visibleEdgePlacements
        XCTAssertTrue(lifecycle.hasEstablishedStructure)
        XCTAssertEqual(lifecycle.currentMeasureCycle, 7)

        lifecycle.resetScheduleTopology(beats: 4, isPlaying: true)
        XCTAssertFalse(lifecycle.isPaused)
        XCTAssertNil(lifecycle.currentMeasureCycle)
        XCTAssertEqual(lifecycle.visibleEdgePlacements, establishedPlacements)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertNil(lifecycle.currentBeatIndex)
        XCTAssertNil(lifecycle.ballPhase)

        let transition = lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 2
        )
        XCTAssertEqual(transition?.kind, .gapRecovery)
        XCTAssertTrue(transition?.rotations.isEmpty == true)
        XCTAssertTrue(transition?.insertedPlacements.isEmpty == true)
        XCTAssertEqual(
            lifecycle.visibleEdgeIndices,
            establishedPlacements.map(\.slotIndex),
            "重排首拍只重绑定音乐身份，不能让既有多边形转一大圈"
        )
        XCTAssertEqual(
            lifecycle.visibleEdgePlacements.first(where: { $0.slotIndex == 0 })?.beatIdentity,
            0,
            "重启后的水平落地点必须与当前音频第 1 拍身份一致"
        )
        XCTAssertEqual(lifecycle.currentMeasureCycle, 0)
    }

    func testScheduleTopologyResetPreservesPartialConstructionWithoutShrinking() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        lifecycle.record(beat: 1, subdivision: 0, cycle: 0, beats: 4)
        XCTAssertEqual(lifecycle.builtEdgeCount, 2)

        lifecycle.resetScheduleTopology(beats: 4, isPlaying: true)
        XCTAssertEqual(lifecycle.builtEdgeCount, 2)
        XCTAssertEqual(lifecycle.phase, .building)

        let recovery = lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 2
        )
        XCTAssertEqual(recovery?.kind, .gapRecovery)
        XCTAssertEqual(lifecycle.builtEdgeCount, 2)
        XCTAssertTrue(recovery?.insertedPlacements.isEmpty == true)
        XCTAssertEqual(
            lifecycle.visibleEdgePlacements.first(where: { $0.slotIndex == 0 })?.beatIdentity,
            0
        )
    }

    func testEverySupportedPolygonResyncsWithoutLargeRotationThenAdvancesOneSlot() throws {
        for beats in 3...9 {
            for oldBeat in 0..<beats {
                var lifecycle = completedLifecycle(beats: beats)
                for beat in 0...oldBeat {
                    lifecycle.record(
                        beat: beat,
                        subdivision: 0,
                        cycle: 1,
                        beats: beats,
                        pulsesPerBeat: 4
                    )
                }
                let beforeResync = lifecycle.visibleEdgePlacements
                let beforeByGeneration = Dictionary(
                    uniqueKeysWithValues: beforeResync.map {
                        ($0.generationIndex, $0.slotIndex)
                    }
                )

                lifecycle.resetScheduleTopology(beats: beats, isPlaying: true)
                let resync = try XCTUnwrap(lifecycle.record(
                    beat: 0,
                    subdivision: 0,
                    cycle: 0,
                    beats: beats,
                    pulsesPerBeat: 2
                ))

                XCTAssertEqual(resync.kind, .gapRecovery)
                XCTAssertTrue(resync.rotations.isEmpty)
                XCTAssertTrue(resync.insertedPlacements.isEmpty)
                XCTAssertEqual(lifecycle.visibleEdgeIndices, beforeResync.map(\.slotIndex))
                XCTAssertEqual(
                    Set(lifecycle.visibleEdgePlacements.map(\.beatIdentity)),
                    Set(0..<beats)
                )
                XCTAssertEqual(
                    lifecycle.visibleEdgePlacements.first(where: { $0.slotIndex == 0 })?.beatIdentity,
                    0
                )
                for placement in lifecycle.visibleEdgePlacements {
                    let oldSlot = try XCTUnwrap(beforeByGeneration[placement.generationIndex])
                    let clockwiseAdvance = (placement.slotIndex - oldSlot + beats) % beats
                    XCTAssertTrue(
                        clockwiseAdvance == 0 || clockwiseAdvance == 1,
                        "\(beats) 拍从旧第 \(oldBeat + 1) 拍重排时转了 \(clockwiseAdvance) 格"
                    )
                }

                let beforeAdvance = Dictionary(
                    uniqueKeysWithValues: lifecycle.visibleEdgePlacements.map {
                        ($0.generationIndex, $0.slotIndex)
                    }
                )
                let advance = try XCTUnwrap(lifecycle.record(
                    beat: 1,
                    subdivision: 0,
                    cycle: 0,
                    beats: beats,
                    pulsesPerBeat: 2
                ))
                XCTAssertEqual(advance.kind, .beatAdvance)
                XCTAssertEqual(advance.rotations.count, beats)
                XCTAssertTrue(advance.rotations.allSatisfy {
                    $0.toSlotIndex == $0.fromSlotIndex + 1
                })
                for placement in lifecycle.visibleEdgePlacements {
                    let oldSlot = try XCTUnwrap(beforeAdvance[placement.generationIndex])
                    XCTAssertEqual(
                        (placement.slotIndex - oldSlot + beats) % beats,
                        1
                    )
                }
                XCTAssertEqual(
                    lifecycle.visibleEdgePlacements.first(where: { $0.slotIndex == 0 })?.beatIdentity,
                    1
                )
            }
        }
    }

    func testBounceContactPlacesTheBallOutsideTheEdgeStroke() {
        let distance = 80.0
        let radius = 7.0
        let stroke = 2.0
        let contact = BeatBounceContactGeometry.inwardOffset(
            edgeToCenterDistance: distance,
            ballRadius: radius,
            edgeStrokeWidth: stroke,
            normalizedHeight: 0
        )
        XCTAssertEqual(contact, radius + stroke / 2, accuracy: 0.000_001)
        XCTAssertEqual(
            BeatBounceContactGeometry.inwardOffset(
                edgeToCenterDistance: distance,
                ballRadius: radius,
                edgeStrokeWidth: stroke,
                normalizedHeight: 1
            ),
            distance,
            accuracy: 0.000_001
        )

        for height in [0.0, 0.01, 0.20, 0.46, 0.72, 0.99, 1.0] {
            let offset = BeatBounceContactGeometry.inwardOffset(
                edgeToCenterDistance: distance,
                ballRadius: radius,
                edgeStrokeWidth: stroke,
                normalizedHeight: height
            )
            XCTAssertGreaterThanOrEqual(
                offset,
                radius + stroke / 2,
                "The rendered ball must stay outside the visible stroke"
            )
        }

        // An impossible visual profile still prefers no penetration over
        // forcing an oversized ball's center inside the polygon.
        XCTAssertEqual(
            BeatBounceContactGeometry.inwardOffset(
                edgeToCenterDistance: 4,
                ballRadius: 7,
                edgeStrokeWidth: 2,
                normalizedHeight: 0
            ),
            8,
            accuracy: 0.000_001
        )
    }

    func testBounceContactAcrossRendererProfilesAndScales() {
        let profiles: [(distance: Double, radius: Double, stroke: Double)] = [
            (80, 6.4, 2.0),   // compact prototype contact
            (80, 8.2, 2.0),   // prototype at maximum visible height
            (72, 5.8, 1.45),  // production base frame
            (72, 7.2, 1.85)   // production strong-feedback frame
        ]
        let heights = [0.0, 0.01, 0.20, 0.46, 0.72, 0.99, 1.0]

        for scale in [0.5, 1.0, 2.0, 3.0] {
            for profile in profiles {
                let distance = profile.distance * scale
                let radius = profile.radius * scale
                let stroke = profile.stroke * scale
                let clearance = radius + stroke / 2

                for height in heights {
                    let offset = BeatBounceContactGeometry.inwardOffset(
                        edgeToCenterDistance: distance,
                        ballRadius: radius,
                        edgeStrokeWidth: stroke,
                        normalizedHeight: height
                    )
                    XCTAssertTrue(offset.isFinite)
                    XCTAssertGreaterThanOrEqual(offset, clearance - 0.000_001)
                    if height == 0 {
                        XCTAssertEqual(offset, clearance, accuracy: 0.000_001)
                    } else if height == 1 {
                        XCTAssertEqual(offset, distance, accuracy: 0.000_001)
                    }
                }
            }
        }
    }

    func testVisibleFeedbackFootprintCannotCrossTheEdge() {
        let ballRadius = 6.8
        let stroke = 1.85
        let centerOffset = BeatBounceContactGeometry.inwardOffset(
            edgeToCenterDistance: 72,
            ballRadius: ballRadius,
            edgeStrokeWidth: stroke,
            normalizedHeight: 0
        )
        let maximumEffectRadius = BeatBounceContactGeometry.maximumNonPenetratingRadius(
            inwardCenterOffset: centerOffset,
            edgeStrokeWidth: stroke
        )

        XCTAssertEqual(maximumEffectRadius, ballRadius, accuracy: 0.000_001)
        XCTAssertEqual(
            centerOffset - maximumEffectRadius,
            stroke / 2,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(maximumEffectRadius, 10.6)
    }

    func testBounceCurveEndpointsResolveToTangentContact() {
        let distance = 80.0
        let radius = 7.0
        let stroke = 2.0
        let tiers: [BeatBounceHeightTier] = [
            .strong,
            .secondary,
            .main,
            .subdivision
        ]

        for tier in tiers {
            for progress in [0.0, 1.0] {
                let height = BeatBounceMotionModel.normalizedArcHeight(
                    eventProgress: progress,
                    tier: tier
                )
                let offset = BeatBounceContactGeometry.inwardOffset(
                    edgeToCenterDistance: distance,
                    ballRadius: radius,
                    edgeStrokeWidth: stroke,
                    normalizedHeight: height
                )
                XCTAssertEqual(offset, radius + stroke / 2, accuracy: 0.000_001)
            }
        }

        let descentContact = BeatBounceContactGeometry.inwardOffset(
            edgeToCenterDistance: distance,
            ballRadius: radius,
            edgeStrokeWidth: stroke,
            normalizedHeight: BeatBounceMotionModel.normalizedInitialDescentHeight(
                eventProgress: 1
            )
        )
        XCTAssertEqual(descentContact, radius + stroke / 2, accuracy: 0.000_001)

        let measureBoundaryContact = BeatBounceContactGeometry.inwardOffset(
            edgeToCenterDistance: distance,
            ballRadius: radius,
            edgeStrokeWidth: stroke,
            normalizedHeight: BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 1,
                toward: .strong,
                startsFromOrigin: false
            )
        )
        XCTAssertEqual(
            measureBoundaryContact,
            radius + stroke / 2,
            accuracy: 0.000_001
        )
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

    func testEachMainBeatRotatesExistingEdgesAndGeneratesAtHorizontalSlot() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)

        let start = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 4
        ))
        XCTAssertEqual(start.kind, .measureStart)
        XCTAssertEqual(lifecycle.phase, .building)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0])
        XCTAssertEqual(
            lifecycle.visibleEdgePlacements,
            [BeatVisualEdgePlacement(generationIndex: 0, slotIndex: 0)]
        )
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1])

        let second = try XCTUnwrap(lifecycle.record(
            beat: 1,
            subdivision: 0,
            cycle: 0,
            beats: 4
        ))
        XCTAssertEqual(second.kind, .beatAdvance)
        XCTAssertEqual(
            second.rotations,
            [BeatVisualEdgeRotation(
                generationIndex: 0,
                fromSlotIndex: 0,
                toSlotIndex: 1
            )]
        )
        XCTAssertEqual(
            second.insertedPlacements,
            [BeatVisualEdgePlacement(generationIndex: 1, slotIndex: 0)]
        )
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [1, 0])

        _ = lifecycle.record(beat: 2, subdivision: 0, cycle: 0, beats: 4)
        _ = lifecycle.record(beat: 3, subdivision: 0, cycle: 0, beats: 4)

        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [3, 2, 1, 0])
        XCTAssertEqual(lifecycle.builtEdgeCount, 4)
        XCTAssertEqual(lifecycle.latestBuiltEdgeIndex, 0)
        XCTAssertTrue(lifecycle.hasEstablishedStructure)
    }

    func testAllSupportedPolygonsHaveNVisibleEdgesDuringBeatN() {
        for beats in 3...9 {
            var lifecycle = BeatVisualLifecycle(beats: beats)
            for beat in 0..<beats {
                lifecycle.record(
                    beat: beat,
                    subdivision: 0,
                    cycle: 0,
                    beats: beats
                )
                XCTAssertEqual(
                    lifecycle.builtEdgeCount,
                    beat + 1,
                    "Failed during beat \(beat + 1) of \(beats)"
                )
                XCTAssertEqual(
                    lifecycle.visibleEdgeIndices,
                    Array((0...beat).reversed())
                )
            }

            XCTAssertEqual(lifecycle.phase, .orbiting, "Failed for \(beats) beats")
            XCTAssertEqual(lifecycle.builtEdgeCount, beats)
            XCTAssertEqual(
                lifecycle.visibleEdgeIndices,
                Array((0..<beats).reversed())
            )
        }
    }

    func testSharedEdgePresentationUsesOneSmoothRotationAndDelayedReveal() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        let transition = try XCTUnwrap(lifecycle.record(
            beat: 1,
            subdivision: 0,
            cycle: 0,
            beats: 4
        ))

        let start = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: 0,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        XCTAssertEqual(start.map(\.slot), [0, 0])
        XCTAssertEqual(start.map(\.drawProgress), [1, 0])

        let midpoint = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: (
                BeatPolygonPresentationModel.rotationStartFraction
                    + BeatPolygonPresentationModel.rotationCompletionFraction
            ) / 2,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        XCTAssertEqual(midpoint[0].slot, 0.5, accuracy: 0.000_001)
        XCTAssertGreaterThan(midpoint[1].drawProgress, 0.5)
        XCTAssertEqual(Set(midpoint.map(\.lineWidth)), [
            BeatPolygonPresentationModel.uniformLineWidth
        ])

        let finished = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        XCTAssertEqual(finished.map(\.slot), [1, 0])
        XCTAssertEqual(finished.map(\.drawProgress), [1, 1])
    }

    func testEveryAudibleMainBeatStartsOnItsOwnContactEdge() throws {
        for beats in 3...9 {
            for pulsesPerBeat in [1, 2, 4] {
                var lifecycle = BeatVisualLifecycle(beats: beats)
                let strongBeatIndices: Set<Int> = [0]
                let secondaryAccentIndices: Set<Int> = [2]

                for beat in 0..<beats {
                    for subdivision in 0..<pulsesPerBeat {
                        lifecycle.record(
                            beat: beat,
                            subdivision: subdivision,
                            cycle: 0,
                            beats: beats,
                            pulsesPerBeat: pulsesPerBeat
                        )
                        let geometry = BeatPolygonPresentationModel.intervalGeometry(
                            lifecycle: lifecycle,
                            beat: beat,
                            subdivision: subdivision,
                            cycle: 0,
                            pulsesPerBeat: pulsesPerBeat
                        )
                        let atSound = BeatPolygonPresentationModel.edgePresentations(
                            placements: geometry.placements,
                            transition: geometry.transition,
                            eventProgress: 0,
                            strongBeatIndices: strongBeatIndices,
                            secondaryAccentIndices: secondaryAccentIndices
                        )
                        let contact = try XCTUnwrap(contactPresentation(
                            in: atSound,
                            beatCount: beats
                        ))
                        XCTAssertEqual(
                            contact.beatIdentity,
                            beat,
                            "\(beats)拍、每拍\(pulsesPerBeat)事件、地址\(beat):\(subdivision) 声音响起时接触边错位"
                        )

                        if subdivision == 0 {
                            let expectedAccent: BeatEdgeAccentLevel = if beat == 0 {
                                .strong
                            } else if beat == 2 {
                                .secondary
                            } else {
                                .weak
                            }
                            XCTAssertEqual(contact.accentLevel, expectedAccent)
                        }

                        let nextTarget = try XCTUnwrap(BeatBounceMotionModel.nextTarget(
                            afterBeat: beat,
                            subdivision: subdivision,
                            beats: beats,
                            pulsesPerBeat: pulsesPerBeat,
                            strongBeatIndices: strongBeatIndices,
                            secondaryAccentIndices: secondaryAccentIndices
                        ))
                        XCTAssertEqual(
                            BeatBounceMotionModel.normalizedAudibleEventHeight(
                                eventProgress: 0,
                                toward: nextTarget.heightTier
                            ),
                            0,
                            accuracy: 0.000_001
                        )
                    }
                }
            }
        }
    }

    func testFinalSubdivisionPreparesNextContactBeforeItsSound() throws {
        var lifecycle = BeatVisualLifecycle(beats: 5)
        for beat in 0..<5 {
            for subdivision in 0..<4 {
                lifecycle.record(
                    beat: beat,
                    subdivision: subdivision,
                    cycle: 0,
                    beats: 5,
                    pulsesPerBeat: 4
                )

                let geometry = BeatPolygonPresentationModel.intervalGeometry(
                    lifecycle: lifecycle,
                    beat: beat,
                    subdivision: subdivision,
                    cycle: 0,
                    pulsesPerBeat: 4
                )
                if subdivision < 3 {
                    XCTAssertNil(geometry.transition)
                    continue
                }

                let start = BeatPolygonPresentationModel.edgePresentations(
                    placements: geometry.placements,
                    transition: geometry.transition,
                    eventProgress: 0,
                    strongBeatIndices: [0],
                    secondaryAccentIndices: [2]
                )
                let end = BeatPolygonPresentationModel.edgePresentations(
                    placements: geometry.placements,
                    transition: geometry.transition,
                    eventProgress: 1,
                    strongBeatIndices: [0],
                    secondaryAccentIndices: [2]
                )
                XCTAssertEqual(
                    try XCTUnwrap(contactPresentation(in: start, beatCount: 5)).beatIdentity,
                    beat
                )
                XCTAssertEqual(
                    try XCTUnwrap(contactPresentation(in: end, beatCount: 5)).beatIdentity,
                    (beat + 1) % 5
                )
            }
        }
    }

    func testReducedMotionNeverShowsTheNextBeatAtTheCurrentSound() throws {
        var lifecycle = completedLifecycle(beats: 5)
        lifecycle.record(
            beat: 4,
            subdivision: 3,
            cycle: 0,
            beats: 5,
            pulsesPerBeat: 4
        )

        let geometry = BeatPolygonPresentationModel.intervalGeometry(
            lifecycle: lifecycle,
            beat: 4,
            subdivision: 3,
            cycle: 0,
            pulsesPerBeat: 4,
            reduceMotion: true
        )
        XCTAssertNil(geometry.transition)
        let presentation = BeatPolygonPresentationModel.edgePresentations(
            placements: geometry.placements,
            transition: geometry.transition,
            eventProgress: 0,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2],
            reduceMotion: true
        )
        XCTAssertEqual(
            try XCTUnwrap(contactPresentation(in: presentation, beatCount: 5)).beatIdentity,
            4
        )
    }

    func testFirstAudibleStrongPulseIsAlreadyAtImpact() {
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedAudibleEventHeight(
                eventProgress: 0,
                toward: .strong
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BeatCollisionVisualModel.collisionAge(
                eventAge: 0,
                eventInterval: 0.5,
                startsFromOrigin: false
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testInsertionRevealLeadsAndOverlapsDelayedRotation() {
        XCTAssertEqual(
            BeatPolygonPresentationModel.insertionProgress(eventProgress: 0),
            0
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.insertionProgress(
                eventProgress: BeatPolygonPresentationModel.insertionDelayFraction
            ),
            0
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.insertionProgress(
                eventProgress: BeatPolygonPresentationModel.insertionCompletionFraction
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(
            BeatPolygonPresentationModel.rotationStartFraction,
            BeatPolygonPresentationModel.insertionCompletionFraction
        )
        XCTAssertLessThan(
            BeatPolygonPresentationModel.insertionCompletionFraction,
            BeatPolygonPresentationModel.activeTransitionFraction
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.transitionProgress(
                eventProgress: BeatPolygonPresentationModel.rotationStartFraction - 0.01
            ),
            0
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.transitionProgress(
                eventProgress: BeatPolygonPresentationModel.rotationCompletionFraction
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testInitialInsertionWaitsForDescentImpactAndStillCompletesAtLanding() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        let initial = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 4
        ))

        let beforeImpact = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: initial,
            eventProgress: BeatPolygonPresentationModel.initialInsertionDelayFraction - 0.01,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2],
            startsFromOrigin: true
        )
        XCTAssertEqual(beforeImpact.map(\.drawProgress), [0])
        XCTAssertGreaterThan(
            BeatBounceMotionModel.normalizedInitialDescentHeight(
                eventProgress: BeatPolygonPresentationModel.initialInsertionDelayFraction - 0.01
            ),
            0
        )

        XCTAssertEqual(
            BeatBounceMotionModel.normalizedInitialDescentHeight(
                eventProgress: BeatPolygonPresentationModel.initialInsertionDelayFraction
            ),
            0,
            accuracy: 0.000_001,
            "第一条线开始生长的同一帧，小球必须已经完成落地"
        )
        for progress in [0.63, 0.72, 0.84, 0.99] {
            let presentation = BeatPolygonPresentationModel.edgePresentations(
                placements: lifecycle.visibleEdgePlacements,
                transition: initial,
                eventProgress: progress,
                strongBeatIndices: [0],
                secondaryAccentIndices: [2],
                startsFromOrigin: true
            )
            XCTAssertGreaterThan(presentation[0].drawProgress, 0)
            XCTAssertEqual(
                BeatBounceMotionModel.normalizedInitialDescentHeight(
                    eventProgress: progress
                ),
                0,
                accuracy: 0.000_001,
                "只允许球落地后从撞击点向两侧生成第一条边"
            )
        }

        let landed = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: initial,
            eventProgress: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2],
            startsFromOrigin: true
        )
        XCTAssertEqual(landed.map(\.drawProgress), [1])
        XCTAssertEqual(
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: 1,
                toward: .strong,
                startsFromOrigin: true
            ),
            0,
            "后移首线生长不能改变首个 training event 的落地端点"
        )
    }

    func testResumeBallStartsFrozenAndAvoidsSyntheticContactUntilStableEdge() {
        let frozenHeight = 0.61
        let target: (Double) -> Double = { progress in
            BeatBounceMotionModel.normalizedEventHeight(
                eventProgress: progress,
                toward: .main,
                startsFromOrigin: false
            )
        }

        XCTAssertEqual(
            BeatBounceMotionModel.resumeNormalizedHeight(
                from: frozenHeight,
                toward: target(0),
                eventProgress: 0
            ),
            frozenHeight,
            accuracy: 0.000_001,
            "恢复的第一帧必须与暂停冻结帧完全一致"
        )

        for progress in [0.02, 0.10, 0.25, 0.50, 0.89] {
            let height = BeatBounceMotionModel.resumeNormalizedHeight(
                from: frozenHeight,
                toward: target(progress),
                eventProgress: progress
            )
            XCTAssertTrue(height.isFinite)
            XCTAssertGreaterThan(
                height,
                0,
                "桥接边尚未稳定到水平槽时，不得让球落到虚构基线上"
            )
            XCTAssertLessThanOrEqual(height, 1)
        }

        let joinProgress = BeatBounceMotionModel.resumeBlendCompletionFraction
        XCTAssertEqual(
            BeatBounceMotionModel.resumeNormalizedHeight(
                from: frozenHeight,
                toward: target(joinProgress),
                eventProgress: joinProgress
            ),
            target(joinProgress),
            accuracy: 0.000_001,
            "边开始旋转前，小球必须已经无缝接入新的音乐弧线"
        )
        XCTAssertEqual(
            BeatBounceMotionModel.resumeNormalizedHeight(
                from: frozenHeight,
                toward: target(1),
                eventProgress: 1
            ),
            0,
            accuracy: 0.000_001,
            "只有边已经稳定回水平槽的事件终点才允许落地"
        )
    }

    func testAllRetainedEdgesShareDelayedSmootherstepRotation() throws {
        var lifecycle = completedLifecycle(beats: 5)
        let transition = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 1,
            beats: 5,
            pulsesPerBeat: 4
        ))
        let beforeStart = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: BeatPolygonPresentationModel.rotationStartFraction - 0.01,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        XCTAssertEqual(
            beforeStart.map(\.slot),
            transition.rotations.map { Double($0.fromSlotIndex) }
        )

        let midpoint = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: (
                BeatPolygonPresentationModel.rotationStartFraction
                    + BeatPolygonPresentationModel.rotationCompletionFraction
            ) / 2,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        for (edge, rotation) in zip(midpoint, transition.rotations) {
            XCTAssertEqual(
                edge.slot,
                Double(rotation.fromSlotIndex) + 0.5,
                accuracy: 0.000_001
            )
        }

        let completed = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: transition,
            eventProgress: BeatPolygonPresentationModel.rotationCompletionFraction,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        XCTAssertEqual(
            completed.map(\.slot),
            transition.rotations.map { Double($0.toSlotIndex) }
        )
    }

    func testResumePresentationStartsFrozenAndConvergesClockwiseToTarget() throws {
        var lifecycle = completedLifecycle(beats: 5)
        let wrap = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 1,
            beats: 5,
            pulsesPerBeat: 4
        ))
        let frozen = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: wrap,
            eventProgress: (
                BeatPolygonPresentationModel.rotationStartFraction
                    + BeatPolygonPresentationModel.rotationCompletionFraction
            ) / 2,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        let target = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: nil,
            eventProgress: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )

        XCTAssertEqual(
            BeatPolygonPresentationModel.resumePresentations(
                from: frozen,
                toward: target,
                beatCount: 5,
                eventProgress: 0
            ),
            frozen
        )
        let resumedMidpoint = BeatPolygonPresentationModel.resumePresentations(
            from: frozen,
            toward: target,
            beatCount: 5,
            eventProgress: (
                BeatPolygonPresentationModel.rotationStartFraction
                    + BeatPolygonPresentationModel.rotationCompletionFraction
            ) / 2
        )
        XCTAssertEqual(resumedMidpoint[0].slot, 4.75, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(resumedMidpoint[0].slot, frozen[0].slot)
        XCTAssertEqual(
            BeatPolygonPresentationModel.resumePresentations(
                from: frozen,
                toward: target,
                beatCount: 5,
                eventProgress: BeatPolygonPresentationModel.rotationCompletionFraction
            ),
            target
        )
    }

    func testResumePresentationIntroducesAWaitingTargetEdgeAtZeroLength() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)
        let frozen = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: nil,
            eventProgress: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        let next = try XCTUnwrap(lifecycle.record(
            beat: 1,
            subdivision: 0,
            cycle: 0,
            beats: 4
        ))
        let target = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: next,
            eventProgress: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: [2]
        )
        let resumedStart = BeatPolygonPresentationModel.resumePresentations(
            from: frozen,
            toward: target,
            beatCount: 4,
            eventProgress: 0
        )
        XCTAssertEqual(resumedStart.first, frozen.first)
        XCTAssertEqual(resumedStart.count, 2)
        XCTAssertEqual(resumedStart[1].drawProgress, 0)
        XCTAssertEqual(
            BeatPolygonPresentationModel.resumePresentations(
                from: frozen,
                toward: target,
                beatCount: 4,
                eventProgress: BeatPolygonPresentationModel.rotationCompletionFraction
            ),
            target
        )
    }

    func testFiveBeatTwoPlusThreeEdgeAccentsFollowStableBeatIdentity() throws {
        var preset = MetronomePreset.standard
        preset.beats = 5
        preset.grouping = "2+3"
        var lifecycle = completedLifecycle(beats: 5)

        let stable = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: nil,
            eventProgress: 1,
            strongBeatIndices: preset.strongBeatIndices,
            secondaryAccentIndices: preset.secondaryAccentIndices
        )
        XCTAssertEqual(
            stable.map(\.accentLevel),
            [.strong, .weak, .secondary, .weak, .weak]
        )
        XCTAssertEqual(stable.map(\.opacity), [0.96, 0.34, 0.68, 0.34, 0.34])
        XCTAssertEqual(stable.map(\.lineWidth), [3.2, 3.2, 3.2, 3.2, 3.2])
        XCTAssertGreaterThan(stable[0].opacity, stable[2].opacity)
        XCTAssertGreaterThan(stable[2].opacity, stable[1].opacity)
        XCTAssertEqual(Set(stable.map(\.lineWidth)).count, 1)
        XCTAssertTrue(stable.allSatisfy { $0.drawProgress == 1 })

        let wrap = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 1,
            beats: 5,
            pulsesPerBeat: 4
        ))
        let rotating = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: wrap,
            eventProgress: (
                BeatPolygonPresentationModel.rotationStartFraction
                    + BeatPolygonPresentationModel.rotationCompletionFraction
            ) / 2,
            strongBeatIndices: preset.strongBeatIndices,
            secondaryAccentIndices: preset.secondaryAccentIndices
        )
        XCTAssertEqual(rotating[0].slot, 4.5, accuracy: 0.000_001)
        XCTAssertEqual(rotating.map(\.accentLevel), stable.map(\.accentLevel))
        XCTAssertEqual(rotating.map(\.opacity), stable.map(\.opacity))
        XCTAssertEqual(rotating.map(\.lineWidth), stable.map(\.lineWidth))
        XCTAssertTrue(rotating.allSatisfy { $0.drawProgress == 1 })

        lifecycle.record(
            beat: 1,
            subdivision: 0,
            cycle: 1,
            beats: 5,
            pulsesPerBeat: 4
        )
        let slotsBeforeResync = lifecycle.visibleEdgeIndices
        lifecycle.resetScheduleTopology(beats: 5, isPlaying: true)
        let resync = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 5,
            pulsesPerBeat: 2
        ))
        let rebound = BeatPolygonPresentationModel.edgePresentations(
            placements: lifecycle.visibleEdgePlacements,
            transition: resync,
            eventProgress: 0.5,
            strongBeatIndices: preset.strongBeatIndices,
            secondaryAccentIndices: preset.secondaryAccentIndices
        )
        XCTAssertEqual(lifecycle.visibleEdgeIndices, slotsBeforeResync)
        XCTAssertTrue(resync.rotations.isEmpty)
        XCTAssertEqual(
            rebound.first(where: { $0.slot == 0 })?.beatIdentity,
            0
        )
        XCTAssertEqual(
            rebound.first(where: { $0.slot == 0 })?.accentLevel,
            .strong
        )
        XCTAssertEqual(
            rebound.first(where: { $0.beatIdentity == 2 })?.accentLevel,
            .secondary
        )
        XCTAssertTrue(rebound.filter { $0.beatIdentity != 0 && $0.beatIdentity != 2 }
            .allSatisfy { $0.accentLevel == .weak })
    }

    func testNextCycleKeepsCompletePolygonAndRotatesEveryEdgeClockwise() throws {
        var lifecycle = completedLifecycle(beats: 5)
        let previousRevision = lifecycle.geometryRevision

        let advance = try XCTUnwrap(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 1,
            beats: 5,
            pulsesPerBeat: 4
        ))

        XCTAssertEqual(advance.kind, .beatAdvance)
        XCTAssertEqual(advance.previousPlacements.count, 5)
        XCTAssertEqual(
            advance.placements,
            [
                BeatVisualEdgePlacement(generationIndex: 0, slotIndex: 0),
                BeatVisualEdgePlacement(generationIndex: 1, slotIndex: 4),
                BeatVisualEdgePlacement(generationIndex: 2, slotIndex: 3),
                BeatVisualEdgePlacement(generationIndex: 3, slotIndex: 2),
                BeatVisualEdgePlacement(generationIndex: 4, slotIndex: 1)
            ]
        )
        XCTAssertEqual(advance.rotations.count, 5)
        XCTAssertEqual(
            advance.rotations.first,
            BeatVisualEdgeRotation(
                generationIndex: 0,
                fromSlotIndex: 4,
                toSlotIndex: 5
            )
        )
        XCTAssertTrue(advance.rotations.allSatisfy {
            $0.toSlotIndex == $0.fromSlotIndex + 1
        })
        XCTAssertTrue(advance.insertedPlacements.isEmpty)
        XCTAssertEqual(lifecycle.geometryRevision, previousRevision + 1)
        XCTAssertEqual(lifecycle.currentMeasureCycle, 1)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [0, 4, 3, 2, 1])
        XCTAssertTrue(lifecycle.hasEstablishedStructure)
    }

    func testClosedPolygonNeverRebuildsAcrossLaterCycles() throws {
        let beats = 5
        var lifecycle = completedLifecycle(beats: beats)

        for cycle in 1...4 {
            for beat in 0..<beats {
                let transition = try XCTUnwrap(lifecycle.record(
                    beat: beat,
                    subdivision: 0,
                    cycle: cycle,
                    beats: beats,
                    pulsesPerBeat: 4
                ))
                XCTAssertEqual(lifecycle.builtEdgeCount, beats)
                XCTAssertEqual(lifecycle.phase, .orbiting)
                XCTAssertTrue(transition.insertedPlacements.isEmpty)
                XCTAssertEqual(transition.rotations.count, beats)
                XCTAssertTrue(transition.rotations.allSatisfy {
                    $0.toSlotIndex == $0.fromSlotIndex + 1
                })
            }
        }
    }

    func testSubdivisionAtNewCyclePreservesCompletePolygonAndGeometryRevision() {
        var lifecycle = completedLifecycle(beats: 4)
        let placements = lifecycle.visibleEdgePlacements
        let revision = lifecycle.geometryRevision
        let transition = lifecycle.record(
            beat: 0,
            subdivision: 1,
            cycle: 1,
            beats: 4,
            pulsesPerBeat: 4
        )

        XCTAssertNil(transition)
        XCTAssertEqual(lifecycle.visibleEdgePlacements, placements)
        XCTAssertEqual(lifecycle.geometryRevision, revision)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.currentBeatIndex, 0)
    }

    func testMissingMainBeatCallbackRecoversAddressDerivedGeometry() throws {
        var lifecycle = BeatVisualLifecycle(beats: 7)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 7)

        let recovery = try XCTUnwrap(lifecycle.record(
            beat: 3,
            subdivision: 0,
            cycle: 0,
            beats: 7
        ))

        XCTAssertEqual(recovery.kind, .gapRecovery)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [3, 2, 1, 0])
        XCTAssertEqual(
            recovery.rotations,
            [BeatVisualEdgeRotation(
                generationIndex: 0,
                fromSlotIndex: 0,
                toSlotIndex: 3
            )]
        )
        XCTAssertEqual(
            recovery.insertedPlacements.map(\.generationIndex),
            [1, 2, 3]
        )
    }

    func testDuplicateAndLateCallbacksAreStrictlyIdempotent() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 2, beats: 4)
        lifecycle.record(
            beat: 0,
            subdivision: 1,
            cycle: 2,
            beats: 4,
            pulsesPerBeat: 4
        )
        lifecycle.pause()
        let paused = lifecycle

        XCTAssertNil(lifecycle.record(
            beat: 0,
            subdivision: 1,
            cycle: 2,
            beats: 4,
            pulsesPerBeat: 4
        ))
        XCTAssertNil(lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 2,
            beats: 4,
            pulsesPerBeat: 4
        ))
        XCTAssertNil(lifecycle.record(
            beat: 3,
            subdivision: 0,
            cycle: 1,
            beats: 4,
            pulsesPerBeat: 4
        ))
        XCTAssertEqual(lifecycle, paused)
    }

    func testPauseFreezesGeometryBallAndCurrentBeat() {
        var lifecycle = BeatVisualLifecycle(beats: 5)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 5)
        lifecycle.record(
            beat: 0,
            subdivision: 1,
            cycle: 0,
            beats: 5,
            pulsesPerBeat: 4
        )
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
        lifecycle.record(beat: 3, subdivision: 0, cycle: 8, beats: 7)
        lifecycle.record(
            beat: 3,
            subdivision: 1,
            cycle: 8,
            beats: 7,
            pulsesPerBeat: 2
        )
        let beforeRevision = lifecycle

        // BPM is deliberately absent from this model. A tempo-only revision
        // therefore presents the same topology and is a strict no-op here.
        lifecycle.reconfigure(beats: 7)

        XCTAssertEqual(lifecycle, beforeRevision)
    }

    func testContinuousTempoChangesKeepMeasureAndEventAddressesContinuous() throws {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(
            beat: 0,
            subdivision: 0,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 4
        )
        let firstRevision = lifecycle.geometryRevision

        for (subdivision, interval) in zip(1..<4, [0.30, 0.11, 0.42]) {
            lifecycle.reconfigure(beats: 4)
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
                elapsed: interval / 2,
                eventInterval: interval,
                pulsesPerBeat: 4,
                eventsPerMeasure: 16,
                beats: 4
            ))
            XCTAssertEqual(sample.eventProgress, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(lifecycle.geometryRevision, firstRevision)
            XCTAssertEqual(lifecycle.visibleEdgeIndices, [0])
        }

        lifecycle.record(
            beat: 1,
            subdivision: 0,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 4
        )
        XCTAssertEqual(lifecycle.currentMeasureCycle, 0)
        XCTAssertEqual(lifecycle.currentBeatIndex, 1)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [1, 0])
        XCTAssertEqual(lifecycle.geometryRevision, firstRevision + 1)
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
            beat: 3,
            subdivision: 1,
            cycle: 0,
            beats: 4,
            pulsesPerBeat: 2
        )

        lifecycle.beginFinishing()

        XCTAssertEqual(lifecycle.phase, .finishing)
        XCTAssertEqual(
            try XCTUnwrap(lifecycle.returnStartBallPhase),
            3.5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(lifecycle.ballIsAtOrigin)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [3, 2, 1, 0])
        XCTAssertEqual(lifecycle.dismantlingOrder, [0, 1, 2, 3])
        XCTAssertNil(lifecycle.removeNextDismantlingEdge())

        lifecycle.completeCenterReturn()
        XCTAssertEqual(lifecycle.phase, .dismantling)
        XCTAssertTrue(lifecycle.ballIsAtOrigin)
        XCTAssertNil(lifecycle.ballPhase)
        XCTAssertEqual(lifecycle.nextEdgeToDismantle, 0)

        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 0)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 1)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 2)
        XCTAssertEqual(lifecycle.phase, .dismantling)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 3)

        XCTAssertEqual(lifecycle.phase, .settled)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [])
        XCTAssertTrue(lifecycle.ballIsAtOrigin)
    }

    func testStoppingDuringBuildDismantlesOnlyConstructedEdges() {
        var lifecycle = BeatVisualLifecycle(beats: 6)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 6)
        lifecycle.record(beat: 1, subdivision: 0, cycle: 0, beats: 6)
        lifecycle.record(beat: 1, subdivision: 1, cycle: 0, beats: 6)
        XCTAssertEqual(lifecycle.visibleEdgeIndices, [1, 0])

        lifecycle.beginFinishing()
        XCTAssertEqual(lifecycle.dismantlingOrder, [0, 1])
        lifecycle.completeCenterReturn()

        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 0)
        XCTAssertEqual(lifecycle.removeNextDismantlingEdge(), 1)
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

    func testCollisionStrengthHierarchy() {
        let duration = 0.1
        let strong = BeatCollisionVisualModel.sample(
            for: .strong,
            age: 0,
            duration: duration
        )
        let secondary = BeatCollisionVisualModel.sample(
            for: .secondary,
            age: 0,
            duration: duration
        )
        let weak = BeatCollisionVisualModel.sample(
            for: .weak,
            age: 0,
            duration: duration
        )
        let subdivision = BeatCollisionVisualModel.sample(
            for: .subdivision,
            age: 0,
            duration: duration
        )

        XCTAssertEqual(strong.edgeSpread, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(secondary.edgeSpread, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(weak.edgeSpread, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(subdivision.edgeSpread, 0.08, accuracy: 0.000_001)
        XCTAssertGreaterThan(strong.edgeOpacity, secondary.edgeOpacity)
        XCTAssertGreaterThan(secondary.edgeOpacity, weak.edgeOpacity)
        XCTAssertGreaterThan(weak.edgeOpacity, subdivision.edgeOpacity)
        XCTAssertGreaterThan(strong.edgeLineWidthBoost, secondary.edgeLineWidthBoost)
        XCTAssertGreaterThan(secondary.edgeLineWidthBoost, weak.edgeLineWidthBoost)
        XCTAssertEqual(
            BeatCollisionVisualModel.sample(
                for: .strong,
                age: duration,
                duration: duration
            ),
            .empty
        )
    }

    func testInitialCollisionStartsOnlyWhenTheBallActuallyLands() {
        let interval = 0.2
        let impact = interval * BeatBounceMotionModel.initialImpactFraction
        let before = BeatCollisionVisualModel.collisionAge(
            eventAge: impact - 0.001,
            eventInterval: interval,
            startsFromOrigin: true
        )
        let atImpact = BeatCollisionVisualModel.collisionAge(
            eventAge: impact,
            eventInterval: interval,
            startsFromOrigin: true
        )
        let ordinary = BeatCollisionVisualModel.collisionAge(
            eventAge: 0,
            eventInterval: interval,
            startsFromOrigin: false
        )

        XCTAssertEqual(atImpact, 0, accuracy: 0.000_001)
        XCTAssertEqual(ordinary, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            BeatCollisionVisualModel.sample(
                for: .strong,
                age: before,
                duration: 0.04
            ),
            .empty
        )
        XCTAssertNotEqual(
            BeatCollisionVisualModel.sample(
                for: .strong,
                age: atImpact,
                duration: 0.04
            ),
            .empty
        )
    }

    func testCollisionFinishesBeforePersistentRotationBegins() {
        for interval in [1.0 / 48.0, 0.06, 0.125, 0.5] {
            let style = BeatPulseVisualModel.style(
                for: .strong,
                eventInterval: interval
            )
            let ordinary = BeatCollisionVisualModel.effectDuration(
                styleDuration: style.duration,
                eventInterval: interval,
                startsFromOrigin: false
            )
            let initial = BeatCollisionVisualModel.effectDuration(
                styleDuration: style.duration,
                eventInterval: interval,
                startsFromOrigin: true
            )
            XCTAssertLessThanOrEqual(
                ordinary,
                interval * BeatPolygonPresentationModel.rotationStartFraction
            )
            XCTAssertLessThanOrEqual(
                BeatBounceMotionModel.initialImpactFraction + initial / interval,
                0.86 + 0.000_001
            )
        }
    }

    func testReducedMotionAndDimFlashingLightsRestrainCollision() {
        let ordinary = BeatCollisionVisualModel.sample(
            for: .strong,
            age: 0.02,
            duration: 0.1
        )
        let reduced = BeatCollisionVisualModel.sample(
            for: .strong,
            age: 0.02,
            duration: 0.1,
            reduceMotion: true
        )
        let dimmed = BeatCollisionVisualModel.sample(
            for: .strong,
            age: 0.02,
            duration: 0.1,
            dimFlashingLights: true
        )
        let resumeSuppressed = BeatCollisionVisualModel.sample(
            for: .strong,
            age: 0,
            duration: 0.1,
            suppressTransientFeedback: true
        )

        XCTAssertEqual(resumeSuppressed, .empty)
        XCTAssertEqual(reduced.edgeSpread, 0.62, accuracy: 0.000_001)
        XCTAssertEqual(
            dimmed.edgeOpacity,
            ordinary.edgeOpacity * 0.55,
            accuracy: 0.000_001
        )
    }

    func testContactLineWidthUsesTheActualHorizontalEdge() {
        let weakContact = BeatEdgePresentation(
            generationIndex: 0,
            beatIdentity: 1,
            slot: 0,
            drawProgress: 1,
            accentLevel: .weak,
            opacity: 0.34,
            lineWidth: 2.4
        )
        let strongAway = BeatEdgePresentation(
            generationIndex: 1,
            beatIdentity: 0,
            slot: 1,
            drawProgress: 1,
            accentLevel: .strong,
            opacity: 0.96,
            lineWidth: 3.6
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.contactLineWidth(
                presentations: [strongAway, weakContact],
                beatCount: 5
            ),
            2.4,
            accuracy: 0.000_001
        )

        let wrappedContact = BeatEdgePresentation(
            generationIndex: 0,
            beatIdentity: 1,
            slot: 5,
            drawProgress: 1,
            accentLevel: .weak,
            opacity: 0.34,
            lineWidth: 2.4
        )
        XCTAssertEqual(
            BeatPolygonPresentationModel.contactLineWidth(
                presentations: [strongAway, wrappedContact],
                beatCount: 5
            ),
            2.4,
            accuracy: 0.000_001
        )
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

    private func contactPresentation(
        in presentations: [BeatEdgePresentation],
        beatCount: Int
    ) -> BeatEdgePresentation? {
        let period = Double(max(1, beatCount))
        return presentations
            .filter { $0.drawProgress > 0.5 }
            .min { lhs, rhs in
                contactDistance(lhs.slot, period: period)
                    < contactDistance(rhs.slot, period: period)
            }
    }

    private func contactDistance(_ slot: Double, period: Double) -> Double {
        let remainder = slot.truncatingRemainder(dividingBy: period)
        let normalized = remainder >= 0 ? remainder : remainder + period
        return min(normalized, period - normalized)
    }

}
