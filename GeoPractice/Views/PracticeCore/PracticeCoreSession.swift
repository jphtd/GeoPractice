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
    // Additive facts: absent on legacy data, never inferred or backfilled.
    var focusEnabled: Bool?
    var focusDurationMilliseconds: Int64?
    var cycleLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateStyle = .medium
        return formatter.string(from: cycleStart)
    }
}

/// Explicit provenance for a saved independent session. Association is chosen
/// at Save; no current Goal or planned-session context is copied into it.
struct CoreIndependentGeoBeatContext: Codable, Equatable {
    let pieceID: UUID
    let divisionID: UUID
    let source: String

    init(pieceID: UUID, divisionID: UUID) {
        self.pieceID = pieceID
        self.divisionID = divisionID
        source = "independentGeoBeat"
    }
}

extension PracticeAttempt {
    var coreContext: CoreSessionContext? {
        guard let coreContextData else { return nil }
        return try? JSONDecoder().decode(CoreSessionContext.self, from: coreContextData)
    }

    var independentGeoBeatContext: CoreIndependentGeoBeatContext? {
        guard let coreContextData,
              let value = try? JSONDecoder().decode(CoreIndependentGeoBeatContext.self, from: coreContextData),
              value.source == "independentGeoBeat"
        else { return nil }
        return value
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
        case .noRecording: "本次没有完成记录，不保存空练习。"
        }
    }
}

