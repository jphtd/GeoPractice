import Foundation

struct HandPracticeStats: Codable, Equatable, Sendable {
    private(set) var count: Int
    private(set) var durationMilliseconds: Int64

    init(count: Int = 0, durationMilliseconds: Int64 = 0) {
        self.count = max(0, count)
        self.durationMilliseconds = max(0, durationMilliseconds)
    }

    mutating func adjustCount(by delta: Int) {
        let (adjusted, overflowed) = count.addingReportingOverflow(delta)
        if overflowed {
            count = delta >= 0 ? Int.max : 0
        } else {
            count = max(0, adjusted)
        }
    }

    mutating func addDuration(milliseconds: Int64) {
        guard milliseconds > 0 else { return }
        let (adjusted, overflowed) = durationMilliseconds.addingReportingOverflow(milliseconds)
        durationMilliseconds = overflowed ? Int64.max : adjusted
    }
}

struct PracticeSessionSummary: Codable, Equatable, Sendable {
    let sourceEventID: UUID?
    let startedAt: Date?
    let finishedAt: Date?
    let left: HandPracticeStats
    let right: HandPracticeStats
    let both: HandPracticeStats

    init(
        sourceEventID: UUID? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        left: HandPracticeStats = HandPracticeStats(),
        right: HandPracticeStats = HandPracticeStats(),
        both: HandPracticeStats = HandPracticeStats()
    ) {
        self.sourceEventID = sourceEventID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.left = left
        self.right = right
        self.both = both
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    var totalCount: Int {
        Self.saturatedSum([left.count, right.count, both.count])
    }

    var totalDurationMilliseconds: Int64 {
        Self.saturatedSum([
            left.durationMilliseconds,
            right.durationMilliseconds,
            both.durationMilliseconds
        ])
    }

    private static func saturatedSum<T: FixedWidthInteger>(_ values: [T]) -> T {
        values.reduce(0) { partialResult, value in
            let (sum, overflowed) = partialResult.addingReportingOverflow(value)
            return overflowed ? T.max : sum
        }
    }
}

struct PracticeSession: Codable, Equatable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case idle
        case running
        case paused
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var sourceEventID: UUID?
    private(set) var currentHand: PracticeHand = .both
    private(set) var startedAt: Date?
    private(set) var segmentStartedAt: Date?

    private var left = HandPracticeStats()
    private var right = HandPracticeStats()
    private var both = HandPracticeStats()
    private var completedSummary: PracticeSessionSummary?

    var isRunning: Bool { phase == .running }
    var reviewSummary: PracticeSessionSummary? {
        phase == .finished ? completedSummary : nil
    }

    mutating func begin(sourceEventID: UUID? = nil, at date: Date) {
        guard phase == .idle else { return }
        self.sourceEventID = sourceEventID
        currentHand = .both
        startedAt = date
        segmentStartedAt = date
        phase = .running
    }

    mutating func resume(at date: Date) {
        guard phase == .paused else { return }
        segmentStartedAt = normalized(date, notBefore: startedAt)
        phase = .running
    }

    mutating func pause(at date: Date) {
        guard phase == .running else { return }
        settleCurrentSegment(at: date)
        segmentStartedAt = nil
        phase = .paused
    }

    mutating func switchHand(to hand: PracticeHand, at date: Date) {
        guard hand != currentHand, phase == .running || phase == .paused else { return }

        if phase == .running {
            let nextSegmentStart = normalized(date, notBefore: segmentStartedAt)
            settleCurrentSegment(at: nextSegmentStart)
            segmentStartedAt = nextSegmentStart
        }
        currentHand = hand
    }

    mutating func adjustCount(for hand: PracticeHand, by delta: Int) {
        guard phase == .running || phase == .paused else { return }
        withStats(for: hand) { $0.adjustCount(by: delta) }
    }

    func stats(for hand: PracticeHand, at date: Date) -> HandPracticeStats {
        var result = storedStats(for: hand)
        if phase == .running, hand == currentHand {
            result.addDuration(milliseconds: currentSegmentMilliseconds(at: date))
        }
        return result
    }

    func currentSegmentMilliseconds(at date: Date) -> Int64 {
        guard phase == .running, let segmentStartedAt else { return 0 }
        return Self.milliseconds(from: segmentStartedAt, to: date)
    }

    @discardableResult
    mutating func finish(at date: Date) -> PracticeSessionSummary? {
        if phase == .finished {
            return completedSummary
        }
        guard phase == .running || phase == .paused else { return nil }

        let finishedAt: Date
        if phase == .running {
            finishedAt = normalized(date, notBefore: segmentStartedAt)
            settleCurrentSegment(at: finishedAt)
            segmentStartedAt = nil
        } else {
            finishedAt = normalized(date, notBefore: startedAt)
        }

        phase = .finished
        let summary = PracticeSessionSummary(
            sourceEventID: sourceEventID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            left: left,
            right: right,
            both: both
        )
        completedSummary = summary
        return summary
    }

    mutating func reset() {
        self = PracticeSession()
    }

    mutating func continueAfterReview(at date: Date) {
        guard phase == .finished else { return }
        completedSummary = nil
        segmentStartedAt = date
        phase = .running
    }

    private func storedStats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    private mutating func withStats(
        for hand: PracticeHand,
        _ update: (inout HandPracticeStats) -> Void
    ) {
        switch hand {
        case .left: update(&left)
        case .right: update(&right)
        case .both: update(&both)
        }
    }

    private mutating func settleCurrentSegment(at date: Date) {
        let elapsed = currentSegmentMilliseconds(at: date)
        withStats(for: currentHand) { $0.addDuration(milliseconds: elapsed) }
    }

    private func normalized(_ date: Date, notBefore lowerBound: Date?) -> Date {
        guard let lowerBound else { return date }
        return max(date, lowerBound)
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int64 {
        let interval = max(0, end.timeIntervalSince(start))
        let milliseconds = interval * 1_000
        guard milliseconds.isFinite else { return Int64.max }
        if milliseconds >= Double(Int64.max) { return Int64.max }
        return Int64(milliseconds.rounded())
    }
}
