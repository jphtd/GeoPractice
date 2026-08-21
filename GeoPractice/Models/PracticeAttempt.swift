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
            sessionID: sessionID
        )
    }

    var completions: [PracticeCompletionSample] {
        Self.decode([PracticeCompletionSample].self, from: completionSamplesData) ?? []
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
}