@MainActor
final class CoreSessionRuntime: ObservableObject {
    static let draftKey = "rovia.practice.core.session.v1"
    @Published private(set) var session = PracticeSession()
    @Published private(set) var context: CoreSessionContext?
    @Published private(set) var preset = MetronomePreset.standard
    @Published private(set) var exitRequest: CoreExitRequest?
    @Published var needsRecovery = false
    @Published private(set) var failure: String?
    @Published private(set) var execution: CoreDivisionDefinition?
    @Published private(set) var hasStartedPlayback = false
    @Published private(set) var independentHand: PracticeHand = .both
    @Published private var provisionalHand: PracticeHand = .both
    private var provisionalSource: (piece: PracticeSong, division: PracticeEvent, calendar: Calendar, starts: [PracticeHand: Int], activation: CoreLadderActivation, focusEnabled: Bool)?
    private let defaults: UserDefaults
    private struct Draft: Codable {
        var session: PracticeSession
        var context: CoreSessionContext
        var preset: MetronomePreset
        var savedAt: Date
        var execution: CoreDivisionDefinition?
        var hasStartedPlayback: Bool?
    }
    var activeID: UUID? { hasStartedPlayback && context != nil ? session.sessionID : nil }
    var independentActiveID: UUID? {
        hasStartedPlayback && context == nil ? session.sessionID : nil
    }
    var currentHand: PracticeHand { hasStartedPlayback ? session.currentHand : provisionalHand }
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
            hasStartedPlayback = draft.hasStartedPlayback ?? true
            if count == 0 { clear(); return } // SES-04: never retain an empty formal session after exit.
            // Exclude process downtime, keeping identity and real samples.
            session.pause(at: draft.savedAt)
            needsRecovery = true
        } catch { failure = CoreFlowError.damagedDraft.localizedDescription }
    }

    func begin(piece: PracticeSong, division: PracticeEvent, initialHand: PracticeHand? = nil, at date: Date = .now,
               calendar: Calendar = .current, confirmedStarts: [PracticeHand: Int] = [:],
               activation: CoreLadderActivation = CoreLadderActivation(), focusEnabled: Bool = false) throws {
        guard failure == nil else { throw CoreFlowError.damagedDraft }
        guard activeID == nil else { throw CoreIntegrationError.activeSession }
        guard piece.deletedAt == nil, division.songID == piece.id, let definition = division.coreDefinition,
              let structure = piece.coreStructure, definition.fits(structure),
              definition.goal != nil, definition.canStart(activation: activation) else { throw CoreIntegrationError.invalidGoal }
        // Resolve before any session, draft, or context mutation. Multi-hand never defaults.
        guard let hand = initialHand ?? definition.handMode.directInitialHand,
              definition.handMode.hands.contains(hand) else {
            throw CoreFlowError.invalidInput("请选择本次练习首先记录的手型。")
        }
        var prepared = try Self.prepare(division: division, at: date, calendar: calendar, activation: activation)
        for hand in prepared.needsStart {
            guard let start = confirmedStarts[hand], let config = prepared.definition.goal?.hands[hand]?.ladder else {
                throw CoreFlowError.invalidInput("请确认新周期每个手型的起始 BPM。")
            }
            let old = definition.ladderStates?[hand]
            let previous = old?.previousValidBPM.map {
                Int((Double($0) * (old?.previousNoteUnit ?? config.noteUnit).quarterMultiplier / config.noteUnit.quarterMultiplier).rounded())
            } ?? 300
            let oldEpoch = old?.activationEpoch ?? definition.ladderConfigurationEpochs?[hand] ?? 0
            let restarting = oldEpoch != activation.epoch || definition.ladderRestartRequired?.contains(hand) == true
            let target = prepared.definition.goal?.hands[hand]?.speed?.bpm
            let ceiling = restarting ? (target.map { $0 - 1 } ?? 300) : min(previous, target ?? 300)
            guard ceiling >= 20, (20...max(20, ceiling)).contains(start) else {
                throw CoreFlowError.invalidInput("\(hand.title)：起始 BPM 须在 20–\(ceiling) 之间。")
            }
            prepared.definition.goal?.hands[hand]?.ladder?.startBPM = start
            if start == prepared.definition.goal?.hands[hand]?.speed?.bpm {
                prepared.definition.goal?.hands[hand]?.ladder?.retainsLockedOrigin = true
            }
        }
        guard let effectiveGoal = prepared.definition.executionGoal(activation: activation) else { throw CoreIntegrationError.invalidGoal }
        for hand in definition.handMode.hands where effectiveGoal.ladderEnabled == true {
            guard let config = effectiveGoal.hands[hand]?.ladder else { continue }
            let old = prepared.definition.ladderStates?[hand]
            var state: CoreLadderState
            if let old, old.cycleStart == prepared.cycle, !prepared.needsStart.contains(hand) {
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
            state.activationEpoch = activation.epoch
            prepared.definition.ladderStates?[hand] = state
            prepared.definition.ladderRestartRequired?.remove(hand)
        }
        execution = prepared.definition
        context = CoreSessionContext(pieceID: piece.id, divisionID: division.id, pieceName: piece.name,
            divisionName: definition.label(mode: structure.mode), handMode: definition.handMode, goal: effectiveGoal,
            cycleStart: prepared.cycle, timeZoneID: calendar.timeZone.identifier, focusEnabled: focusEnabled)
        var initialPreset = division.preset

        if effectiveGoal.ladderEnabled == true,
           effectiveGoal.hands[hand]?.ladder != nil,
           let ladderState = execution?.ladderStates?[hand],
           let referenceNote = TempoReferenceNote(rawValue: ladderState.noteUnit.rawValue) {
            initialPreset.bpm = ladderState.currentBPM
            initialPreset.referenceNote = referenceNote
        }

        preset = initialPreset.normalized
        // A11-SES: preview configuration has no Session identity, clock or draft.
        session.reset()
        provisionalHand = hand
        provisionalSource = (piece, division, calendar, confirmedStarts, activation, focusEnabled)
        hasStartedPlayback = false
        needsRecovery = false
        persist(at: date)
    }

    // Resolve boundaries once at Session start. A running Session never changes its cycle.
    static func prepare(division: PracticeEvent, at date: Date = .now, calendar: Calendar = .current,
                        activation: CoreLadderActivation = CoreLadderActivation())
        throws -> (definition: CoreDivisionDefinition, cycle: Date, needsStart: [PracticeHand]) {
        guard let definition = division.coreDefinition else { throw CoreIntegrationError.invalidGoal }
        return try prepare(definition: definition, at: date, calendar: calendar, activation: activation)
    }

    // Pure projection shared with Analyze; never persists pending goals or cycle changes.
    static func prepare(definition stored: CoreDivisionDefinition, at date: Date = .now,
                        calendar: Calendar = .current, activation: CoreLadderActivation = CoreLadderActivation())
        throws -> (definition: CoreDivisionDefinition, cycle: Date, needsStart: [PracticeHand]) {
        var definition = stored
        guard var goal = definition.goal, goal.reset?.isValid ?? true else { throw CoreIntegrationError.invalidGoal }
        let today = calendar.startOfDay(for: date)
        let oldCycle = definition.executionCycleStart ?? definition.applicableLadderStates.values.map(\.cycleStart).min()
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
        let eligible = definition.executionGoal(activation: activation)
        let needsStart = definition.handMode.hands.filter { hand in
            guard activation.enabled, eligible?.hands[hand]?.ladder != nil else { return false }
            let epoch = definition.ladderStates?[hand]?.activationEpoch ?? definition.ladderConfigurationEpochs?[hand] ?? 0
            return (changed && !hasPending) || epoch != activation.epoch || definition.ladderRestartRequired?.contains(hand) == true
        }
        return (definition, cycle, needsStart)
    }

    var isFocusEnabled: Bool { context?.focusEnabled == true }
    func practiceDurationMilliseconds(at date: Date = .now) -> Int64 {
        guard hasStartedPlayback else { return 0 }
        return PracticeHand.allCases.reduce(0) { $0 + session.stats(for: $1, at: date).durationMilliseconds }
    }
    // Focus and Practice have identical eligible intervals for this captured On
    // session. Reuse the authoritative paused/recovered clock, not a second timer.
    func focusDurationMilliseconds(at date: Date = .now) -> Int64 {
        isFocusEnabled ? practiceDurationMilliseconds(at: date) : 0
    }

    func updatePreset(_ value: MetronomePreset, at date: Date = .now) {
        preset = value.normalized
        persist(at: date)
    }

    @discardableResult
    func startIndependentPlayback(at date: Date = .now, using start: () -> Bool) -> Bool {
        let succeeded = start()
        guard succeeded else { return false }
        if !hasStartedPlayback {
            session.begin(initialHand: independentHand, at: date)
            hasStartedPlayback = true
        } else {
            session.resume(at: date)
        }
        return true
    }

    func selectIndependentHand(_ hand: PracticeHand, at date: Date = .now) {
        independentHand = hand
        if hasStartedPlayback { session.switchHand(to: hand, at: date) }
    }

    func recordIndependent(preset: MetronomePreset, at date: Date = .now) {
        guard hasStartedPlayback, session.isRunning else { return }
        self.preset = preset.normalized
        session.recordCompletion(for: independentHand, preset: preset, at: date)
    }

    @discardableResult
    func saveIndependent(
        piece: PracticeSong,
        division: PracticeEvent,
        in modelContext: ModelContext,
        at date: Date = .now
    ) throws -> PracticeAttempt {
        guard piece.deletedAt == nil, division.songID == piece.id,
              let definition = division.coreDefinition,
              hasStartedPlayback else { throw CoreIntegrationError.wrongDestination }
        let usedHands = Set(PracticeHand.allCases.filter {
            !session.completionSamples(for: $0).isEmpty
                || session.stats(for: $0, at: date).durationMilliseconds > 0
        })
        guard usedHands.allSatisfy({ definition.handMode.hands.contains($0) }) else {
            throw CoreFlowError.invalidInput("请选择包含本次记录手型的练习划分。")
        }
        if session.reviewSummary == nil { _ = session.finish(at: date) }
        guard let summary = session.reviewSummary,
              summary.totalDurationMilliseconds > 0 || !summary.completions.isEmpty
        else { throw CoreFlowError.noRecording }
        let provenance = CoreIndependentGeoBeatContext(
            pieceID: piece.id, divisionID: division.id
        )
        let saved = try division.commit(
            summary: summary,
            in: modelContext,
            coreContextData: JSONEncoder().encode(provenance)
        ).attempt
        session.reset()
        hasStartedPlayback = false
        return saved
    }

    func discardIndependent() {
        session.reset()
        hasStartedPlayback = false
    }
    func pause(at date: Date = .now) { session.pause(at: date); persist(at: date) }
    func resume(at date: Date = .now) {
        guard activeID != nil else { return }
        session.resume(at: date); needsRecovery = false; persist(at: date)
    }
    // Revalidate the preview at Play (including a crossed cycle boundary), then
    // commit only after the audio engine reports that startup succeeded.
    @discardableResult
    func startPlayback(at date: Date? = nil, using start: () -> Bool) throws -> Bool {
        if !hasStartedPlayback, let source = provisionalSource {
            let selectedPreset = preset
            try begin(piece: source.piece, division: source.division, initialHand: currentHand,
                      at: date ?? .now, calendar: source.calendar, confirmedStarts: source.starts, activation: source.activation, focusEnabled: source.focusEnabled)
            preset = selectedPreset
        }
        let succeeded = start()
        synchronizePlayback(isPlaying: succeeded, at: date ?? .now)
        return succeeded
    }
    func synchronizePlayback(isPlaying: Bool, at date: Date = .now) {
        if isPlaying, !hasStartedPlayback, let context {
            session.begin(sourceEventID: context.divisionID, initialHand: provisionalHand, at: date)
            hasStartedPlayback = true
            provisionalSource = nil
        }
        if isPlaying { resume(at: date) } else { pause(at: date) }
    }
    func cancelBeforePlayback() throws -> UUID {
        guard let context, !hasStartedPlayback, count == 0 else { throw CoreIntegrationError.activeSession }
        let piece = context.pieceID
        clear()
        return piece
    }
    func switchHand(_ hand: PracticeHand, at date: Date = .now) {
        guard context?.handMode.allowsHandSwitching == true,
              context?.handMode.hands.contains(hand) == true,
              hand != currentHand else { return }

        if hasStartedPlayback { session.switchHand(to: hand, at: date) }
        else { provisionalHand = hand }

        if context?.goal.ladderEnabled == true,
           context?.goal.hands[hand]?.ladder != nil,
           let state = execution?.ladderStates?[hand],
           let referenceNote = TempoReferenceNote(rawValue: state.noteUnit.rawValue) {

            var handPreset = preset
            handPreset.bpm = state.currentBPM
            handPreset.referenceNote = referenceNote
            preset = handPreset.normalized
        }

        persist(at: date)
    }
    func record(preset: MetronomePreset, at date: Date = .now) {
        guard activeID != nil, session.isRunning else { return }
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

                    var nextPreset = self.preset
                    nextPreset.bpm = state.currentBPM

                    if let nextReference = TempoReferenceNote(rawValue: state.noteUnit.rawValue) {
                        nextPreset.referenceNote = nextReference
                    }

                    self.preset = nextPreset.normalized
                }
                execution?.ladderStates?[session.currentHand] = state
            }
        }
        persist(at: date)
    }
    func requestExit(_ request: CoreExitRequest) throws {
        guard activeID != nil else { throw CoreIntegrationError.wrongDestination }
        guard exitRequest == nil else { return }
        exitRequest = request
    }

    // Count and Ladder remain provisional until Save; Discard only releases the draft.
    @discardableResult
    func resolveExit(_ choice: CoreExitChoice, division: PracticeEvent, in modelContext: ModelContext,
                     at date: Date = .now, saving: (() throws -> Void)? = nil) throws -> CoreExitDestination? {
        guard let context, let request = exitRequest else { throw CoreIntegrationError.wrongDestination }
        if choice == .cancel { exitRequest = nil; return nil }
        guard division.id == context.divisionID && division.songID == context.pieceID else {
            throw CoreIntegrationError.wrongDestination
        }
        if request.saveOnly && choice == .discard {
            throw CoreFlowError.invalidInput("修改练习划分范围或适用手型前，必须保存并结束当前练习。")
        }
        let destination: CoreExitDestination
        switch request {
        case .ordinary: destination = .piece(context.pieceID)
        case .transition(let route): destination = .route(route)
        }
        if choice == .save && count > 0 {
            let originalSession = session
            finish(at: date)
            do { _ = try save(division: division, in: modelContext, saving: saving) }
            catch {
                session = originalSession
                persist(at: date)
                throw error
            }
        } else {
            // SES-04: even Save & End does not manufacture an empty formal Session.
            clear()
        }
        exitRequest = nil
        return destination
    }

    func finish(at date: Date = .now) {
        _ = session.finish(at: date)
        persist(at: date)
    }
    func continuePractice(at date: Date = .now) {
        session.continueAfterReview(at: date)
        session.pause(at: date)
        persist(at: date)
    }
    func persist(at date: Date = .now) {
        guard let context, hasStartedPlayback else { return }
        do {
            defaults.set(try JSONEncoder().encode(Draft(session: session, context: context, preset: preset, savedAt: date, execution: execution, hasStartedPlayback: hasStartedPlayback)), forKey: Self.draftKey)
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func save(division: PracticeEvent, in modelContext: ModelContext, saving: (() throws -> Void)? = nil) throws -> PracticeAttempt {
        guard let context, context.divisionID == division.id, context.pieceID == division.songID,
              let summary = session.reviewSummary else { throw CoreIntegrationError.wrongDestination }
        guard !summary.completions.isEmpty else { throw CoreFlowError.noRecording }
        var savedContext = context
        if context.focusEnabled != nil {
            savedContext.focusDurationMilliseconds = context.focusEnabled == true ? summary.totalDurationMilliseconds : 0
        }
        let oldDefinition = division.coreDefinitionData
        if let execution { division.coreDefinitionData = try JSONEncoder().encode(execution) }
        let result: PracticeAttemptCommitResult
        do {
            result = try division.commit(summary: summary, in: modelContext,
                                         coreContextData: JSONEncoder().encode(savedContext), saving: saving ?? { try modelContext.save() })
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
        session.reset(); hasStartedPlayback = false; context = nil; execution = nil; needsRecovery = false; exitRequest = nil
        provisionalSource = nil
    }
}

@MainActor
enum CoreSyncProtection {
    static func activeEventID(
        planned: CoreSessionRuntime,
        independent: CoreSessionRuntime,
        recoveryID: UUID?
    ) -> UUID? {
        planned.activeID ?? independent.independentActiveID ?? recoveryID
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
                        scoreTempo: CoreTargetSpeed? = nil, speedWeight: Double = 0.75,
                        now: Date = .now, calendar: Calendar = .current) -> Double? {
        guard let target = goal.hands[hand], let speed = target.speed ?? scoreTempo,
              let stable = stable(attempts, hand: hand) else { return nil }
        let speedProgress = min(1, stable / speed.quarterEquivalent)
        guard let targetCount = target.count else { return speedProgress }
        let today = calendar.startOfDay(for: now)
        let latest = attempts.first { $0.completions.contains { $0.hand == hand } }
        // CYCLE-04 / MAS-06: carry the last hand's cycle until new facts arrive.
        // A goal edit is an explicit re-evaluation against today's execution facts.
        let editedAfterLatest = (goal.updatedAt ?? .distantPast) > (latest?.finishedAt ?? .distantPast)
        let cycle = editedAfterLatest ? calendar.startOfDay(for: goal.updatedAt ?? now) : (latest?.coreContext?.cycleStart ?? today)
        let countProgress = min(1, Double(count(attempts, hand: hand, cycleStart: cycle)) / Double(targetCount))
        let weight = min(1, max(0, speedWeight))
        return weight * speedProgress + (1 - weight) * countProgress
    }
    static func divisionMastery(_ attempts: [PracticeAttempt], definition: CoreDivisionDefinition,
                                scoreTempo: CoreTargetSpeed? = nil, speedWeight: Double = 0.75,
                                now: Date = .now) -> Double? {
        guard let goal = definition.goal else { return nil }
        let values = definition.handMode.hands.compactMap {
            mastery(attempts, hand: $0, goal: goal, scoreTempo: scoreTempo,
                    speedWeight: speedWeight, now: now)
        }
        guard values.count == definition.handMode.hands.count else { return nil }
        return values.count == 1 ? values[0] : values[0] * 0.25 + values[1] * 0.25 + values[2] * 0.5
    }
    static func speedTargetProtectionApplies(_ attempts: [PracticeAttempt], hand: PracticeHand,
                                             goal: CoreGoal, scoreTempo: CoreTargetSpeed? = nil) -> Bool {
        guard let target = goal.hands[hand], let count = target.count, count > 0,
              let speed = target.speed ?? scoreTempo, (20...300).contains(speed.bpm),
              let stable = stable(attempts, hand: hand), stable.isFinite, stable > 0
        else { return false }
        return stable < speed.quarterEquivalent
    }
    static func divisionNeedsAttention(_ attempts: [PracticeAttempt], definition: CoreDivisionDefinition,
                                       scoreTempo: CoreTargetSpeed? = nil, speedWeight: Double = 0.75,
                                       threshold: Double = 0.20, now: Date = .now) -> Bool? {
        guard let goal = definition.goal,
              let score = divisionMastery(attempts, definition: definition, scoreTempo: scoreTempo,
                                          speedWeight: speedWeight, now: now)
        else { return nil }
        if definition.handMode.hands.contains(where: {
            speedTargetProtectionApplies(attempts, hand: $0, goal: goal, scoreTempo: scoreTempo)
        }) { return true }
        return score <= 1 - threshold
    }
}

// A11-TC / A12-ANA-05: progress against finite goals, independent of Weakness.
struct CoreHandTargetCompletion: Equatable {
    let actualCount: Int?
    let count: Double?
    let speed: Double?
    let combined: Double?
}

struct CoreDivisionTargetCompletion {
    let goal: CoreGoal?
    let hands: [PracticeHand: CoreHandTargetCompletion]
    let combined: Double?
}

struct CorePieceTargetCompletion {
    let combined: Double?
    let divisionCount: Int
    let achievedCount: Int
    let inProgressCount: Int
    let unavailableCount: Int
}

@MainActor
enum CoreTargetCompletion {
    static func hand(target: CoreHandGoal, actualCount: Int?, stableSpeed: Double?) -> CoreHandTargetCompletion {
        let count: Double? = target.count.flatMap { denominator in
            guard denominator > 0, let actualCount, actualCount >= 0 else { return nil }
            return min(1, Double(actualCount) / Double(denominator))
        }
        let speed: Double? = target.speed.flatMap { target in
            guard (20...300).contains(target.bpm), let stableSpeed,
                  stableSpeed.isFinite, stableSpeed > 0 else { return nil }
            return min(1, stableSpeed / target.quarterEquivalent)
        }
        let combined: Double?
        switch (target.count != nil, target.speed != nil) {
        case (true, true): combined = count.flatMap { c in speed.map { (c + $0) / 2 } }
        case (true, false): combined = count
        case (false, true): combined = speed
        case (false, false): combined = nil // Only open-ended Ladder has no finite denominator.
        }
        return CoreHandTargetCompletion(actualCount: actualCount, count: count, speed: speed, combined: combined)
    }

    static func division(definition: CoreDivisionDefinition, attempts: [PracticeAttempt],
                         isCurrent: Bool = true, now: Date = .now, calendar: Calendar = .current) -> CoreDivisionTargetCompletion {
        guard isCurrent, let projected = try? CoreSessionRuntime.prepare(definition: definition, at: now, calendar: calendar),
              let executionGoal = projected.definition.goal else {
            return CoreDivisionTargetCompletion(goal: nil, hands: [:], combined: nil)
        }
        // An explicit immediate Analyze choice uses pending targets without changing execution.
        let goal = definition.nextCycleAnalyzeTiming == .immediately
            ? (definition.nextCycleGoal ?? executionGoal) : executionGoal
        let saved = attempts.filter { $0.coreContext?.source == "planned" && $0.finishedAt <= now }
            .sorted { $0.finishedAt == $1.finishedAt ? $0.createdAt > $1.createdAt : $0.finishedAt > $1.finishedAt }
        var hands: [PracticeHand: CoreHandTargetCompletion] = [:]
        for hand in definition.handMode.hands {
            guard let target = goal.hands[hand] else { continue }
            // Saved aggregate counts remain facts even when per-record speed evidence is absent.
            let actual = saved.filter { $0.coreContext?.cycleStart == projected.cycle }.reduce(0) { total, attempt in
                let (sum, overflow) = total.addingReportingOverflow(max(0, attempt.stats(for: hand).count))
                return overflow ? Int.max : sum
            }
            hands[hand] = self.hand(target: target, actualCount: actual, stableSpeed: CoreAnalysis.stable(saved, hand: hand))
        }
        let values = definition.handMode.hands.compactMap { hands[$0]?.combined }
        let combined = values.count == definition.handMode.hands.count
            ? values.reduce(0, +) / Double(values.count) : nil
        return CoreDivisionTargetCompletion(goal: goal, hands: hands, combined: combined)
    }

    static func piece(structure: CorePieceStructure?, divisions: [(CoreDivisionDefinition, CoreDivisionTargetCompletion)],
                      isCurrent: Bool = true) -> CorePieceTargetCompletion {
        let achieved = divisions.filter { $0.1.combined == 1 }.count
        let progressing = divisions.filter { $0.1.combined.map { $0 < 1 } ?? false }.count
        let unavailable = divisions.count - achieved - progressing
        var completion: Double?
        if isCurrent, let structure, let total = structure.total, total > 0, !divisions.isEmpty {
            let ordered = divisions.sorted { $0.0.first < $1.0.first }
            var coveredEnd = 0
            var weighted = 0.0
            var covered = true
            for (definition, result) in ordered {
                guard definition.fits(structure), coveredEnd < total, definition.first == coveredEnd + 1, let value = result.combined else {
                    covered = false; break
                }
                weighted += Double(definition.last - definition.first + 1) * value
                coveredEnd = definition.last
            }
            if covered && coveredEnd == total { completion = weighted / Double(total) }
        }
        return CorePieceTargetCompletion(combined: completion, divisionCount: divisions.count,
            achievedCount: achieved, inProgressCount: progressing, unavailableCount: unavailable)
    }

    static func piece(_ piece: PracticeSong, events: [PracticeEvent], attempts: [PracticeAttempt],
                      now: Date = .now, calendar: Calendar = .current) -> CorePieceTargetCompletion {
        let current = !piece.isArchived && piece.deletedAt == nil
        let divisions = events.filter { $0.songID == piece.id }.compactMap { event -> (CoreDivisionDefinition, CoreDivisionTargetCompletion)? in
            guard let definition = event.coreDefinition else { return nil }
            return (definition, division(definition: definition, attempts: CoreAnalysis.planned(attempts, division: event.id),
                                         isCurrent: current, now: now, calendar: calendar))
        }
        return self.piece(structure: piece.coreStructure, divisions: divisions, isCurrent: current)
    }

    static func percentage(_ value: Double?) -> String {
        value.map { ($0 * 100).formatted(.number.precision(.fractionLength(0...1))) + "%" }
            ?? "暂无法计算（N/A）"
    }
}
