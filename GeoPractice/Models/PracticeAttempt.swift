import Foundation
import SwiftData

/// One immutable, user-confirmed practice result.
///
/// `sessionID` is unique so replaying a save after a crash or an uncertain
/// response returns the committed attempt instead of adding the totals twice.
@Model
final class PracticeAttempt {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var sessionID: UUID
    var eventID: UUID
    /// Explicit planned-practice provenance; nil legacy attempts are not inferred.
    var coreContextData: Data?
    /// The event name at the moment this result was confirmed.
    ///
    /// This is optional so stores created before time-based statistics can be
    /// migrated additively. Callers presenting an older attempt should resolve
    /// the missing value from its current `PracticeEvent` name.
    var eventNameSnapshot: String?
    var startedAt: Date
    var finishedAt: Date
    var createdAt: Date
    var dailyGoalKey: String?

    var leftCount: Int
    var rightCount: Int
    var bothCount: Int
    var leftDurationMilliseconds: Int64
    var rightDurationMilliseconds: Int64
    var bothDurationMilliseconds: Int64

    var leftMostPracticedBPM: Int?
    var rightMostPracticedBPM: Int?
    var bothMostPracticedBPM: Int?
    var leftMaximumAttemptBPM: Int?
    var rightMaximumAttemptBPM: Int?
    var bothMaximumAttemptBPM: Int?

    private var leftMostPracticedData: Data?
    private var rightMostPracticedData: Data?
    private var bothMostPracticedData: Data?
    private var leftMaximumAttemptData: Data?
    private var rightMaximumAttemptData: Data?
    private var bothMaximumAttemptData: Data?
    private var completionSamplesData: Data?
    private var leftSessionPresetData: Data?
    private var rightSessionPresetData: Data?
    private var bothSessionPresetData: Data?
    private var goalLaunchContextData: Data?
    private var goalReportData: Data?

    init(
        id: UUID = UUID(),
        eventID: UUID,
        eventNameSnapshot: String? = nil,
        summary: PracticeSessionSummary,
        createdAt: Date = .now
    ) {
        self.id = id
        sessionID = summary.sessionID
        self.eventID = eventID
        self.eventNameSnapshot = eventNameSnapshot
        self.createdAt = createdAt
        startedAt = summary.startedAt ?? summary.finishedAt ?? createdAt
        finishedAt = summary.finishedAt ?? createdAt
        dailyGoalKey = summary.goalLaunchContext?.dailyGoalKey

        leftCount = summary.left.count
        rightCount = summary.right.count
        bothCount = summary.both.count
        leftDurationMilliseconds = summary.left.durationMilliseconds
        rightDurationMilliseconds = summary.right.durationMilliseconds
        bothDurationMilliseconds = summary.both.durationMilliseconds

        let leftSpeed = summary.speedSummary(for: .left)
        let rightSpeed = summary.speedSummary(for: .right)
        let bothSpeed = summary.speedSummary(for: .both)

        leftMostPracticedBPM = leftSpeed.mostPracticed?.bpm
        rightMostPracticedBPM = rightSpeed.mostPracticed?.bpm
        bothMostPracticedBPM = bothSpeed.mostPracticed?.bpm
        leftMaximumAttemptBPM = leftSpeed.maximumAttempt?.bpm
        rightMaximumAttemptBPM = rightSpeed.maximumAttempt?.bpm
        bothMaximumAttemptBPM = bothSpeed.maximumAttempt?.bpm

        leftMostPracticedData = Self.encode(leftSpeed.mostPracticed)
        rightMostPracticedData = Self.encode(rightSpeed.mostPracticed)
        bothMostPracticedData = Self.encode(bothSpeed.mostPracticed)
        leftMaximumAttemptData = Self.encode(leftSpeed.maximumAttempt)
        rightMaximumAttemptData = Self.encode(rightSpeed.maximumAttempt)
        bothMaximumAttemptData = Self.encode(bothSpeed.maximumAttempt)
        completionSamplesData = Self.encode(summary.completions)
        leftSessionPresetData = Self.encode(summary.leftPreset)
        rightSessionPresetData = Self.encode(summary.rightPreset)
        bothSessionPresetData = Self.encode(summary.bothPreset)
        goalLaunchContextData = Self.encode(summary.goalLaunchContext)
        goalReportData = Self.encode(summary.goalReport)
    }

    var recordedAt: Date { createdAt }

