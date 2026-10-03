import Combine
import Foundation
import SwiftData

/// A session's immutable association and daily cycle, captured at explicit start.
/// No interpretation of legacy attempts or of independent GeoBeat recordings.
struct CoreSessionContext: Codable, Equatable {
    var pieceID: UUID
    var divisionID: UUID
    var pieceName: String
    var divisionName: String
    var handMode: CoreHandMode
    var goal: CoreGoal
    var cycleStart: Date
    var timeZoneID: String
    var source = "planned"
    var cycleLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateStyle = .medium
        return formatter.string(from: cycleStart)
    }
}

extension PracticeAttempt {
    var coreContext: CoreSessionContext? {
        guard let coreContextData else { return nil }
        return try? JSONDecoder().decode(CoreSessionContext.self, from: coreContextData)
    }
}

extension CoreNoteUnit {
    var title: String { TempoReferenceNote(rawValue: rawValue)?.title ?? rawValue }
}

enum CoreFlowError: LocalizedError {
    case invalidInput(String), damagedDraft, noRecording
    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .damagedDraft: "未完成练习资料无法读取。资料已保留，请联系开发者处理后再开始新练习。"
        case .noRecording: "本次没有完成记录，不保存空 Session。"
        }
    }
}

@MainActor
final class CoreSessionRuntime: ObservableObject {
    static let draftKey = "rovia.practice.core.session.v1"
    @Published private(set) var session = PracticeSession()
    @Published private(set) var context: CoreSessionContext?
    @Published private(set) var preset = MetronomePreset.standard
    @Published var needsRecovery = false
    @Published private(set) var failure: String?
    @Published private(set) var execution: CoreDivisionDefinition?
    private let defaults: UserDefaults
    private struct Draft: Codable {
        var session: PracticeSession
        var context: CoreSessionContext
        var preset: MetronomePreset
        var savedAt: Date
        var execution: CoreDivisionDefinition?
    }
    var activeID: UUID? { context == nil ? nil : session.sessionID }
    var count: Int { PracticeHand.allCases.reduce(0) { $0 + session.completionSamples(for: $1).count } }

    init(defaults: UserDefaults = .standard, restore: Bool = true) {
        self.defaults = defaults
        guard restore, let data = defaults.data(forKey: Self.draftKey) else { return }
        do {
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard draft.context.source == "planned", draft.session.phase != .idle,
                  draft.session.sourceEventID == draft.context.divisionID,
                  draft.context.goal.isValid(for: draft.context.handMode) else { throw CoreFlowError.damagedDraft }
            session = draft.session
            context = draft.context
            preset = draft.preset
            execution = draft.execution
            if count == 0 { clear(); return } // SES-04: never retain an empty formal session after exit.
            // Exclude process downtime, keeping identity and real samples.
            session.pause(at: draft.savedAt)
            needsRecovery = true
        } catch { failure = CoreFlowError.damagedDraft.localizedDescription }
    }

