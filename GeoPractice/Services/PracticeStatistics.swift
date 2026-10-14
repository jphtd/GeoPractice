import Foundation

enum PracticeRecordSource: String, Equatable, Sendable {
    case planned
    case independentGeoBeat

    var title: String {
        switch self {
        case .planned: "计划练习"
        case .independentGeoBeat: "独立节拍器练习"
        }
    }
}

struct PracticeHistoricalSpeedPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let completedAt: Date
    let hand: PracticeHand
    let bpm: Int
    let noteUnit: TempoReferenceNote
    let quarterEquivalentBPM: Double
    let recordSource: PracticeRecordSource
}

/// Immutable input consumed by the statistics engine.
///
/// Persisted models should be converted to this value before aggregation so
/// statistics stay independent from SwiftData and SwiftUI.
struct PracticeHistoryRecordSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceEventID: UUID?
    let eventNameSnapshot: String
    let startedAt: Date
    let finishedAt: Date

    let leftCount: Int
    let rightCount: Int
    let bothCount: Int
    let leftDurationMilliseconds: Int64
    let rightDurationMilliseconds: Int64
    let bothDurationMilliseconds: Int64

    let bpm: Int?
    let beats: Int?
    let subdivision: Int?
    let directionRawValue: String?
    let grouping: String?
    let referenceNoteRaw: String?
    /// Per-hand settings are additive so snapshots produced by older callers
    /// can continue to use the legacy, session-wide scalar fields above.
    let leftPreset: MetronomePreset?
    let rightPreset: MetronomePreset?
    let bothPreset: MetronomePreset?
    let sessionID: UUID?
    /// Immutable per-completion settings captured while this session ran.
    ///
    /// Older stores legitimately decode to an empty array. Callers must keep
    /// that distinction instead of manufacturing per-tap timestamps.
    let completionSamples: [PracticeCompletionSample]
    /// `nil` identifies legacy aggregate timing with no saved active intervals.
    let activeIntervals: [PracticeDurationInterval]?
    let recordSource: PracticeRecordSource?

    init(
        id: UUID,
        sourceEventID: UUID?,
        eventNameSnapshot: String,
        startedAt: Date,
        finishedAt: Date,
        leftCount: Int,
        rightCount: Int,
        bothCount: Int,
        leftDurationMilliseconds: Int64,
        rightDurationMilliseconds: Int64,
        bothDurationMilliseconds: Int64,
        bpm: Int? = nil,
        beats: Int? = nil,
        subdivision: Int? = nil,
        directionRawValue: String? = nil,
        grouping: String? = nil,
        referenceNoteRaw: String? = nil,
        leftPreset: MetronomePreset? = nil,
        rightPreset: MetronomePreset? = nil,
        bothPreset: MetronomePreset? = nil,
        sessionID: UUID? = nil,
        completionSamples: [PracticeCompletionSample] = [],
        activeIntervals: [PracticeDurationInterval]? = nil,
        recordSource: PracticeRecordSource? = nil
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.eventNameSnapshot = eventNameSnapshot
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.leftCount = leftCount
        self.rightCount = rightCount
        self.bothCount = bothCount
        self.leftDurationMilliseconds = leftDurationMilliseconds
        self.rightDurationMilliseconds = rightDurationMilliseconds
        self.bothDurationMilliseconds = bothDurationMilliseconds
        self.bpm = bpm
        self.beats = beats
        self.subdivision = subdivision
        self.directionRawValue = directionRawValue
        self.grouping = grouping
        self.referenceNoteRaw = referenceNoteRaw
        self.leftPreset = leftPreset?.normalized
        self.rightPreset = rightPreset?.normalized
        self.bothPreset = bothPreset?.normalized
        self.sessionID = sessionID
        self.completionSamples = completionSamples
        self.activeIntervals = activeIntervals
        self.recordSource = recordSource
    }

    var left: HandPracticeStats {
        HandPracticeStats(
            count: leftCount,
            durationMilliseconds: leftDurationMilliseconds
        )
    }

    var right: HandPracticeStats {
        HandPracticeStats(
            count: rightCount,
            durationMilliseconds: rightDurationMilliseconds
        )
    }

    var both: HandPracticeStats {
        HandPracticeStats(
            count: bothCount,
            durationMilliseconds: bothDurationMilliseconds
        )
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    /// Returns the setting actually represented by one hand's aggregate.
    ///
    /// The scalar fallback preserves snapshots created before per-hand presets
    /// were added; their former overall/latest-preset behavior remains intact.
    func preset(for hand: PracticeHand) -> MetronomePreset? {
        let handPreset: MetronomePreset?
        switch hand {
        case .left: handPreset = leftPreset
        case .right: handPreset = rightPreset
        case .both: handPreset = bothPreset
        }
        return handPreset ?? legacyOverallPreset
    }

    /// Returns real completion samples in deterministic chronological order.
    /// Passing `nil` keeps all hands; no synthetic samples are introduced for
    /// migration-era records that only contain aggregate counts.
    func completionSamples(for hand: PracticeHand? = nil) -> [PracticeCompletionSample] {
        completionSamples.enumerated()
            .filter { hand == nil || $0.element.hand == hand }
            .sorted { lhs, rhs in
                if lhs.element.completedAt != rhs.element.completedAt {
                    return lhs.element.completedAt < rhs.element.completedAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var legacyOverallPreset: MetronomePreset? {
        guard bpm != nil
                || beats != nil
                || subdivision != nil
                || directionRawValue != nil
                || grouping != nil
                || referenceNoteRaw != nil
        else { return nil }

        let standard = MetronomePreset.standard
        return MetronomePreset(
            bpm: bpm ?? standard.bpm,
            beats: beats ?? standard.beats,
            subdivision: subdivision ?? standard.subdivision,
            direction: directionRawValue.flatMap(RotationDirection.init(rawValue:))
                ?? standard.direction,
            grouping: grouping ?? standard.grouping,
            referenceNoteRaw: referenceNoteRaw
        ).normalized
    }

    var totalCount: Int {
        StatisticsMath.saturatedSum([
            max(0, leftCount),
            max(0, rightCount),
            max(0, bothCount)
        ])
    }

    var totalDurationMilliseconds: Int64 {
        StatisticsMath.saturatedSum([
            max(0, leftDurationMilliseconds),
            max(0, rightDurationMilliseconds),
            max(0, bothDurationMilliseconds)
        ])
    }
}

/// Editable aggregate for one hand inside a persisted history record.
///
/// A missing preset is meaningful for migration-era records. The editor keeps
/// it missing unless the user explicitly supplies a configuration, rather
/// than filling old history with the current metronome defaults.
struct PracticeHistoryHandEditDraft: Identifiable, Equatable, Sendable {
    let hand: PracticeHand
    var count: Int
    var durationMilliseconds: Int64
    var preset: MetronomePreset?

    var id: PracticeHand { hand }
    var hasRecordedData: Bool {
        count > 0 || durationMilliseconds > 0 || preset != nil
    }
}

/// A detached value edited by the history sheet. Nothing in SwiftData changes
/// until `PracticeLibraryStore.updateHistoryRecord(_:)` successfully saves it.
struct PracticeHistoryRecordEditDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let originalStartedAt: Date
    let originalFinishedAt: Date
    var startedAt: Date
    var finishedAt: Date
    var hands: [PracticeHistoryHandEditDraft]

    init(record: PracticeHistoryRecordSnapshot) {
        id = record.id
        originalStartedAt = record.startedAt
        originalFinishedAt = record.finishedAt
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        hands = PracticeHand.controlOrder.map { hand in
            let stats = record.stats(for: hand)
            return PracticeHistoryHandEditDraft(
                hand: hand,
                count: stats.count,
                durationMilliseconds: stats.durationMilliseconds,
                preset: stats.count > 0 || stats.durationMilliseconds > 0
                    ? record.preset(for: hand)
                    : nil
            )
        }
    }

    var populatedHands: [PracticeHand] {
        hands.filter(\.hasRecordedData).map(\.hand)
    }

    var totalCount: Int {
        hands.reduce(0) { partial, value in
            let (sum, overflowed) = partial.addingReportingOverflow(max(0, value.count))
            return overflowed ? Int.max : sum
        }
    }

    var totalDurationMilliseconds: Int64 {
        hands.reduce(0) { partial, value in
            let (sum, overflowed) = partial.addingReportingOverflow(
                max(0, value.durationMilliseconds)
            )
            return overflowed ? Int64.max : sum
        }
    }

    func value(for hand: PracticeHand) -> PracticeHistoryHandEditDraft {
        hands.first { $0.hand == hand }
            ?? PracticeHistoryHandEditDraft(
                hand: hand,
                count: 0,
                durationMilliseconds: 0,
                preset: nil
            )
    }

    mutating func update(
        hand: PracticeHand,
        _ mutation: (inout PracticeHistoryHandEditDraft) -> Void
    ) {
        guard let index = hands.firstIndex(where: { $0.hand == hand }) else { return }
        mutation(&hands[index])
        hands[index].count = max(0, hands[index].count)
        hands[index].durationMilliseconds = max(0, hands[index].durationMilliseconds)
        hands[index].preset = hands[index].preset?.normalized
    }

    /// The date picker represents the record timestamp. Moving it shifts the
    /// whole session without changing its elapsed span.
    mutating func move(to newFinishedAt: Date) {
        let delta = newFinishedAt.timeIntervalSince(finishedAt)
        finishedAt = newFinishedAt
        startedAt = startedAt.addingTimeInterval(delta)
    }

    /// Single-hand sessions can be reassigned directly. Multi-hand sessions
    /// remain independently editable so one hand is never silently discarded.
    mutating func moveSingleHand(from source: PracticeHand, to destination: PracticeHand) {
        guard source != destination,
              populatedHands == [source],
              let sourceIndex = hands.firstIndex(where: { $0.hand == source }),
              let destinationIndex = hands.firstIndex(where: { $0.hand == destination })
        else { return }
        let sourceValue = hands[sourceIndex]
        hands[sourceIndex].count = 0
        hands[sourceIndex].durationMilliseconds = 0
        hands[sourceIndex].preset = nil
        hands[destinationIndex].count = sourceValue.count
        hands[destinationIndex].durationMilliseconds = sourceValue.durationMilliseconds
        hands[destinationIndex].preset = sourceValue.preset
    }
}

/// Detached editor value for one real `+1` completion. Its count is always
/// exactly one; deleting it is a separate confirmed action.
struct PracticeHistoryCompletionEditDraft: Identifiable, Equatable, Sendable {
    let recordID: UUID
    let id: UUID
    var completedAt: Date
    var hand: PracticeHand
    var preset: MetronomePreset

    init(recordID: UUID, completion: PracticeHistoryCompletionEntry) {
        self.recordID = recordID
        id = completion.id
        completedAt = completion.completedAt
        hand = completion.hand
        preset = completion.preset.normalized
    }
}

/// Detached editor value for one truthful aggregate row shown in history.
///
/// Manual backfills retain the exact persisted sample IDs that make up the
/// row, so editing or deleting the row cannot affect neighboring live `+1`
/// entries. A migration-era residual legitimately has no IDs; in that case
/// only its unsampled count/configuration is changed.
struct PracticeHistoryUnitemizedEditDraft: Identifiable, Equatable, Sendable {
    let recordID: UUID
    let originalHand: PracticeHand
    let reason: PracticeHistoryUnitemizedReason
    let completionIDs: [UUID]
    let originalCount: Int
    let originalPreset: MetronomePreset?
    let isWholeRecordRepresentation: Bool
    var hand: PracticeHand
    var count: Int
    var preset: MetronomePreset?
    var completedAt: Date?
    var durationMilliseconds: Int64?

    var id: PracticeHistoryUnitemizedCompletionSummary.ID {
        PracticeHistoryUnitemizedCompletionSummary.ID(
            recordID: recordID,
            hand: originalHand,
            reason: reason,
            preset: originalPreset
        )
    }

    init(
        record: PracticeHistoryRecordSnapshot,
        summary: PracticeHistoryUnitemizedCompletionSummary
    ) {
        recordID = record.id
        originalHand = summary.hand
        reason = summary.reason
        completionIDs = summary.completionIDs
        originalCount = summary.count
        originalPreset = summary.preset?.normalized
        isWholeRecordRepresentation = summary.representsWholeRecord(in: record)
        hand = summary.hand
        count = summary.count
        preset = summary.preset?.normalized
        completedAt = summary.completedAt
        durationMilliseconds = isWholeRecordRepresentation
            ? record.stats(for: summary.hand).durationMilliseconds
            : nil
    }
}

/// One truthful line in a section's practice-detail breakdown.
///
/// BPM is represented as a range because users may change tempo between
/// repetitions while keeping the same hand, metre, and training note.
struct PracticeConfigurationBreakdown: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let sectionID: UUID
        let hand: PracticeHand
        let beats: Int
        let subdivision: Int
    }

    let sectionID: UUID
    let hand: PracticeHand
    let beats: Int
    let subdivision: Int
    let minimumBPM: Int
    let maximumBPM: Int
    let count: Int
    let latestCompletedAt: Date
    /// True when at least one migration-era record contributed only its
    /// per-hand aggregate count and saved preset.
    let usedLegacyFallback: Bool

    var id: ID {
        ID(
            sectionID: sectionID,
            hand: hand,
            beats: beats,
            subdivision: subdivision
        )
    }

    var bpmRangeTitle: String {
        minimumBPM == maximumBPM
            ? "\(minimumBPM) BPM"
            : "\(minimumBPM)–\(maximumBPM) BPM"
    }

    var subdivisionTitle: String {
        var preset = MetronomePreset.standard
        preset.subdivision = subdivision
        return preset.normalized.subdivisionTitle
    }
}

