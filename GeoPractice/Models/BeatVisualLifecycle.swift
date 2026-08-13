import Foundation

enum BeatPulseKind: Equatable, Sendable {
    case strong
    case secondary
    case weak
    case subdivision
}

struct BeatPulseAddress: Equatable, Sendable {
    let beat: Int
    let subdivision: Int
    /// Position around the N-point geometry. Integer values are main-beat
    /// vertices; fractional values are fixed subdivision positions.
    let phase: Double
}

struct BeatPulseStyle: Equatable, Sendable {
    let peakRadius: Double
    let peakOpacity: Double
    let duration: TimeInterval
}

enum BeatPulseVisualModel {
    static func address(
        beat: Int,
        subdivision: Int,
        beats: Int,
        pulsesPerBeat: Int
    ) -> BeatPulseAddress? {
        guard beats > 0,
              pulsesPerBeat > 0,
              beat >= 0, beat < beats,
              subdivision >= 0, subdivision < pulsesPerBeat
        else { return nil }

        return BeatPulseAddress(
            beat: beat,
            subdivision: subdivision,
            phase: Double(beat) + Double(subdivision) / Double(pulsesPerBeat)
        )
    }

    static func kind(
        beat: Int,
        subdivision: Int,
        strongBeatIndices: Set<Int>,
        secondaryAccentIndices: Set<Int>
    ) -> BeatPulseKind {
        if subdivision > 0 { return .subdivision }
        if strongBeatIndices.contains(beat) { return .strong }
        if secondaryAccentIndices.contains(beat) { return .secondary }
        return .weak
    }

    static func style(
        for kind: BeatPulseKind,
        eventInterval: TimeInterval,
        dimFlashingLights: Bool = false
    ) -> BeatPulseStyle {
        let nominal: (radius: Double, opacity: Double, duration: Double, intervalCap: Double)
        switch kind {
        case .strong:
            nominal = (10.6, 0.96, 0.165, 0.78)
        case .secondary:
            nominal = (8.8, 0.84, 0.140, 0.68)
        case .weak:
            nominal = (7.2, 0.70, 0.115, 0.58)
        case .subdivision:
            nominal = (5.0, 0.48, 0.075, 0.42)
        }

        let safeInterval = max(0.001, eventInterval)
        let intensity = dimFlashingLights ? 0.72 : 1
        let intervalDuration = max(0.04, safeInterval * nominal.intervalCap)
        return BeatPulseStyle(
            peakRadius: nominal.radius * intensity,
            peakOpacity: nominal.opacity * (dimFlashingLights ? 0.68 : 1),
            duration: min(nominal.duration, min(safeInterval * 0.82, intervalDuration))
        )
    }

    /// A Hit starts at full intensity and only decays. There is deliberately no
    /// attack or breathing phase while the metronome is playing.
    static func envelope(age: TimeInterval, duration: TimeInterval) -> Double {
        guard age >= 0, duration > 0, age < duration else { return 0 }
        let peakHold = min(0.014, duration * 0.28)
        if age <= peakHold { return 1 }
        let decayDuration = max(0.001, duration - peakHold)
        return pow(1 - (age - peakHold) / decayDuration, 2.2)
    }
}

/// Playback and visual lifecycle are intentionally separate. Waiting is a
/// single breathing point; the first valid audio event establishes one fixed
/// N-point structure which survives pauses and audio rescheduling.
struct BeatVisualLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case origin
        case orbiting
        case finishing
        case settled
    }

    private(set) var phase: Phase = .origin
    private(set) var beatCount: Int
    private(set) var revealedBeats: Set<Int> = []
    private(set) var isPaused = true

    init(beats: Int = 4) {
        beatCount = Self.normalizedBeatCount(beats)
    }

    var hasEstablishedStructure: Bool {
        phase == .orbiting || (phase == .finishing && revealedBeats.count == beatCount)
    }

    var visibleBeatIndices: [Int] {
        switch phase {
        case .origin, .settled:
            []
        case .orbiting, .finishing:
            revealedBeats.sorted()
        }
    }

    mutating func reset(beats: Int) {
        self = BeatVisualLifecycle(beats: beats)
    }

    mutating func reconfigure(beats: Int) {
        let normalized = Self.normalizedBeatCount(beats)
        guard normalized != beatCount else { return }

        // A live topology change swaps one fixed geometry for another without
        // collapsing the stage to the waiting point. A session that has not
        // started still remains in its single-point waiting state.
        if phase == .orbiting {
            beatCount = normalized
            revealedBeats = Set(0..<normalized)
        } else {
            reset(beats: normalized)
        }
    }

    mutating func resume() {
        guard phase != .finishing, phase != .settled else { return }
        isPaused = false
    }

    mutating func pause() {
        guard phase != .finishing, phase != .settled else { return }
        isPaused = true
    }

    mutating func record(beat: Int, subdivision: Int, cycle: Int, beats: Int) {
        reconfigure(beats: beats)
        guard phase != .finishing, phase != .settled,
              beat >= 0, beat < beatCount,
              subdivision >= 0
        else { return }

        isPaused = false

        // Geometry is a stable frame for the pulses, not something that is
        // progressively drawn by a travelling point. Even a first subdivision
        // event establishes all main-beat anchors at once.
        revealedBeats = Set(0..<beatCount)
        phase = .orbiting
    }

    mutating func beginFinishing() {
        guard phase != .finishing, phase != .settled else { return }
        isPaused = true
        phase = .finishing
    }

    mutating func settle() {
        isPaused = true
        phase = .settled
    }

    private static func normalizedBeatCount(_ beats: Int) -> Int {
        min(max(beats, 3), 9)
    }
}
