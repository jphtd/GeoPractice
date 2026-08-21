import Foundation
import SwiftData

enum PracticeHand: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: "左手"
        case .right: "右手"
        case .both: "合手"
        }
    }

    var shortTitle: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .both: "B"
        }
    }

    static let controlOrder: [PracticeHand] = [.left, .both, .right]
}

enum PracticeAttemptPersistenceError: LocalizedError, Equatable {
    case sourceEventMismatch
    case sessionAlreadyAssignedToAnotherEvent

    var errorDescription: String? {
        switch self {
        case .sourceEventMismatch:
            "本次练习并非从这条练习记录进入，无法追加。"
        case .sessionAlreadyAssignedToAnotherEvent:
            "本次练习已经追加到另一条练习记录。"
        }
    }
}

struct PracticeEventAggregateSnapshot: Equatable, Sendable {
    let leftCount: Int
    let rightCount: Int
    let bothCount: Int
    let leftDurationMilliseconds: Int64?
    let rightDurationMilliseconds: Int64?
    let bothDurationMilliseconds: Int64?
    let updatedAt: Date
}

enum PracticeAttemptCommitDisposition: Equatable, Sendable {
    case inserted
    case alreadyCommitted
}

struct PracticeAttemptCommitResult {
    let attempt: PracticeAttempt
    let disposition: PracticeAttemptCommitDisposition

    var wasInserted: Bool { disposition == .inserted }
}

@Model
final class PracticeEvent {
    @Attribute(.unique) var id: UUID
    var name: String
    var leftCount: Int
    var rightCount: Int
    var bothCount: Int
    var leftDurationMilliseconds: Int64?
    var rightDurationMilliseconds: Int64?
    var bothDurationMilliseconds: Int64?
    var bpm: Int
    var beats: Int
    var subdivision: Int
    var directionRawValue: String
    var grouping: String
    var referenceNoteRaw: String?
    var createdAt: Date
    var updatedAt: Date
    private var goalPlanData: Data?

    init(
        id: UUID = UUID(),
        name: String,
        leftCount: Int = 0,
        rightCount: Int = 0,
        bothCount: Int = 0,
        leftDurationMilliseconds: Int64? = nil,
        rightDurationMilliseconds: Int64? = nil,
        bothDurationMilliseconds: Int64? = nil,
        preset: MetronomePreset = .standard,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        let preset = preset.normalized
        self.id = id
        self.name = name
        self.leftCount = max(0, leftCount)
        self.rightCount = max(0, rightCount)
        self.bothCount = max(0, bothCount)
        self.leftDurationMilliseconds = leftDurationMilliseconds.map { max(0, $0) }
        self.rightDurationMilliseconds = rightDurationMilliseconds.map { max(0, $0) }
        self.bothDurationMilliseconds = bothDurationMilliseconds.map { max(0, $0) }
        self.bpm = preset.bpm
        self.beats = preset.beats
        self.subdivision = preset.subdivision
        self.directionRawValue = preset.direction.rawValue
        self.grouping = preset.grouping
        self.referenceNoteRaw = preset.referenceNoteRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.goalPlanData = nil
    }

    var preset: MetronomePreset {
        MetronomePreset(
            bpm: bpm,
            beats: beats,
            subdivision: subdivision,
            direction: RotationDirection(rawValue: directionRawValue) ?? .counterclockwise,
            grouping: grouping,
            referenceNoteRaw: referenceNoteRaw
        ).normalized
    }

    var totalCount: Int {
        Self.saturatedSum([leftCount, rightCount, bothCount])
    }

    var totalDurationMilliseconds: Int64 {
        Self.saturatedSum([
            durationMilliseconds(for: .left),
            durationMilliseconds(for: .right),
            durationMilliseconds(for: .both)
        ])
    }

    var goalPlan: PracticeGoalPlan? {
        guard let goalPlanData else { return nil }
        return try? JSONDecoder().decode(
            PracticeGoalPlan.self,
            from: goalPlanData
        )
    }

    var hasGoalPlan: Bool { goalPlan != nil }

    func enableGoalPlan(
        targets: PracticeGoalCounts,
        at date: Date = .now
    ) {
        let plan = PracticeGoalPlan(
            targets: targets,
            baseline: PracticeGoalCounts(
                left: leftCount,
                right: rightCount,
                both: bothCount
            ),
            enabledAt: date
        )
        goalPlanData = try? JSONEncoder().encode(plan)
        updatedAt = date
    }

    func updateGoalPlanTargets(
        _ targets: PracticeGoalCounts,
        at date: Date = .now
    ) {
        if let current = goalPlan {
            setGoalPlan(
                PracticeGoalPlan(
                    id: current.id,
                    targets: targets,
                    baseline: current.baseline,
                    enabledAt: current.enabledAt
                ),
                at: date
            )
        } else {
            enableGoalPlan(targets: targets, at: date)
        }
    }

    func setGoalPlan(
        _ plan: PracticeGoalPlan?,
        at date: Date = .now
    ) {
        goalPlanData = plan.flatMap { try? JSONEncoder().encode($0) }
        updatedAt = date
    }

    func disableGoalPlan(at date: Date = .now) {
        setGoalPlan(nil, at: date)
    }

    func apply(preset: MetronomePreset) {
        let preset = preset.normalized
        bpm = preset.bpm
        beats = preset.beats
        subdivision = preset.subdivision
        directionRawValue = preset.direction.rawValue
        grouping = preset.grouping
        referenceNoteRaw = preset.referenceNoteRaw
        updatedAt = .now
    }

    func setCount(_ value: Int, for hand: PracticeHand) {
        let value = max(0, value)
        switch hand {
        case .left: leftCount = value
        case .right: rightCount = value
        case .both: bothCount = value
        }
        updatedAt = .now
    }