    func begin(piece: PracticeSong, division: PracticeEvent, initialHand: PracticeHand? = nil, at date: Date = .now,
               calendar: Calendar = .current, confirmedStarts: [PracticeHand: Int] = [:]) throws {
        guard failure == nil else { throw CoreFlowError.damagedDraft }
        guard context == nil else { throw CoreIntegrationError.activeSession }
        guard division.songID == piece.id, let definition = division.coreDefinition,
              let structure = piece.coreStructure, definition.fits(structure),
              let goal = definition.goal, goal.isValid(for: definition.handMode) else { throw CoreIntegrationError.invalidGoal }
        // Resolve before any session, draft, or context mutation. Multi-hand never defaults.
        guard let hand = initialHand ?? definition.handMode.directInitialHand,
              definition.handMode.hands.contains(hand) else {
            throw CoreFlowError.invalidInput("请选择本次练习首先记录的手型。")
        }
        var prepared = try Self.prepare(division: division, at: date, calendar: calendar)
        for hand in prepared.needsStart {
            guard let start = confirmedStarts[hand], let config = prepared.definition.goal?.hands[hand]?.ladder else {
                throw CoreFlowError.invalidInput("请确认新周期每个手型的起始 BPM。")
            }
            let old = definition.ladderStates?[hand]
            let previous = old?.previousValidBPM.map {
                Int((Double($0) * (old?.previousNoteUnit ?? config.noteUnit).quarterMultiplier / config.noteUnit.quarterMultiplier).rounded())
            } ?? 300
            let ceiling = min(previous, prepared.definition.goal?.hands[hand]?.speed?.bpm ?? 300)
            guard (20...max(20, ceiling)).contains(start) else {
                throw CoreFlowError.invalidInput("\(hand.title)：起始 BPM 须在 20–\(ceiling) 之间。")
            }
            prepared.definition.goal?.hands[hand]?.ladder?.startBPM = start
            if start == prepared.definition.goal?.hands[hand]?.speed?.bpm {
                prepared.definition.goal?.hands[hand]?.ladder?.retainsLockedOrigin = true
            }
        }
        let effectiveGoal = prepared.definition.goal ?? goal
        for hand in definition.handMode.hands where effectiveGoal.ladderEnabled == true {
            guard let config = effectiveGoal.hands[hand]?.ladder else { continue }
            let old = prepared.definition.ladderStates?[hand]
            var state: CoreLadderState
            if let old, old.cycleStart == prepared.cycle {
                state = old
                let ratio = old.noteUnit.quarterMultiplier / config.noteUnit.quarterMultiplier
                let bpm = Int((Double(old.currentBPM) * ratio).rounded())
                if Double(bpm) * config.noteUnit.quarterMultiplier != Double(old.currentBPM) * old.noteUnit.quarterMultiplier {
                    state.repsCompleted = 0
                }
                state.currentBPM = bpm
                state.cycleStartBPM = Int((Double(old.cycleStartBPM) * ratio).rounded())
                state.noteUnit = config.noteUnit
                if !state.startLocked { state.cycleStartBPM = config.startBPM; state.currentBPM = config.startBPM }
            } else {
                state = CoreLadderState(cycleStart: prepared.cycle, cycleStartBPM: config.startBPM,
                    currentBPM: config.startBPM, repsCompleted: 0, noteUnit: config.noteUnit,
                    previousValidBPM: old?.previousValidBPM, previousNoteUnit: old?.previousNoteUnit ?? old?.noteUnit)
            }
            if prepared.definition.ladderStates == nil { prepared.definition.ladderStates = [:] }
            prepared.definition.ladderStates?[hand] = state
        }
        execution = prepared.definition
        context = CoreSessionContext(pieceID: piece.id, divisionID: division.id, pieceName: piece.name,
            divisionName: definition.label(mode: structure.mode), handMode: definition.handMode, goal: effectiveGoal,
            cycleStart: prepared.cycle, timeZoneID: calendar.timeZone.identifier)
        preset = division.preset
        session.begin(sourceEventID: division.id, initialHand: hand, at: date)
        needsRecovery = false
        persist(at: date)
    }

