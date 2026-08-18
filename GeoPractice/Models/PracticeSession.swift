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

/// One completed repetition at the exact metronome settings used for it.
struct PracticeCompletionSample: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let hand: PracticeHand
    let preset: MetronomePreset
    let completedAt: Date

    init(
        id: UUID = UUID(),
        hand: PracticeHand,
        preset: MetronomePreset,
        completedAt: Date = .now
    ) {
        self.id = id
        self.hand = hand
        self.preset = preset.normalized
        self.completedAt = completedAt
    }
}

/// A derived result keeps the complete preset, not only its BPM number.
struct PracticeSpeedRecord: Codable, Equatable, Sendable {
    let bpm: Int
    let preset: MetronomePreset
    let completionCount: Int
    let lastCompletedAt: Date

    init(
        preset: MetronomePreset,
        completionCount: Int,
        lastCompletedAt: Date
    ) {
        let preset = preset.normalized
        self.bpm = preset.bpm
        self.preset = preset
        self.completionCount = max(1, completionCount)
        self.lastCompletedAt = lastCompletedAt
    }
}

struct PracticeHandSpeedSummary: Codable, Equatable, Sendable {
    let mostPracticed: PracticeSpeedRecord?
    let maximumAttempt: PracticeSpeedRecord?

    init(
        mostPracticed: PracticeSpeedRecord? = nil,
        maximumAttempt: PracticeSpeedRecord? = nil
    ) {
        self.mostPracticed = mostPracticed
        self.maximumAttempt = maximumAttempt
    }

    init(samples: [PracticeCompletionSample], for hand: PracticeHand) {
        struct Aggregate {
            var count: Int
            var latestSample: PracticeCompletionSample
            var latestIndex: Int
        }

        var byBPM: [Int: Aggregate] = [:]
        for (index, sample) in samples.enumerated() where sample.hand == hand {
            let bpm = sample.preset.normalized.bpm
            if var aggregate = byBPM[bpm] {
                aggregate.count += 1
                if sample.completedAt > aggregate.latestSample.completedAt
                    || (sample.completedAt == aggregate.latestSample.completedAt
                        && index > aggregate.latestIndex) {
                    aggregate.latestSample = sample
                    aggregate.latestIndex = index
                }
                byBPM[bpm] = aggregate
            } else {
                byBPM[bpm] = Aggregate(
                    count: 1,
                    latestSample: sample,
                    latestIndex: index
                )
            }
        }

        func record(from aggregate: Aggregate?) -> PracticeSpeedRecord? {
            guard let aggregate else { return nil }
            return PracticeSpeedRecord(
                preset: aggregate.latestSample.preset,
                completionCount: aggregate.count,
                lastCompletedAt: aggregate.latestSample.completedAt
            )
        }

        let mostPracticedAggregate = byBPM.values.max { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            if lhs.latestSample.completedAt != rhs.latestSample.completedAt {
                return lhs.latestSample.completedAt < rhs.latestSample.completedAt
            }
            return lhs.latestIndex < rhs.latestIndex
        }
        let maximumAttemptAggregate = byBPM.max { lhs, rhs in
            lhs.key < rhs.key
        }?.value

        mostPracticed = record(from: mostPracticedAggregate)
        maximumAttempt = record(from: maximumAttemptAggregate)
    }
}

