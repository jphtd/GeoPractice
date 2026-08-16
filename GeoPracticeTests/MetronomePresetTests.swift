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

    func testTempoScrubUsesExactStepsAndClamps() {
        XCTAssertEqual(TempoScrubModel.bpm(start: 120, horizontalTranslation: 2.9), 120)
        XCTAssertEqual(TempoScrubModel.bpm(start: 120, horizontalTranslation: 3), 121)
        XCTAssertEqual(TempoScrubModel.bpm(start: 120, horizontalTranslation: -3), 119)
        XCTAssertEqual(TempoScrubModel.bpm(start: 30, horizontalTranslation: -300), 30)
        XCTAssertEqual(TempoScrubModel.bpm(start: 240, horizontalTranslation: 300), 240)
    }

    func testTempoScrubPrimaryAxisAndDirectEntryValidation() {
        XCTAssertEqual(TempoScrubModel.bpm(start: 88, primaryTranslation: 30), 98)
        XCTAssertEqual(TempoScrubModel.bpm(start: 88, primaryTranslation: -30), 78)
        XCTAssertEqual(TempoScrubModel.validatedBPMInput(" 120\n"), 120)
        XCTAssertEqual(TempoScrubModel.validatedBPMInput("30"), 30)
        XCTAssertEqual(TempoScrubModel.validatedBPMInput("240"), 240)
        XCTAssertNil(TempoScrubModel.validatedBPMInput(""))
        XCTAssertNil(TempoScrubModel.validatedBPMInput("29"))
        XCTAssertNil(TempoScrubModel.validatedBPMInput("241"))
        XCTAssertNil(TempoScrubModel.validatedBPMInput("88.5"))
        XCTAssertNil(TempoScrubModel.validatedBPMInput("Allegro"))
    }

    func testV41TempoDirectionsKeepIncreaseSemanticsPredictable() {
        XCTAssertEqual(
            TempoScrubDirection.horizontal.primaryTranslation(
                horizontal: 30,
                vertical: -90
            ),
            30
        )
        XCTAssertEqual(
            TempoScrubDirection.vertical.primaryTranslation(
                horizontal: 90,
                vertical: -30
            ),
            30
        )
        XCTAssertEqual(
            TempoScrubDirection.vertical.primaryTranslation(
                horizontal: -90,
                vertical: 30
            ),
            -30
        )
    }

    func testV41BackgroundAndIdleTimerPolicyKeepsStateConsistent() {
        let defaults = PracticeRuntimePolicy()
        XCTAssertEqual(
            defaults.backgroundAction(
                isMetronomeSelected: true,
                isMetronomePlaying: true
            ),
            .continueRunning
        )
        XCTAssertEqual(
            defaults.backgroundAction(
                isMetronomeSelected: true,
                isMetronomePlaying: false
            ),
            .stopAndPause
        )
        XCTAssertEqual(
            defaults.backgroundAction(
                isMetronomeSelected: false,
                isMetronomePlaying: true
            ),
            .stopAndPause
        )

        let keepAwake = PracticeRuntimePolicy(
            continueAudioInBackground: true,
            keepScreenAwake: true
        )
        XCTAssertTrue(
            keepAwake.shouldDisableIdleTimer(
                sceneState: .active,
                isMetronomeSelected: true,
                isMetronomePlaying: true
            )
        )
        for state in [
            PracticeRuntimePolicy.SceneState.inactive,
            .background
        ] {
            XCTAssertFalse(
                keepAwake.shouldDisableIdleTimer(
                    sceneState: state,
                    isMetronomeSelected: true,
                    isMetronomePlaying: true
                )
            )
        }

        XCTAssertTrue(
            defaults.shouldPersistCheckpoint(
                sceneState: .background,
                isMetronomeSelected: true,
                isMetronomePlaying: true,
                isPracticeRunning: true
            )
        )
        XCTAssertTrue(
            defaults.shouldPauseWhenEnteringInactive(
                isMetronomeSelected: true,
                isMetronomePlaying: false,
                isPracticeRunning: true
            )
        )
        XCTAssertFalse(
            defaults.shouldPauseWhenEnteringInactive(
                isMetronomeSelected: true,
                isMetronomePlaying: true,
                isPracticeRunning: true
            )
        )
        XCTAssertTrue(
            defaults.shouldPauseAfterOffscreenPlaybackStops(
                sceneState: .background,
                isMetronomeSelected: true,
                wasPlaying: true,
                isPlaying: false,
                isPracticeRunning: true
            )
        )
        XCTAssertTrue(
            defaults.shouldPauseAfterOffscreenPlaybackStops(
                sceneState: .inactive,
                isMetronomeSelected: true,
                wasPlaying: true,
                isPlaying: false,
                isPracticeRunning: true
            )
        )
        XCTAssertFalse(
            defaults.shouldPauseAfterOffscreenPlaybackStops(
                sceneState: .active,
                isMetronomeSelected: true,
                wasPlaying: true,
                isPlaying: false,
                isPracticeRunning: true
            )
        )
    }

    func testV41HostDeclaresBackgroundAudioCapability() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertTrue(modes.contains("audio"))
    }

    func testV41ClickProfilesAreShortSafeAndKeepAudibleHierarchy() throws {
        let orderedKinds: [MetronomeClickKind] = [
            .downbeat, .groupAccent, .beat, .subdivision
        ]
        let pulseKinds: [BeatPulseKind] = [.strong, .secondary, .weak, .subdivision]
        let profiles = orderedKinds.map(MetronomeClickProfile.profile(for:))
        let minimumEnhancedPeaks = [0.50, 0.40, 0.30, 0.20]

        XCTAssertEqual(
            pulseKinds.map { MetronomeClickKind(pulseKind: $0) },
            orderedKinds
        )
        XCTAssertTrue(zip(profiles, minimumEnhancedPeaks).allSatisfy {
            $0.0.targetPeak >= $0.1
                && $0.0.targetPeak <= MetronomeClickProfile.maximumPeak
                && $0.0.duration > 0
                && $0.0.duration <= MetronomeClickProfile.maximumDuration
        })
        for pair in zip(profiles, profiles.dropFirst()) {
            XCTAssertGreaterThan(pair.0.targetPeak, pair.1.targetPeak)
            XCTAssertGreaterThan(pair.0.frequency, pair.1.frequency)
            XCTAssertGreaterThan(pair.0.duration, pair.1.duration)
        }

        let trainingValues: [(note: TempoReferenceNote, subdivision: Int)] = [
            (.half, 0), (.quarter, 1), (.eighth, 2), (.sixteenth, 4)
        ]
        XCTAssertEqual(trainingValues.map(\.note), TempoReferenceNote.trainingNoteOptions)
        let supportedIntervals = TempoReferenceNote.tempoReferenceOptions.flatMap { reference in
            trainingValues.map { training -> TimeInterval in
                var candidate = MetronomePreset.standard
                candidate.bpm = TempoScrubModel.maximumBPM
                candidate.referenceNote = reference
                candidate.subdivision = training.subdivision
                return candidate.playbackPlan().eventInterval
            }
        }
        let shortestSupportedInterval = try XCTUnwrap(supportedIntervals.min())
        XCTAssertEqual(shortestSupportedInterval, 1.0 / 48.0, accuracy: 0.000_001)
        XCTAssertTrue(
            profiles.allSatisfy {
                $0.duration < shortestSupportedInterval
            }
        )
    }

    func testV41ClickWaveformsAreDeterministicFiniteAndPeakLimited() throws {
        var rootMeanSquares: [Double] = []
        for kind in MetronomeClickKind.allCases {
            let first = MetronomeClickWaveform.samples(for: kind, sampleRate: 44_100)
            let second = MetronomeClickWaveform.samples(for: kind, sampleRate: 44_100)
            let profile = MetronomeClickProfile.profile(for: kind)
            let peak = try XCTUnwrap(first.map { abs(Double($0)) }.max())

            XCTAssertEqual(first, second)
            XCTAssertGreaterThan(first.count, 2)
            XCTAssertLessThanOrEqual(
                Double(first.count) / 44_100,
                MetronomeClickProfile.maximumDuration
            )
            XCTAssertTrue(first.allSatisfy(\.isFinite))
            XCTAssertEqual(first.first, 0)
            XCTAssertEqual(first.last, 0)
            XCTAssertEqual(peak, profile.targetPeak, accuracy: 0.000_01)
            XCTAssertLessThanOrEqual(peak, MetronomeClickProfile.maximumPeak)
            rootMeanSquares.append(
                sqrt(first.reduce(0) { $0 + Double($1 * $1) } / Double(first.count))
            )
        }
        for pair in zip(rootMeanSquares, rootMeanSquares.dropFirst()) {
            XCTAssertGreaterThan(pair.0, pair.1)
        }
        XCTAssertGreaterThanOrEqual(rootMeanSquares[0], 0.13)
        XCTAssertGreaterThanOrEqual(rootMeanSquares[1], 0.095)
        XCTAssertGreaterThanOrEqual(rootMeanSquares[2], 0.085)
        XCTAssertGreaterThanOrEqual(rootMeanSquares[3], 0.06)
    }

    func testGroupingStartIndices() {
        var preset = MetronomePreset.standard
        preset.beats = 4
        preset.grouping = "标准"
        XCTAssertEqual(preset.groupStartIndices, [0, 2])

        preset.beats = 7
        preset.grouping = "3+4"
        XCTAssertEqual(preset.groupStartIndices, [0, 3])

        preset.beats = 5
        preset.grouping = "2+3"
        XCTAssertEqual(preset.strongBeatIndices, [0])
        XCTAssertEqual(preset.secondaryAccentIndices, [2])

        preset.beats = 5
        preset.grouping = "3+2"
        XCTAssertEqual(preset.strongBeatIndices, [0])
        XCTAssertEqual(preset.secondaryAccentIndices, [3])

        preset.beats = 7
        preset.grouping = "4+3"
        XCTAssertEqual(preset.groupStartIndices, [0, 4])
        XCTAssertEqual(preset.strongBeatIndices, [0, 4])
        XCTAssertEqual(preset.secondaryAccentIndices, [2])
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
        XCTAssertEqual(invalid.grouping, "3+4")
        XCTAssertEqual(invalid.direction, .clockwise)
    }

    func testV4BeatRangeAndTrainingNoteValues() {
        var belowRange = MetronomePreset.standard
        belowRange.beats = 2
        XCTAssertEqual(belowRange.normalized.beats, 3)

        var aboveRange = MetronomePreset.standard
        aboveRange.beats = 12
        XCTAssertEqual(aboveRange.normalized.beats, 9)

        XCTAssertEqual(MetronomePreset.supportedSubdivisions, [0, 1, 2, 4])

        var halfNote = MetronomePreset.standard
        halfNote.bpm = 120
        halfNote.subdivision = 0
        XCTAssertEqual(halfNote.subdivisionTitle, "二分音符")
        XCTAssertEqual(halfNote.pulsesPerBeat, 1)
        XCTAssertEqual(halfNote.eventDensity, 0.5)
        XCTAssertEqual(halfNote.mainBeatDuration, 1, accuracy: 0.000_1)

        var sixteenth = halfNote
        sixteenth.subdivision = 4
        XCTAssertEqual(sixteenth.pulsesPerBeat, 4)
        XCTAssertEqual(sixteenth.eventDensity, 4)
        XCTAssertEqual(sixteenth.eventsPerMeasure, 16)
        XCTAssertEqual(sixteenth.mainBeatDuration, 0.5, accuracy: 0.000_1)
    }

    func testTempoReferenceAndTrainingOptionsStayDistinct() {
        XCTAssertEqual(
            TempoReferenceNote.tempoReferenceOptions,
            [.half, .dottedHalf, .quarter, .dottedQuarter, .eighth, .dottedEighth]
        )
        XCTAssertEqual(
            TempoReferenceNote.trainingNoteOptions,
            [.half, .quarter, .eighth, .sixteenth]
        )
        XCTAssertTrue(TempoReferenceNote.tempoReferenceOptions.allSatisfy { $0 != .sixteenth })
        XCTAssertTrue(TempoReferenceNote.trainingNoteOptions.allSatisfy { !$0.isDotted })
        XCTAssertEqual(
            TempoReferenceNote.trainingNoteOptions.map(\.symbol),
            ["\u{ECA3}", "\u{ECA5}", "\u{ECA7}", "\u{ECA9}"]
        )
        XCTAssertEqual(
            TempoReferenceNote.tempoReferenceOptions.map(\.symbol),
            [
                "\u{ECA3}", "\u{ECA3}\u{ECB7}",
                "\u{ECA5}", "\u{ECA5}\u{ECB7}",
                "\u{ECA7}", "\u{ECA7}\u{ECB7}"
            ]
        )
    }

    func testDottedReferenceNotesAreOneAndAHalfTimesTheirBaseValue() {
        let pairs: [(plain: TempoReferenceNote, dotted: TempoReferenceNote)] = [
            (.half, .dottedHalf),
            (.quarter, .dottedQuarter),
            (.eighth, .dottedEighth)
        ]

        for pair in pairs {
            XCTAssertTrue(pair.dotted.isDotted)
            XCTAssertFalse(pair.plain.isDotted)
            XCTAssertEqual(pair.dotted.undottedNote, pair.plain)
            XCTAssertEqual(
                pair.dotted.durationInQuarterNotes,
                pair.plain.durationInQuarterNotes * 1.5,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                pair.dotted.density,
                pair.plain.density / 1.5,
                accuracy: 0.000_001
            )
        }
    }

    func testFirstPulseEstablishesFixedGeometryAndKeepsItAcrossCycles() {
        var lifecycle = BeatVisualLifecycle(beats: 4)

        XCTAssertEqual(lifecycle.phase, .origin)
        XCTAssertTrue(lifecycle.isPaused)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [])

        lifecycle.resume()
        lifecycle.record(beat: 0, subdivision: 1, cycle: 0, beats: 4)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3])
        XCTAssertTrue(lifecycle.hasEstablishedStructure)

        lifecycle.record(beat: 0, subdivision: 0, cycle: 1, beats: 4)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 100, beats: 4)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: 4)

        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3])
        XCTAssertTrue(lifecycle.hasEstablishedStructure)
    }

    func testFourBeatEighthNoteProducesEightFixedPulseAddresses() throws {
        let addresses = try (0..<4).flatMap { beat in
            try (0..<2).map { subdivision in
                try XCTUnwrap(BeatPulseVisualModel.address(
                    beat: beat,
                    subdivision: subdivision,
                    beats: 4,
                    pulsesPerBeat: 2
                ))
            }
        }

        XCTAssertEqual(addresses.map(\.phase), [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        XCTAssertEqual(Set(addresses.map(\.beat)), [0, 1, 2, 3])

        let preset = MetronomePreset.standard
        let kinds = addresses.map { address in
            BeatPulseVisualModel.kind(
                beat: address.beat,
                subdivision: address.subdivision,
                strongBeatIndices: preset.strongBeatIndices,
                secondaryAccentIndices: preset.secondaryAccentIndices
            )
        }
        XCTAssertEqual(
            kinds,
            [.strong, .subdivision, .weak, .subdivision,
             .secondary, .subdivision, .weak, .subdivision]
        )
    }

    func testSubdivisionHitNeverInheritsMainBeatAccent() {
        let kind = BeatPulseVisualModel.kind(
            beat: 0,
            subdivision: 1,
            strongBeatIndices: [0],
            secondaryAccentIndices: []
        )
        XCTAssertEqual(kind, .subdivision)
    }

    func testPulseStylesAreOrderedAndDecayAfterShortPeakHold() {
        let interval = 60.0 / 88.0 / 2.0
        let strong = BeatPulseVisualModel.style(for: .strong, eventInterval: interval)
        let secondary = BeatPulseVisualModel.style(for: .secondary, eventInterval: interval)
        let weak = BeatPulseVisualModel.style(for: .weak, eventInterval: interval)
        let subdivision = BeatPulseVisualModel.style(for: .subdivision, eventInterval: interval)

        XCTAssertGreaterThan(strong.peakRadius, secondary.peakRadius)
        XCTAssertGreaterThan(secondary.peakRadius, weak.peakRadius)
        XCTAssertGreaterThan(weak.peakRadius, subdivision.peakRadius)
        XCTAssertGreaterThan(strong.peakOpacity, secondary.peakOpacity)
        XCTAssertGreaterThan(secondary.peakOpacity, weak.peakOpacity)
        XCTAssertGreaterThan(weak.peakOpacity, subdivision.peakOpacity)
        XCTAssertGreaterThan(strong.duration, secondary.duration)
        XCTAssertGreaterThan(secondary.duration, weak.duration)
        XCTAssertGreaterThan(weak.duration, subdivision.duration)

        let start = BeatPulseVisualModel.envelope(age: 0, duration: strong.duration)
        let middle = BeatPulseVisualModel.envelope(
            age: strong.duration / 2,
            duration: strong.duration
        )
        let end = BeatPulseVisualModel.envelope(
            age: strong.duration,
            duration: strong.duration
        )
        XCTAssertEqual(start, 1, accuracy: 0.000_1)
        XCTAssertGreaterThan(start, middle)
        XCTAssertGreaterThan(middle, end)
        XCTAssertEqual(end, 0, accuracy: 0.000_1)

        let fastestSubdivision = BeatPulseVisualModel.style(
            for: .subdivision,
            eventInterval: 60.0 / 240.0 / 4.0
        )
        XCTAssertGreaterThanOrEqual(fastestSubdivision.duration, 0.04)
        XCTAssertEqual(
            BeatPulseVisualModel.envelope(age: 0.01, duration: fastestSubdivision.duration),
            1,
            accuracy: 0.000_1
        )
        XCTAssertLessThan(fastestSubdivision.duration, 60.0 / 240.0 / 4.0)
    }

    func testBPMChangesTimingWithoutChangingPulseAddresses() throws {
        var slow = MetronomePreset.standard
        slow.bpm = 88
        slow.subdivision = 2
        var fast = slow
        fast.bpm = 176

        XCTAssertEqual(slow.eventsPerMeasure, 8)

        let address = try XCTUnwrap(BeatPulseVisualModel.address(
            beat: 2,
            subdivision: 1,
            beats: slow.beats,
            pulsesPerBeat: slow.pulsesPerBeat
        ))
        let fastAddress = try XCTUnwrap(BeatPulseVisualModel.address(
            beat: 2,
            subdivision: 1,
            beats: fast.beats,
            pulsesPerBeat: fast.pulsesPerBeat
        ))
        XCTAssertEqual(address, fastAddress)
        XCTAssertEqual(slow.eventInterval, 0.340_909, accuracy: 0.000_001)
        XCTAssertEqual(
            fast.eventInterval,
            slow.eventInterval / 2,
            accuracy: 0.000_001
        )
    }

    func testScheduleFrontierChangesTempoWithoutChangingNextAddress() {
        var oldPreset = MetronomePreset.standard
        oldPreset.bpm = 60
        oldPreset.beats = 4
        oldPreset.subdivision = 2
        var newPreset = oldPreset
        newPreset.bpm = 120
        let oldPlan = oldPreset.playbackPlan()
        let newPlan = newPreset.playbackPlan()
        var frontier = BeatScheduleFrontier()

        _ = frontier.takeNext(plan: oldPlan, sampleRate: 1_000)
        _ = frontier.takeNext(plan: oldPlan, sampleRate: 1_000)
        let lastOldEvent = frontier.takeNext(plan: oldPlan, sampleRate: 1_000)
        frontier.reviseFutureInterval(
            to: newPlan.eventInterval,
            sampleRate: 1_000,
            minimumNextExactFrame: 0
        )
        let firstNewEvent = frontier.takeNext(plan: newPlan, sampleRate: 1_000)
        let secondNewEvent = frontier.takeNext(plan: newPlan, sampleRate: 1_000)

        XCTAssertEqual(lastOldEvent.eventIndex, 2)
        XCTAssertEqual(firstNewEvent.eventIndex, 3)
        XCTAssertEqual(firstNewEvent.beat, 1)
        XCTAssertEqual(firstNewEvent.subdivision, 1)
        XCTAssertEqual(firstNewEvent.cycle, 0)
        XCTAssertEqual(
            firstNewEvent.exactFrame - lastOldEvent.exactFrame,
            newPlan.eventInterval * 1_000,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            secondNewEvent.exactFrame - firstNewEvent.exactFrame,
            newPlan.eventInterval * 1_000,
            accuracy: 0.000_001
        )
        XCTAssertEqual(firstNewEvent.eventInterval, newPlan.eventInterval)
    }

    func testScheduleFrontierWrapsMeasureExactlyOnceAfterTempoChange() {
        var preset = MetronomePreset.standard
        preset.beats = 4
        preset.subdivision = 2
        let plan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier(eventIndex: 7, cycle: 9)

        let finalEvent = frontier.takeNext(plan: plan, sampleRate: 1_000)
        frontier.reviseFutureInterval(
            to: plan.eventInterval / 2,
            sampleRate: 1_000,
            minimumNextExactFrame: 0
        )
        var fasterPreset = preset
        fasterPreset.bpm *= 2
        let wrappedEvent = frontier.takeNext(
            plan: fasterPreset.playbackPlan(),
            sampleRate: 1_000
        )

        XCTAssertEqual(finalEvent.eventIndex, 7)
        XCTAssertEqual(finalEvent.cycle, 9)
        XCTAssertEqual(wrappedEvent.eventIndex, 0)
        XCTAssertEqual(wrappedEvent.beat, 0)
        XCTAssertEqual(wrappedEvent.subdivision, 0)
        XCTAssertEqual(wrappedEvent.cycle, 10)
    }

    func testScheduleFrontierBeforeFirstEventKeepsInitialDownbeat() {
        var preset = MetronomePreset.standard
        preset.beats = 5
        preset.subdivision = 4
        let plan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier()

        frontier.reviseFutureInterval(
            to: plan.eventInterval / 2,
            sampleRate: 1_000,
            minimumNextExactFrame: 900
        )
        let firstEvent = frontier.takeNext(plan: plan, sampleRate: 1_000)

        XCTAssertEqual(firstEvent.exactFrame, 0)
        XCTAssertEqual(firstEvent.eventIndex, 0)
        XCTAssertEqual(firstEvent.beat, 0)
        XCTAssertEqual(firstEvent.subdivision, 0)
        XCTAssertEqual(firstEvent.cycle, 0)
    }

    func testScheduleFrontierOverdueSuccessorIsEmittedOnceAtSafeBoundary() {
        var preset = MetronomePreset.standard
        preset.bpm = 30
        let slowPlan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier()
        let firstEvent = frontier.takeNext(plan: slowPlan, sampleRate: 1_000)

        preset.bpm = 240
        let fastPlan = preset.playbackPlan()
        frontier.reviseFutureInterval(
            to: fastPlan.eventInterval,
            sampleRate: 1_000,
            minimumNextExactFrame: 1_500
        )
        let successor = frontier.takeNext(plan: fastPlan, sampleRate: 1_000)
        let following = frontier.takeNext(plan: fastPlan, sampleRate: 1_000)

        XCTAssertEqual(firstEvent.eventIndex, 0)
        XCTAssertEqual(successor.eventIndex, 1)
        XCTAssertEqual(successor.exactFrame, 1_500)
        XCTAssertEqual(following.eventIndex, 2)
        XCTAssertEqual(
            following.exactFrame - successor.exactFrame,
            fastPlan.eventInterval * 1_000,
            accuracy: 0.000_001
        )
    }

    func testRapidTempoRevisionsUseLatestIntervalWithoutAdvancingCursor() {
        var preset = MetronomePreset.standard
        preset.bpm = 60
        preset.beats = 4
        preset.subdivision = 2
        let initialPlan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier(eventIndex: 3, cycle: 4)
        let queuedEvent = frontier.takeNext(plan: initialPlan, sampleRate: 1_000)

        for bpm in [70, 80, 65] {
            preset.bpm = bpm
            frontier.reviseFutureInterval(
                to: preset.playbackPlan().eventInterval,
                sampleRate: 1_000,
                minimumNextExactFrame: 0
            )
        }
        let finalPlan = preset.playbackPlan()
        let successor = frontier.takeNext(plan: finalPlan, sampleRate: 1_000)

        XCTAssertEqual(queuedEvent.eventIndex, 3)
        XCTAssertEqual(successor.eventIndex, 4)
        XCTAssertEqual(successor.cycle, 4)
        XCTAssertEqual(
            successor.exactFrame - queuedEvent.exactFrame,
            finalPlan.eventInterval * 1_000,
            accuracy: 0.000_001
        )
    }

    func testQueuedLookaheadTailAndFirstRetimedEventStayInOneOrderedSequence() {
        var preset = MetronomePreset.standard
        preset.bpm = 240
        preset.beats = 4
        preset.subdivision = 4
        preset.referenceNote = .dottedHalf
        let oldPlan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier()
        let queuedEventCount = Int(floor(0.22 / oldPlan.eventInterval)) + 1
        let queuedTail = (0..<queuedEventCount).map { _ in
            frontier.takeNext(plan: oldPlan, sampleRate: 44_100)
        }

        preset.bpm = 60
        let newPlan = preset.playbackPlan()
        frontier.reviseFutureInterval(
            to: newPlan.eventInterval,
            sampleRate: 44_100,
            minimumNextExactFrame: 0
        )
        let firstRetimedEvent = frontier.takeNext(
            plan: newPlan,
            sampleRate: 44_100
        )

        XCTAssertEqual(queuedEventCount, 11)
        XCTAssertEqual(queuedTail.map(\.eventIndex), Array(0..<queuedEventCount))
        XCTAssertTrue(queuedTail.allSatisfy { $0.eventInterval == oldPlan.eventInterval })
        XCTAssertEqual(firstRetimedEvent.eventIndex, queuedEventCount)
        XCTAssertEqual(firstRetimedEvent.cycle, 0)
        XCTAssertEqual(firstRetimedEvent.eventInterval, newPlan.eventInterval)
        XCTAssertEqual(
            firstRetimedEvent.exactFrame - queuedTail[queuedEventCount - 1].exactFrame,
            newPlan.eventInterval * 44_100,
            accuracy: 0.000_001
        )
    }

    func testLateSchedulerDefersOneSuccessorWithoutSkippingOrBursting() {
        var preset = MetronomePreset.standard
        preset.bpm = 240
        preset.subdivision = 4
        let plan = preset.playbackPlan()
        var frontier = BeatScheduleFrontier()
        let firstEvent = frontier.takeNext(plan: plan, sampleRate: 44_100)

        frontier.ensureNextEventIsNoEarlier(than: 0.5 * 44_100)
        let deferredSuccessor = frontier.takeNext(
            plan: plan,
            sampleRate: 44_100
        )
        let followingEvent = frontier.takeNext(
            plan: plan,
            sampleRate: 44_100
        )

        XCTAssertEqual(firstEvent.eventIndex, 0)
        XCTAssertEqual(firstEvent.sequence, 0)
        XCTAssertEqual(deferredSuccessor.eventIndex, 1)
        XCTAssertEqual(deferredSuccessor.sequence, 1)
        XCTAssertEqual(deferredSuccessor.exactFrame, 0.5 * 44_100)
        XCTAssertEqual(followingEvent.eventIndex, 2)
        XCTAssertEqual(followingEvent.sequence, 2)
        XCTAssertEqual(
            followingEvent.exactFrame - deferredSuccessor.exactFrame,
            plan.eventInterval * 44_100,
            accuracy: 0.000_001
        )
    }

    func testCustomerTempoPlansKeepEightNoteTopologyButChangeTiming() {
        var preset = MetronomePreset.standard
        preset.bpm = 88
        preset.beats = 4
        preset.subdivision = 2

        let legacy = preset.playbackPlan(semantics: .legacyQuarterReference)
        let training = preset.playbackPlan(semantics: .trainingNoteReference)
        let independentQuarter = preset.playbackPlan(
            semantics: .independentReference,
            referenceNote: .quarter
        )
        let independentEighth = preset.playbackPlan(
            semantics: .independentReference,
            referenceNote: .eighth
        )

        for plan in [legacy, training, independentQuarter, independentEighth] {
            XCTAssertEqual(plan.pulsesPerBeat, 2)
            XCTAssertEqual(plan.eventsPerMeasure, 8)
            XCTAssertEqual(plan.trainingNote, .eighth)
        }

        XCTAssertEqual(legacy.referenceNote, .quarter)
        XCTAssertEqual(legacy.bpmMark, "\u{ECA5} = 88")
        XCTAssertEqual(legacy.actualPulsesPerMinute, 176, accuracy: 0.000_001)
        XCTAssertEqual(legacy.eventInterval, 60.0 / 176.0, accuracy: 0.000_001)
        XCTAssertEqual(legacy.measureDuration, 240.0 / 88.0, accuracy: 0.000_001)

        XCTAssertEqual(training.referenceNote, .eighth)
        XCTAssertEqual(training.bpmMark, "\u{ECA7} = 88")
        XCTAssertEqual(training.actualPulsesPerMinute, 88, accuracy: 0.000_001)
        XCTAssertEqual(training.eventInterval, 60.0 / 88.0, accuracy: 0.000_001)
        XCTAssertEqual(training.measureDuration, 480.0 / 88.0, accuracy: 0.000_001)

        XCTAssertEqual(independentQuarter.eventInterval, legacy.eventInterval, accuracy: 0.000_001)
        XCTAssertEqual(independentEighth.eventInterval, training.eventInterval, accuracy: 0.000_001)
        XCTAssertTrue(independentQuarter.hasSameSchedule(as: legacy))
        XCTAssertTrue(independentEighth.hasSameSchedule(as: training))
        XCTAssertFalse(training.hasSameSchedule(as: legacy))
    }

    func testIndependentTempoReferenceCoversAllCandidateInterpretations() {
        var preset = MetronomePreset.standard
        preset.bpm = 88
        preset.beats = 4
        preset.subdivision = 2

        let expectedRates: [TempoReferenceNote: Double] = [
            .half: 352,
            .dottedHalf: 528,
            .quarter: 176,
            .dottedQuarter: 264,
            .eighth: 88,
            .dottedEighth: 132
        ]

        for note in TempoReferenceNote.tempoReferenceOptions {
            let plan = preset.playbackPlan(
                semantics: .independentReference,
                referenceNote: note
            )
            XCTAssertEqual(
                plan.actualPulsesPerMinute,
                expectedRates[note]!,
                accuracy: 0.000_001
            )
            XCTAssertEqual(plan.eventsPerMeasure, 8)
            XCTAssertEqual(plan.eventInterval, 60 / expectedRates[note]!, accuracy: 0.000_001)
        }
    }

    func testDottedReferenceChangesOnlyTimingNotTrainingTopology() {
        var preset = MetronomePreset.standard
        preset.bpm = 60
        preset.beats = 4
        preset.subdivision = 2

        let plain = preset.playbackPlan(
            semantics: .independentReference,
            referenceNote: .quarter
        )
        let dotted = preset.playbackPlan(
            semantics: .independentReference,
            referenceNote: .dottedQuarter
        )

        XCTAssertEqual(plain.bpmMark, "\u{ECA5} = 60")
        XCTAssertEqual(dotted.bpmMark, "\u{ECA5}\u{ECB7} = 60")
        XCTAssertEqual(dotted.trainingNote, .eighth)
        XCTAssertEqual(dotted.pulsesPerBeat, plain.pulsesPerBeat)
        XCTAssertEqual(dotted.eventsPerMeasure, plain.eventsPerMeasure)
        XCTAssertEqual(dotted.eventInterval, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(dotted.eventInterval, plain.eventInterval / 1.5, accuracy: 0.000_001)
        XCTAssertFalse(dotted.hasSameSchedule(as: plain))
    }

    func testDefaultPlaybackPlanUsesReferenceSavedInPreset() {
        var preset = MetronomePreset.standard
        preset.bpm = 60
        preset.subdivision = 2
        preset.referenceNote = .dottedQuarter

        let plan = preset.playbackPlan()

        XCTAssertEqual(plan.semantics, .independentReference)
        XCTAssertEqual(plan.referenceNote, .dottedQuarter)
        XCTAssertEqual(plan.eventInterval, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(preset.eventInterval, plan.eventInterval, accuracy: 0.000_001)
        XCTAssertEqual(preset.mainBeatDuration, plan.mainBeatDuration, accuracy: 0.000_001)
    }

    func testTempoSemanticsDoNotChangeVisualPulseAddresses() throws {
        var preset = MetronomePreset.standard
        preset.bpm = 88
        preset.beats = 4
        preset.subdivision = 2

        let plans = [
            preset.playbackPlan(semantics: .legacyQuarterReference),
            preset.playbackPlan(semantics: .trainingNoteReference),
            preset.playbackPlan(semantics: .independentReference, referenceNote: .eighth)
        ]

        let phaseSets = try plans.map { plan in
            try (0..<plan.eventsPerMeasure).map { eventIndex in
                let beat = eventIndex / plan.pulsesPerBeat
                let subdivision = eventIndex % plan.pulsesPerBeat
                return try XCTUnwrap(BeatPulseVisualModel.address(
                    beat: beat,
                    subdivision: subdivision,
                    beats: preset.beats,
                    pulsesPerBeat: plan.pulsesPerBeat
                )).phase
            }
        }

        XCTAssertEqual(phaseSets[0], [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        XCTAssertEqual(phaseSets[1], phaseSets[0])
        XCTAssertEqual(phaseSets[2], phaseSets[0])
    }

    func testLegacyFiveFieldPresetJSONStillDecodes() throws {
        let json = """
        {
          "bpm": 88,
          "beats": 4,
          "subdivision": 2,
          "direction": "counterclockwise",
          "grouping": "标准"
        }
        """
        let decoded = try JSONDecoder().decode(
            MetronomePreset.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(decoded.bpm, 88)
        XCTAssertEqual(decoded.beats, 4)
        XCTAssertEqual(decoded.subdivision, 2)
        XCTAssertEqual(decoded.direction, .counterclockwise)
        XCTAssertEqual(decoded.grouping, "标准")
        XCTAssertNil(decoded.referenceNoteRaw)
        XCTAssertEqual(decoded.referenceNote, .quarter)

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["bpm", "beats", "subdivision", "direction", "grouping"]
        )
    }

    func testSelectedReferenceNoteRoundTripsInsidePreset() throws {
        var source = MetronomePreset.standard
        source.referenceNote = .dottedHalf

        let data = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["referenceNoteRaw"] as? String, "dottedHalf")

        let restored = try JSONDecoder().decode(MetronomePreset.self, from: data)
        XCTAssertEqual(restored.referenceNoteRaw, "dottedHalf")
        XCTAssertEqual(restored.referenceNote, .dottedHalf)
        XCTAssertEqual(restored, source)
    }

    func testUnknownStoredReferenceFallsBackWithoutDestroyingRawValue() throws {
        let json = """
        {
          "bpm": 88,
          "beats": 4,
          "subdivision": 2,
          "direction": "counterclockwise",
          "grouping": "标准",
          "referenceNoteRaw": "futureReferenceValue"
        }
        """
        let decoded = try JSONDecoder().decode(
            MetronomePreset.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(decoded.referenceNote, .quarter)
        XCTAssertEqual(decoded.referenceNoteRaw, "futureReferenceValue")
    }

    func testTempoReferenceRawValuesRemainBackwardCompatibleAndCodable() throws {
        XCTAssertEqual(TempoReferenceNote.half.rawValue, "half")
        XCTAssertEqual(TempoReferenceNote.quarter.rawValue, "quarter")
        XCTAssertEqual(TempoReferenceNote.eighth.rawValue, "eighth")
        XCTAssertEqual(TempoReferenceNote.sixteenth.rawValue, "sixteenth")

        let restoredLegacy = try JSONDecoder().decode(
            TempoReferenceNote.self,
            from: Data("\"sixteenth\"".utf8)
        )
        XCTAssertEqual(restoredLegacy, .sixteenth)

        let dottedData = try JSONEncoder().encode(TempoReferenceNote.dottedQuarter)
        XCTAssertEqual(String(decoding: dottedData, as: UTF8.self), "\"dottedQuarter\"")
        XCTAssertEqual(
            try JSONDecoder().decode(TempoReferenceNote.self, from: dottedData),
            .dottedQuarter
        )
    }

    func testLiquidSelectorRelativeMathClampsAndUsesGestureOrigin() {
        XCTAssertEqual(
            LiquidSelectorMath.relativeIndex(
                startIndex: 3,
                translation: -44,
                pointsPerStep: 44,
                optionCount: 7
            ),
            2
        )
        XCTAssertEqual(
            LiquidSelectorMath.relativeIndex(
                startIndex: 3,
                translation: 44,
                pointsPerStep: 44,
                optionCount: 7
            ),
            4
        )
        XCTAssertEqual(
            LiquidSelectorMath.relativeIndex(
                startIndex: 0,
                translation: 1_000,
                pointsPerStep: 44,
                optionCount: 7
            ),
            6
        )
        XCTAssertEqual(
            LiquidSelectorMath.relativeIndex(
                startIndex: 6,
                translation: -1_000,
                pointsPerStep: 44,
                optionCount: 7
            ),
            0
        )
        XCTAssertNil(
            LiquidSelectorMath.relativeIndex(
                startIndex: 0,
                translation: 44,
                pointsPerStep: 0,
                optionCount: 7
            )
        )
    }

    func testLiquidSelectorContinuousIndexHandlesAllOptionCountsAndEdges() {
        XCTAssertNil(
            LiquidSelectorMath.continuousIndex(
                startIndex: 0,
                translation: 0,
                pointsPerStep: 44,
                optionCount: 0
            )
        )

        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 0,
                translation: 1_000,
                pointsPerStep: 44,
                optionCount: 1
            ),
            0
        )

        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 0,
                translation: 22,
                pointsPerStep: 44,
                optionCount: 2
            ),
            0.5
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 1,
                translation: 1_000,
                pointsPerStep: 44,
                optionCount: 2
            ),
            1
        )

        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 1,
                translation: -44,
                pointsPerStep: 44,
                optionCount: 3
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 1,
                translation: 44,
                pointsPerStep: 44,
                optionCount: 3
            ),
            2
        )

        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 0,
                translation: 0,
                pointsPerStep: 44,
                optionCount: 7
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 3,
                translation: 22,
                pointsPerStep: 44,
                optionCount: 7
            ),
            3.5
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 6,
                translation: 0,
                pointsPerStep: 44,
                optionCount: 7
            ),
            6
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 3,
                translation: -10_000,
                pointsPerStep: 44,
                optionCount: 7
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 3,
                translation: 10_000,
                pointsPerStep: 44,
                optionCount: 7
            ),
            6
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: -10,
                translation: 0,
                pointsPerStep: 44,
                optionCount: 7
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 10,
                translation: 0,
                pointsPerStep: 44,
                optionCount: 7
            ),
            6
        )

        XCTAssertNil(
            LiquidSelectorMath.continuousIndex(
                startIndex: 3,
                translation: 44,
                pointsPerStep: 0,
                optionCount: 7
            )
        )
        XCTAssertEqual(
            LiquidSelectorMath.continuousIndex(
                startIndex: 3,
                translation: 0.25,
                pointsPerStep: 0.5,
                optionCount: 7
            ),
            3.5
        )
    }

    func testLiquidSelectorEdgePinnedStripOffsetHandlesCountsAndWidths() {
        for optionCount in [0, 1, 2, 3] {
            XCTAssertEqual(
                LiquidSelectorMath.edgePinnedStripOffset(
                    continuousIndex: -1_000,
                    optionCount: optionCount,
                    slotWidth: 40
                ),
                0,
                "A \(optionCount)-option strip must stay fixed at its first edge"
            )
            XCTAssertEqual(
                LiquidSelectorMath.edgePinnedStripOffset(
                    continuousIndex: 1_000,
                    optionCount: optionCount,
                    slotWidth: 40
                ),
                0,
                "A \(optionCount)-option strip must stay fixed at its last edge"
            )
        }

        XCTAssertEqual(
            LiquidSelectorMath.edgePinnedStripOffset(
                continuousIndex: 3,
                optionCount: 7,
                slotWidth: 0
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.edgePinnedStripOffset(
                continuousIndex: 3,
                optionCount: 7,
                slotWidth: -1
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.edgePinnedStripOffset(
                continuousIndex: 3,
                optionCount: 7,
                slotWidth: 0.5
            ),
            -1
        )
    }

    func testLiquidSelectorEdgePinnedStripShowsBoundaryTripletsInCorrectSlots() {
        let values = Array(3...9)
        let slotWidth: CGFloat = 40
        let viewportWidth = slotWidth * 3

        func center(of index: Int, offset: CGFloat) -> CGFloat {
            (CGFloat(index) + 0.5) * slotWidth + offset
        }

        func visibleValues(at offset: CGFloat) -> [Int] {
            values.enumerated().compactMap { index, value in
                let itemCenter = center(of: index, offset: offset)
                return (0..<viewportWidth).contains(itemCenter) ? value : nil
            }
        }

        let expectedOffsets: [(index: CGFloat, offset: CGFloat)] = [
            (0, 0),
            (1, 0),
            (2, -40),
            (3, -80),
            (4, -120),
            (5, -160),
            (6, -160)
        ]
        for item in expectedOffsets {
            XCTAssertEqual(
                LiquidSelectorMath.edgePinnedStripOffset(
                    continuousIndex: item.index,
                    optionCount: values.count,
                    slotWidth: slotWidth
                ),
                item.offset
            )
        }

        let firstOffset = LiquidSelectorMath.edgePinnedStripOffset(
            continuousIndex: 0,
            optionCount: values.count,
            slotWidth: slotWidth
        )
        XCTAssertEqual(visibleValues(at: firstOffset), [3, 4, 5])
        XCTAssertEqual(center(of: 0, offset: firstOffset), slotWidth / 2)

        let lastOffset = LiquidSelectorMath.edgePinnedStripOffset(
            continuousIndex: 6,
            optionCount: values.count,
            slotWidth: slotWidth
        )
        XCTAssertEqual(visibleValues(at: lastOffset), [7, 8, 9])
        XCTAssertEqual(center(of: 6, offset: lastOffset), slotWidth * 2.5)

        XCTAssertEqual(
            LiquidSelectorMath.edgePinnedStripOffset(
                continuousIndex: -1_000,
                optionCount: values.count,
                slotWidth: slotWidth
            ),
            firstOffset
        )
        XCTAssertEqual(
            LiquidSelectorMath.edgePinnedStripOffset(
                continuousIndex: 1_000,
                optionCount: values.count,
                slotWidth: slotWidth
            ),
            lastOffset
        )
    }

    func testLiquidSelectorClampedCenterHandlesEdgesAndDegenerateWidths() {
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: -1_000,
                scaledCursorWidth: 20,
                lowerBound: 4,
                upperBound: 96
            ),
            14
        )
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: 50,
                scaledCursorWidth: 20,
                lowerBound: 4,
                upperBound: 96
            ),
            50
        )
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: 1_000,
                scaledCursorWidth: 20,
                lowerBound: 4,
                upperBound: 96
            ),
            86
        )

        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: -1_000,
                scaledCursorWidth: 0,
                lowerBound: 4,
                upperBound: 96
            ),
            4
        )
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: 1_000,
                scaledCursorWidth: 0,
                lowerBound: 4,
                upperBound: 96
            ),
            96
        )

        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: -1_000,
                scaledCursorWidth: 20,
                lowerBound: 0,
                upperBound: 8
            ),
            4
        )
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: 1_000,
                scaledCursorWidth: 20,
                lowerBound: 0,
                upperBound: 0
            ),
            0
        )
        XCTAssertEqual(
            LiquidSelectorMath.clampedCenter(
                proposedCenter: -1_000,
                scaledCursorWidth: -20,
                lowerBound: 4,
                upperBound: 96
            ),
            4
        )
    }

    func testBeatVisualLifecyclePauseDoesNotCollapseAndFinishIsExplicit() {
        var lifecycle = BeatVisualLifecycle(beats: 3)
        for beat in 0..<3 {
            lifecycle.record(beat: beat, subdivision: 0, cycle: 0, beats: 3)
        }

        XCTAssertEqual(lifecycle.currentBeatIndex, 2)
        lifecycle.record(beat: 2, subdivision: 1, cycle: 0, beats: 3)
        XCTAssertEqual(lifecycle.currentBeatIndex, 2)

        lifecycle.pause()
        XCTAssertTrue(lifecycle.isPaused)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2])
        XCTAssertEqual(lifecycle.currentBeatIndex, 2)

        lifecycle.resume()
        XCTAssertFalse(lifecycle.isPaused)
        XCTAssertEqual(lifecycle.phase, .orbiting)

        lifecycle.beginFinishing()
        XCTAssertEqual(lifecycle.phase, .finishing)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2])
        XCTAssertTrue(lifecycle.hasEstablishedStructure)
        XCTAssertNil(lifecycle.currentBeatIndex)

        lifecycle.record(beat: 1, subdivision: 0, cycle: 22, beats: 3)
        XCTAssertEqual(lifecycle.phase, .finishing)
        XCTAssertNil(lifecycle.currentBeatIndex)

        lifecycle.settle()
        XCTAssertEqual(lifecycle.phase, .settled)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [])
        XCTAssertNil(lifecycle.currentBeatIndex)
        XCTAssertTrue(lifecycle.isPaused)
    }

    func testBeatVisualLifecycleLiveTopologyChangeKeepsEstablishedShape() {
        var lifecycle = BeatVisualLifecycle(beats: 5)
        lifecycle.record(beat: 0, subdivision: 0, cycle: 1, beats: 5)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3, 4])

        lifecycle.reconfigure(beats: 5)
        XCTAssertEqual(lifecycle.phase, .orbiting)

        lifecycle.reconfigure(beats: 7)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.beatCount, 7)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3, 4, 5, 6])
        XCTAssertNil(lifecycle.currentBeatIndex)

        lifecycle.record(beat: -1, subdivision: 0, cycle: 0, beats: 7)
        lifecycle.record(beat: 9, subdivision: 0, cycle: 0, beats: 7)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3, 4, 5, 6])
    }

    func testBeatVisualLifecycleCanClearOnlyStaleCurrentBeatLocation() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 1, beats: 4)
        XCTAssertEqual(lifecycle.currentBeatIndex, 2)

        lifecycle.clearCurrentBeatLocation()

        XCTAssertNil(lifecycle.currentBeatIndex)
        XCTAssertEqual(lifecycle.phase, .orbiting)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3])
    }

    func testBeatVisualLifecycleWaitingTopologyChangeStaysAtOrigin() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.reconfigure(beats: 7)

        XCTAssertEqual(lifecycle.phase, .origin)
        XCTAssertEqual(lifecycle.beatCount, 7)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [])
        XCTAssertTrue(lifecycle.isPaused)
    }

    func testMetronomeGlanceStatusResolvesAllFiveStates() {
        let preset = MetronomePreset.standard
        var lifecycle = BeatVisualLifecycle(beats: preset.beats)

        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: preset,
                hand: .both,
                lifecycle: lifecycle,
                isPlaying: false
            ).state,
            .ready
        )

        lifecycle.record(beat: 0, subdivision: 0, cycle: 0, beats: preset.beats)
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: preset,
                hand: .both,
                lifecycle: lifecycle,
                isPlaying: true
            ).state,
            .playing
        )

        lifecycle.pause()
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: preset,
                hand: .both,
                lifecycle: lifecycle,
                isPlaying: false
            ).state,
            .paused
        )

        lifecycle.beginFinishing()
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: preset,
                hand: .both,
                lifecycle: lifecycle,
                isPlaying: false,
                isFinishing: true
            ).state,
            .finishing
        )

        lifecycle.settle()
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: preset,
                hand: .both,
                lifecycle: lifecycle,
                isPlaying: false,
                isFinished: true
            ).state,
            .finished
        )
    }

    func testMetronomeGlanceStatusContainsCompletePracticeContext() {
        var preset = MetronomePreset.standard
        preset.bpm = 88
        preset.beats = 5
        preset.grouping = "3+2"
        preset.subdivision = 2
        preset.referenceNote = .dottedQuarter
        var lifecycle = BeatVisualLifecycle(beats: preset.beats)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 4, beats: preset.beats)

        let status = MetronomeGlanceStatus(
            preset: preset,
            hand: .left,
            lifecycle: lifecycle,
            isPlaying: true
        )

        XCTAssertEqual(status.bpm, 88)
        XCTAssertEqual(status.bpmText, "88 BPM")
        XCTAssertEqual(status.referenceNote, .dottedQuarter)
        XCTAssertEqual(status.referenceTempoText, "\u{ECA5}\u{ECB7} = 88")
        XCTAssertEqual(status.trainingNote, .eighth)
        XCTAssertEqual(status.trainingNoteText, "\u{ECA7}")
        XCTAssertEqual(status.beats, 5)
        XCTAssertEqual(status.grouping, "3+2")
        XCTAssertEqual(status.beatStructureText, "5 拍 · 3+2")
        XCTAssertEqual(status.hand, .left)
        XCTAssertEqual(status.currentMainBeat, 3)
        XCTAssertEqual(status.currentBeatText, "第 3 / 5 拍")
        XCTAssertTrue(status.accessibilitySummary.contains("演奏中"))
        XCTAssertTrue(status.accessibilitySummary.contains("当前第 3 拍"))
        XCTAssertTrue(
            status.accessibilitySummary.contains(
                "速度基准，附点四分音符等于每分钟 88 拍"
            )
        )
        XCTAssertTrue(status.accessibilitySummary.contains("训练音符八分音符"))
        XCTAssertTrue(status.accessibilitySummary.contains("左手"))
    }

    func testMetronomeGlanceStatusUsesTheEffectivePlaybackReference() {
        var preset = MetronomePreset.standard
        preset.referenceNote = .dottedHalf

        let status = MetronomeGlanceStatus(
            preset: preset,
            hand: .both,
            lifecycle: BeatVisualLifecycle(beats: preset.beats),
            isPlaying: false,
            effectiveReferenceNote: .eighth
        )

        XCTAssertEqual(status.referenceNote, .eighth)
        XCTAssertEqual(status.referenceTempoText, "\u{ECA7} = 112")
        XCTAssertTrue(status.accessibilitySummary.contains("基准音符八分音符"))
    }

    func testSubdivisionKeepsItsContainingMainBeatCurrent() {
        let preset = MetronomePreset.standard
        var lifecycle = BeatVisualLifecycle(beats: preset.beats)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 0, beats: preset.beats)
        let before = MetronomeGlanceStatus(
            preset: preset,
            hand: .both,
            lifecycle: lifecycle,
            isPlaying: true
        )

        lifecycle.record(beat: 2, subdivision: 1, cycle: 0, beats: preset.beats)
        let after = MetronomeGlanceStatus(
            preset: preset,
            hand: .both,
            lifecycle: lifecycle,
            isPlaying: true
        )

        XCTAssertEqual(before.currentMainBeat, 3)
        XCTAssertEqual(after.currentMainBeat, before.currentMainBeat)
    }

    func testSubdivisionPulseLocatesItsMainBeatAfterTopologyChange() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 2, subdivision: 0, cycle: 0, beats: 4)
        lifecycle.reconfigure(beats: 7)
        XCTAssertNil(lifecycle.currentBeatIndex)

        lifecycle.record(beat: 4, subdivision: 1, cycle: 0, beats: 7)

        XCTAssertEqual(lifecycle.currentBeatIndex, 4)
        XCTAssertEqual(lifecycle.visibleBeatIndices, [0, 1, 2, 3, 4, 5, 6])
    }

    func testCurrentAnchorRemainsDominantWhilePlayingAndPaused() {
        var lifecycle = BeatVisualLifecycle(beats: 4)
        lifecycle.record(beat: 1, subdivision: 0, cycle: 0, beats: 4)

        let playingCurrent = BeatVisualHierarchyModel.anchorStyle(
            for: 1,
            lifecycle: lifecycle
        )
        let playingInactive = BeatVisualHierarchyModel.anchorStyle(
            for: 0,
            lifecycle: lifecycle
        )
        XCTAssertGreaterThan(playingCurrent.radius, playingInactive.radius)
        XCTAssertGreaterThan(playingCurrent.opacity, playingInactive.opacity)
        XCTAssertGreaterThan(playingCurrent.prominence, playingInactive.prominence * 2)

        lifecycle.pause()
        let pausedCurrent = BeatVisualHierarchyModel.anchorStyle(
            for: 1,
            lifecycle: lifecycle
        )
        let pausedInactive = BeatVisualHierarchyModel.anchorStyle(
            for: 2,
            lifecycle: lifecycle
        )
        XCTAssertGreaterThan(pausedCurrent.radius, pausedInactive.radius)
        XCTAssertGreaterThan(pausedCurrent.opacity, pausedInactive.opacity)
        XCTAssertGreaterThan(pausedCurrent.prominence, pausedInactive.prominence * 2)
    }

    func testDimFlashingLightsKeepsPulseHierarchy() {
        let eventInterval = 60.0 / 112.0 / 4.0
        let styles = [
            BeatPulseKind.strong,
            .secondary,
            .weak,
            .subdivision
        ].map {
            BeatVisualHierarchyModel.pulseStyle(
                for: $0,
                eventInterval: eventInterval,
                dimFlashingLights: true
            )
        }

        XCTAssertGreaterThan(styles[0].peakRadius, styles[1].peakRadius)
        XCTAssertGreaterThan(styles[1].peakRadius, styles[2].peakRadius)
        XCTAssertGreaterThan(styles[2].peakRadius, styles[3].peakRadius)
        XCTAssertGreaterThan(styles[0].peakOpacity, styles[1].peakOpacity)
        XCTAssertGreaterThan(styles[1].peakOpacity, styles[2].peakOpacity)
        XCTAssertGreaterThan(styles[2].peakOpacity, styles[3].peakOpacity)
    }

    func testGlanceStatusClearsCurrentBeatAcrossFinishAndReset() {
        var lifecycle = BeatVisualLifecycle(beats: 7)
        lifecycle.record(beat: 5, subdivision: 0, cycle: 2, beats: 7)
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: MetronomePreset(
                    bpm: 120,
                    beats: 7,
                    subdivision: 1,
                    direction: .clockwise,
                    grouping: "3+4"
                ),
                hand: .right,
                lifecycle: lifecycle,
                isPlaying: true
            ).currentMainBeat,
            6
        )

        lifecycle.beginFinishing()
        let finishing = MetronomeGlanceStatus(
            preset: MetronomePreset(
                bpm: 120,
                beats: 7,
                subdivision: 1,
                direction: .clockwise,
                grouping: "3+4"
            ),
            hand: .right,
            lifecycle: lifecycle,
            isPlaying: false,
            isFinishing: true
        )
        XCTAssertEqual(finishing.state, .finishing)
        XCTAssertNil(finishing.currentMainBeat)

        lifecycle.settle()
        XCTAssertEqual(
            MetronomeGlanceStatus(
                preset: MetronomePreset.standard,
                hand: .right,
                lifecycle: lifecycle,
                isPlaying: false
            ).state,
            .finished
        )

        lifecycle.reset(beats: 4)
        let ready = MetronomeGlanceStatus(
            preset: MetronomePreset.standard,
            hand: .both,
            lifecycle: lifecycle,
            isPlaying: false
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertNil(ready.currentMainBeat)
        XCTAssertEqual(ready.currentBeatText, "尚无当前拍")
    }

    func testPracticeHandControlOrderAndSymbols() {
        XCTAssertEqual(PracticeHand.controlOrder, [.left, .both, .right])
        XCTAssertEqual(PracticeHand.controlOrder.map(\.shortTitle), ["L", "B", "R"])
    }

    @MainActor
    func testEngineRemembersGroupingWhenReturningToBeatCount() {
        let engine = MetronomeEngine()

        engine.setBeats(5)
        XCTAssertEqual(engine.preset.grouping, "2+3")
        engine.setGrouping("3+2")
        engine.setBeats(4)
        engine.setBeats(5)

        XCTAssertEqual(engine.preset.grouping, "3+2")
    }

    func testPracticeEventStoresPresetSnapshotAndCounts() {
        var source = MetronomePreset.standard
        source.bpm = 144
        source.beats = 5
        source.grouping = "3+2"
        source.referenceNote = .dottedQuarter

        let event = PracticeEvent(name: "音阶", leftCount: 2, preset: source)
        source.bpm = 72
        source.referenceNote = .half

        XCTAssertEqual(event.preset.bpm, 144)
        XCTAssertEqual(event.preset.grouping, "3+2")
        XCTAssertEqual(event.preset.referenceNote, .dottedQuarter)
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

    func testQuickIncrementAffectsOnlyCurrentHand() {
        let start = Date(timeIntervalSinceReferenceDate: 2_500)
        var session = PracticeSession()
        session.begin(at: start)

        session.adjustCount(for: session.currentHand, by: 1)
        session.switchHand(to: .left, at: start.addingTimeInterval(1))
        session.adjustCount(for: session.currentHand, by: 1)
        session.switchHand(to: .right, at: start.addingTimeInterval(2))
        session.adjustCount(for: session.currentHand, by: 1)

        XCTAssertEqual(session.stats(for: .left, at: start).count, 1)
        XCTAssertEqual(session.stats(for: .both, at: start).count, 1)
        XCTAssertEqual(session.stats(for: .right, at: start).count, 1)
    }

    func testSelectingCurrentHandDoesNotRestartSegment() {
        let start = Date(timeIntervalSinceReferenceDate: 2_750)
        var session = PracticeSession()
        session.begin(at: start)
        let originalSegmentStart = session.segmentStartedAt

        session.switchHand(to: .both, at: start.addingTimeInterval(3))

        XCTAssertEqual(session.currentHand, .both)
        XCTAssertEqual(session.segmentStartedAt, originalSegmentStart)
        XCTAssertEqual(
            session.stats(for: .both, at: start.addingTimeInterval(4)).durationMilliseconds,
            4_000
        )
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
