import Foundation

enum TempoScrubModel {
    static let minimumBPM = 30
    static let maximumBPM = 240
    static let pointsPerBPM: Double = 3

    static func bpm(start: Int, horizontalTranslation: Double) -> Int {
        bpm(start: start, primaryTranslation: horizontalTranslation)
    }

    static func bpm(start: Int, primaryTranslation: Double) -> Int {
        let delta = Int(primaryTranslation / pointsPerBPM)
        return min(maximumBPM, max(minimumBPM, start + delta))
    }

    static func validatedBPMInput(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Int(trimmed),
              (minimumBPM...maximumBPM).contains(value)
        else { return nil }
        return value
    }
}

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

/// Runtime-only tempo interpretations used by the DEBUG experience settings.
/// These values deliberately are not stored inside `MetronomePreset`, so
/// existing event snapshots and practice-session drafts remain compatible.
enum TempoSemantics: String, CaseIterable, Identifiable, Sendable {
    case legacyQuarterReference
    case trainingNoteReference
    case independentReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .legacyQuarterReference: "四分音符固定基准"
        case .trainingNoteReference: "训练音符就是 BPM 单位"
        case .independentReference: "独立选择 BPM 基准音符"
        }
    }

    var explanation: String {
        switch self {
        case .legacyQuarterReference:
            "对照逻辑。BPM 始终表示四分音符速度，训练音符越细，实际脉冲越密。"
        case .trainingNoteReference:
            "BPM 表示当前训练音符的速度。八分音符 88 BPM 就是每分钟 88 次脉冲。"
        case .independentReference:
            "训练内容与 BPM 的计速单位分开选择，可同时表达“练八分音符、四分音符等于 88”。"
        }
    }
}

enum TempoReferenceNote: String, CaseIterable, Codable, Identifiable, Sendable {
    case half
    case dottedHalf
    case quarter
    case dottedQuarter
    case eighth
    case dottedEighth
    case sixteenth

    var id: String { rawValue }

    /// Notes offered by the independent BPM-reference selector. Sixteenth
    /// notes remain available as a training value, but are intentionally not
    /// part of the customer's requested reference-note choices.
    static let tempoReferenceOptions: [TempoReferenceNote] = [
        .half, .dottedHalf,
        .quarter, .dottedQuarter,
        .eighth, .dottedEighth
    ]

    /// Undotted rhythmic values supported by the training-note selector.
    static let trainingNoteOptions: [TempoReferenceNote] = [
        .half, .quarter, .eighth, .sixteenth
    ]

    /// SMuFL `metAugmentationDot` in Bravura Text. The selector renders this
    /// separately from the note so it can stay legible at compact UI sizes.
    static let augmentationDotSymbol = "\u{ECB7}"

    /// Written duration measured in quarter notes. An augmentation dot adds
    /// half of the undotted value, so every dotted option is exactly 1.5x its
    /// corresponding base note.
    var durationInQuarterNotes: Double {
        switch self {
        case .half: 2
        case .dottedHalf: 3
        case .quarter: 1
        case .dottedQuarter: 1.5
        case .eighth: 0.5
        case .dottedEighth: 0.75
        case .sixteenth: 0.25
        }
    }

    var density: Double {
        1 / durationInQuarterNotes
    }

    var isDotted: Bool {
        switch self {
        case .dottedHalf, .dottedQuarter, .dottedEighth: true
        default: false
        }
    }

    var undottedNote: TempoReferenceNote {
        switch self {
        case .dottedHalf: .half
        case .dottedQuarter: .quarter
        case .dottedEighth: .eighth
        default: self
        }
    }

    var title: String {
        switch self {
        case .half: "二分音符"
        case .dottedHalf: "附点二分音符"
        case .quarter: "四分音符"
        case .dottedQuarter: "附点四分音符"
        case .eighth: "八分音符"
        case .dottedEighth: "附点八分音符"
        case .sixteenth: "十六分音符"
        }
    }

    var shortTitle: String {
        switch self {
        case .half: "2 分"
        case .dottedHalf: "附点 2 分"
        case .quarter: "4 分"
        case .dottedQuarter: "附点 4 分"
        case .eighth: "8 分"
        case .dottedEighth: "附点 8 分"
        case .sixteenth: "16 分"
        }
    }

    /// Bravura Text SMuFL glyph used by the selectors and BPM mark.
    var symbol: String {
        switch self {
        case .half: "\u{ECA3}"
        case .dottedHalf: "\u{ECA3}\(Self.augmentationDotSymbol)"
        case .quarter: "\u{ECA5}"
        case .dottedQuarter: "\u{ECA5}\(Self.augmentationDotSymbol)"
        case .eighth: "\u{ECA7}"
        case .dottedEighth: "\u{ECA7}\(Self.augmentationDotSymbol)"
        case .sixteenth: "\u{ECA9}"
        }
    }