struct PracticeSessionSummary: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sourceEventID: UUID?
    let startedAt: Date?
    let finishedAt: Date?
    let left: HandPracticeStats
    let right: HandPracticeStats
    let both: HandPracticeStats
    let completions: [PracticeCompletionSample]

    init(
        sessionID: UUID = UUID(),
        sourceEventID: UUID? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        left: HandPracticeStats = HandPracticeStats(),
        right: HandPracticeStats = HandPracticeStats(),
        both: HandPracticeStats = HandPracticeStats(),
        completions: [PracticeCompletionSample] = []
    ) {
        self.sessionID = sessionID
        self.sourceEventID = sourceEventID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.left = left
        self.right = right
        self.both = both
        self.completions = completions
    }

    func stats(for hand: PracticeHand) -> HandPracticeStats {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    func speedSummary(for hand: PracticeHand) -> PracticeHandSpeedSummary {
        PracticeHandSpeedSummary(samples: completions, for: hand)
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

    private enum CodingKeys: String, CodingKey {
        case sessionID, sourceEventID, startedAt, finishedAt
        case left, right, both, completions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        sourceEventID = try container.decodeIfPresent(UUID.self, forKey: .sourceEventID)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        left = try container.decodeIfPresent(HandPracticeStats.self, forKey: .left)
            ?? HandPracticeStats()
        right = try container.decodeIfPresent(HandPracticeStats.self, forKey: .right)
            ?? HandPracticeStats()
        both = try container.decodeIfPresent(HandPracticeStats.self, forKey: .both)
            ?? HandPracticeStats()
        completions = try container.decodeIfPresent(
            [PracticeCompletionSample].self,
            forKey: .completions
        ) ?? []
    }
}

struct PracticeSession: Codable, Equatable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case idle
        case running
        case paused
        case finished
    }

    private static let idleSessionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    private(set) var sessionID: UUID = Self.idleSessionID
    private(set) var phase: Phase = .idle
    private(set) var sourceEventID: UUID?
    private(set) var currentHand: PracticeHand = .both
    private(set) var startedAt: Date?
    private(set) var segmentStartedAt: Date?

    private var left = HandPracticeStats()
    private var right = HandPracticeStats()
    private var both = HandPracticeStats()
    private var completions: [PracticeCompletionSample] = []
    private var completedSummary: PracticeSessionSummary?

    init() {}

    var isRunning: Bool { phase == .running }
    var reviewSummary: PracticeSessionSummary? {
        phase == .finished ? completedSummary : nil
    }

    mutating func begin(sourceEventID: UUID? = nil, at date: Date) {
        guard phase == .idle else { return }
        sessionID = UUID()
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

    /// Compatibility path for legacy callers that have no speed sample.
    /// New `+1` interactions should use `recordCompletion` so history is kept.
    mutating func adjustCount(for hand: PracticeHand, by delta: Int) {
        guard phase == .running || phase == .paused else { return }
        withStats(for: hand) { $0.adjustCount(by: delta) }
    }

    @discardableResult
    mutating func recordCompletion(
        for hand: PracticeHand,
        preset: MetronomePreset,
        at date: Date = .now
    ) -> PracticeCompletionSample? {
        guard phase == .running || phase == .paused else { return nil }
        let sample = PracticeCompletionSample(
            hand: hand,
            preset: preset,
            completedAt: normalized(date, notBefore: startedAt)
        )
        completions.append(sample)
        withStats(for: hand) { $0.adjustCount(by: 1) }
        return sample
    }

    @discardableResult
    mutating func undoLastCompletion(for hand: PracticeHand) -> PracticeCompletionSample? {
        guard phase == .running || phase == .paused,
              let index = completions.lastIndex(where: { $0.hand == hand })
        else { return nil }
        let removed = completions.remove(at: index)
        withStats(for: hand) { $0.adjustCount(by: -1) }
        return removed
    }

    func completionSamples(for hand: PracticeHand) -> [PracticeCompletionSample] {
        completions.filter { $0.hand == hand }
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
        if phase == .finished { return completedSummary }
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
            sessionID: sessionID,
            sourceEventID: sourceEventID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            left: left,
            right: right,
            both: both,
            completions: completions
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

    private enum CodingKeys: String, CodingKey {
        case sessionID, phase, sourceEventID, currentHand, startedAt, segmentStartedAt
        case left, right, both, completions, completedSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        sourceEventID = try container.decodeIfPresent(UUID.self, forKey: .sourceEventID)
        currentHand = try container.decodeIfPresent(PracticeHand.self, forKey: .currentHand)
            ?? .both
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        segmentStartedAt = try container.decodeIfPresent(Date.self, forKey: .segmentStartedAt)
        left = try container.decodeIfPresent(HandPracticeStats.self, forKey: .left)
            ?? HandPracticeStats()
        right = try container.decodeIfPresent(HandPracticeStats.self, forKey: .right)
            ?? HandPracticeStats()
        both = try container.decodeIfPresent(HandPracticeStats.self, forKey: .both)
            ?? HandPracticeStats()
        completions = try container.decodeIfPresent(
            [PracticeCompletionSample].self,
            forKey: .completions
        ) ?? []
        completedSummary = try container.decodeIfPresent(
            PracticeSessionSummary.self,
            forKey: .completedSummary
        )
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
            ?? completedSummary?.sessionID
            ?? (phase == .idle ? Self.idleSessionID : UUID())
    }
}