/// Counts retained from an aggregate-only/hybrid record whose metronome
/// configuration was never persisted. Keeping this separate prevents the UI
/// from presenting a fabricated BPM, metre, or training note.
struct PracticeUnavailableConfigurationSummary: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let sectionID: UUID
        let hand: PracticeHand
    }

    let sectionID: UUID
    let hand: PracticeHand
    let count: Int
    let latestCompletedAt: Date

    var id: ID { ID(sectionID: sectionID, hand: hand) }
    var title: String { "配置不可用" }
}

struct PracticeSectionBreakdownReport: Equatable, Sendable {
    let configurations: [PracticeConfigurationBreakdown]
    let unavailableConfigurations: [PracticeUnavailableConfigurationSummary]

    var totalCount: Int {
        StatisticsMath.saturatedSum(
            configurations.map(\.count)
                + unavailableConfigurations.map(\.count)
        )
    }
}

/// Derives the detailed rows used by a section card from immutable attempts.
enum PracticeSectionBreakdownStatistics {
    /// Applies the section's current target period automatically:
    /// daily-reset songs use today; other songs use the current goal's
    /// `enabledAt` boundary. A section without a goal boundary remains
    /// all-time so legacy data is still visible.
    static func breakdowns(
        section: PracticeSectionSnapshot,
        song: PracticeSongSnapshot,
        records: [PracticeHistoryRecordSnapshot],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PracticeConfigurationBreakdown] {
        report(
            section: section,
            song: song,
            records: records,
            now: now,
            calendar: calendar
        ).configurations
    }

    static func report(
        section: PracticeSectionSnapshot,
        song: PracticeSongSnapshot,
        records: [PracticeHistoryRecordSnapshot],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> PracticeSectionBreakdownReport {
        let interval: DateInterval?
        if song.resetsDaily,
           let dayInterval = calendar.dateInterval(of: .day, for: now) {
            let start = max(dayInterval.start, section.goalEnabledAt ?? dayInterval.start)
            interval = DateInterval(
                start: start,
                end: max(start, dayInterval.end)
            )
        } else if let enabledAt = section.goalEnabledAt {
            interval = DateInterval(start: enabledAt, end: .distantFuture)
        } else {
            interval = nil
        }

        return report(
            sectionID: section.id,
            records: records,
            interval: interval
        )
    }

    /// Low-level form for callers that already resolved their own half-open
    /// target interval. `nil` means all persisted history.
    static func breakdowns(
        sectionID: UUID,
        records: [PracticeHistoryRecordSnapshot],
        interval: DateInterval?
    ) -> [PracticeConfigurationBreakdown] {
        report(
            sectionID: sectionID,
            records: records,
            interval: interval
        ).configurations
    }

    static func report(
        sectionID: UUID,
        records: [PracticeHistoryRecordSnapshot],
        interval: DateInterval?
    ) -> PracticeSectionBreakdownReport {
        struct Key: Hashable {
            let hand: PracticeHand
            let beats: Int
            let subdivision: Int
        }
        struct Aggregate {
            var minimumBPM: Int
            var maximumBPM: Int
            var count: Int
            var latestCompletedAt: Date
            var usedLegacyFallback: Bool

            mutating func add(
                bpm: Int,
                count addedCount: Int,
                completedAt: Date,
                legacy: Bool
            ) {
                minimumBPM = min(minimumBPM, bpm)
                maximumBPM = max(maximumBPM, bpm)
                count = StatisticsMath.saturatedAdd(count, max(0, addedCount))
                latestCompletedAt = max(latestCompletedAt, completedAt)
                usedLegacyFallback = usedLegacyFallback || legacy
            }
        }
        struct UnavailableAggregate {
            var count: Int
            var latestCompletedAt: Date
        }

        func isIncluded(_ date: Date) -> Bool {
            interval?.containsHalfOpen(date) ?? true
        }

        var aggregates: [Key: Aggregate] = [:]
        var unavailableByHand: [PracticeHand: UnavailableAggregate] = [:]

        func append(
            hand: PracticeHand,
            preset rawPreset: MetronomePreset,
            count: Int,
            completedAt: Date,
            legacy: Bool
        ) {
            let count = max(0, count)
            guard count > 0 else { return }
            let preset = rawPreset.normalized
            let key = Key(
                hand: hand,
                beats: preset.beats,
                subdivision: preset.subdivision
            )
            if var aggregate = aggregates[key] {
                aggregate.add(
                    bpm: preset.bpm,
                    count: count,
                    completedAt: completedAt,
                    legacy: legacy
                )
                aggregates[key] = aggregate
            } else {
                aggregates[key] = Aggregate(
                    minimumBPM: preset.bpm,
                    maximumBPM: preset.bpm,
                    count: count,
                    latestCompletedAt: completedAt,
                    usedLegacyFallback: legacy
                )
            }
        }

        for record in records where record.sourceEventID == sectionID {
            let sampleCountsByHand = Dictionary(
                grouping: record.completionSamples,
                by: \PracticeCompletionSample.hand
            ).mapValues(\.count)

            // Every persisted sample has a trustworthy configuration. Manual
            // batches share one explicit timestamp and source; live samples
            // retain their real tap time.
            for sample in record.completionSamples(for: nil)
            where isIncluded(sample.completedAt) {
                append(
                    hand: sample.hand,
                    preset: sample.preset,
                    count: 1,
                    completedAt: sample.completedAt,
                    legacy: false
                )
            }

            // A hybrid migration may have fewer raw samples than its durable
            // aggregate count. Preserve the remainder as an unitemized
            // summary at the session boundary; never invent tap timestamps.
            guard isIncluded(record.finishedAt) else { continue }
            for hand in PracticeHand.controlOrder {
                let aggregateCount = record.stats(for: hand).count
                let sampledCount = sampleCountsByHand[hand] ?? 0
                let residualCount = max(0, aggregateCount - sampledCount)
                guard residualCount > 0 else { continue }

                if let preset = record.preset(for: hand) {
                    append(
                        hand: hand,
                        preset: preset,
                        count: residualCount,
                        completedAt: record.finishedAt,
                        legacy: true
                    )
                } else if var unavailable = unavailableByHand[hand] {
                    unavailable.count = StatisticsMath.saturatedAdd(
                        unavailable.count,
                        residualCount
                    )
                    unavailable.latestCompletedAt = max(
                        unavailable.latestCompletedAt,
                        record.finishedAt
                    )
                    unavailableByHand[hand] = unavailable
                } else {
                    unavailableByHand[hand] = UnavailableAggregate(
                        count: residualCount,
                        latestCompletedAt: record.finishedAt
                    )
                }
            }
        }

        let handOrder = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let configurations = aggregates.map { key, aggregate in
            PracticeConfigurationBreakdown(
                sectionID: sectionID,
                hand: key.hand,
                beats: key.beats,
                subdivision: key.subdivision,
                minimumBPM: aggregate.minimumBPM,
                maximumBPM: aggregate.maximumBPM,
                count: aggregate.count,
                latestCompletedAt: aggregate.latestCompletedAt,
                usedLegacyFallback: aggregate.usedLegacyFallback
            )
        }.sorted { lhs, rhs in
            let leftHand = handOrder[lhs.hand] ?? Int.max
            let rightHand = handOrder[rhs.hand] ?? Int.max
            if leftHand != rightHand { return leftHand < rightHand }
            if lhs.beats != rhs.beats { return lhs.beats < rhs.beats }
            if lhs.subdivision != rhs.subdivision {
                return lhs.subdivision < rhs.subdivision
            }
            if lhs.minimumBPM != rhs.minimumBPM {
                return lhs.minimumBPM < rhs.minimumBPM
            }
            return lhs.maximumBPM < rhs.maximumBPM
        }

        let unavailableConfigurations = unavailableByHand.map { hand, aggregate in
            PracticeUnavailableConfigurationSummary(
                sectionID: sectionID,
                hand: hand,
                count: aggregate.count,
                latestCompletedAt: aggregate.latestCompletedAt
            )
        }.sorted { lhs, rhs in
            (handOrder[lhs.hand] ?? Int.max) < (handOrder[rhs.hand] ?? Int.max)
        }

        return PracticeSectionBreakdownReport(
            configurations: configurations,
            unavailableConfigurations: unavailableConfigurations
        )
    }
}

/// One real `+1` sample inside a persisted practice session.
struct PracticeHistoryCompletionEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let sequenceNumber: Int
    let completedAt: Date
    let hand: PracticeHand
    let preset: MetronomePreset
}

