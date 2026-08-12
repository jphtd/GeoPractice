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
    var createdAt: Date
    var updatedAt: Date

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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var preset: MetronomePreset {
        MetronomePreset(
            bpm: bpm,
            beats: beats,
            subdivision: subdivision,
            direction: RotationDirection(rawValue: directionRawValue) ?? .counterclockwise,
            grouping: grouping
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

    func apply(preset: MetronomePreset) {
        let preset = preset.normalized
        bpm = preset.bpm
        beats = preset.beats
        subdivision = preset.subdivision
        directionRawValue = preset.direction.rawValue
        grouping = preset.grouping
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