    static func trainingNote(for subdivision: Int) -> TempoReferenceNote {
        switch subdivision {
        case 0: .half
        case 2: .eighth
        case 4: .sixteenth
        default: .quarter
        }
    }
}

/// An immutable timing snapshot shared by audio scheduling and visual Hits.
/// Beat topology always comes from the training note; tempo semantics only
/// change the time between those events.
struct MetronomePlaybackPlan: Hashable, Sendable {
    let semantics: TempoSemantics
    let referenceNote: TempoReferenceNote
    let trainingNote: TempoReferenceNote
    let bpm: Int
    let pulsesPerBeat: Int
    let eventsPerMeasure: Int
    let eventInterval: TimeInterval

    init(
        preset: MetronomePreset,
        semantics: TempoSemantics = .independentReference,
        referenceNote: TempoReferenceNote? = nil
    ) {
        let normalized = preset.normalized
        let trainingNote = TempoReferenceNote.trainingNote(for: normalized.subdivision)
        let effectiveReference: TempoReferenceNote
        switch semantics {
        case .legacyQuarterReference:
            effectiveReference = .quarter
        case .trainingNoteReference:
            effectiveReference = trainingNote
        case .independentReference:
            effectiveReference = referenceNote ?? normalized.referenceNote
        }

        let pulsesPerBeat = max(1, normalized.subdivision)
        let trainingDensity = normalized.subdivision == 0
            ? 0.5
            : Double(normalized.subdivision)

        self.semantics = semantics
        self.referenceNote = effectiveReference
        self.trainingNote = trainingNote
        self.bpm = normalized.bpm
        self.pulsesPerBeat = pulsesPerBeat
        self.eventsPerMeasure = normalized.beats * pulsesPerBeat
        self.eventInterval = 60 / Double(normalized.bpm)
            * effectiveReference.density / trainingDensity
    }

    var mainBeatDuration: TimeInterval {
        eventInterval * Double(pulsesPerBeat)
    }

    var measureDuration: TimeInterval {
        eventInterval * Double(eventsPerMeasure)
    }

    var actualPulsesPerMinute: Double {
        60 / eventInterval
    }

    var bpmMark: String {
        "\(referenceNote.symbol) = \(bpm)"
    }

    func hasSameSchedule(as other: MetronomePlaybackPlan) -> Bool {
        eventInterval == other.eventInterval
            && eventsPerMeasure == other.eventsPerMeasure
            && pulsesPerBeat == other.pulsesPerBeat
    }
}

/// The scheduler's musical cursor at the boundary between queued and not-yet
/// queued events. Keeping this independent from AVAudioEngine lets tempo
/// changes preserve event order without consulting delayed UI callbacks.
struct BeatScheduleFrontier: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        let exactFrame: Double
        let eventIndex: Int
        let beat: Int
        let subdivision: Int
        let cycle: Int
        let sequence: UInt64
        let eventInterval: TimeInterval
    }

    private(set) var nextExactFrame: Double
    private(set) var eventIndex: Int
    private(set) var cycle: Int
    private(set) var lastScheduledExactFrame: Double?

    init(
        nextExactFrame: Double = 0,
        eventIndex: Int = 0,
        cycle: Int = 0,
        lastScheduledExactFrame: Double? = nil
    ) {
        self.nextExactFrame = max(0, nextExactFrame)
        self.eventIndex = max(0, eventIndex)
        self.cycle = max(0, cycle)
        self.lastScheduledExactFrame = lastScheduledExactFrame
    }

    mutating func takeNext(
        plan: MetronomePlaybackPlan,
        sampleRate: Double
    ) -> Event {
        let safeSampleRate = max(1, sampleRate)
        let eventCount = max(1, plan.eventsPerMeasure)
        let pulsesPerBeat = max(1, plan.pulsesPerBeat)
        let safeIndex = min(max(0, eventIndex), eventCount - 1)
        let frame = nextExactFrame
        let eventCountValue = UInt64(eventCount)
        let eventIndexValue = UInt64(safeIndex)
        let cycleValue = UInt64(max(0, cycle))
        let maximumCycle = (UInt64.max - eventIndexValue) / eventCountValue
        let event = Event(
            exactFrame: frame,
            eventIndex: safeIndex,
            beat: safeIndex / pulsesPerBeat,
            subdivision: safeIndex % pulsesPerBeat,
            cycle: cycle,
            sequence: min(cycleValue, maximumCycle) * eventCountValue
                + eventIndexValue,
            eventInterval: plan.eventInterval
        )

        lastScheduledExactFrame = frame
        nextExactFrame = frame + safeSampleRate * plan.eventInterval
        if safeIndex + 1 >= eventCount {
            eventIndex = 0
            cycle += 1
        } else {
            eventIndex = safeIndex + 1
        }
        return event
    }

    /// Moves only the future timing frontier. The next musical address is not
    /// changed, and an overdue successor is scheduled once at the earliest
    /// safe frame instead of being skipped or emitted in a catch-up burst.
    mutating func reviseFutureInterval(
        to eventInterval: TimeInterval,
        sampleRate: Double,
        minimumNextExactFrame: Double
    ) {
        guard let lastScheduledExactFrame else { return }
        let intervalFrames = max(0.001, eventInterval) * max(1, sampleRate)
        nextExactFrame = max(
            lastScheduledExactFrame + intervalFrames,
            max(0, minimumNextExactFrame)
        )
    }

    /// Defers the same next musical event when a scheduler wake-up is late.
    /// The address and sequence are deliberately untouched, preventing both a
    /// catch-up burst and a skipped beat.
    mutating func ensureNextEventIsNoEarlier(than minimumExactFrame: Double) {
        nextExactFrame = max(nextExactFrame, max(0, minimumExactFrame))
    }
}