enum PracticeHistoryUnitemizedReason: String, Hashable, Sendable {
    /// Counts entered together through the manual backfill sheet.
    case manualBackfill
    /// Aggregate count remaining after all persisted samples are accounted for.
    case legacyAggregate
}

/// A truthful count that has no real per-tap timeline. Configuration remains
/// optional so migration-era data can explicitly say it is unavailable.
struct PracticeHistoryUnitemizedCompletionSummary: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let recordID: UUID
        let hand: PracticeHand
        let reason: PracticeHistoryUnitemizedReason
        let preset: MetronomePreset?
    }

    let recordID: UUID
    let hand: PracticeHand
    let count: Int
    let preset: MetronomePreset?
    let reason: PracticeHistoryUnitemizedReason
    /// Exact persisted members for a manual-backfill row. Legacy aggregate
    /// residuals have no member IDs and therefore remain explicitly empty.
    let completionIDs: [UUID]
    /// A manual batch has a truthful batch timestamp; an unsampled legacy
    /// residual only has a session boundary and therefore remains `nil`.
    let completedAt: Date?

    var id: ID {
        ID(recordID: recordID, hand: hand, reason: reason, preset: preset)
    }

    var title: String {
        switch reason {
        case .manualBackfill: "补录汇总"
        case .legacyAggregate:
            preset == nil ? "旧记录 · 配置不可用" : "旧记录汇总"
        }
    }

    func representsWholeRecord(in record: PracticeHistoryRecordSnapshot) -> Bool {
        guard !completionIDs.isEmpty else { return false }
        return Set(completionIDs) == Set(record.completionSamples.map(\.id))
            && count == record.totalCount
    }
}

/// Session-level access for the history UI. `attempts` is intentionally empty
/// for old aggregate-only records; `summaryStats` remains the truthful fallback.
struct PracticeHistorySessionDetail: Identifiable, Equatable, Sendable {
    let record: PracticeHistoryRecordSnapshot
    let selectedHand: PracticeHand?
    let attempts: [PracticeHistoryCompletionEntry]
    let unitemizedCompletions: [PracticeHistoryUnitemizedCompletionSummary]

    var id: UUID { record.id }
    var sessionID: UUID? { record.sessionID }
    var eventID: UUID? { record.sourceEventID }
    var eventName: String { record.eventNameSnapshot }
    var startedAt: Date { record.startedAt }
    var finishedAt: Date { record.finishedAt }
    var isLegacySummaryOnly: Bool {
        attempts.isEmpty && unitemizedCompletions.contains {
            $0.reason == .legacyAggregate
        }
    }
    var isSummaryOnly: Bool { attempts.isEmpty && summaryStats.count > 0 }
    var unitemizedCount: Int {
        StatisticsMath.saturatedSum(unitemizedCompletions.map(\.count))
    }

    var summaryStats: HandPracticeStats {
        guard let selectedHand else {
            return HandPracticeStats(
                count: record.totalCount,
                durationMilliseconds: record.totalDurationMilliseconds
            )
        }
        return record.stats(for: selectedHand)
    }
}

/// Relative/interval copy rounded down to the largest meaningful unit.
enum PracticeHistoryIntervalFormatter {
    static func string(
        since earlierDate: Date,
        to laterDate: Date = .now
    ) -> String {
        string(for: laterDate.timeIntervalSince(earlierDate))
    }

    static func string(for interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0s前" }
        let finiteInterval = max(0, interval)
        // Leave headroom because `Double(Int.max)` rounds one unit beyond the
        // representable integer boundary on 64-bit platforms.
        let maximumSafeInteger = Int.max - 2_048
        let seconds = Int(min(
            finiteInterval.rounded(.down),
            Double(maximumSafeInteger)
        ))
        if seconds < 60 { return "\(seconds)s前" }
        if seconds < 3_600 { return "\(seconds / 60)分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600)h前" }
        return "\(seconds / 86_400)d前"
    }
}

/// Rolling ranges offered by the piece-speed trend chart.
enum PracticePieceAnalysisTrendRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var dayCount: Int { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .sevenDays: "7 天"
        case .thirtyDays: "30 天"
        case .ninetyDays: "90 天"
        }
    }
}

/// Preferred range name now that one selection drives every analysis metric.
typealias PracticePieceAnalysisRange = PracticePieceAnalysisTrendRange

/// The only fields that must match before two recorded speeds are compared.
///
/// BPM and hand are measured dimensions. Rotation direction does not change
/// the musical tempo, while reference notes are normalized to quarter-note
/// equivalent BPM before comparison, so none of those belong in this key.
struct PracticePieceAnalysisComparableConfiguration: Hashable, Sendable {
    let sourceEventID: UUID?
    let beats: Int
    let subdivision: Int
    let grouping: String

    fileprivate init(
        sourceEventID: UUID?,
        preset rawPreset: MetronomePreset
    ) {
        let preset = rawPreset.normalized
        self.sourceEventID = sourceEventID
        beats = preset.beats
        subdivision = preset.subdivision
        grouping = preset.grouping
    }
}

/// Explicit scope for a piece analysis request.
///
/// A section target always resolves to one comparable rhythmic setup: beats,
/// training-note subdivision and grouping. Supplying a configuration selects
/// it explicitly; otherwise the engine chooses the dominant saved setup.
struct PracticePieceAnalysisTarget: Equatable, Sendable {
    let sectionID: UUID
    let configuration: PracticePieceAnalysisComparableConfiguration?

    init(
        sectionID: UUID,
        configuration: PracticePieceAnalysisComparableConfiguration? = nil
    ) {
        self.sectionID = sectionID
        self.configuration = configuration
    }

    init(sectionID: UUID, preset: MetronomePreset) {
        self.init(
            sectionID: sectionID,
            configuration: PracticePieceAnalysisComparableConfiguration(
                sourceEventID: sectionID,
                preset: preset
            )
        )
    }
}

/// The section, hand and rhythmic configuration driving the analysis.
struct PracticePieceAnalysisContext: Equatable, Sendable {
    let configuration: PracticePieceAnalysisComparableConfiguration
    let eventName: String
    let focusHand: PracticeHand
}

struct PracticePieceAnalysisSpeedPerformance: Equatable, Sendable {
    let maximumBPM: Double?
    let weightedAverageBPM: Double?
    let stableBPM: Double?
    let completionCount: Int

    static let empty = PracticePieceAnalysisSpeedPerformance(
        maximumBPM: nil,
        weightedAverageBPM: nil,
        stableBPM: nil,
        completionCount: 0
    )
}

