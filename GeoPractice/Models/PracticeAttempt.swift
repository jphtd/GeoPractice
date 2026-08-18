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
    var startedAt: Date
    var finishedAt: Date
    var createdAt: Date

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

    init(
        id: UUID = UUID(),
        eventID: UUID,
        summary: PracticeSessionSummary,
        createdAt: Date = .now
    ) {
        self.id = id
        sessionID = summary.sessionID
        self.eventID = eventID
        self.createdAt = createdAt
        startedAt = summary.startedAt ?? summary.finishedAt ?? createdAt
        finishedAt = summary.finishedAt ?? createdAt

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
    }

    var recordedAt: Date { createdAt }

    var completions: [PracticeCompletionSample] {
        Self.decode([PracticeCompletionSample].self, from: completionSamplesData) ?? []
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