    /// Resolves the historical name while keeping pre-statistics attempts
    /// readable. New attempts always return their immutable saved name.
    func resolvedEventName(fallback: String) -> String {
        if let eventNameSnapshot,
           !eventNameSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return eventNameSnapshot
        }
        if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return "未命名练习"
    }

    /// Pure value consumed by `PracticeStatisticsEngine`.
    ///
    /// The no-argument form is safe when an event has already been deleted.
    /// Statistics screens that also fetched `PracticeEvent` should call
    /// `makeStatisticsSnapshot(eventNameFallback:)` so pre-statistics records
    /// can display the current event name.
    var statisticsSnapshot: PracticeHistoryRecordSnapshot {
        makeStatisticsSnapshot(eventNameFallback: "未命名练习")
    }

    func makeStatisticsSnapshot(
        eventNameFallback: String
    ) -> PracticeHistoryRecordSnapshot {
        let leftPreset = statisticsPreset(for: .left)
        let rightPreset = statisticsPreset(for: .right)
        let bothPreset = statisticsPreset(for: .both)
        let latestPreset = completions.enumerated().max { lhs, rhs in
            if lhs.element.completedAt != rhs.element.completedAt {
                return lhs.element.completedAt < rhs.element.completedAt
            }
            return lhs.offset < rhs.offset
        }?.element.preset.normalized

        return PracticeHistoryRecordSnapshot(
            id: id,
            sourceEventID: eventID,
            eventNameSnapshot: resolvedEventName(fallback: eventNameFallback),
            startedAt: startedAt,
            finishedAt: finishedAt,
            leftCount: leftCount,
            rightCount: rightCount,
            bothCount: bothCount,
            leftDurationMilliseconds: leftDurationMilliseconds,
            rightDurationMilliseconds: rightDurationMilliseconds,
            bothDurationMilliseconds: bothDurationMilliseconds,
            bpm: latestPreset?.bpm,
            beats: latestPreset?.beats,
            subdivision: latestPreset?.subdivision,
            directionRawValue: latestPreset?.direction.rawValue,
            grouping: latestPreset?.grouping,
            referenceNoteRaw: latestPreset?.referenceNoteRaw,
            leftPreset: leftPreset,
            rightPreset: rightPreset,
            bothPreset: bothPreset,
            sessionID: sessionID,
            completionSamples: completions
        )
    }

    var completions: [PracticeCompletionSample] {
        Self.decode([PracticeCompletionSample].self, from: completionSamplesData) ?? []
    }

    /// The final live setting for a hand is independent from completion
    /// samples: timed practice remains meaningful even when no `+1` was
    /// recorded during the session.
    func sessionPreset(for hand: PracticeHand) -> MetronomePreset? {
        let data: Data?
        switch hand {
        case .left: data = leftSessionPresetData
        case .right: data = rightSessionPresetData
        case .both: data = bothSessionPresetData
        }
        return Self.decode(MetronomePreset.self, from: data)?.normalized
    }

    var goalLaunchContext: PracticeGoalLaunchContext? {
        Self.decode(
            PracticeGoalLaunchContext.self,
            from: goalLaunchContextData
        )
    }

    var goalReport: PracticeGoalReportSnapshot? {
        Self.decode(
            PracticeGoalReportSnapshot.self,
            from: goalReportData
        )
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left:
            HandPracticeStats(
                count: leftCount,
                durationMilliseconds: leftDurationMilliseconds
            )
        case .right:
            HandPracticeStats(
                count: rightCount,
                durationMilliseconds: rightDurationMilliseconds
            )
        case .both:
            HandPracticeStats(
                count: bothCount,
                durationMilliseconds: bothDurationMilliseconds
            )
        }
    }

    func speedSummary(for hand: PracticeHand) -> PracticeHandSpeedSummary {
        let mostPracticedData: Data?
        let maximumAttemptData: Data?
        switch hand {
        case .left:
            mostPracticedData = leftMostPracticedData
            maximumAttemptData = leftMaximumAttemptData
        case .right:
            mostPracticedData = rightMostPracticedData
            maximumAttemptData = rightMaximumAttemptData
        case .both:
            mostPracticedData = bothMostPracticedData
            maximumAttemptData = bothMaximumAttemptData
        }
        return PracticeHandSpeedSummary(
            mostPracticed: Self.decode(
                PracticeSpeedRecord.self,
                from: mostPracticedData
            ),
            maximumAttempt: Self.decode(
                PracticeSpeedRecord.self,
                from: maximumAttemptData
            )
        )
    }

    func mostPracticedPreset(for hand: PracticeHand) -> MetronomePreset? {
        speedSummary(for: hand).mostPracticed?.preset
    }

    /// Applies a user-confirmed history edit to the persisted attempt.
    ///
    /// Existing real completion samples are retained whenever possible. A
    /// user-entered count increase is stored as an aggregate manual backfill,
    /// never as a fabricated live tap timeline. Moving a single-hand record
    /// to another hand keeps its real timestamps and configuration.
    func applyHistoryEdit(_ edit: PracticeHistoryRecordEditDraft) {
        let oldFinishedAt = finishedAt
        let timeShift = edit.finishedAt.timeIntervalSince(oldFinishedAt)
        let originalSamples = completions
        let oldPopulatedHands = PracticeHand.controlOrder.filter { hand in
            let value = stats(for: hand)
            return value.count > 0
                || value.durationMilliseconds > 0
                || statisticsPreset(for: hand) != nil
        }
        let newPopulatedHands = edit.populatedHands
        let movedPair: (source: PracticeHand, destination: PracticeHand)?
        if oldPopulatedHands.count == 1,
           newPopulatedHands.count == 1,
           oldPopulatedHands[0] != newPopulatedHands[0] {
            movedPair = (oldPopulatedHands[0], newPopulatedHands[0])
        } else {
            movedPair = nil
        }

        var editedSamples: [PracticeCompletionSample] = []
        var speeds: [PracticeHand: PracticeHandSpeedSummary] = [:]
        var sessionPresets: [PracticeHand: MetronomePreset] = [:]

        for hand in PracticeHand.controlOrder {
            let target = edit.value(for: hand)
            let sourceHand = movedPair?.destination == hand
                ? movedPair?.source ?? hand
                : hand
            let oldStats = stats(for: sourceHand)
            let oldPreset = statisticsPreset(for: sourceHand)
            let targetPreset = target.preset?.normalized
            if let targetPreset, target.hasRecordedData {
                sessionPresets[hand] = targetPreset
            }
            let configurationChanged = targetPreset != oldPreset
            let handChanged = sourceHand != hand
            let sourceSamples = originalSamples
                .filter { $0.hand == sourceHand }
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.completedAt != rhs.element.completedAt {
                        return lhs.element.completedAt < rhs.element.completedAt
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)

            let retainedCount = min(max(0, target.count), sourceSamples.count)
            for sample in sourceSamples.prefix(retainedCount) {
                if timeShift == 0, !configurationChanged, !handChanged {
                    editedSamples.append(sample)
                    continue
                }
                let shiftedTime = sample.completedAt.addingTimeInterval(timeShift)
                let boundedTime = min(
                    edit.finishedAt,
                    max(edit.startedAt, shiftedTime)
                )
                editedSamples.append(
                    PracticeCompletionSample(
                        id: sample.id,
                        hand: hand,
                        preset: targetPreset ?? sample.preset,
                        completedAt: boundedTime,
                        source: sample.source
                    )
                )
            }

            // The part of a legacy aggregate that had no samples remains an
            // aggregate. Only a count newly added by this edit receives
            // explicit manual-backfill provenance.
            let addedCount = max(0, target.count - oldStats.count)
            if addedCount > 0, let targetPreset {
                editedSamples.append(contentsOf: PracticeCompletionSample.manualBackfillBatch(
                    hand: hand,
                    preset: targetPreset,
                    count: addedCount,
                    completedAt: edit.finishedAt
                ))
            }

            let countChanged = target.count != oldStats.count
            if target.count <= 0 {
                speeds[hand] = PracticeHandSpeedSummary()
            } else if configurationChanged || countChanged {
                if let targetPreset {
                    let record = PracticeSpeedRecord(
                        preset: targetPreset,
                        completionCount: target.count,
                        lastCompletedAt: edit.finishedAt
                    )
                    speeds[hand] = PracticeHandSpeedSummary(
                        mostPracticed: record,
                        maximumAttempt: record
                    )
                } else {
                    speeds[hand] = PracticeHandSpeedSummary()
                }
            } else {
                speeds[hand] = Self.shifted(
                    speedSummary(for: sourceHand),
                    by: timeShift
                )
            }
        }

        editedSamples.sort { lhs, rhs in
            if lhs.completedAt != rhs.completedAt {
                return lhs.completedAt < rhs.completedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let counts = PracticeGoalCounts(
            left: edit.value(for: .left).count,
            right: edit.value(for: .right).count,
            both: edit.value(for: .both).count
        )
        let revisedLaunchContext = goalLaunchContext.map { context in
            let localDay = PracticeDailyGoal.localDay(
                containing: edit.finishedAt,
                timeZone: context.timeZone
            )
            let key = context.dailyGoalKey.map { _ in
                PracticeDailyGoal.makeKey(
                    eventID: eventID,
                    planID: context.plan?.id,
                    localDay: localDay
                )
            }
            return PracticeGoalLaunchContext(
                eventID: context.eventID,
                launchedAt: context.launchedAt.addingTimeInterval(timeShift),
                localDay: localDay,
                timeZoneIdentifier: context.timeZoneIdentifier,
                timeZoneSecondsFromGMT: context.timeZoneSecondsFromGMT,
                dailyGoalKey: key,
                dailyTargets: context.dailyTargets,
                dailyCompletedBeforeSession: context.dailyCompletedBeforeSession,
                plan: context.plan,
                planCompletedBeforeSession: context.planCompletedBeforeSession
            )
        }
        let revisedGoalReport = revisedLaunchContext.map {
            PracticeGoalReportSnapshot(
                launchContext: $0,
                sessionCompleted: counts,
                generatedAt: edit.finishedAt
            )
        }

        replacePersistedStateForRestore(
            id: id,
            sessionID: sessionID,
            eventID: eventID,
            eventNameSnapshot: eventNameSnapshot,
            startedAt: edit.startedAt,
            finishedAt: edit.finishedAt,
            createdAt: createdAt,
            dailyGoalKey: revisedLaunchContext?.dailyGoalKey ?? dailyGoalKey,
            left: HandPracticeStats(
                count: edit.value(for: .left).count,
                durationMilliseconds: edit.value(for: .left).durationMilliseconds
            ),
            right: HandPracticeStats(
                count: edit.value(for: .right).count,
                durationMilliseconds: edit.value(for: .right).durationMilliseconds
            ),
            both: HandPracticeStats(
                count: edit.value(for: .both).count,
                durationMilliseconds: edit.value(for: .both).durationMilliseconds
            ),
            completions: editedSamples,
            leftSpeed: speeds[.left] ?? PracticeHandSpeedSummary(),
            rightSpeed: speeds[.right] ?? PracticeHandSpeedSummary(),
            bothSpeed: speeds[.both] ?? PracticeHandSpeedSummary(),
            goalLaunchContext: revisedLaunchContext,
            goalReport: revisedGoalReport,
            leftSessionPreset: sessionPresets[.left],
            rightSessionPreset: sessionPresets[.right],
            bothSessionPreset: sessionPresets[.both]
        )
    }

    /// Edits one real completion without rewriting neighboring `+1` rows.
    /// Counts move with the completion when its hand changes; durations remain
    /// session-level because no truthful per-completion duration exists.
    @discardableResult
    func applyHistoryCompletionEdit(
        _ edit: PracticeHistoryCompletionEditDraft
    ) -> Bool {
        var samples = completions
        guard let index = samples.firstIndex(where: { $0.id == edit.id }) else {
            return false
        }
        let oldSample = samples[index]
        let replacement = PracticeCompletionSample(
            id: oldSample.id,
            hand: edit.hand,
            preset: edit.preset.normalized,
            completedAt: edit.completedAt,
            source: oldSample.source
        )
        samples[index] = replacement

        var statsByHand = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.map {
                ($0, stats(for: $0))
            }
        )
        if oldSample.hand != edit.hand {
            let oldStats = statsByHand[oldSample.hand] ?? HandPracticeStats()
            statsByHand[oldSample.hand] = HandPracticeStats(
                count: max(0, oldStats.count - 1),
                durationMilliseconds: oldStats.durationMilliseconds
            )
            let newStats = statsByHand[edit.hand] ?? HandPracticeStats()
            let (incremented, overflowed) = newStats.count.addingReportingOverflow(1)
            statsByHand[edit.hand] = HandPracticeStats(
                count: overflowed ? Int.max : incremented,
                durationMilliseconds: newStats.durationMilliseconds
            )
        }
        var fallbackPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                statisticsPreset(for: hand).map { (hand, $0) }
            }
        )
        fallbackPresets[edit.hand] = edit.preset.normalized
        var sessionPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                sessionPreset(for: hand).map { (hand, $0) }
            }
        )
        sessionPresets[edit.hand] = edit.preset.normalized
        let revisedStartedAt = min(startedAt, edit.completedAt)
        let revisedFinishedAt = max(finishedAt, edit.completedAt)
        replaceHistoryDetails(
            startedAt: revisedStartedAt,
            finishedAt: revisedFinishedAt,
            statsByHand: statsByHand,
            samples: samples,
            fallbackPresets: fallbackPresets,
            sessionPresets: sessionPresets
        )
        return true
    }

    /// Removes one persisted completion. The caller decides whether an empty,
    /// zero-duration attempt should then be deleted as a whole.
    @discardableResult
    func removeHistoryCompletion(id completionID: UUID) -> Bool {
        var samples = completions
        guard let index = samples.firstIndex(where: { $0.id == completionID }) else {
            return false
        }
        let removed = samples.remove(at: index)
        var statsByHand = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.map {
                ($0, stats(for: $0))
            }
        )
        let oldStats = statsByHand[removed.hand] ?? HandPracticeStats()
        statsByHand[removed.hand] = HandPracticeStats(
            count: max(0, oldStats.count - 1),
            durationMilliseconds: oldStats.durationMilliseconds
        )
        let fallbackPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                statisticsPreset(for: hand).map { (hand, $0) }
            }
        )
        let sessionPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                sessionPreset(for: hand).map { (hand, $0) }
            }
        )
        replaceHistoryDetails(
            startedAt: startedAt,
            finishedAt: finishedAt,
            statsByHand: statsByHand,
            samples: samples,
            fallbackPresets: fallbackPresets,
            sessionPresets: sessionPresets
        )
        return true
    }

    /// Updates one unitemized row without rewriting neighboring live samples.
    /// Exact manual-batch members are addressed by UUID. A legacy residual has
    /// no UUIDs, so only the count left after persisted samples is reconciled.
    @discardableResult
    func applyHistoryUnitemizedEdit(
        _ edit: PracticeHistoryUnitemizedEditDraft
    ) -> Bool {
        if !edit.completionIDs.isEmpty {
            return applyHistorySampleBatchEdit(edit)
        }
        return applyHistoryResidualEdit(edit)
    }

    private func applyHistorySampleBatchEdit(
        _ edit: PracticeHistoryUnitemizedEditDraft
    ) -> Bool {
        let targetIDs = Set(edit.completionIDs)
        let originalSamples = completions
        let matched = originalSamples
            .filter { targetIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.completedAt != rhs.completedAt {
                    return lhs.completedAt < rhs.completedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard matched.count == targetIDs.count,
              matched.count == edit.originalCount,
              matched.allSatisfy({ $0.hand == edit.originalHand }),
              let targetPreset = edit.preset?.normalized
        else { return false }

        let currentSnapshot = statisticsSnapshot
        let trulyWholeRecord = targetIDs == Set(originalSamples.map(\.id))
            && matched.count == currentSnapshot.totalCount
        if trulyWholeRecord {
            var whole = PracticeHistoryRecordEditDraft(record: currentSnapshot)
            if edit.hand != edit.originalHand {
                whole.moveSingleHand(from: edit.originalHand, to: edit.hand)
            }
            whole.update(hand: edit.hand) {
                $0.count = max(0, edit.count)
                $0.preset = targetPreset
                if let duration = edit.durationMilliseconds {
                    $0.durationMilliseconds = max(0, duration)
                }
            }
            if let completedAt = edit.completedAt {
                whole.move(to: completedAt)
            }
            applyHistoryEdit(whole)
            // A pre-provenance backfill decodes as `.live` for compatibility.
            // Once the user edits its aggregate row, persist the now-known
            // provenance explicitly so it never turns into numbered `+1` rows.
            completionSamplesData = Self.encode(completions.map { sample in
                PracticeCompletionSample(
                    id: sample.id,
                    hand: sample.hand,
                    preset: sample.preset,
                    completedAt: sample.completedAt,
                    source: .manualBackfill
                )
            })
            return true
        }

        var samples = originalSamples.filter { !targetIDs.contains($0.id) }
        let targetCount = max(0, edit.count)
        let retainedCount = min(targetCount, matched.count)
        let batchTime = edit.completedAt ?? matched.last?.completedAt ?? finishedAt
        for sample in matched.prefix(retainedCount) {
            samples.append(
                PracticeCompletionSample(
                    id: sample.id,
                    hand: edit.hand,
                    preset: targetPreset,
                    completedAt: batchTime,
                    source: .manualBackfill
                )
            )
        }
        if targetCount > retainedCount {
            samples.append(contentsOf: PracticeCompletionSample.manualBackfillBatch(
                hand: edit.hand,
                preset: targetPreset,
                count: targetCount - retainedCount,
                completedAt: batchTime
            ))
        }
        samples.sort { lhs, rhs in
            if lhs.completedAt != rhs.completedAt {
                return lhs.completedAt < rhs.completedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var statsByHand = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.map {
                ($0, stats(for: $0))
            }
        )
        let sourceStats = statsByHand[edit.originalHand] ?? HandPracticeStats()
        statsByHand[edit.originalHand] = HandPracticeStats(
            count: max(0, sourceStats.count - matched.count),
            durationMilliseconds: sourceStats.durationMilliseconds
        )
        let destinationStats = statsByHand[edit.hand] ?? HandPracticeStats()
        let destinationBase = edit.hand == edit.originalHand
            ? max(0, sourceStats.count - matched.count)
            : destinationStats.count
        statsByHand[edit.hand] = HandPracticeStats(
            count: Self.saturatedCount(destinationBase, adding: targetCount),
            durationMilliseconds: destinationStats.durationMilliseconds
        )

        var fallbackPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                statisticsPreset(for: hand).map { (hand, $0) }
            }
        )
        fallbackPresets[edit.hand] = targetPreset
        var sessionPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                sessionPreset(for: hand).map { (hand, $0) }
            }
        )
        sessionPresets[edit.hand] = targetPreset

        replaceHistoryDetails(
            startedAt: min(startedAt, batchTime),
            finishedAt: max(finishedAt, batchTime),
            statsByHand: statsByHand,
            samples: samples,
            fallbackPresets: fallbackPresets,
            sessionPresets: sessionPresets
        )
        return true
    }

    private func applyHistoryResidualEdit(
        _ edit: PracticeHistoryUnitemizedEditDraft
    ) -> Bool {
        let samples = completions
        let sampledCounts = Dictionary(grouping: samples, by: \.hand).mapValues(\.count)
        let sourceStats = stats(for: edit.originalHand)
        let sourceSampleCount = sampledCounts[edit.originalHand] ?? 0
        let sourceResidualCount = max(0, sourceStats.count - sourceSampleCount)
        guard sourceResidualCount == edit.originalCount else { return false }

        let targetCount = max(0, edit.count)
        let targetPreset = edit.preset?.normalized
        if edit.hand != edit.originalHand {
            let destinationStats = stats(for: edit.hand)
            let destinationResidualCount = max(
                0,
                destinationStats.count - (sampledCounts[edit.hand] ?? 0)
            )
            if destinationResidualCount > 0,
               let existingPreset = statisticsPreset(for: edit.hand),
               existingPreset.normalized != targetPreset {
                return false
            }
        }

        var statsByHand = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.map {
                ($0, stats(for: $0))
            }
        )
        let sourceDurationMoves = edit.hand != edit.originalHand
            && sourceSampleCount == 0
            && sourceResidualCount == sourceStats.count
        statsByHand[edit.originalHand] = HandPracticeStats(
            count: max(0, sourceStats.count - sourceResidualCount),
            durationMilliseconds: sourceDurationMoves
                ? 0
                : sourceStats.durationMilliseconds
        )
        let destinationStats = statsByHand[edit.hand] ?? HandPracticeStats()
        let destinationBase = edit.hand == edit.originalHand
            ? max(0, sourceStats.count - sourceResidualCount)
            : destinationStats.count
        statsByHand[edit.hand] = HandPracticeStats(
            count: Self.saturatedCount(destinationBase, adding: targetCount),
            durationMilliseconds: sourceDurationMoves
                ? Self.saturatedDuration(
                    destinationStats.durationMilliseconds,
                    adding: sourceStats.durationMilliseconds
                )
                : destinationStats.durationMilliseconds
        )

        var fallbackPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                statisticsPreset(for: hand).map { (hand, $0) }
            }
        )
        if sourceResidualCount == sourceStats.count, sourceSampleCount == 0 {
            fallbackPresets[edit.originalHand] = nil
        }
        if targetCount > 0 {
            fallbackPresets[edit.hand] = targetPreset
        }
        var sessionPresets = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.compactMap { hand in
                sessionPreset(for: hand).map { (hand, $0) }
            }
        )
        if sourceDurationMoves {
            sessionPresets[edit.originalHand] = nil
        }
        if targetCount > 0 {
            sessionPresets[edit.hand] = targetPreset
        }

        replaceHistoryDetails(
            startedAt: startedAt,
            finishedAt: finishedAt,
            statsByHand: statsByHand,
            samples: samples,
            fallbackPresets: fallbackPresets,
            sessionPresets: sessionPresets
        )
        return true
    }

    private static func saturatedCount(_ value: Int, adding added: Int) -> Int {
        let (sum, overflowed) = max(0, value).addingReportingOverflow(max(0, added))
        return overflowed ? Int.max : sum
    }

    private static func saturatedDuration(
        _ value: Int64,
        adding added: Int64
    ) -> Int64 {
        let (sum, overflowed) = max(0, value).addingReportingOverflow(max(0, added))
        return overflowed ? Int64.max : sum
    }

    private func statisticsPreset(for hand: PracticeHand) -> MetronomePreset? {
        if let persisted = mostPracticedPreset(for: hand) {
            return persisted.normalized
        }

        // An additive-migration store may contain completion samples from
        // before the encoded speed summary existed. Derive the same
        // most-practiced rule instead of losing that hand's real setting.
        if let derived = PracticeHandSpeedSummary(samples: completions, for: hand)
            .mostPracticed?.preset.normalized {
            return derived
        }
        return sessionPreset(for: hand)
    }

    /// Replaces every persisted field when an existing attempt is reconciled
    /// with a library backup.
    ///
    /// Keeping this operation on the model prevents the backup DTO from
    /// reaching into the encoded payload fields directly. In particular, an
    /// in-place restore must replace the full completion, speed, and goal
    /// snapshots instead of only updating their scalar fallbacks.
    func replacePersistedStateForRestore(
        id: UUID,
        sessionID: UUID,
        eventID: UUID,
        eventNameSnapshot: String?,
        startedAt: Date,
        finishedAt: Date,
        createdAt: Date,
        dailyGoalKey: String?,
        left: HandPracticeStats,
        right: HandPracticeStats,
        both: HandPracticeStats,
        completions: [PracticeCompletionSample],
        leftSpeed: PracticeHandSpeedSummary,
        rightSpeed: PracticeHandSpeedSummary,
        bothSpeed: PracticeHandSpeedSummary,
        goalLaunchContext: PracticeGoalLaunchContext?,
        goalReport: PracticeGoalReportSnapshot?,
        leftSessionPreset: MetronomePreset? = nil,
        rightSessionPreset: MetronomePreset? = nil,
        bothSessionPreset: MetronomePreset? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.eventID = eventID
        self.eventNameSnapshot = eventNameSnapshot
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.createdAt = createdAt
        self.dailyGoalKey = dailyGoalKey

        leftCount = left.count
        rightCount = right.count
        bothCount = both.count
        leftDurationMilliseconds = left.durationMilliseconds
        rightDurationMilliseconds = right.durationMilliseconds
        bothDurationMilliseconds = both.durationMilliseconds

        leftMostPracticedBPM = leftSpeed.mostPracticed?.bpm
        rightMostPracticedBPM = rightSpeed.mostPracticed?.bpm
        bothMostPracticedBPM = bothSpeed.mostPracticed?.bpm
        leftMaximumAttemptBPM = leftSpeed.maximumAttempt?.bpm
        rightMaximumAttemptBPM = rightSpeed.maximumAttempt?.bpm
        bothMaximumAttemptBPM = bothSpeed.maximumAttempt?.bpm

        leftMostPracticedData = Self.encode(leftSpeed.mostPracticed)
        rightMostPracticedData = Self.encode(rightSpeed.mostPracticed)
        bothMostPracticedData = Self.encode(bothSpeed.mostPracticed)
        leftMaximumAttemptData = Self.encode(leftSpeed.maximumAttempt)
        rightMaximumAttemptData = Self.encode(rightSpeed.maximumAttempt)
        bothMaximumAttemptData = Self.encode(bothSpeed.maximumAttempt)
        completionSamplesData = Self.encode(completions)
        leftSessionPresetData = Self.encode(leftSessionPreset?.normalized)
        rightSessionPresetData = Self.encode(rightSessionPreset?.normalized)
        bothSessionPresetData = Self.encode(bothSessionPreset?.normalized)
        goalLaunchContextData = Self.encode(goalLaunchContext)
        goalReportData = Self.encode(goalReport)
    }

    static func find(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> PracticeAttempt? {
        let targetSessionID = sessionID
        var descriptor = FetchDescriptor<PracticeAttempt>(
            predicate: #Predicate { $0.sessionID == targetSessionID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func find(
        id: UUID,
        in context: ModelContext
    ) throws -> PracticeAttempt? {
        let targetID = id
        var descriptor = FetchDescriptor<PracticeAttempt>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func history(
        for eventID: UUID,
        in context: ModelContext
    ) throws -> [PracticeAttempt] {
        let targetEventID = eventID
        let descriptor = FetchDescriptor<PracticeAttempt>(
            predicate: #Predicate { $0.eventID == targetEventID },
            sortBy: [
                SortDescriptor(\PracticeAttempt.finishedAt, order: .reverse),
                SortDescriptor(\PracticeAttempt.createdAt, order: .reverse)
            ]
        )
        return try context.fetch(descriptor)
    }

    /// The newest result that completed at least one repetition for `hand`.
    static func latest(
        for eventID: UUID,
        hand: PracticeHand,
        in context: ModelContext
    ) throws -> PracticeAttempt? {
        try history(for: eventID, in: context).first {
            $0.speedSummary(for: hand).mostPracticed != nil
        }
    }

    static func latestMostPracticedPreset(
        for eventID: UUID,
        hand: PracticeHand,
        in context: ModelContext
    ) throws -> MetronomePreset? {
        try latest(for: eventID, hand: hand, in: context)?
            .mostPracticedPreset(for: hand)
    }

    static func goalProgressCounts(
        dailyGoalKey: String,
        eventID: UUID,
        in context: ModelContext
    ) throws -> PracticeGoalCounts {
        try history(for: eventID, in: context)
            .filter { $0.dailyGoalKey == dailyGoalKey }
            .reduce(PracticeGoalCounts()) { result, attempt in
                result.adding(PracticeGoalCounts(attempt: attempt))
            }
    }

    static func deleteHistory(for eventID: UUID, in context: ModelContext) throws {
        for attempt in try history(for: eventID, in: context) {
            context.delete(attempt)
        }
    }

    static func deleteAll(for eventID: UUID, in context: ModelContext) throws {
        try deleteHistory(for: eventID, in: context)
    }

    private static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func shifted(
        _ summary: PracticeHandSpeedSummary,
        by interval: TimeInterval
    ) -> PracticeHandSpeedSummary {
        func shiftedRecord(_ value: PracticeSpeedRecord?) -> PracticeSpeedRecord? {
            value.map {
                PracticeSpeedRecord(
                    preset: $0.preset,
                    completionCount: $0.completionCount,
                    lastCompletedAt: $0.lastCompletedAt.addingTimeInterval(interval)
                )
            }
        }
        return PracticeHandSpeedSummary(
            mostPracticed: shiftedRecord(summary.mostPracticed),
            maximumAttempt: shiftedRecord(summary.maximumAttempt)
        )
    }

    private func replaceHistoryDetails(
        startedAt revisedStartedAt: Date,
        finishedAt revisedFinishedAt: Date,
        statsByHand: [PracticeHand: HandPracticeStats],
        samples: [PracticeCompletionSample],
        fallbackPresets: [PracticeHand: MetronomePreset],
        sessionPresets: [PracticeHand: MetronomePreset]
    ) {
        let counts = PracticeGoalCounts(
            left: statsByHand[.left]?.count ?? 0,
            right: statsByHand[.right]?.count ?? 0,
            both: statsByHand[.both]?.count ?? 0
        )
        let revisedGoalReport = goalLaunchContext.map {
            PracticeGoalReportSnapshot(
                launchContext: $0,
                sessionCompleted: counts,
                generatedAt: revisedFinishedAt
            )
        }
        replacePersistedStateForRestore(
            id: id,
            sessionID: sessionID,
            eventID: eventID,
            eventNameSnapshot: eventNameSnapshot,
            startedAt: revisedStartedAt,
            finishedAt: revisedFinishedAt,
            createdAt: createdAt,
            dailyGoalKey: dailyGoalKey,
            left: statsByHand[.left] ?? HandPracticeStats(),
            right: statsByHand[.right] ?? HandPracticeStats(),
            both: statsByHand[.both] ?? HandPracticeStats(),
            completions: samples,
            leftSpeed: Self.reconciledSpeedSummary(
                hand: .left,
                count: statsByHand[.left]?.count ?? 0,
                samples: samples,
                fallback: fallbackPresets[.left],
                finishedAt: revisedFinishedAt
            ),
            rightSpeed: Self.reconciledSpeedSummary(
                hand: .right,
                count: statsByHand[.right]?.count ?? 0,
                samples: samples,
                fallback: fallbackPresets[.right],
                finishedAt: revisedFinishedAt
            ),
            bothSpeed: Self.reconciledSpeedSummary(
                hand: .both,
                count: statsByHand[.both]?.count ?? 0,
                samples: samples,
                fallback: fallbackPresets[.both],
                finishedAt: revisedFinishedAt
            ),
            goalLaunchContext: goalLaunchContext,
            goalReport: revisedGoalReport,
            leftSessionPreset: sessionPresets[.left],
            rightSessionPreset: sessionPresets[.right],
            bothSessionPreset: sessionPresets[.both]
        )
    }

    private static func reconciledSpeedSummary(
        hand: PracticeHand,
        count: Int,
        samples: [PracticeCompletionSample],
        fallback: MetronomePreset?,
        finishedAt: Date
    ) -> PracticeHandSpeedSummary {
        guard count > 0 else { return PracticeHandSpeedSummary() }
        let handSamples = samples.filter { $0.hand == hand }
        let derived = PracticeHandSpeedSummary(samples: handSamples, for: hand)
        let residualCount = max(0, count - handSamples.count)
        guard residualCount > 0, let fallback else { return derived }
        let residual = PracticeSpeedRecord(
            preset: fallback,
            completionCount: residualCount,
            lastCompletedAt: finishedAt
        )
        let mostPracticed: PracticeSpeedRecord
        if let sampled = derived.mostPracticed {
            if sampled.completionCount != residual.completionCount {
                mostPracticed = sampled.completionCount > residual.completionCount
                    ? sampled
                    : residual
            } else {
                mostPracticed = sampled.lastCompletedAt > residual.lastCompletedAt
                    ? sampled
                    : residual
            }
        } else {
            mostPracticed = residual
        }
        let maximumAttempt: PracticeSpeedRecord
        if let sampled = derived.maximumAttempt, sampled.bpm > residual.bpm {
            maximumAttempt = sampled
        } else {
            maximumAttempt = residual
        }
        return PracticeHandSpeedSummary(
            mostPracticed: mostPracticed,
            maximumAttempt: maximumAttempt
        )
    }
}