struct PracticePieceAnalysisSpeedGrowth: Equatable, Sendable {
    let currentMaximumBPM: Double?
    let comparisonMaximumBPM: Double?
    let changeBPM: Double?
    let percentage: Double?

    static let empty = PracticePieceAnalysisSpeedGrowth(
        currentMaximumBPM: nil,
        comparisonMaximumBPM: nil,
        changeBPM: nil,
        percentage: nil
    )
}

struct PracticePieceAnalysisHandComparison: Equatable, Sendable {
    let leftMaximumBPM: Double?
    let rightMaximumBPM: Double?
    let absoluteDifferenceBPM: Double?
    let differencePercentage: Double?
    let slowerHand: PracticeHand?

    static let empty = PracticePieceAnalysisHandComparison(
        leftMaximumBPM: nil,
        rightMaximumBPM: nil,
        absoluteDifferenceBPM: nil,
        differencePercentage: nil,
        slowerHand: nil
    )
}

struct PracticePieceAnalysisTrendPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let maximumBPM: Double

    var id: Date { date }
}

struct PracticePieceAnalysis: Equatable, Sendable {
    let context: PracticePieceAnalysisContext?
    let speedPerformance: PracticePieceAnalysisSpeedPerformance
    let thirtyDayGrowth: PracticePieceAnalysisSpeedGrowth
    let handComparison: PracticePieceAnalysisHandComparison
    let trendRange: PracticePieceAnalysisTrendRange
    let trendPoints: [PracticePieceAnalysisTrendPoint]

    /// Range-aware name used by the current analysis UI. The stored legacy
    /// name remains available while older call sites migrate.
    var growth: PracticePieceAnalysisSpeedGrowth { thirtyDayGrowth }
    var range: PracticePieceAnalysisRange { trendRange }
}

/// Truthful, configuration-aware speed analysis for one already-filtered song.
///
/// The engine consumes immutable snapshots only. It never fills gaps with the
/// current metronome setting and never fabricates per-tap history.
enum PracticePieceAnalysisEngine {
    static let stabilityRecentCompletionLimit = 10
    static let stabilityRequiredRepetitionCount = 3

    /// An explicit, range-aware analysis for the section and hand selected by
    /// the user. Unlike the compatibility entry point below, the selected
    /// range governs every metric instead of the chart alone.
    static func analyze(
        records: [PracticeHistoryRecordSnapshot],
        target: PracticePieceAnalysisTarget,
        range: PracticePieceAnalysisRange,
        hand: PracticeHand,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> PracticePieceAnalysis {
        let historicalObservations = observations(from: records).filter {
            $0.completedAt <= now
                && $0.configuration.sourceEventID == target.sectionID
        }
        guard let contextConfiguration = target.configuration
                ?? selectedConfiguration(from: historicalObservations)
        else {
            return PracticePieceAnalysis(
                context: nil,
                speedPerformance: .empty,
                thirtyDayGrowth: .empty,
                handComparison: .empty,
                trendRange: range,
                trendPoints: []
            )
        }
        let scopedObservations = historicalObservations.filter {
            $0.configuration == contextConfiguration
        }

        guard !scopedObservations.isEmpty else {
            return PracticePieceAnalysis(
                context: nil,
                speedPerformance: .empty,
                thirtyDayGrowth: .empty,
                handComparison: .empty,
                trendRange: range,
                trendPoints: []
            )
        }

        let latestContextObservation = scopedObservations.max(
            by: observationIsEarlier
        )
        let context = PracticePieceAnalysisContext(
            configuration: contextConfiguration,
            eventName: latestContextObservation?.eventName ?? "",
            focusHand: hand
        )
        let currentWindow = rollingWindow(
            dayCount: range.dayCount,
            now: now,
            calendar: calendar
        )
        let observationsInRange = scopedObservations.filter(
            currentWindow.contains
        )
        let focusObservations = observationsInRange.filter {
            $0.hand == hand
        }

        return PracticePieceAnalysis(
            context: context,
            speedPerformance: speedPerformance(
                observations: focusObservations
            ),
            thirtyDayGrowth: speedGrowth(
                observations: scopedObservations.filter { $0.hand == hand },
                range: range,
                now: now,
                calendar: calendar
            ),
            handComparison: handComparison(
                observations: observationsInRange
            ),
            trendRange: range,
            trendPoints: trend(
                observations: focusObservations,
                range: range,
                calendar: calendar
            )
        )
    }

    /// Compatibility entry point for the first version of piece analysis.
    /// It retains dominant-context selection and its historic 30-day metric
    /// windows until all older call sites have migrated to an explicit target.
    static func analyze(
        records: [PracticeHistoryRecordSnapshot],
        trendRange: PracticePieceAnalysisTrendRange,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> PracticePieceAnalysis {
        // A malformed future timestamp is not historical evidence and must
        // not take over the selected context or any current-period metric.
        let observations = observations(from: records).filter {
            $0.completedAt <= now
        }
        let selectionWindow = rollingWindow(
            dayCount: PracticePieceAnalysisTrendRange.ninetyDays.dayCount,
            now: now,
            calendar: calendar
        )
        let recentSelection = observations.filter(selectionWindow.contains)
        let selectionPool = recentSelection.isEmpty ? observations : recentSelection

        guard let configuration = selectedConfiguration(from: selectionPool),
              let focusHand = selectedFocusHand(
                for: configuration,
                observations: selectionPool
              )
        else {
            return PracticePieceAnalysis(
                context: nil,
                speedPerformance: .empty,
                thirtyDayGrowth: .empty,
                handComparison: .empty,
                trendRange: trendRange,
                trendPoints: []
            )
        }

        let configurationObservations = observations.filter {
            $0.configuration == configuration
        }
        let latestContextObservation = configurationObservations.max(
            by: observationIsEarlier
        )
        let context = PracticePieceAnalysisContext(
            configuration: configuration,
            eventName: latestContextObservation?.eventName ?? "",
            focusHand: focusHand
        )

        let thirtyDayWindow = rollingWindow(
            dayCount: 30,
            now: now,
            calendar: calendar
        )
        let focusThirtyDayObservations = configurationObservations.filter {
            $0.hand == focusHand && thirtyDayWindow.contains($0)
        }
        let speedPerformance = speedPerformance(
            observations: focusThirtyDayObservations
        )
        let growth = thirtyDayGrowth(
            observations: configurationObservations.filter {
                $0.hand == focusHand
            },
            now: now,
            calendar: calendar
        )
        let handComparison = handComparison(
            observations: configurationObservations.filter(
                thirtyDayWindow.contains
            )
        )
        let trendWindow = rollingWindow(
            dayCount: trendRange.dayCount,
            now: now,
            calendar: calendar
        )
        let trendPoints = trend(
            observations: configurationObservations.filter {
                $0.hand == focusHand && trendWindow.contains($0)
            },
            calendar: calendar
        )

        return PracticePieceAnalysis(
            context: context,
            speedPerformance: speedPerformance,
            thirtyDayGrowth: growth,
            handComparison: handComparison,
            trendRange: trendRange,
            trendPoints: trendPoints
        )
    }

    private struct Observation: Sendable {
        let configuration: PracticePieceAnalysisComparableConfiguration
        let eventName: String
        let hand: PracticeHand
        let bpm: Double
        let completedAt: Date
        let completionCount: Int
        let stableID: String
    }

    private struct RollingWindow {
        let start: Date
        let end: Date

        func contains(_ observation: Observation) -> Bool {
            observation.completedAt >= start && observation.completedAt <= end
        }
    }

    private struct SelectionAggregate {
        var completionCount = 0
        var latestCompletedAt = Date.distantPast

        mutating func add(_ observation: Observation) {
            completionCount = StatisticsMath.saturatedAdd(
                completionCount,
                observation.completionCount
            )
            latestCompletedAt = max(latestCompletedAt, observation.completedAt)
        }
    }

    private static func observations(
        from records: [PracticeHistoryRecordSnapshot]
    ) -> [Observation] {
        var result: [Observation] = []
        for record in records {
            let sampleCountsByHand = Dictionary(
                grouping: record.completionSamples,
                by: \PracticeCompletionSample.hand
            ).mapValues(\.count)

            for sample in record.completionSamples {
                let preset = sample.preset.normalized
                guard let equivalentBPM = quarterNoteEquivalentBPM(
                    preset: preset
                ) else { continue }
                result.append(Observation(
                    configuration: PracticePieceAnalysisComparableConfiguration(
                        sourceEventID: record.sourceEventID,
                        preset: preset
                    ),
                    eventName: record.eventNameSnapshot,
                    hand: sample.hand,
                    bpm: equivalentBPM,
                    completedAt: sample.completedAt,
                    completionCount: 1,
                    stableID: "sample:\(sample.id.uuidString)"
                ))
            }

            for hand in PracticeHand.controlOrder {
                let residualCount = max(
                    0,
                    record.stats(for: hand).count
                        - (sampleCountsByHand[hand] ?? 0)
                )
                guard residualCount > 0,
                      let preset = record.preset(for: hand)?.normalized
                else { continue }
                guard let equivalentBPM = quarterNoteEquivalentBPM(
                    preset: preset
                ) else { continue }
                result.append(Observation(
                    configuration: PracticePieceAnalysisComparableConfiguration(
                        sourceEventID: record.sourceEventID,
                        preset: preset
                    ),
                    eventName: record.eventNameSnapshot,
                    hand: hand,
                    bpm: equivalentBPM,
                    completedAt: record.finishedAt,
                    completionCount: residualCount,
                    stableID: "residual:\(record.id.uuidString):\(hand.rawValue)"
                ))
            }
        }
        return result
    }

    /// Converts a tempo mark to the number of quarter notes represented per
    /// minute. For example, half note = 60 is equivalent to quarter = 120,
    /// while eighth note = 121 is quarter = 60.5.
    ///
    /// Missing reference-note storage is the app's documented legacy quarter
    /// note value. An unknown non-empty raw value is not guessed and therefore
    /// cannot enter a comparison.
    private static func quarterNoteEquivalentBPM(
        preset: MetronomePreset
    ) -> Double? {
        let referenceNote: TempoReferenceNote
        if let rawValue = preset.referenceNoteRaw {
            guard let parsed = TempoReferenceNote(rawValue: rawValue) else {
                return nil
            }
            referenceNote = parsed
        } else {
            referenceNote = .quarter
        }
        return Double(preset.bpm) * referenceNote.durationInQuarterNotes
    }

    private static func rollingWindow(
        dayCount: Int,
        now: Date,
        calendar: Calendar
    ) -> RollingWindow {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .day,
            value: -(max(1, dayCount) - 1),
            to: today
        ) ?? today
        return RollingWindow(start: start, end: now)
    }

    private static func selectedConfiguration(
        from observations: [Observation]
    ) -> PracticePieceAnalysisComparableConfiguration? {
        var aggregates: [PracticePieceAnalysisComparableConfiguration: SelectionAggregate] = [:]
        for observation in observations {
            aggregates[observation.configuration, default: SelectionAggregate()]
                .add(observation)
        }
        return aggregates.sorted { lhs, rhs in
            if lhs.value.completionCount != rhs.value.completionCount {
                return lhs.value.completionCount > rhs.value.completionCount
            }
            if lhs.value.latestCompletedAt != rhs.value.latestCompletedAt {
                return lhs.value.latestCompletedAt > rhs.value.latestCompletedAt
            }
            return configurationPrecedes(lhs.key, rhs.key)
        }.first?.key
    }

    private static func selectedFocusHand(
        for configuration: PracticePieceAnalysisComparableConfiguration,
        observations: [Observation]
    ) -> PracticeHand? {
        var aggregates: [PracticeHand: SelectionAggregate] = [:]
        for observation in observations
        where observation.configuration == configuration {
            aggregates[observation.hand, default: SelectionAggregate()]
                .add(observation)
        }
        let handRank = Dictionary(
            uniqueKeysWithValues: PracticeHand.controlOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        return aggregates.sorted { lhs, rhs in
            if lhs.value.completionCount != rhs.value.completionCount {
                return lhs.value.completionCount > rhs.value.completionCount
            }
            if lhs.value.latestCompletedAt != rhs.value.latestCompletedAt {
                return lhs.value.latestCompletedAt > rhs.value.latestCompletedAt
            }
            return (handRank[lhs.key] ?? Int.max)
                < (handRank[rhs.key] ?? Int.max)
        }.first?.key
    }

    private static func configurationPrecedes(
        _ lhs: PracticePieceAnalysisComparableConfiguration,
        _ rhs: PracticePieceAnalysisComparableConfiguration
    ) -> Bool {
        let lhsEventID = lhs.sourceEventID?.uuidString
        let rhsEventID = rhs.sourceEventID?.uuidString
        if lhsEventID != rhsEventID {
            return optionalStringPrecedes(lhsEventID, rhsEventID)
        }
        if lhs.beats != rhs.beats { return lhs.beats < rhs.beats }
        if lhs.subdivision != rhs.subdivision {
            return lhs.subdivision < rhs.subdivision
        }
        return lhs.grouping < rhs.grouping
    }

    private static func optionalStringPrecedes(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): false
        case (nil, _): true
        case (_, nil): false
        case let (lhs?, rhs?): lhs < rhs
        }
    }

