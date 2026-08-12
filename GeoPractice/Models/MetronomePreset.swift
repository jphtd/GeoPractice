import Foundation

enum RotationDirection: String, CaseIterable, Codable, Identifiable, Sendable {
    case counterclockwise
    case clockwise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .counterclockwise: "逆时针"
        case .clockwise: "顺时针"
        }
    }

    var symbol: String {
        switch self {
        case .counterclockwise: "arrow.counterclockwise"
        case .clockwise: "arrow.clockwise"
        }
    }
}

struct MetronomePreset: Codable, Hashable, Sendable {
    var bpm: Int
    var beats: Int
    var subdivision: Int
    var direction: RotationDirection
    var grouping: String

    static let standard = MetronomePreset(
        bpm: 112,
        beats: 4,
        subdivision: 1,
        direction: .counterclockwise,
        grouping: "标准"
    )

    static let builtIns: [(name: String, bpm: Int)] = [
        ("慢", 72),
        ("中速", 112),
        ("快", 144)
    ]

    static let supportedSubdivisions = [1, 2, 4]

    static func groupings(for beats: Int) -> [String] {
        switch beats {
        case 5: ["2+3", "3+2"]
        case 6: ["3+3", "2+2+2"]
        case 7: ["2+2+3", "2+3+2", "3+2+2"]
        case 8: ["4+4", "3+3+2", "2+3+3"]
        default: ["标准"]
        }
    }

    var normalized: MetronomePreset {
        var result = self
        result.bpm = min(max(result.bpm, 30), 240)
        result.beats = min(max(result.beats, 2), 8)
        if !Self.supportedSubdivisions.contains(result.subdivision) {
            result.subdivision = 1
        }
        let validGroupings = Self.groupings(for: result.beats)
        if !validGroupings.contains(result.grouping) {
            result.grouping = validGroupings[0]
        }
        return result
    }

    var tempoName: String {
        switch bpm {
        case ..<55: "Largo"
        case ..<76: "Adagio"
        case ..<108: "Andante"
        case ..<120: "Moderato"
        case ..<168: "Allegro"
        case ..<200: "Presto"
        default: "Prestissimo"
        }
    }

    var tempoDisplay: String {
        "\(tempoName) · \(bpm) BPM"
    }

    var subdivisionTitle: String {
        switch subdivision {
        case 2: "八分音符"
        case 4: "十六分音符"
        default: "四分音符"
        }
    }

    var compactSummary: String {
        "\(bpm) BPM · \(beats) 拍 · \(subdivisionTitle)"
    }

    var groupStartIndices: Set<Int> {
        guard grouping != "标准" else { return [0] }
        let groupSizes = grouping.split(separator: "+").compactMap { Int($0) }
        var starts: Set<Int> = [0]
        var runningTotal = 0
        for size in groupSizes.dropLast() {
            runningTotal += size
            starts.insert(runningTotal)
        }
        return starts
    }
}