    // Resolve boundaries once at Session start. A running Session never changes its cycle.
    static func prepare(division: PracticeEvent, at date: Date = .now, calendar: Calendar = .current)
        throws -> (definition: CoreDivisionDefinition, cycle: Date, needsStart: [PracticeHand]) {
        guard var definition = division.coreDefinition, var goal = definition.goal else { throw CoreIntegrationError.invalidGoal }
        let today = calendar.startOfDay(for: date)
        let oldCycle = definition.executionCycleStart ?? definition.ladderStates?.values.map(\.cycleStart).min()
        var reset = goal.reset ?? CoreResetConfiguration()
        var anchor = min(calendar.startOfDay(for: reset.anchor ?? oldCycle ?? today), today)
        var cycle = oldCycle ?? anchor
        if reset.enabled {
            if let pending = reset.pendingDays, let effective = reset.pendingEffectiveAt, date >= effective {
                reset.days = pending; anchor = effective; reset.anchor = effective
                reset.pendingDays = nil; reset.pendingEffectiveAt = nil
                cycle = effective
            }
            let days = max(0, calendar.dateComponents([.day], from: anchor, to: today).day ?? 0)
            let boundary = calendar.date(byAdding: .day, value: days / reset.days * reset.days, to: anchor) ?? anchor
            // Off -> On changes the anchor without clearing existing facts that day.
            if oldCycle == nil || boundary > anchor || cycle == anchor { cycle = boundary }
        }
        reset.anchor = anchor
        let changed = oldCycle != nil && cycle > oldCycle!
        let hasPending = changed && definition.nextCycleGoal != nil
        if hasPending {
            goal = definition.nextCycleGoal!
            definition.nextCycleGoal = nil; definition.nextCycleAnalyzeTiming = nil
            definition.nextCycleAdjustedStartHands = nil
        }
        goal.reset = reset
        definition.goal = goal; definition.executionCycleStart = cycle
        let needsStart = changed && !hasPending && goal.ladderEnabled == true
            ? definition.handMode.hands.filter { goal.hands[$0]?.ladder != nil } : []
        return (definition, cycle, needsStart)
    }

