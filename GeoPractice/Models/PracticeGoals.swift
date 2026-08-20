import Foundation
import SwiftData

struct PracticeGoalCounts: Codable, Equatable, Sendable {
    let left: Int
    let right: Int
    let both: Int

    init(left: Int = 0, right: Int = 0, both: Int = 0) {
        self.left = max(0, left)
        self.right = max(0, right)
        self.both = max(0, both)
    }

    init(summary: PracticeSessionSummary) {
        self.init(
            left: summary.left.count,
            right: summary.right.count,
            both: summary.both.count
        )
    }

    init(attempt: PracticeAttempt) {
        self.init(
            left: attempt.leftCount,
            right: attempt.rightCount,
            both: attempt.bothCount
        )
    }

    func value(for hand: PracticeHand) -> Int {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    var total: Int {
        Self.saturatedSum([left, right, both])
    }

    func adding(_ other: PracticeGoalCounts) -> PracticeGoalCounts {
        PracticeGoalCounts(
            left: Self.saturatedSum([left, other.left]),
            right: Self.saturatedSum([right, other.right]),
            both: Self.saturatedSum([both, other.both])
        )
    }

    func subtractingFloorAtZero(_ other: PracticeGoalCounts) -> PracticeGoalCounts {
        PracticeGoalCounts(
            left: Self.nonnegativeDifference(left, other.left),
            right: Self.nonnegativeDifference(right, other.right),
            both: Self.nonnegativeDifference(both, other.both)
        )
    }

    func capped(to limits: PracticeGoalCounts) -> PracticeGoalCounts {
        PracticeGoalCounts(
            left: min(left, limits.left),
            right: min(right, limits.right),
            both: min(both, limits.both)
        )
    }

    private static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { result, value in
            let (sum, overflowed) = result.addingReportingOverflow(value)
            return overflowed ? Int.max : sum
        }
    }

    private static func nonnegativeDifference(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > rhs else { return 0 }
        let (difference, overflowed) = lhs.subtractingReportingOverflow(rhs)
        return overflowed ? Int.max : difference
    }
}

struct PracticeGoalProgress: Codable, Equatable, Sendable {
    let targets: PracticeGoalCounts
    let completed: PracticeGoalCounts
    let remaining: PracticeGoalCounts
    let completionRate: Double
    let isComplete: Bool

    /// Overall progress credits each hand only up to its own target. Actual
    /// over-target repetitions remain visible in the per-hand rows, but they
    /// cannot make the aggregate fraction contradict the completion rate.
    var creditedCompletedTotal: Int {
        completed.capped(to: targets).total
    }

    init(targets: PracticeGoalCounts, completed: PracticeGoalCounts) {
        self.targets = targets
        self.completed = completed
        remaining = targets.subtractingFloorAtZero(completed)

        // Each hand earns at most its own target. Extra repetitions for one
        // hand therefore cannot hide unfinished work for another hand.
        let targetTotal = targets.total
        let creditedTotal = completed.capped(to: targets).total
        if targetTotal > 0 {
            completionRate = min(1, Double(creditedTotal) / Double(targetTotal))
            isComplete = remaining.total == 0
        } else {
            completionRate = 0
            isComplete = false
        }
    }
}

struct PracticeGoalPlan: Codable, Equatable, Sendable {
    let id: UUID
    let targets: PracticeGoalCounts
    let baseline: PracticeGoalCounts
    let enabledAt: Date

    init(
        id: UUID = UUID(),
        targets: PracticeGoalCounts,
        baseline: PracticeGoalCounts,
        enabledAt: Date = .now
    ) {
        self.id = id
        self.targets = targets
        self.baseline = baseline
        self.enabledAt = enabledAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, targets, baseline, enabledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        targets = try container.decode(PracticeGoalCounts.self, forKey: .targets)
        baseline = try container.decode(PracticeGoalCounts.self, forKey: .baseline)
        enabledAt = try container.decode(Date.self, forKey: .enabledAt)
    }
}

enum PracticeGoalScope: String, Codable, Equatable, Sendable {
    case daily
    case plan
}