    func count(for hand: PracticeHand) -> Int {
        switch hand {
        case .left: leftCount
        case .right: rightCount
        case .both: bothCount
        }
    }

    func durationMilliseconds(for hand: PracticeHand) -> Int64 {
        switch hand {
        case .left: max(0, leftDurationMilliseconds ?? 0)
        case .right: max(0, rightDurationMilliseconds ?? 0)
        case .both: max(0, bothDurationMilliseconds ?? 0)
        }
    }

    func append(summary: PracticeSessionSummary) {
        for hand in PracticeHand.allCases {
            let stats = summary.stats(for: hand)
            setCount(Self.saturatedSum([count(for: hand), stats.count]), for: hand)
            setDurationMilliseconds(
                Self.saturatedSum([durationMilliseconds(for: hand), stats.durationMilliseconds]),
                for: hand
            )
        }
        updatedAt = .now
    }

    /// Atomically stages both the legacy aggregate update and an immutable
    /// attempt. Replaying the same session is a no-op and returns the existing
    /// object, which keeps crash/retry handling idempotent.
    @discardableResult
    func append(
        summary: PracticeSessionSummary,
        in context: ModelContext
    ) throws -> PracticeAttempt {
        if let sourceEventID = summary.sourceEventID, sourceEventID != id {
            throw PracticeAttemptPersistenceError.sourceEventMismatch
        }

        if let existing = try PracticeAttempt.find(
            sessionID: summary.sessionID,
            in: context
        ) {
            guard existing.eventID == id else {
                throw PracticeAttemptPersistenceError.sessionAlreadyAssignedToAnotherEvent
            }
            return existing
        }

        let attempt = PracticeAttempt(
            eventID: id,
            eventNameSnapshot: name,
            summary: summary
        )
        append(summary: summary)
        context.insert(attempt)
        return attempt
    }

    /// Persists the attempt and aggregate as one user-visible commit. SwiftData
    /// removes an inserted model on rollback but does not reliably restore the
    /// live `PracticeEvent` instance, so the explicit snapshot is essential to
    /// prevent a failed save from leaving false totals on screen.
    @discardableResult
    func commit(
        summary: PracticeSessionSummary,
        in context: ModelContext
    ) throws -> PracticeAttemptCommitResult {
        try commit(summary: summary, in: context) {
            try context.save()
        }
    }

    /// Injection point used by deterministic persistence-failure tests.
    @discardableResult
    func commit(
        summary: PracticeSessionSummary,
        in context: ModelContext,
        saving: () throws -> Void
    ) throws -> PracticeAttemptCommitResult {
        if let sourceEventID = summary.sourceEventID, sourceEventID != id {
            throw PracticeAttemptPersistenceError.sourceEventMismatch
        }

        if let existing = try PracticeAttempt.find(
            sessionID: summary.sessionID,
            in: context
        ) {
            guard existing.eventID == id else {
                throw PracticeAttemptPersistenceError.sessionAlreadyAssignedToAnotherEvent
            }
            return PracticeAttemptCommitResult(
                attempt: existing,
                disposition: .alreadyCommitted
            )
        }

        let snapshot = aggregateSnapshot()
        let attempt = PracticeAttempt(
            eventID: id,
            eventNameSnapshot: name,
            summary: summary
        )
        append(summary: summary)
        context.insert(attempt)
        do {
            try saving()
            return PracticeAttemptCommitResult(
                attempt: attempt,
                disposition: .inserted
            )
        } catch {
            context.rollback()
            restoreAggregate(from: snapshot)
            throw error
        }
    }

    func aggregateSnapshot() -> PracticeEventAggregateSnapshot {
        PracticeEventAggregateSnapshot(
            leftCount: leftCount,
            rightCount: rightCount,
            bothCount: bothCount,
            leftDurationMilliseconds: leftDurationMilliseconds,
            rightDurationMilliseconds: rightDurationMilliseconds,
            bothDurationMilliseconds: bothDurationMilliseconds,
            updatedAt: updatedAt
        )
    }

    func restoreAggregate(from snapshot: PracticeEventAggregateSnapshot) {
        leftCount = snapshot.leftCount
        rightCount = snapshot.rightCount
        bothCount = snapshot.bothCount
        leftDurationMilliseconds = snapshot.leftDurationMilliseconds
        rightDurationMilliseconds = snapshot.rightDurationMilliseconds
        bothDurationMilliseconds = snapshot.bothDurationMilliseconds
        updatedAt = snapshot.updatedAt
    }

    func inheritedPreset(
        for hand: PracticeHand,
        in context: ModelContext
    ) throws -> MetronomePreset? {
        try PracticeAttempt.latestMostPracticedPreset(
            for: id,
            hand: hand,
            in: context
        )
    }

    func increment(_ hand: PracticeHand) {
        setCount(Self.saturatedSum([count(for: hand), 1]), for: hand)
    }

    func decrement(_ hand: PracticeHand) {
        let current = max(0, count(for: hand))
        setCount(current > 0 ? current - 1 : 0, for: hand)
    }

    func setDurationMilliseconds(_ value: Int64, for hand: PracticeHand) {
        let value = max(0, value)
        switch hand {
        case .left: leftDurationMilliseconds = value
        case .right: rightDurationMilliseconds = value
        case .both: bothDurationMilliseconds = value
        }
    }

    private static func saturatedSum<T: FixedWidthInteger>(_ values: [T]) -> T {
        values.reduce(0) { partialResult, value in
            let (sum, overflowed) = partialResult.addingReportingOverflow(value)
            return overflowed ? T.max : sum
        }
    }
}