    func updatePreset(_ value: MetronomePreset, at date: Date = .now) {
        preset = value.normalized
        persist(at: date)
    }
    func pause(at date: Date = .now) { session.pause(at: date); persist(at: date) }
    func resume(at date: Date = .now) { session.resume(at: date); needsRecovery = false; persist(at: date) }
    func switchHand(_ hand: PracticeHand, at date: Date = .now) {
        guard context?.handMode.allowsHandSwitching == true,
              context?.handMode.hands.contains(hand) == true else { return }
        session.switchHand(to: hand, at: date)
        persist(at: date)
    }
    func record(preset: MetronomePreset, at date: Date = .now) {
        guard session.isRunning else { return }
        self.preset = preset.normalized
        session.recordCompletion(for: session.currentHand, preset: preset, at: date)
        if let goal = context?.goal, goal.ladderEnabled == true,
           let config = goal.hands[session.currentHand]?.ladder,
           var state = execution?.ladderStates?[session.currentHand] {
            let actual = Double(self.preset.bpm) * self.preset.referenceNote.durationInQuarterNotes
            let rung = Double(state.currentBPM) * state.noteUnit.quarterMultiplier
            if actual == rung {
                state.firstValidRecordAt = state.firstValidRecordAt ?? date
                state.previousValidBPM = self.preset.bpm
                state.previousNoteUnit = CoreNoteUnit(rawValue: self.preset.referenceNote.rawValue)
                state.repsCompleted = min(config.repsPerLevel, state.repsCompleted + (state.repsCompleted < config.repsPerLevel ? 1 : 0))
                let ceiling = goal.hands[session.currentHand]?.speed?.bpm ?? 300
                if state.repsCompleted >= config.repsPerLevel && state.currentBPM < ceiling {
                    state.currentBPM = min(ceiling, state.currentBPM + config.stepBPM)
                    state.repsCompleted = 0
                }
                execution?.ladderStates?[session.currentHand] = state
            }
        }
        persist(at: date)
    }
    func finish(at date: Date = .now) {
        _ = session.finish(at: date)
        persist(at: date)
    }
    func continuePractice(at date: Date = .now) {
        session.continueAfterReview(at: date)
        persist(at: date)
    }
    func persist(at date: Date = .now) {
        guard let context else { return }
        do {
            defaults.set(try JSONEncoder().encode(Draft(session: session, context: context, preset: preset, savedAt: date, execution: execution)), forKey: Self.draftKey)
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func save(division: PracticeEvent, in modelContext: ModelContext) throws -> PracticeAttempt {
        guard let context, context.divisionID == division.id, context.pieceID == division.songID,
              let summary = session.reviewSummary else { throw CoreIntegrationError.wrongDestination }
        guard !summary.completions.isEmpty else { throw CoreFlowError.noRecording }
        let oldDefinition = division.coreDefinitionData
        if let execution { division.coreDefinitionData = try JSONEncoder().encode(execution) }
        let result: PracticeAttemptCommitResult
        do {
            result = try division.commit(summary: summary, in: modelContext,
                                         coreContextData: JSONEncoder().encode(context))
        } catch {
            division.coreDefinitionData = oldDefinition
            throw error
        }
        clear()
        return result.attempt
    }
    func discardEmpty() throws {
        guard count == 0 else { throw CoreFlowError.invalidInput("已有练习记录，请结束并确认保存。") }
        clear()
    }
    private func clear() {
        defaults.removeObject(forKey: Self.draftKey)
        session.reset(); context = nil; execution = nil; needsRecovery = false
    }
}

@MainActor
enum CoreAnalysis {
    static func planned(_ attempts: [PracticeAttempt], division: UUID) -> [PracticeAttempt] {
        attempts.filter { $0.eventID == division && $0.coreContext?.divisionID == division && $0.coreContext?.source == "planned" }
            .sorted { $0.finishedAt == $1.finishedAt ? $0.createdAt > $1.createdAt : $0.finishedAt > $1.finishedAt }
    }
    static func median(_ samples: [PracticeCompletionSample]) -> Double? {
        let values = samples.map { Double($0.preset.bpm) * $0.preset.referenceNote.durationInQuarterNotes }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    static func stable(_ attempts: [PracticeAttempt], hand: PracticeHand) -> Double? {
        for attempt in attempts {
            if let value = median(attempt.completions.filter({ $0.hand == hand })) { return value }
        }
        return nil
    }
    static func count(_ attempts: [PracticeAttempt], hand: PracticeHand, cycleStart: Date) -> Int {
        attempts.filter { $0.coreContext?.cycleStart == cycleStart }
            .reduce(0) { $0 + $1.completions.filter { $0.hand == hand }.count }
    }
    static func mastery(_ attempts: [PracticeAttempt], hand: PracticeHand, goal: CoreGoal,
                        now: Date = .now, calendar: Calendar = .current) -> Double? {
        guard let target = goal.hands[hand], let speed = target.speed, let stable = stable(attempts, hand: hand) else { return nil }
        let speedProgress = min(1, stable / speed.quarterEquivalent)
        guard let targetCount = target.count else { return speedProgress }
        let today = calendar.startOfDay(for: now)
        let latest = attempts.first { $0.completions.contains { $0.hand == hand } }
        // CYCLE-04 / MAS-06: carry the last hand's cycle until new facts arrive.
        // A goal edit is an explicit re-evaluation against today's execution facts.
        let editedAfterLatest = (goal.updatedAt ?? .distantPast) > (latest?.finishedAt ?? .distantPast)
        let cycle = editedAfterLatest ? calendar.startOfDay(for: goal.updatedAt ?? now) : (latest?.coreContext?.cycleStart ?? today)
        let countProgress = min(1, Double(count(attempts, hand: hand, cycleStart: cycle)) / Double(targetCount))
        return 0.75 * speedProgress + 0.25 * countProgress
    }
    static func divisionMastery(_ attempts: [PracticeAttempt], definition: CoreDivisionDefinition,
                                now: Date = .now) -> Double? {
        guard let goal = definition.goal else { return nil }
        let values = definition.handMode.hands.compactMap { mastery(attempts, hand: $0, goal: goal, now: now) }
        guard values.count == definition.handMode.hands.count else { return nil }
        return values.count == 1 ? values[0] : values[0] * 0.25 + values[1] * 0.25 + values[2] * 0.5
    }
}