@Model
final class PracticeDailyGoal {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var eventID: UUID
    var planID: UUID?
    var localDay: String
    var timeZoneIdentifier: String
    var timeZoneSecondsFromGMT: Int
    var leftTarget: Int
    var rightTarget: Int
    var bothTarget: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        eventID: UUID,
        planID: UUID? = nil,
        targets: PracticeGoalCounts,
        date: Date = .now,
        timeZone: TimeZone = .current,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        let localDay = Self.localDay(containing: date, timeZone: timeZone)
        self.id = id
        self.eventID = eventID
        self.planID = planID
        self.localDay = localDay
        self.key = Self.makeKey(
            eventID: eventID,
            planID: planID,
            localDay: localDay
        )
        self.timeZoneIdentifier = timeZone.identifier
        self.timeZoneSecondsFromGMT = timeZone.secondsFromGMT(for: date)
        self.leftTarget = targets.left
        self.rightTarget = targets.right
        self.bothTarget = targets.both
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var targets: PracticeGoalCounts {
        PracticeGoalCounts(
            left: leftTarget,
            right: rightTarget,
            both: bothTarget
        )
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: timeZoneSecondsFromGMT)
            ?? TimeZone(secondsFromGMT: 0)!
    }

    func updateTargets(_ targets: PracticeGoalCounts, at date: Date = .now) {
        leftTarget = targets.left
        rightTarget = targets.right
        bothTarget = targets.both
        updatedAt = date
    }

    static func today(
        for eventID: UUID,
        planID: UUID? = nil,
        at date: Date = .now,
        timeZone: TimeZone = .current,
        in context: ModelContext
    ) throws -> PracticeDailyGoal? {
        let key = makeKey(
            eventID: eventID,
            planID: planID,
            localDay: localDay(containing: date, timeZone: timeZone)
        )
        var descriptor = FetchDescriptor<PracticeDailyGoal>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func previous(
        for eventID: UUID,
        planID: UUID? = nil,
        before date: Date = .now,
        timeZone: TimeZone = .current,
        in context: ModelContext
    ) throws -> PracticeDailyGoal? {
        let currentDay = localDay(containing: date, timeZone: timeZone)
        return try history(for: eventID, in: context).first {
            $0.planID == planID && $0.localDay < currentDay
        }
    }

    @discardableResult
    static func create(
        for eventID: UUID,
        planID: UUID? = nil,
        targets: PracticeGoalCounts,
        at date: Date = .now,
        timeZone: TimeZone = .current,
        in context: ModelContext
    ) throws -> PracticeDailyGoal {
        if let existing = try today(
            for: eventID,
            planID: planID,
            at: date,
            timeZone: timeZone,
            in: context
        ) {
            existing.updateTargets(targets, at: date)
            return existing
        }

        let goal = PracticeDailyGoal(
            eventID: eventID,
            planID: planID,
            targets: targets,
            date: date,
            timeZone: timeZone,
            createdAt: date,
            updatedAt: date
        )
        context.insert(goal)
        return goal
    }

    static func history(
        for eventID: UUID,
        in context: ModelContext
    ) throws -> [PracticeDailyGoal] {
        let targetEventID = eventID
        let descriptor = FetchDescriptor<PracticeDailyGoal>(
            predicate: #Predicate { $0.eventID == targetEventID },
            sortBy: [
                SortDescriptor(\PracticeDailyGoal.localDay, order: .reverse),
                SortDescriptor(\PracticeDailyGoal.createdAt, order: .reverse)
            ]
        )
        return try context.fetch(descriptor)
    }

    static func deleteAll(for eventID: UUID, in context: ModelContext) throws {
        for goal in try history(for: eventID, in: context) {
            context.delete(goal)
        }
    }

    static func localDay(containing date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    static func makeKey(
        eventID: UUID,
        planID: UUID? = nil,
        localDay: String
    ) -> String {
        let planComponent = planID?.uuidString.lowercased() ?? "legacy"
        return "\(eventID.uuidString.lowercased())|\(planComponent)|\(localDay)"
    }
}

struct PracticeGoalLaunchContext: Codable, Equatable, Sendable {
    let eventID: UUID
    let launchedAt: Date
    let localDay: String
    let timeZoneIdentifier: String
    let timeZoneSecondsFromGMT: Int
    let dailyGoalKey: String?
    let dailyTargets: PracticeGoalCounts?
    let dailyCompletedBeforeSession: PracticeGoalCounts
    let plan: PracticeGoalPlan?
    let planCompletedBeforeSession: PracticeGoalCounts

    init(
        eventID: UUID,
        launchedAt: Date,
        localDay: String,
        timeZoneIdentifier: String,
        timeZoneSecondsFromGMT: Int,
        dailyGoalKey: String? = nil,
        dailyTargets: PracticeGoalCounts? = nil,
        dailyCompletedBeforeSession: PracticeGoalCounts = PracticeGoalCounts(),
        plan: PracticeGoalPlan? = nil,
        planCompletedBeforeSession: PracticeGoalCounts = PracticeGoalCounts()
    ) {
        self.eventID = eventID
        self.launchedAt = launchedAt
        self.localDay = localDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeZoneSecondsFromGMT = timeZoneSecondsFromGMT
        self.dailyGoalKey = dailyGoalKey
        self.dailyTargets = dailyTargets
        self.dailyCompletedBeforeSession = dailyCompletedBeforeSession
        self.plan = plan
        self.planCompletedBeforeSession = planCompletedBeforeSession
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: timeZoneSecondsFromGMT)
            ?? TimeZone(secondsFromGMT: 0)!
    }

    static func capture(
        for event: PracticeEvent,
        dailyGoal: PracticeDailyGoal?,
        launchedAt: Date = .now,
        timeZone: TimeZone = .current,
        in context: ModelContext
    ) throws -> PracticeGoalLaunchContext? {
        let plan = event.goalPlan
        let validDailyGoal = dailyGoal.flatMap { goal in
            goal.eventID == event.id && goal.planID == plan?.id ? goal : nil
        }
        guard validDailyGoal != nil || plan != nil else { return nil }

        let dailyCompleted: PracticeGoalCounts
        if let key = validDailyGoal?.key {
            dailyCompleted = try PracticeAttempt.goalProgressCounts(
                dailyGoalKey: key,
                eventID: event.id,
                in: context
            )
        } else {
            dailyCompleted = PracticeGoalCounts()
        }

        let planCompleted: PracticeGoalCounts
        if let plan {
            planCompleted = PracticeGoalCounts(
                left: event.leftCount,
                right: event.rightCount,
                both: event.bothCount
            ).subtractingFloorAtZero(plan.baseline)
        } else {
            planCompleted = PracticeGoalCounts()
        }

        let launchTimeZone = validDailyGoal?.timeZone ?? timeZone
        let launchLocalDay = validDailyGoal?.localDay
            ?? PracticeDailyGoal.localDay(
                containing: launchedAt,
                timeZone: launchTimeZone
            )
        return PracticeGoalLaunchContext(
            eventID: event.id,
            launchedAt: launchedAt,
            localDay: launchLocalDay,
            timeZoneIdentifier: launchTimeZone.identifier,
            timeZoneSecondsFromGMT: launchTimeZone.secondsFromGMT(for: launchedAt),
            dailyGoalKey: validDailyGoal?.key,
            dailyTargets: validDailyGoal?.targets,
            dailyCompletedBeforeSession: dailyCompleted,
            plan: plan,
            planCompletedBeforeSession: planCompleted
        )
    }

    func progress(
        for scope: PracticeGoalScope,
        sessionCompleted: PracticeGoalCounts
    ) -> PracticeGoalProgress? {
        switch scope {
        case .daily:
            guard let dailyTargets else { return nil }
            return PracticeGoalProgress(
                targets: dailyTargets,
                completed: dailyCompletedBeforeSession.adding(sessionCompleted)
            )
        case .plan:
            guard let plan else { return nil }
            return PracticeGoalProgress(
                targets: plan.targets,
                completed: planCompletedBeforeSession.adding(sessionCompleted)
            )
        }
    }
}

struct PracticeGoalReportSnapshot: Codable, Equatable, Sendable {
    let launchContext: PracticeGoalLaunchContext
    let sessionCompleted: PracticeGoalCounts
    let dailyProgress: PracticeGoalProgress?
    let planProgress: PracticeGoalProgress?
    let generatedAt: Date

    init(
        launchContext: PracticeGoalLaunchContext,
        sessionCompleted: PracticeGoalCounts,
        generatedAt: Date
    ) {
        self.launchContext = launchContext
        self.sessionCompleted = sessionCompleted
        dailyProgress = launchContext.progress(
            for: .daily,
            sessionCompleted: sessionCompleted
        )
        planProgress = launchContext.progress(
            for: .plan,
            sessionCompleted: sessionCompleted
        )
        self.generatedAt = generatedAt
    }

    func progress(for scope: PracticeGoalScope) -> PracticeGoalProgress? {
        switch scope {
        case .daily: dailyProgress
        case .plan: planProgress
        }
    }
}