struct MetronomePreset: Codable, Hashable, Sendable {
    var bpm: Int
    var beats: Int
    var subdivision: Int
    var direction: RotationDirection
    var grouping: String
    /// Optional raw storage keeps legacy five-field preset payloads valid.
    /// A missing or unrecognized value safely retains the historical quarter-
    /// note reference without discarding a future value during decoding.
    var referenceNoteRaw: String? = nil

    var referenceNote: TempoReferenceNote {
        get {
            referenceNoteRaw.flatMap(TempoReferenceNote.init(rawValue:)) ?? .quarter
        }
        set {
            referenceNoteRaw = newValue.rawValue
        }
    }

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

    /// 0 is the migration-safe sentinel for half-note training. The remaining
    /// values are the number of pulses inside one main beat.
    static let supportedSubdivisions = [0, 1, 2, 4]

    static func groupings(for beats: Int) -> [String] {
        switch beats {
        case 5: ["2+3", "3+2"]
        case 7: ["3+4", "4+3"]
        default: ["标准"]
        }
    }

    var normalized: MetronomePreset {
        var result = self
        result.bpm = min(max(result.bpm, TempoScrubModel.minimumBPM), TempoScrubModel.maximumBPM)
        result.beats = min(max(result.beats, 3), 9)
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
        case 0: "二分音符"
        case 2: "八分音符"
        case 4: "十六分音符"
        default: "四分音符"
        }
    }

    var subdivisionShortTitle: String {
        switch subdivision {
        case 0: "2 分"
        case 2: "8 分"
        case 4: "16 分"
        default: "4 分"
        }
    }

    /// Pulses scheduled inside each geometric beat. Half notes remain one
    /// pulse per beat, while their interval is stretched by `eventDensity`.
    var pulsesPerBeat: Int {
        max(1, subdivision)
    }

    /// Relative rhythmic density with a quarter note as 1.0.
    var eventDensity: Double {
        subdivision == 0 ? 0.5 : Double(subdivision)
    }

    var eventInterval: TimeInterval {
        playbackPlan().eventInterval
    }

    var eventsPerMeasure: Int {
        playbackPlan().eventsPerMeasure
    }

    var mainBeatDuration: TimeInterval {
        playbackPlan().mainBeatDuration
    }

    func playbackPlan(
        semantics: TempoSemantics = .independentReference,
        referenceNote: TempoReferenceNote? = nil
    ) -> MetronomePlaybackPlan {
        MetronomePlaybackPlan(
            preset: self,
            semantics: semantics,
            referenceNote: referenceNote
        )
    }

    var compactSummary: String {
        "\(bpm) BPM · \(beats) 拍 · \(subdivisionTitle)"
    }

    var groupStartIndices: Set<Int> {
        if grouping == "标准" {
            return beats == 4 ? [0, 2] : [0]
        }
        let groupSizes = grouping.split(separator: "+").compactMap { Int($0) }
        var starts: Set<Int> = [0]
        var runningTotal = 0
        for size in groupSizes.dropLast() {
            runningTotal += size
            starts.insert(runningTotal)
        }
        return starts
    }

    /// Primary accents. The 7-beat 4+3 pattern follows the V4 music-design
    /// table: beat 5 begins the second group with another strong accent.
    var strongBeatIndices: Set<Int> {
        if beats == 7, grouping == "4+3" {
            return [0, 4]
        }
        return [0]
    }

    /// Secondary accents generated by the rhythmic structure. The unusual
    /// beat 3 accent in 7-beat 4+3 is deliberate and documented in V4.
    var secondaryAccentIndices: Set<Int> {
        if beats == 7, grouping == "4+3" {
            return [2]
        }
        return groupStartIndices.subtracting(strongBeatIndices)
    }
}