    private static func speedPerformance(
        observations: [Observation]
    ) -> PracticePieceAnalysisSpeedPerformance {
        guard !observations.isEmpty else { return .empty }
        let count = StatisticsMath.saturatedSum(
            observations.map(\.completionCount)
        )
        guard count > 0 else { return .empty }

        let totalWeight = observations.reduce(0.0) { partial, observation in
            partial + Double(observation.completionCount)
        }
        let weightedTotal = observations.reduce(0.0) { partial, observation in
            partial + Double(observation.bpm) * Double(observation.completionCount)
        }
        return PracticePieceAnalysisSpeedPerformance(
            maximumBPM: observations.map(\.bpm).max(),
            weightedAverageBPM: totalWeight > 0
                ? weightedTotal / totalWeight
                : nil,
            stableBPM: stableBPM(observations: observations),
            completionCount: count
        )
    }

    private static func stableBPM(observations: [Observation]) -> Double? {
        let newestFirst = observations.sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt {
                return lhs.completedAt > rhs.completedAt
            }
            return lhs.stableID < rhs.stableID
        }
        var remaining = stabilityRecentCompletionLimit
        var countsByBPM: [Double: Int] = [:]
        for observation in newestFirst where remaining > 0 {
            let includedCount = min(remaining, observation.completionCount)
            countsByBPM[observation.bpm, default: 0] += includedCount
            remaining -= includedCount
        }
        return countsByBPM
            .filter { $0.value >= stabilityRequiredRepetitionCount }
            .map(\.key)
            .max()
    }

    /// Compares the selected range with the immediately preceding, disjoint
    /// range containing the same number of local calendar days.
    private static func speedGrowth(
        observations: [Observation],
        range: PracticePieceAnalysisTrendRange,
        now: Date,
        calendar: Calendar
    ) -> PracticePieceAnalysisSpeedGrowth {
        let currentWindow = rollingWindow(
            dayCount: range.dayCount,
            now: now,
            calendar: calendar
        )
        let comparisonEnd = currentWindow.start
        let comparisonStart = calendar.date(
            byAdding: .day,
            value: -range.dayCount,
            to: comparisonEnd
        ) ?? comparisonEnd

        let currentMaximum = observations
            .filter(currentWindow.contains)
            .map(\.bpm)
            .max()
        let comparisonMaximum = observations
            .filter {
                $0.completedAt >= comparisonStart
                    && $0.completedAt < comparisonEnd
            }
            .map(\.bpm)
            .max()
        let percentage: Double?
        if let currentMaximum,
           let comparisonMaximum,
           comparisonMaximum > 0 {
            percentage = (currentMaximum - comparisonMaximum)
                / comparisonMaximum * 100
        } else {
            percentage = nil
        }
        return PracticePieceAnalysisSpeedGrowth(
            currentMaximumBPM: currentMaximum,
            comparisonMaximumBPM: comparisonMaximum,
            changeBPM: currentMaximum.flatMap { current in
                comparisonMaximum.map { current - $0 }
            },
            percentage: percentage
        )
    }

    private static func thirtyDayGrowth(
        observations: [Observation],
        now: Date,
        calendar: Calendar
    ) -> PracticePieceAnalysisSpeedGrowth {
        let currentWindow = rollingWindow(
            dayCount: 7,
            now: now,
            calendar: calendar
        )
        let comparisonStart = calendar.date(
            byAdding: .day,
            value: -30,
            to: currentWindow.start
        ) ?? currentWindow.start
        let comparisonEnd = calendar.date(
            byAdding: .day,
            value: -30,
            to: currentWindow.end
        ) ?? currentWindow.end
        let comparisonWindow = RollingWindow(
            start: comparisonStart,
            end: comparisonEnd
        )
        let currentMaximum = observations
            .filter(currentWindow.contains)
            .map(\.bpm)
            .max()
        let comparisonMaximum = observations
            .filter(comparisonWindow.contains)
            .map(\.bpm)
            .max()
        let percentage: Double?
        if let currentMaximum,
           let comparisonMaximum,
           comparisonMaximum > 0 {
            percentage = Double(currentMaximum - comparisonMaximum)
                / Double(comparisonMaximum) * 100
        } else {
            percentage = nil
        }
        return PracticePieceAnalysisSpeedGrowth(
            currentMaximumBPM: currentMaximum,
            comparisonMaximumBPM: comparisonMaximum,
            changeBPM: currentMaximum.flatMap { current in
                comparisonMaximum.map { current - $0 }
            },
            percentage: percentage
        )
    }

    private static func handComparison(
        observations: [Observation]
    ) -> PracticePieceAnalysisHandComparison {
        let left = observations
            .filter { $0.hand == .left }
            .map(\.bpm)
            .max()
        let right = observations
            .filter { $0.hand == .right }
            .map(\.bpm)
            .max()
        guard let left, let right else {
            return PracticePieceAnalysisHandComparison(
                leftMaximumBPM: left,
                rightMaximumBPM: right,
                absoluteDifferenceBPM: nil,
                differencePercentage: nil,
                slowerHand: nil
            )
        }
        let difference = abs(left - right)
        let denominator = max(left, right)
        let slowerHand: PracticeHand?
        if left < right {
            slowerHand = .left
        } else if right < left {
            slowerHand = .right
        } else {
            slowerHand = nil
        }
        return PracticePieceAnalysisHandComparison(
            leftMaximumBPM: left,
            rightMaximumBPM: right,
            absoluteDifferenceBPM: difference,
            differencePercentage: denominator > 0
                ? Double(difference) / Double(denominator) * 100
                : nil,
            slowerHand: slowerHand
        )
    }

    private static func trend(
        observations: [Observation],
        range: PracticePieceAnalysisTrendRange,
        calendar: Calendar
    ) -> [PracticePieceAnalysisTrendPoint] {
        var maximumByBucket: [Date: Double] = [:]
        for observation in observations {
            let bucket = range == .today
                ? observation.completedAt
                : calendar.startOfDay(for: observation.completedAt)
            maximumByBucket[bucket] = max(
                maximumByBucket[bucket] ?? -.infinity,
                observation.bpm
            )
        }
        return maximumByBucket.map { bucket, maximum in
            PracticePieceAnalysisTrendPoint(
                date: bucket,
                maximumBPM: maximum
            )
        }.sorted { $0.date < $1.date }
    }

    private static func trend(
        observations: [Observation],
        calendar: Calendar
    ) -> [PracticePieceAnalysisTrendPoint] {
        trend(
            observations: observations,
            range: .thirtyDays,
            calendar: calendar
        )
    }

    private static func observationIsEarlier(
        _ lhs: Observation,
        _ rhs: Observation
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt {
            return lhs.completedAt < rhs.completedAt
        }
        return lhs.stableID > rhs.stableID
    }
}

enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }
}

struct PracticeStatisticsQuery: Equatable, Sendable {
    var period: StatisticsPeriod
    var anchorDate: Date
    var calendar: Calendar

    init(
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) {
        self.period = period
        self.anchorDate = anchorDate
        self.calendar = calendar
    }
}

enum HistoricalMetricState: Equatable, Sendable {
    case verified
    case verifiedZero
    case noRecords
    case incomplete
    case unverifiable
}

/// Product A12 result for Practice Days. `verifiedDayCount` is always factual;
/// `exactDayCount` is present only when every contributing record is verifiable.
struct PracticeDaysResult: Equatable, Sendable {
    let state: HistoricalMetricState
    let verifiedDayCount: Int
    let exactDayCount: Int?
    let incompleteRecordCount: Int

    static let noRecords = PracticeDaysResult(
        state: .noRecords,
        verifiedDayCount: 0,
        exactDayCount: nil,
        incompleteRecordCount: 0
    )
}

/// A duration is exact only when every contributing interval can be placed in time.
struct PracticeDurationResult: Equatable, Sendable {
    let state: HistoricalMetricState
    let verifiedMilliseconds: Int64
    let exactMilliseconds: Int64?
    let incompleteRecordCount: Int
    let removedOverlapMilliseconds: Int64

    static let noRecords = PracticeDurationResult(
        state: .noRecords, verifiedMilliseconds: 0, exactMilliseconds: nil,
        incompleteRecordCount: 0, removedOverlapMilliseconds: 0
    )
}

struct PracticeStatisticsSummary: Equatable, Sendable {
    let totalCount: Int
    let sessionCount: Int
    let practiceDays: PracticeDaysResult
    let totalDurationMilliseconds: Int64

    var activeDayCount: Int { practiceDays.verifiedDayCount }

    init(
        totalCount: Int,
        sessionCount: Int,
        activeDayCount: Int,
        totalDurationMilliseconds: Int64,
        practiceDays: PracticeDaysResult? = nil
    ) {
        self.totalCount = totalCount
        self.sessionCount = sessionCount
        self.practiceDays = practiceDays ?? PracticeDaysResult(
            state: activeDayCount == 0 ? .verifiedZero : .verified,
            verifiedDayCount: activeDayCount,
            exactDayCount: activeDayCount,
            incompleteRecordCount: 0
        )
        self.totalDurationMilliseconds = totalDurationMilliseconds
    }

    static let zero = PracticeStatisticsSummary(
        totalCount: 0,
        sessionCount: 0,
        activeDayCount: 0,
        totalDurationMilliseconds: 0,
        practiceDays: .noRecords
    )
}

struct PracticeEventStatistics: Identifiable, Equatable, Sendable {
    let eventID: UUID?
    let name: String
    let totalCount: Int
    let sessionCount: Int
    let activeDayCount: Int
    let totalDurationMilliseconds: Int64
    let dailyCounts: [Date: Int]
    let dailySessionCounts: [Date: Int]
    let latestFinishedAt: Date

    var id: String {
        eventID?.uuidString ?? "name:\(name)"
    }
}

struct PracticeDayTimelineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let eventID: UUID?
    let name: String
    let startedAt: Date
    let finishedAt: Date
    let left: HandPracticeStats
    let right: HandPracticeStats
    let both: HandPracticeStats
    let bpm: Int?
    let beats: Int?
    let subdivision: Int?

    var totalCount: Int {
        StatisticsMath.saturatedSum([left.count, right.count, both.count])
    }

    var totalDurationMilliseconds: Int64 {
        StatisticsMath.saturatedSum([
            left.durationMilliseconds,
            right.durationMilliseconds,
            both.durationMilliseconds
        ])
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }
}

