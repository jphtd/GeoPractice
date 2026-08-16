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
    /// The main-beat vertex which owns the most recent valid pulse. It
    /// deliberately survives pauses and interval-only tempo changes so
    /// peripheral vision can still locate the current beat after the short Hit
    /// has decayed. Subdivision pulses select their containing main beat.
    private(set) var currentBeatIndex: Int?
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
            currentBeatIndex = nil
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

    /// Clears only the persistent main-beat locator while preserving the
    /// established geometry. Used when the event topology is replaced and the
    /// old vertex can no longer describe the pending scheduler cursor.
    mutating func clearCurrentBeatLocation() {
        currentBeatIndex = nil
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
        currentBeatIndex = beat
        phase = .orbiting
    }

    mutating func beginFinishing() {
        guard phase != .finishing, phase != .settled else { return }
        isPaused = true
        currentBeatIndex = nil
        phase = .finishing
    }

    mutating func settle() {
        isPaused = true
        currentBeatIndex = nil
        phase = .settled
    }

    private static func normalizedBeatCount(_ beats: Int) -> Int {
        min(max(beats, 3), 9)
    }
}

/// Presentation-neutral tokens for a persistent geometry anchor. The canvas
/// owns drawing and animation; this model only defines the visual hierarchy
/// that must survive the short pulse envelope.
struct BeatAnchorVisualStyle: Equatable, Sendable {
    let radius: Double
    let opacity: Double

    /// A stable comparison value for tests and alternate renderers. It is not
    /// intended to be interpreted as a physical luminance measurement.
    var prominence: Double {
        radius * opacity
    }
}

/// Keeps the current main-beat locator visually dominant without coupling the
/// rhythm model to SwiftUI, Canvas, or a particular screen size.
enum BeatVisualHierarchyModel {
    static let inactiveAnchorStyle = BeatAnchorVisualStyle(
        radius: 3.8,
        opacity: 0.30
    )

    static let currentPlayingAnchorStyle = BeatAnchorVisualStyle(
        radius: 6.4,
        opacity: 0.88
    )

    static let currentPausedAnchorStyle = BeatAnchorVisualStyle(
        radius: 6.0,
        opacity: 0.70
    )

    static func anchorStyle(
        for beatIndex: Int,
        lifecycle: BeatVisualLifecycle
    ) -> BeatAnchorVisualStyle {
        guard lifecycle.phase == .orbiting,
              lifecycle.currentBeatIndex == beatIndex
        else { return inactiveAnchorStyle }

        return lifecycle.isPaused
            ? currentPausedAnchorStyle
            : currentPlayingAnchorStyle
    }

    static func pulseStyle(
        for kind: BeatPulseKind,
        eventInterval: TimeInterval,
        dimFlashingLights: Bool = false
    ) -> BeatPulseStyle {
        BeatPulseVisualModel.style(
            for: kind,
            eventInterval: eventInterval,
            dimFlashingLights: dimFlashingLights
        )
    }
}

/// The small set of facts a musician should be able to obtain at a glance
/// while the controls remain secondary. This value is renderer-agnostic so
/// the compact iPhone and spacious iPad layouts can present the same truth.
struct MetronomeGlanceStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case ready
        case playing
        case paused
        case finishing
        case finished

        var title: String {
            switch self {
            case .ready: "准备"
            case .playing: "演奏中"
            case .paused: "已暂停"
            case .finishing: "正在结束"
            case .finished: "已结束"
            }
        }
    }

    let state: State
    let bpm: Int
    let referenceNote: TempoReferenceNote
    let trainingNote: TempoReferenceNote
    let beats: Int
    let grouping: String
    let hand: PracticeHand
    /// Human-facing beat number. Unlike `BeatVisualLifecycle.currentBeatIndex`,
    /// this value is one-based so it can be displayed or spoken directly.
    let currentMainBeat: Int?

    init(
        preset: MetronomePreset,
        hand: PracticeHand,
        lifecycle: BeatVisualLifecycle,
        isPlaying: Bool,
        isFinishing: Bool = false,
        isFinished: Bool = false,
        effectiveReferenceNote: TempoReferenceNote? = nil
    ) {
        let preset = preset.normalized
        self.state = Self.resolveState(
            lifecycle: lifecycle,
            isPlaying: isPlaying,
            isFinishing: isFinishing,
            isFinished: isFinished
        )
        bpm = preset.bpm
        referenceNote = effectiveReferenceNote ?? preset.referenceNote
        trainingNote = TempoReferenceNote.trainingNote(for: preset.subdivision)
        beats = preset.beats
        grouping = preset.grouping
        self.hand = hand
        currentMainBeat = lifecycle.currentBeatIndex.flatMap { index in
            (0..<preset.beats).contains(index) ? index + 1 : nil
        }
    }

    var stateTitle: String { state.title }

    var bpmText: String { "\(bpm) BPM" }

    var referenceTempoText: String {
        "\(referenceNote.symbol) = \(bpm)"
    }

    var trainingNoteText: String { trainingNote.symbol }

    var beatStructureText: String {
        grouping == "标准"
            ? "\(beats) 拍"
            : "\(beats) 拍 · \(grouping)"
    }

    var currentBeatText: String {
        guard let currentMainBeat else {
            return state == .playing ? "等待首拍" : "尚无当前拍"
        }
        return "第 \(currentMainBeat) / \(beats) 拍"
    }

    var statusText: String {
        "\(stateTitle) · \(currentBeatText) · \(bpmText)"
    }

    /// VoiceOver and other non-visual clients should receive the same status
    /// hierarchy without having to pronounce SMuFL private-use glyphs.
    var accessibilitySummary: String {
        let beatDescription = currentMainBeat.map {
            "当前第 \($0) 拍，共 \(beats) 拍"
        } ?? "共 \(beats) 拍，尚无当前拍"
        let groupingDescription = grouping == "标准"
            ? "标准分组"
            : "分组 \(grouping)"
        return [
            stateTitle,
            beatDescription,
            groupingDescription,
            "速度每分钟 \(bpm) 拍",
            "基准音符\(referenceNote.title)",
            "训练音符\(trainingNote.title)",
            hand.title
        ].joined(separator: "，")
    }

    private static func resolveState(
        lifecycle: BeatVisualLifecycle,
        isPlaying: Bool,
        isFinishing: Bool,
        isFinished: Bool
    ) -> State {
        if isFinished || lifecycle.phase == .settled { return .finished }
        if isFinishing || lifecycle.phase == .finishing { return .finishing }
        if isPlaying { return .playing }
        if lifecycle.phase == .orbiting { return .paused }
        return .ready
    }
}
