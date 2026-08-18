import XCTest
import SwiftData
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
        for offset in [2.1, 2.2, 2.3] {
            original.recordCompletion(
                for: .left,
                preset: preset,
                at: start.addingTimeInterval(offset)
            )
        }
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
        for offset in [0.1, 0.2, 0.3, 0.4] {
            original.recordCompletion(
                for: .both,
                preset: preset,
                at: start.addingTimeInterval(offset)
            )
        }
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

    @MainActor
    func testControllerRewritesLegacyFinishedDraftAndKeepsMigratedSessionIDStable() throws {
        struct DraftEnvelope: Encodable {
            let session: PracticeSession
            let savedAt: Date
            let preset: MetronomePreset?
        }

        let suiteName = "GeoPracticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSinceReferenceDate: 8_500)
        let savedAt = start.addingTimeInterval(8)
        let sourceID = UUID()
        var preset = MetronomePreset.standard
        preset.bpm = 126
        preset.beats = 5
        preset.grouping = "3+2"
        preset.referenceNote = .dottedQuarter
        preset.subdivision = 4

        var finishedSession = PracticeSession()
        finishedSession.begin(sourceEventID: sourceID, at: start)
        finishedSession.adjustCount(for: .left, by: 3)
        _ = finishedSession.finish(at: savedAt)

        let currentDraftData = try JSONEncoder().encode(DraftEnvelope(
            session: finishedSession,
            savedAt: savedAt,
            preset: preset
        ))
        var legacyDraft = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentDraftData) as? [String: Any]
        )
        var legacySession = try XCTUnwrap(
            legacyDraft["session"] as? [String: Any]
        )
        legacySession.removeValue(forKey: "sessionID")
        legacySession.removeValue(forKey: "completions")
        var legacySummary = try XCTUnwrap(
            legacySession["completedSummary"] as? [String: Any]
        )
        legacySummary.removeValue(forKey: "sessionID")
        legacySummary.removeValue(forKey: "completions")
        legacySession["completedSummary"] = legacySummary
        legacyDraft["session"] = legacySession
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDraft)
        defaults.set(legacyData, forKey: "practiceSessionDraft.v1")

        let firstRestore = PracticeSessionController(defaults: defaults)
        let migratedID = firstRestore.session.sessionID
        XCTAssertEqual(firstRestore.session.phase, .finished)
        XCTAssertEqual(firstRestore.session.sourceEventID, sourceID)
        XCTAssertEqual(firstRestore.session.reviewSummary?.sessionID, migratedID)
        XCTAssertEqual(firstRestore.session.reviewSummary?.stats(for: .left).count, 3)
        XCTAssertEqual(firstRestore.sessionPreset, preset.normalized)

        let rewrittenData = try XCTUnwrap(
            defaults.data(forKey: "practiceSessionDraft.v1")
        )
        let rewrittenDraft = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        )
        let rewrittenSession = try XCTUnwrap(
            rewrittenDraft["session"] as? [String: Any]
        )
        let rewrittenSummary = try XCTUnwrap(
            rewrittenSession["completedSummary"] as? [String: Any]
        )
        XCTAssertEqual(rewrittenSession["sessionID"] as? String, migratedID.uuidString)
        XCTAssertEqual(rewrittenSummary["sessionID"] as? String, migratedID.uuidString)
        XCTAssertNotNil(rewrittenSession["completions"])
        XCTAssertNotNil(rewrittenSummary["completions"])

        let secondRestore = PracticeSessionController(defaults: defaults)
        XCTAssertEqual(secondRestore.session.sessionID, migratedID)
        XCTAssertEqual(secondRestore.session.reviewSummary?.sessionID, migratedID)
        XCTAssertEqual(secondRestore.session, firstRestore.session)
    }

    @MainActor
    func testControllerUndoFallsBackToLegacyCountOnlyDraftAndPersistsIt() throws {
        struct DraftEnvelope: Encodable {
            let session: PracticeSession
            let savedAt: Date
            let preset: MetronomePreset?
        }

        let suiteName = "GeoPracticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSinceReferenceDate: 8_750)
        let savedAt = start.addingTimeInterval(2)
        var legacySession = PracticeSession()
        legacySession.begin(at: start)
        legacySession.adjustCount(for: .right, by: 1)
        let draftData = try JSONEncoder().encode(DraftEnvelope(
            session: legacySession,
            savedAt: savedAt,
            preset: .standard
        ))
        defaults.set(draftData, forKey: "practiceSessionDraft.v1")

        let controller = PracticeSessionController(defaults: defaults)
        XCTAssertEqual(controller.session.phase, .paused)
        XCTAssertEqual(controller.session.stats(for: .right, at: savedAt).count, 1)
        XCTAssertTrue(controller.session.completionSamples(for: .right).isEmpty)

        XCTAssertTrue(
            controller.undoLatestCompletionOrLegacyCount(for: .right, at: savedAt)
        )
        XCTAssertEqual(controller.session.stats(for: .right, at: savedAt).count, 0)
        XCTAssertTrue(controller.session.completionSamples(for: .right).isEmpty)
        XCTAssertFalse(
            controller.undoLatestCompletionOrLegacyCount(for: .right, at: savedAt)
        )

        let restoredAgain = PracticeSessionController(defaults: defaults)
        XCTAssertEqual(restoredAgain.session.stats(for: .right, at: savedAt).count, 0)
        XCTAssertTrue(restoredAgain.session.completionSamples(for: .right).isEmpty)
    }

    func testLegacyPracticeSessionJSONWithoutSpeedHistoryStillDecodes() throws {
        let start = Date(timeIntervalSinceReferenceDate: 9_000)
        let sourceEventID = UUID()
        var legacySession = PracticeSession()
        legacySession.begin(sourceEventID: sourceEventID, at: start)
        legacySession.adjustCount(for: .both, by: 3)
        legacySession.switchHand(to: .left, at: start.addingTimeInterval(2))
        legacySession.adjustCount(for: .left, by: 2)

        let currentData = try JSONEncoder().encode(legacySession)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "sessionID")
        legacyJSON.removeValue(forKey: "completions")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let restored = try JSONDecoder().decode(PracticeSession.self, from: legacyData)

        XCTAssertEqual(restored.phase, .running)
        XCTAssertEqual(restored.sourceEventID, sourceEventID)
        XCTAssertEqual(restored.currentHand, .left)
        XCTAssertEqual(restored.stats(for: .both, at: start).count, 3)
        XCTAssertEqual(restored.stats(for: .left, at: start).count, 2)
        XCTAssertTrue(restored.completionSamples(for: .left).isEmpty)
        XCTAssertTrue(restored.completionSamples(for: .both).isEmpty)

        let migratedData = try JSONEncoder().encode(restored)
        let roundTripped = try JSONDecoder().decode(PracticeSession.self, from: migratedData)
        XCTAssertEqual(roundTripped.sessionID, restored.sessionID)
        XCTAssertEqual(roundTripped, restored)
    }

    func testPracticeSessionIDIsStableForTheWholeLifecycle() throws {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var session = PracticeSession()
        let idleID = session.sessionID

        session.begin(at: start)
        let runningID = session.sessionID
        XCTAssertNotEqual(runningID, idleID)

        session.begin(at: start.addingTimeInterval(1))
        XCTAssertEqual(session.sessionID, runningID)

        var preset = MetronomePreset.standard
        preset.bpm = 132
        _ = session.recordCompletion(
            for: .both,
            preset: preset,
            at: start.addingTimeInterval(2)
        )
        session.pause(at: start.addingTimeInterval(3))
        session.resume(at: start.addingTimeInterval(4))
        let summary = try XCTUnwrap(session.finish(at: start.addingTimeInterval(5)))

        XCTAssertEqual(session.sessionID, runningID)
        XCTAssertEqual(summary.sessionID, runningID)

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(PracticeSession.self, from: data)
        XCTAssertEqual(restored.sessionID, runningID)
        XCTAssertEqual(restored.reviewSummary?.sessionID, runningID)

        session.reset()
        XCTAssertEqual(session.sessionID, idleID)
        session.begin(at: start.addingTimeInterval(10))
        XCTAssertNotEqual(session.sessionID, runningID)
        XCTAssertNotEqual(session.sessionID, idleID)
    }

    func testCompletionRecordsFullPresetAndUndoRemovesLatestForOnlyThatHand() throws {
        let start = Date(timeIntervalSinceReferenceDate: 11_000)
        var session = PracticeSession()
        session.begin(at: start)

        var firstLeftPreset = MetronomePreset.standard
        firstLeftPreset.bpm = 88
        firstLeftPreset.beats = 5
        firstLeftPreset.grouping = "3+2"
        firstLeftPreset.subdivision = 2
        firstLeftPreset.direction = .clockwise
        firstLeftPreset.referenceNote = .dottedQuarter

        var secondLeftPreset = MetronomePreset.standard
        secondLeftPreset.bpm = 144
        secondLeftPreset.beats = 7
        secondLeftPreset.grouping = "2+3+2"
        secondLeftPreset.subdivision = 4
        secondLeftPreset.direction = .counterclockwise
        secondLeftPreset.referenceNote = .dottedEighth

        var rightPreset = MetronomePreset.standard
        rightPreset.bpm = 72
        rightPreset.beats = 3
        rightPreset.grouping = "标准"
        rightPreset.subdivision = 0
        rightPreset.referenceNote = .half

        let firstLeft = try XCTUnwrap(session.recordCompletion(
            for: .left,
            preset: firstLeftPreset,
            at: start.addingTimeInterval(1)
        ))
        let secondLeft = try XCTUnwrap(session.recordCompletion(
            for: .left,
            preset: secondLeftPreset,
            at: start.addingTimeInterval(2)
        ))
        let right = try XCTUnwrap(session.recordCompletion(
            for: .right,
            preset: rightPreset,
            at: start.addingTimeInterval(3)
        ))

        XCTAssertEqual(firstLeft.preset, firstLeftPreset.normalized)
        XCTAssertEqual(secondLeft.preset, secondLeftPreset.normalized)
        XCTAssertEqual(right.preset, rightPreset.normalized)
        XCTAssertEqual(session.stats(for: .left, at: start).count, 2)
        XCTAssertEqual(session.stats(for: .right, at: start).count, 1)

        let removed = try XCTUnwrap(session.undoLastCompletion(for: .left))
        XCTAssertEqual(removed.id, secondLeft.id)
        XCTAssertEqual(removed.preset, secondLeftPreset.normalized)
        XCTAssertEqual(session.completionSamples(for: .left), [firstLeft])
        XCTAssertEqual(session.completionSamples(for: .right), [right])
        XCTAssertEqual(session.stats(for: .left, at: start).count, 1)
        XCTAssertEqual(session.stats(for: .right, at: start).count, 1)

        XCTAssertEqual(session.undoLastCompletion(for: .left)?.id, firstLeft.id)
        XCTAssertNil(session.undoLastCompletion(for: .left))
        XCTAssertEqual(session.stats(for: .left, at: start).count, 0)
        XCTAssertEqual(session.stats(for: .right, at: start).count, 1)
    }

    func testMostPracticedBPMUsesFrequencyAndBreaksTiesByLatestCompletion() throws {
        let base = Date(timeIntervalSinceReferenceDate: 12_000)
        func sample(_ bpm: Int, seconds: TimeInterval) -> PracticeCompletionSample {
            var preset = MetronomePreset.standard
            preset.bpm = bpm
            return PracticeCompletionSample(
                hand: .left,
                preset: preset,
                completedAt: base.addingTimeInterval(seconds)
            )
        }

        let summary = PracticeHandSpeedSummary(
            samples: [
                sample(88, seconds: 1),
                sample(96, seconds: 2),
                sample(96, seconds: 4),
                sample(88, seconds: 5),
                sample(220, seconds: 3)
            ],
            for: .left
        )

        let mostPracticed = try XCTUnwrap(summary.mostPracticed)
        XCTAssertEqual(mostPracticed.bpm, 88)
        XCTAssertEqual(mostPracticed.completionCount, 2)
        XCTAssertEqual(mostPracticed.lastCompletedAt, base.addingTimeInterval(5))

        let maximumAttempt = try XCTUnwrap(summary.maximumAttempt)
        XCTAssertEqual(maximumAttempt.bpm, 220)
        XCTAssertEqual(maximumAttempt.completionCount, 1)
    }

    func testSpeedSummaryGroupsOnlyByBPMDespiteDifferentNoteSettings() throws {
        let base = Date(timeIntervalSinceReferenceDate: 13_000)
        var quarterEighthTraining = MetronomePreset.standard
        quarterEighthTraining.bpm = 88
        quarterEighthTraining.referenceNote = .quarter
        quarterEighthTraining.subdivision = 2

        var dottedEighthHalfTraining = MetronomePreset.standard
        dottedEighthHalfTraining.bpm = 88
        dottedEighthHalfTraining.referenceNote = .dottedEighth
        dottedEighthHalfTraining.subdivision = 0
        dottedEighthHalfTraining.beats = 5
        dottedEighthHalfTraining.grouping = "3+2"

        var faster = MetronomePreset.standard
        faster.bpm = 96
        faster.referenceNote = .half
        faster.subdivision = 4

        let speed = PracticeHandSpeedSummary(
            samples: [
                PracticeCompletionSample(
                    hand: .both,
                    preset: quarterEighthTraining,
                    completedAt: base
                ),
                PracticeCompletionSample(
                    hand: .both,
                    preset: dottedEighthHalfTraining,
                    completedAt: base.addingTimeInterval(1)
                ),
                PracticeCompletionSample(
                    hand: .both,
                    preset: faster,
                    completedAt: base.addingTimeInterval(2)
                )
            ],
            for: .both
        )

        let mostPracticed = try XCTUnwrap(speed.mostPracticed)
        XCTAssertEqual(mostPracticed.bpm, 88)
        XCTAssertEqual(mostPracticed.completionCount, 2)
        XCTAssertEqual(mostPracticed.preset, dottedEighthHalfTraining.normalized)
        XCTAssertEqual(speed.maximumAttempt?.bpm, 96)
    }

    func testSpeedSummariesRemainIndependentForAllThreeHands() throws {
        let base = Date(timeIntervalSinceReferenceDate: 14_000)
        func sample(
            _ hand: PracticeHand,
            _ bpm: Int,
            _ seconds: TimeInterval
        ) -> PracticeCompletionSample {
            var preset = MetronomePreset.standard
            preset.bpm = bpm
            return PracticeCompletionSample(
                hand: hand,
                preset: preset,
                completedAt: base.addingTimeInterval(seconds)
            )
        }

        let samples = [
            sample(.left, 72, 1), sample(.left, 72, 2), sample(.left, 200, 3),
            sample(.right, 100, 4), sample(.right, 120, 5), sample(.right, 120, 6),
            sample(.both, 50, 7), sample(.both, 40, 8)
        ]

        let left = PracticeHandSpeedSummary(samples: samples, for: .left)
        let right = PracticeHandSpeedSummary(samples: samples, for: .right)
        let both = PracticeHandSpeedSummary(samples: samples, for: .both)

        XCTAssertEqual(left.mostPracticed?.bpm, 72)
        XCTAssertEqual(left.maximumAttempt?.bpm, 200)
        XCTAssertEqual(right.mostPracticed?.bpm, 120)
        XCTAssertEqual(right.maximumAttempt?.bpm, 120)
        XCTAssertEqual(both.mostPracticed?.bpm, 40, "A frequency tie must use the latest completion")
        XCTAssertEqual(both.maximumAttempt?.bpm, 50)

        XCTAssertNil(PracticeHandSpeedSummary(samples: [], for: .both).mostPracticed)
        XCTAssertNil(PracticeHandSpeedSummary(samples: [], for: .both).maximumAttempt)
    }

    @MainActor
    func testPracticeAttemptCommitIsIdempotentAndSessionIDsStayUnique() throws {
        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let event = PracticeEvent(name: "肖邦练习曲", leftCount: 4)
        context.insert(event)
        try context.save()

        let start = Date(timeIntervalSinceReferenceDate: 15_000)
        var preset = MetronomePreset.standard
        preset.bpm = 116
        preset.beats = 5
        preset.grouping = "3+2"
        preset.subdivision = 2
        preset.referenceNote = .dottedQuarter

        var firstSession = PracticeSession()
        firstSession.begin(sourceEventID: event.id, at: start)
        _ = firstSession.recordCompletion(
            for: .left,
            preset: preset,
            at: start.addingTimeInterval(1)
        )
        let firstSummary = try XCTUnwrap(
            firstSession.finish(at: start.addingTimeInterval(2))
        )

        let firstCommit = try event.commit(summary: firstSummary, in: context)
        let replayedCommit = try event.commit(summary: firstSummary, in: context)

        XCTAssertEqual(firstCommit.disposition, .inserted)
        XCTAssertEqual(replayedCommit.disposition, .alreadyCommitted)
        XCTAssertEqual(firstCommit.attempt.id, replayedCommit.attempt.id)
        XCTAssertEqual(firstCommit.attempt.sessionID, firstSummary.sessionID)
        XCTAssertEqual(event.leftCount, 5, "A replay must not add the aggregate twice")
        XCTAssertEqual(try PracticeAttempt.history(for: event.id, in: context).count, 1)

        var secondPreset = preset
        secondPreset.bpm = 132
        secondPreset.subdivision = 4
        var secondSession = PracticeSession()
        secondSession.begin(sourceEventID: event.id, at: start.addingTimeInterval(10))
        _ = secondSession.recordCompletion(
            for: .right,
            preset: secondPreset,
            at: start.addingTimeInterval(11)
        )
        let secondSummary = try XCTUnwrap(
            secondSession.finish(at: start.addingTimeInterval(12))
        )
        let secondAttempt = try event.commit(
            summary: secondSummary,
            in: context
        ).attempt

        let history = try PracticeAttempt.history(for: event.id, in: context)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(Set(history.map(\.sessionID)).count, 2)
        XCTAssertTrue(history.contains { $0.id == firstCommit.attempt.id })
        XCTAssertTrue(history.contains { $0.id == secondAttempt.id })
        XCTAssertEqual(event.leftCount, 5)
        XCTAssertEqual(event.rightCount, 1)
    }

    @MainActor
    func testPracticeAttemptPersistsSnapshotsAndInheritsLatestPresetPerHand() throws {
        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let event = PracticeEvent(name: "音阶")
        context.insert(event)
        try context.save()

        var leftPreset = MetronomePreset.standard
        leftPreset.bpm = 91
        leftPreset.beats = 5
        leftPreset.grouping = "3+2"
        leftPreset.subdivision = 2
        leftPreset.direction = .clockwise
        leftPreset.referenceNote = .dottedEighth

        var bothPreset = MetronomePreset.standard
        bothPreset.bpm = 104
        bothPreset.beats = 7
        bothPreset.grouping = "2+3+2"
        bothPreset.subdivision = 4
        bothPreset.direction = .counterclockwise
        bothPreset.referenceNote = .dottedQuarter

        let start = Date(timeIntervalSinceReferenceDate: 16_000)
        var firstSession = PracticeSession()
        firstSession.begin(sourceEventID: event.id, at: start)
        _ = firstSession.recordCompletion(
            for: .left,
            preset: leftPreset,
            at: start.addingTimeInterval(1)
        )
        _ = firstSession.recordCompletion(
            for: .both,
            preset: bothPreset,
            at: start.addingTimeInterval(2)
        )
        let firstSummary = try XCTUnwrap(
            firstSession.finish(at: start.addingTimeInterval(3))
        )
        let firstAttempt = try event.commit(
            summary: firstSummary,
            in: context
        ).attempt

        var rightPreset = MetronomePreset.standard
        rightPreset.bpm = 150
        rightPreset.beats = 3
        rightPreset.subdivision = 0
        rightPreset.referenceNote = .half

        var secondSession = PracticeSession()
        secondSession.begin(
            sourceEventID: event.id,
            at: start.addingTimeInterval(10)
        )
        _ = secondSession.recordCompletion(
            for: .right,
            preset: rightPreset,
            at: start.addingTimeInterval(11)
        )
        let secondSummary = try XCTUnwrap(
            secondSession.finish(at: start.addingTimeInterval(12))
        )
        let secondAttempt = try event.commit(
            summary: secondSummary,
            in: context
        ).attempt

        XCTAssertEqual(firstAttempt.completions, firstSummary.completions)
        XCTAssertEqual(firstAttempt.mostPracticedPreset(for: .left), leftPreset.normalized)
        XCTAssertEqual(firstAttempt.mostPracticedPreset(for: .both), bothPreset.normalized)
        XCTAssertEqual(secondAttempt.mostPracticedPreset(for: .right), rightPreset.normalized)

        XCTAssertEqual(
            try PracticeAttempt.latest(for: event.id, hand: .left, in: context)?.id,
            firstAttempt.id,
            "A newer session for another hand must not hide the latest left-hand setting"
        )
        XCTAssertEqual(
            try event.inheritedPreset(for: .left, in: context),
            leftPreset.normalized
        )
        XCTAssertEqual(
            try event.inheritedPreset(for: .right, in: context),
            rightPreset.normalized
        )
        XCTAssertEqual(
            try event.inheritedPreset(for: .both, in: context),
            bothPreset.normalized
        )
    }

    @MainActor
    func testPracticeAttemptRejectsWrongEventAndCrossEventSessionReplay() throws {
        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let firstEvent = PracticeEvent(name: "第一首")
        let secondEvent = PracticeEvent(name: "第二首")
        context.insert(firstEvent)
        context.insert(secondEvent)
        try context.save()

        let start = Date(timeIntervalSinceReferenceDate: 17_000)
        var preset = MetronomePreset.standard
        preset.bpm = 126

        var linkedSession = PracticeSession()
        linkedSession.begin(sourceEventID: firstEvent.id, at: start)
        _ = linkedSession.recordCompletion(for: .both, preset: preset, at: start)
        let linkedSummary = try XCTUnwrap(linkedSession.finish(at: start))

        XCTAssertThrowsError(
            try secondEvent.commit(summary: linkedSummary, in: context)
        ) { error in
            XCTAssertEqual(
                error as? PracticeAttemptPersistenceError,
                .sourceEventMismatch
            )
        }

        let detachedSummary = PracticeSessionSummary(
            sessionID: UUID(),
            finishedAt: start.addingTimeInterval(1),
            both: HandPracticeStats(count: 1),
            completions: [
                PracticeCompletionSample(
                    hand: .both,
                    preset: preset,
                    completedAt: start.addingTimeInterval(1)
                )
            ]
        )
        _ = try firstEvent.commit(summary: detachedSummary, in: context)
        XCTAssertThrowsError(
            try secondEvent.commit(summary: detachedSummary, in: context)
        ) { error in
            XCTAssertEqual(
                error as? PracticeAttemptPersistenceError,
                .sessionAlreadyAssignedToAnotherEvent
            )
        }
    }

    @MainActor
    func testPracticeAttemptDeleteHistoryIsScopedToOneEvent() throws {
        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let firstEvent = PracticeEvent(name: "第一首")
        let secondEvent = PracticeEvent(name: "第二首")
        context.insert(firstEvent)
        context.insert(secondEvent)
        try context.save()

        let firstSummary = PracticeSessionSummary(
            sourceEventID: firstEvent.id,
            finishedAt: Date(timeIntervalSinceReferenceDate: 18_000),
            left: HandPracticeStats(count: 1)
        )
        let secondSummary = PracticeSessionSummary(
            sourceEventID: secondEvent.id,
            finishedAt: Date(timeIntervalSinceReferenceDate: 18_001),
            right: HandPracticeStats(count: 1)
        )
        let firstAttempt = try firstEvent.commit(
            summary: firstSummary,
            in: context
        ).attempt
        let secondAttempt = try secondEvent.commit(
            summary: secondSummary,
            in: context
        ).attempt

        try PracticeAttempt.deleteHistory(for: firstEvent.id, in: context)
        try context.save()

        XCTAssertTrue(try PracticeAttempt.history(for: firstEvent.id, in: context).isEmpty)
        XCTAssertEqual(
            try PracticeAttempt.history(for: secondEvent.id, in: context).map(\.id),
            [secondAttempt.id]
        )
        XCTAssertNil(try PracticeAttempt.find(sessionID: firstAttempt.sessionID, in: context))
        XCTAssertEqual(
            try PracticeAttempt.find(sessionID: secondAttempt.sessionID, in: context)?.id,
            secondAttempt.id
        )
    }

    @MainActor
    func testPracticeAttemptHistoryBreaksEqualFinishTimeByNewestCreatedAt() throws {
        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let eventID = UUID()
        let finishedAt = Date(timeIntervalSinceReferenceDate: 18_250)
        let older = PracticeAttempt(
            eventID: eventID,
            summary: PracticeSessionSummary(
                sessionID: UUID(),
                finishedAt: finishedAt,
                left: HandPracticeStats(count: 1)
            ),
            createdAt: finishedAt.addingTimeInterval(1)
        )
        let newer = PracticeAttempt(
            eventID: eventID,
            summary: PracticeSessionSummary(
                sessionID: UUID(),
                finishedAt: finishedAt,
                right: HandPracticeStats(count: 1)
            ),
            createdAt: finishedAt.addingTimeInterval(2)
        )
        context.insert(older)
        context.insert(newer)
        try context.save()

        XCTAssertEqual(
            try PracticeAttempt.history(for: eventID, in: context).map(\.id),
            [newer.id, older.id]
        )
    }

    @MainActor
    func testPracticeAttemptCommitFailureRestoresEveryLiveAggregateField() throws {
        enum ForcedSaveError: Error {
            case failed
        }

        let container = try makeInMemoryPracticeContainer()
        let context = container.mainContext
        let originalUpdate = Date(timeIntervalSinceReferenceDate: 18_500)
        let event = PracticeEvent(
            name: "回滚测试",
            leftCount: 2,
            rightCount: 3,
            bothCount: 4,
            leftDurationMilliseconds: 500,
            rightDurationMilliseconds: 600,
            bothDurationMilliseconds: 700,
            updatedAt: originalUpdate
        )
        context.insert(event)
        try context.save()
        let originalAggregate = event.aggregateSnapshot()

        let summary = PracticeSessionSummary(
            sourceEventID: event.id,
            finishedAt: Date(timeIntervalSinceReferenceDate: 19_000),
            left: HandPracticeStats(count: 3, durationMilliseconds: 2_000),
            right: HandPracticeStats(count: 4, durationMilliseconds: 3_000),
            both: HandPracticeStats(count: 5, durationMilliseconds: 4_000)
        )
        XCTAssertThrowsError(
            try event.commit(summary: summary, in: context) {
                throw ForcedSaveError.failed
            }
        ) { error in
            XCTAssertTrue(error is ForcedSaveError)
        }

        XCTAssertEqual(event.aggregateSnapshot(), originalAggregate)
        XCTAssertEqual(event.updatedAt, originalUpdate)
        XCTAssertNil(try PracticeAttempt.find(sessionID: summary.sessionID, in: context))
        XCTAssertTrue(try PracticeAttempt.history(for: event.id, in: context).isEmpty)
    }

    @MainActor
    func testLegacySingleEntityStoreMigratesAdditivelyToAttemptHistorySchema() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeoPracticeMigrationTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("GeoPractice.store")
        let eventID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 20_000)

        do {
            let legacySchema = Schema([PracticeEvent.self])
            let legacyConfiguration = ModelConfiguration(
                "GeoPractice",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [legacyConfiguration]
            )
            let legacyEvent = PracticeEvent(
                id: eventID,
                name: "升级前记录",
                leftCount: 7,
                rightCount: 5,
                bothCount: 3,
                leftDurationMilliseconds: 1_000,
                rightDurationMilliseconds: 2_000,
                bothDurationMilliseconds: 3_000,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            legacyContainer.mainContext.insert(legacyEvent)
            try legacyContainer.mainContext.save()
        }

        let currentSchema = Schema([
            PracticeEvent.self,
            PracticeAttempt.self
        ])
        let currentConfiguration = ModelConfiguration(
            "GeoPractice",
            schema: currentSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let currentContainer = try ModelContainer(
            for: currentSchema,
            configurations: [currentConfiguration]
        )
        let context = currentContainer.mainContext
        let restoredEvents = try context.fetch(FetchDescriptor<PracticeEvent>())
        let restored = try XCTUnwrap(restoredEvents.first { $0.id == eventID })

        XCTAssertEqual(restored.name, "升级前记录")
        XCTAssertEqual(restored.leftCount, 7)
        XCTAssertEqual(restored.rightCount, 5)
        XCTAssertEqual(restored.bothCount, 3)
        XCTAssertEqual(restored.totalDurationMilliseconds, 6_000)
        XCTAssertTrue(try PracticeAttempt.history(for: eventID, in: context).isEmpty)

        var preset = MetronomePreset.standard
        preset.bpm = 138
        preset.referenceNote = .dottedQuarter
        preset.subdivision = 4
        let summary = PracticeSessionSummary(
            sourceEventID: eventID,
            finishedAt: createdAt.addingTimeInterval(10),
            both: HandPracticeStats(count: 1),
            completions: [
                PracticeCompletionSample(
                    hand: .both,
                    preset: preset,
                    completedAt: createdAt.addingTimeInterval(10)
                )
            ]
        )
        _ = try restored.commit(summary: summary, in: context)

        XCTAssertEqual(restored.bothCount, 4)
        XCTAssertEqual(
            try PracticeAttempt.history(for: eventID, in: context).count,
            1
        )
        XCTAssertEqual(
            try restored.inheritedPreset(for: .both, in: context),
            preset.normalized
        )
    }

    @MainActor
    private func makeInMemoryPracticeContainer() throws -> ModelContainer {
        let schema = Schema([
            PracticeEvent.self,
            PracticeAttempt.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}