struct PracticeDailyBucket: Identifiable, Equatable, Sendable {
    let date: Date
    let totalCount: Int
    let sessionCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { date }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeCalendarDay: Identifiable, Equatable, Sendable {
    let date: Date
    let isInDisplayedMonth: Bool
    let totalCount: Int
    let sessionCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { date }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeMonthlyBucket: Identifiable, Equatable, Sendable {
    let month: Int
    let startDate: Date
    let totalCount: Int
    let sessionCount: Int
    let activeDayCount: Int
    let totalDurationMilliseconds: Int64

    var id: Date { startDate }
    var isActive: Bool { sessionCount > 0 }
}

struct PracticeStatisticsResult: Equatable, Sendable {
    let query: PracticeStatisticsQuery
    let interval: DateInterval
    let records: [PracticeHistoryRecordSnapshot]
    let summary: PracticeStatisticsSummary
    let events: [PracticeEventStatistics]
}

enum StatisticsTimelineOrder: Sendable {
    case newestFirst
    case oldestFirst
}

enum PracticeStatisticsEngine {
    static func historicalSpeedPoints(
        records: [PracticeHistoryRecordSnapshot],
        divisionID: UUID,
        applicableHands: [PracticeHand]
    ) -> [PracticeHistoricalSpeedPoint] {
        var points: [PracticeHistoricalSpeedPoint] = []
        for record in records {
            guard record.sourceEventID == divisionID,
                  let source = record.recordSource,
                  record.finishedAt >= record.startedAt
            else { continue }
            for sample in record.completionSamples {
                let preset = sample.preset
                guard sample.source == .live, sample.hasExplicitSource,
                      applicableHands.contains(sample.hand),
                      sample.completedAt >= record.startedAt,
                      sample.completedAt <= record.finishedAt,
                      (20...300).contains(preset.bpm)
                else { continue }
                points.append(PracticeHistoricalSpeedPoint(
                    id: sample.id,
                    completedAt: sample.completedAt,
                    hand: sample.hand,
                    bpm: preset.bpm,
                    noteUnit: preset.referenceNote,
                    quarterEquivalentBPM: Double(preset.bpm)
                        * preset.referenceNote.durationInQuarterNotes,
                    recordSource: source
                ))
            }
        }
        return points.sorted {
            $0.completedAt == $1.completedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.completedAt < $1.completedAt
        }
    }

    /// Global duration uses the union of saved, verifiable real-time intervals.
    /// The record and its Piece ownership are never changed by this operation.
    static func globalDuration(
        records: [PracticeHistoryRecordSnapshot]
    ) -> PracticeDurationResult {
        guard !records.isEmpty else { return .noRecords }
        var intervals: [DateInterval] = []
        var rawMilliseconds: Int64 = 0
        var incomplete = 0
        for record in records {
            guard case .success(let verified) = verifiedPracticeIntervals(
                for: record, calendar: .current
            ) else {
                incomplete += 1
                continue
            }
            if record.activeIntervals == nil {
                let elapsed = record.finishedAt.timeIntervalSince(record.startedAt) * 1_000
                guard abs(elapsed - Double(record.totalDurationMilliseconds)) <= 5 else {
                    incomplete += 1
                    continue
                }
            }
            intervals.append(contentsOf: verified)
            rawMilliseconds = StatisticsMath.saturatedSum([
                rawMilliseconds, record.totalDurationMilliseconds
            ])
        }
        let sorted = intervals.sorted { $0.start < $1.start }
        var union: [DateInterval] = []
        for interval in sorted {
            if let last = union.last, interval.start <= last.end {
                union[union.count - 1] = DateInterval(
                    start: last.start, end: max(last.end, interval.end)
                )
            } else {
                union.append(interval)
            }
        }
        let verified = StatisticsMath.saturatedSum(union.map { interval in
            PracticeDurationInterval(startedAt: interval.start, finishedAt: interval.end)?
                .durationMilliseconds ?? 0
        })
        return PracticeDurationResult(
            state: incomplete > 0
                ? (intervals.isEmpty ? .unverifiable : .incomplete)
                : (verified == 0 ? .verifiedZero : .verified),
            verifiedMilliseconds: verified,
            exactMilliseconds: incomplete == 0 ? verified : nil,
            incompleteRecordCount: incomplete,
            removedOverlapMilliseconds: max(0, rawMilliseconds - verified)
        )
    }

    /// Piece duration keeps each saved record's attribution, including time
    /// that overlaps a different Piece's record in the Global union.
    static func pieceDuration(
        records: [PracticeHistoryRecordSnapshot]
    ) -> PracticeDurationResult {
        guard !records.isEmpty else { return .noRecords }
        var verified: Int64 = 0
        var incomplete = 0
        for record in records {
            guard record.finishedAt >= record.startedAt,
                  record.totalDurationMilliseconds >= 0,
                  case .success = verifiedPracticeIntervals(for: record, calendar: .current)
            else {
                incomplete += 1
                continue
            }
            verified = StatisticsMath.saturatedSum([
                verified, record.totalDurationMilliseconds
            ])
        }
        return PracticeDurationResult(
            state: incomplete > 0
                ? (incomplete == records.count ? .unverifiable : .incomplete)
                : (verified == 0 ? .verifiedZero : .verified),
            verifiedMilliseconds: verified,
            exactMilliseconds: incomplete == 0 ? verified : nil,
            incompleteRecordCount: incomplete,
            removedOverlapMilliseconds: 0
        )
    }

    static func query(
        records: [PracticeHistoryRecordSnapshot],
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> PracticeStatisticsResult {
        query(
            records: records,
            query: PracticeStatisticsQuery(
                period: period,
                anchorDate: anchorDate,
                calendar: calendar
            )
        )
    }

    static func query(
        records: [PracticeHistoryRecordSnapshot],
        query: PracticeStatisticsQuery
    ) -> PracticeStatisticsResult {
        let interval = periodInterval(
            for: query.period,
            anchorDate: query.anchorDate,
            calendar: query.calendar
        )
        let filtered = sortedNewestFirst(records.filter {
            interval.containsHalfOpen($0.startedAt)
        })
        let practiceDays = practiceDays(
            records: records,
            calendar: query.calendar,
            interval: interval
        )
        return PracticeStatisticsResult(
            query: query,
            interval: interval,
            records: filtered,
            summary: summary(
                records: filtered,
                calendar: query.calendar,
                practiceDays: practiceDays
            ),
            events: aggregateEvents(records: filtered, calendar: query.calendar)
        )
    }

    static func periodInterval(
        for period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }

        if let interval = calendar.dateInterval(of: component, for: anchorDate) {
            return interval
        }

        let start = calendar.startOfDay(for: anchorDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func offsetAnchor(
        _ anchorDate: Date,
        period: StatisticsPeriod,
        by value: Int,
        calendar: Calendar = .current
    ) -> Date {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(
            byAdding: component,
            value: value,
            to: anchorDate
        ) ?? anchorDate
    }

    static func summary(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar = .current,
        practiceDays suppliedPracticeDays: PracticeDaysResult? = nil
    ) -> PracticeStatisticsSummary {
        if records.isEmpty {
            guard let suppliedPracticeDays,
                  suppliedPracticeDays.state != .noRecords
            else { return .zero }
            return PracticeStatisticsSummary(
                totalCount: 0,
                sessionCount: 0,
                activeDayCount: suppliedPracticeDays.verifiedDayCount,
                totalDurationMilliseconds: 0,
                practiceDays: suppliedPracticeDays
            )
        }

        let days = suppliedPracticeDays ?? practiceDays(
            records: records,
            calendar: calendar
        )
        return PracticeStatisticsSummary(
            totalCount: StatisticsMath.saturatedSum(records.map(\.totalCount)),
            sessionCount: records.count,
            activeDayCount: days.verifiedDayCount,
            totalDurationMilliseconds: StatisticsMath.saturatedSum(
                records.map(\.totalDurationMilliseconds)
            ),
            practiceDays: days
        )
    }

    /// Counts only local calendar days backed by positive, saved timing facts.
    /// Legacy same-day aggregates remain verifiable because their complete
    /// bounding interval lies within one day. A cross-midnight aggregate needs
    /// saved non-paused intervals; otherwise its date allocation is unknown.
    static func practiceDays(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar = .current,
        interval queryInterval: DateInterval? = nil
    ) -> PracticeDaysResult {
        let scopedRecords = queryInterval.map { interval in
            records.filter { record in
                interval.containsHalfOpen(record.startedAt)
                    || (record.startedAt < interval.end
                        && record.finishedAt > interval.start)
            }
        } ?? records
        guard !scopedRecords.isEmpty else { return .noRecords }

        var verifiedDays: Set<Date> = []
        var incompleteRecords = 0

        for record in scopedRecords {
            switch verifiedPracticeIntervals(for: record, calendar: calendar) {
            case .success(let intervals):
                for interval in intervals {
                    addPositiveDays(
                        in: interval,
                        limitedTo: queryInterval,
                        calendar: calendar,
                        into: &verifiedDays
                    )
                }
            case .failure:
                incompleteRecords += 1
            }
        }

        if incompleteRecords > 0 {
            return PracticeDaysResult(
                state: verifiedDays.isEmpty ? .unverifiable : .incomplete,
                verifiedDayCount: verifiedDays.count,
                exactDayCount: nil,
                incompleteRecordCount: incompleteRecords
            )
        }
        let count = verifiedDays.count
        return PracticeDaysResult(
            state: count == 0 ? .verifiedZero : .verified,
            verifiedDayCount: count,
            exactDayCount: count,
            incompleteRecordCount: 0
        )
    }

    private enum PracticeIntervalEvidence {
        case success([DateInterval])
        case failure
    }

    private static func verifiedPracticeIntervals(
        for record: PracticeHistoryRecordSnapshot,
        calendar: Calendar
    ) -> PracticeIntervalEvidence {
        let duration = record.totalDurationMilliseconds
        guard record.finishedAt >= record.startedAt else { return .failure }

        if let saved = record.activeIntervals {
            guard duration > 0 || saved.isEmpty else { return .failure }
            let sorted = saved.sorted { $0.startedAt < $1.startedAt }
            var previousEnd: Date?
            var total: Int64 = 0
            var intervals: [DateInterval] = []
            for value in sorted {
                guard value.startedAt >= record.startedAt,
                      value.finishedAt <= record.finishedAt,
                      value.finishedAt > value.startedAt,
                      previousEnd.map({ value.startedAt >= $0 }) ?? true
                else { return .failure }
                previousEnd = value.finishedAt
                total = StatisticsMath.saturatedSum([total, value.durationMilliseconds])
                intervals.append(DateInterval(start: value.startedAt, end: value.finishedAt))
            }
            let tolerance = Int64(max(5, saved.count * 2))
            guard abs(total - duration) <= tolerance else { return .failure }
            return .success(intervals)
        }

        guard duration > 0, record.finishedAt > record.startedAt else {
            return .failure
        }
        let elapsed = record.finishedAt.timeIntervalSince(record.startedAt) * 1_000
        guard elapsed.isFinite, Double(duration) <= elapsed + 5 else { return .failure }
        let lastActiveInstant = record.finishedAt.addingTimeInterval(-0.001)
        guard calendar.isDate(record.startedAt, inSameDayAs: lastActiveInstant) else {
            return .failure
        }
        return .success([DateInterval(start: record.startedAt, end: record.finishedAt)])
    }

    private static func addPositiveDays(
        in interval: DateInterval,
        limitedTo queryInterval: DateInterval?,
        calendar: Calendar,
        into days: inout Set<Date>
    ) {
        let start = max(interval.start, queryInterval?.start ?? interval.start)
        let end = min(interval.end, queryInterval?.end ?? interval.end)
        guard end > start else { return }

        var cursor = start
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? end
            let segmentEnd = min(end, next)
            if segmentEnd > cursor { days.insert(day) }
            cursor = segmentEnd
        }
    }

    static func eventStatistics(
        records: [PracticeHistoryRecordSnapshot],
        period: StatisticsPeriod,
        anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeEventStatistics] {
        query(
            records: records,
            period: period,
            anchorDate: anchorDate,
            calendar: calendar
        ).events
    }

    static func dayTimeline(
        records: [PracticeHistoryRecordSnapshot],
        anchorDate: Date,
        calendar: Calendar = .current,
        order: StatisticsTimelineOrder = .newestFirst
    ) -> [PracticeDayTimelineItem] {
        let dayRecords = query(
            records: records,
            period: .day,
            anchorDate: anchorDate,
            calendar: calendar
        ).records
        let items = dayRecords.map { record in
            PracticeDayTimelineItem(
                id: record.id,
                eventID: record.sourceEventID,
                name: record.eventNameSnapshot,
                startedAt: record.startedAt,
                finishedAt: record.finishedAt,
                left: record.left,
                right: record.right,
                both: record.both,
                bpm: record.bpm,
                beats: record.beats,
                subdivision: record.subdivision
            )
        }
        switch order {
        case .newestFirst:
            return items
        case .oldestFirst:
            return Array(items.reversed())
        }
    }

    /// Builds session rows and their real per-completion children for history.
    /// `hand == nil` means all hands. Aggregate-only legacy records remain as
    /// sessions but deliberately have no fabricated completion children.
    static func historySessions(
        records: [PracticeHistoryRecordSnapshot],
        hand: PracticeHand? = nil,
        order: StatisticsTimelineOrder = .newestFirst
    ) -> [PracticeHistorySessionDetail] {
        let details = records.compactMap { record -> PracticeHistorySessionDetail? in
            let summaryStats: HandPracticeStats
            if let hand {
                summaryStats = record.stats(for: hand)
            } else {
                summaryStats = HandPracticeStats(
                    count: record.totalCount,
                    durationMilliseconds: record.totalDurationMilliseconds
                )
            }
            let samples = record.completionSamples(for: hand)
            guard summaryStats.count > 0
                    || summaryStats.durationMilliseconds > 0
                    || !samples.isEmpty
            else { return nil }

            let isLegacyManualBatch = isLegacyManualBackfillBatch(
                samples: samples,
                record: record,
                selectedHand: hand
            )
            let liveSamples = isLegacyManualBatch
                ? []
                : samples.filter { $0.source == .live }
            let attempts = liveSamples.enumerated().map { index, sample in
                PracticeHistoryCompletionEntry(
                    id: sample.id,
                    sequenceNumber: index + 1,
                    completedAt: sample.completedAt,
                    hand: sample.hand,
                    preset: sample.preset.normalized
                )
            }

            struct ManualKey: Hashable {
                let hand: PracticeHand
                let preset: MetronomePreset
            }
            var unitemized = Dictionary(
                grouping: samples.filter {
                    $0.source == .manualBackfill || isLegacyManualBatch
                }
            ) {
                ManualKey(hand: $0.hand, preset: $0.preset.normalized)
            }.map { key, values in
                PracticeHistoryUnitemizedCompletionSummary(
                    recordID: record.id,
                    hand: key.hand,
                    count: values.count,
                    preset: key.preset,
                    reason: .manualBackfill,
                    completionIDs: values.map(\.id).sorted {
                        $0.uuidString < $1.uuidString
                    },
                    completedAt: values.map(\.completedAt).max()
                )
            }

            let sampledCountsByHand = Dictionary(
                grouping: record.completionSamples,
                by: \PracticeCompletionSample.hand
            ).mapValues(\.count)
            let visibleHands = hand.map { [$0] } ?? PracticeHand.controlOrder
            for visibleHand in visibleHands {
                let residualCount = max(
                    0,
                    record.stats(for: visibleHand).count
                        - (sampledCountsByHand[visibleHand] ?? 0)
                )
                guard residualCount > 0 else { continue }
                unitemized.append(
                    PracticeHistoryUnitemizedCompletionSummary(
                        recordID: record.id,
                        hand: visibleHand,
                        count: residualCount,
                        preset: record.preset(for: visibleHand),
                        reason: .legacyAggregate,
                        completionIDs: [],
                        completedAt: nil
                    )
                )
            }
            let handOrder = Dictionary(
                uniqueKeysWithValues: PracticeHand.controlOrder.enumerated().map {
                    ($0.element, $0.offset)
                }
            )
            unitemized.sort { lhs, rhs in
                let leftHand = handOrder[lhs.hand] ?? Int.max
                let rightHand = handOrder[rhs.hand] ?? Int.max
                if leftHand != rightHand { return leftHand < rightHand }
                if lhs.reason != rhs.reason {
                    return lhs.reason == .manualBackfill
                }
                return (lhs.preset?.bpm ?? Int.max) < (rhs.preset?.bpm ?? Int.max)
            }
            return PracticeHistorySessionDetail(
                record: record,
                selectedHand: hand,
                attempts: attempts,
                unitemizedCompletions: unitemized
            )
        }

        let newestFirst = details.sorted { lhs, rhs in
            if lhs.finishedAt != rhs.finishedAt {
                return lhs.finishedAt > rhs.finishedAt
            }
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        switch order {
        case .newestFirst: return newestFirst
        case .oldestFirst: return Array(newestFirst.reversed())
        }
    }

    /// Versions through 5.3(4) represented one manual aggregate as N samples
    /// spaced exactly 1 ms apart and ending at the session finish. Only
    /// source-less legacy payloads matching the complete signature qualify;
    /// an explicitly persisted source always wins.
    private static func isLegacyManualBackfillBatch(
        samples: [PracticeCompletionSample],
        record: PracticeHistoryRecordSnapshot,
        selectedHand: PracticeHand?
    ) -> Bool {
        guard samples.count > 1,
              samples.allSatisfy({
                  !$0.hasExplicitSource && $0.source == .live
              }),
              let first = samples.first,
              samples.allSatisfy({
                  $0.hand == first.hand
                      && $0.preset.normalized == first.preset.normalized
              })
        else { return false }

        let expectedCount = selectedHand == nil
            ? record.totalCount
            : record.stats(for: first.hand).count
        guard expectedCount == samples.count,
              abs((samples.last?.completedAt ?? .distantPast)
                  .timeIntervalSince(record.finishedAt)) <= 0.000_25
        else { return false }

        return zip(samples, samples.dropFirst()).allSatisfy { earlier, later in
            abs(later.completedAt.timeIntervalSince(earlier.completedAt) - 0.001)
                <= 0.000_25
        }
    }

    static func weekBuckets(
        records: [PracticeHistoryRecordSnapshot],
        week anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeDailyBucket] {
        let interval = periodInterval(
            for: .week,
            anchorDate: anchorDate,
            calendar: calendar
        )
        let grouped = dailyRecords(records: records, calendar: calendar)
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: interval.start
            ) else { return nil }
            let day = calendar.startOfDay(for: date)
            let samples = grouped[day] ?? []
            return PracticeDailyBucket(
                date: day,
                totalCount: StatisticsMath.saturatedSum(samples.map(\.totalCount)),
                sessionCount: samples.count,
                totalDurationMilliseconds: StatisticsMath.saturatedSum(
                    samples.map(\.totalDurationMilliseconds)
                )
            )
        }
    }

    /// A stable six-week grid keeps the month UI from jumping between 5 and
    /// 6 rows and always includes leading/trailing placeholder days.
    static func monthCalendar(
        records: [PracticeHistoryRecordSnapshot],
        month anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeCalendarDay] {
        let monthInterval = periodInterval(
            for: .month,
            anchorDate: anchorDate,
            calendar: calendar
        )
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDays,
            to: monthInterval.start
        ) ?? monthInterval.start
        let grouped = dailyRecords(records: records, calendar: calendar)

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: gridStart
            ) else { return nil }
            let day = calendar.startOfDay(for: date)
            let samples = grouped[day] ?? []
            return PracticeCalendarDay(
                date: day,
                isInDisplayedMonth: monthInterval.containsHalfOpen(day),
                totalCount: StatisticsMath.saturatedSum(samples.map(\.totalCount)),
                sessionCount: samples.count,
                totalDurationMilliseconds: StatisticsMath.saturatedSum(
                    samples.map(\.totalDurationMilliseconds)
                )
            )
        }
    }

    static func yearBuckets(
        records: [PracticeHistoryRecordSnapshot],
        year anchorDate: Date,
        calendar: Calendar = .current
    ) -> [PracticeMonthlyBucket] {
        let yearInterval = periodInterval(
            for: .year,
            anchorDate: anchorDate,
            calendar: calendar
        )
        return (0..<12).compactMap { offset in
            guard let monthStart = calendar.date(
                byAdding: .month,
                value: offset,
                to: yearInterval.start
            ) else { return nil }
            let interval = periodInterval(
                for: .month,
                anchorDate: monthStart,
                calendar: calendar
            )
            let samples = records.filter {
                interval.containsHalfOpen($0.startedAt)
            }
            let month = calendar.component(.month, from: monthStart)
            let monthSummary = summary(records: samples, calendar: calendar)
            return PracticeMonthlyBucket(
                month: month,
                startDate: monthStart,
                totalCount: monthSummary.totalCount,
                sessionCount: monthSummary.sessionCount,
                activeDayCount: monthSummary.activeDayCount,
                totalDurationMilliseconds: monthSummary.totalDurationMilliseconds
            )
        }
    }

    private enum EventGroupKey: Hashable {
        case event(UUID)
        case name(String)
    }

    private static func aggregateEvents(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar
    ) -> [PracticeEventStatistics] {
        let grouped = Dictionary(grouping: records) { record in
            if let eventID = record.sourceEventID {
                return EventGroupKey.event(eventID)
            }
            return EventGroupKey.name(record.eventNameSnapshot)
        }

        return grouped.compactMap { key, records in
            guard let latest = sortedLatestFinishedFirst(records).first else { return nil }
            var dailyCounts: [Date: Int] = [:]
            var dailySessionCounts: [Date: Int] = [:]
            for record in records {
                let day = calendar.startOfDay(for: record.startedAt)
                dailyCounts[day] = StatisticsMath.saturatedAdd(
                    dailyCounts[day] ?? 0,
                    record.totalCount
                )
                dailySessionCounts[day] = StatisticsMath.saturatedAdd(
                    dailySessionCounts[day] ?? 0,
                    1
                )
            }
            let aggregate = summary(records: records, calendar: calendar)
            let eventID: UUID?
            switch key {
            case let .event(id): eventID = id
            case .name: eventID = nil
            }
            return PracticeEventStatistics(
                eventID: eventID,
                name: latest.eventNameSnapshot,
                totalCount: aggregate.totalCount,
                sessionCount: aggregate.sessionCount,
                activeDayCount: aggregate.activeDayCount,
                totalDurationMilliseconds: aggregate.totalDurationMilliseconds,
                dailyCounts: dailyCounts,
                dailySessionCounts: dailySessionCounts,
                latestFinishedAt: latest.finishedAt
            )
        }.sorted { lhs, rhs in
            if lhs.latestFinishedAt != rhs.latestFinishedAt {
                return lhs.latestFinishedAt > rhs.latestFinishedAt
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }

    private static func dailyRecords(
        records: [PracticeHistoryRecordSnapshot],
        calendar: Calendar
    ) -> [Date: [PracticeHistoryRecordSnapshot]] {
        Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.startedAt)
        }
    }

    private static func sortedNewestFirst(
        _ records: [PracticeHistoryRecordSnapshot]
    ) -> [PracticeHistoryRecordSnapshot] {
        records.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func sortedLatestFinishedFirst(
        _ records: [PracticeHistoryRecordSnapshot]
    ) -> [PracticeHistoryRecordSnapshot] {
        records.sorted { lhs, rhs in
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private enum StatisticsMath {
    static func saturatedAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        return overflowed ? T.max : result
    }

    static func saturatedSum<T: FixedWidthInteger>(_ values: [T]) -> T {
        values.reduce(0, saturatedAdd)
    }
}

private extension DateInterval {
    func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
