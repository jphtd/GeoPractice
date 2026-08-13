import Foundation

/// Playback and visual lifecycle are intentionally separate. Audio can pause,
/// restart after a tempo change, or be interrupted without destroying the
/// geometry that the practice session has already created.
struct BeatVisualLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case origin
        case building
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
        case .building, .orbiting, .finishing:
            revealedBeats.sorted()
        }
    }

    mutating func reset(beats: Int) {
        self = BeatVisualLifecycle(beats: beats)
    }

    mutating func reconfigure(beats: Int) {
        let normalized = Self.normalizedBeatCount(beats)
        guard normalized != beatCount else { return }
        reset(beats: normalized)
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

        // A cycle greater than zero proves that the first complete orbit has
        // finished. Engine restarts may later report cycle zero again, but the
        // established structure remains sticky for the rest of the session.
        if cycle > 0 || phase == .orbiting {
            revealedBeats = Set(0..<beatCount)
            phase = .orbiting
            return
        }

        guard subdivision == 0 else { return }
        revealedBeats.insert(beat)
        phase = revealedBeats.count == beatCount ? .orbiting : .building
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
