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
    private let defaults: UserDefaults
    private struct Draft: Codable {
        var session: PracticeSession
        var context: CoreSessionContext
        var preset: MetronomePreset
        var savedAt: Date
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
            if count == 0 { clear(); return } // SES-04: never retain an empty formal session after exit.
            // Exclude process downtime, keeping identity and real samples.
            session.pause(at: draft.savedAt)
            needsRecovery = true
        } catch { failure = CoreFlowError.damagedDraft.localizedDescription }
    }

    func begin(piece: PracticeSong, division: PracticeEvent, at date: Date = .now,
               calendar: Calendar = .current) throws {
        guard failure == nil else { throw CoreFlowError.damagedDraft }
        guard context == nil else { throw CoreIntegrationError.activeSession }
        guard division.songID == piece.id, let definition = division.coreDefinition,
              let structure = piece.coreStructure, definition.fits(structure),
              let goal = definition.goal, goal.isValid(for: definition.handMode) else { throw CoreIntegrationError.invalidGoal }
        context = CoreSessionContext(pieceID: piece.id, divisionID: division.id, pieceName: piece.name,
            divisionName: definition.label(mode: structure.mode), handMode: definition.handMode, goal: goal,
            cycleStart: calendar.startOfDay(for: date), timeZoneID: calendar.timeZone.identifier)
        preset = division.preset
        session.begin(sourceEventID: division.id, initialHand: definition.handMode.hands.first ?? .both, at: date)
        needsRecovery = false
        persist(at: date)
    }

    func updatePreset(_ value: MetronomePreset, at date: Date = .now) {
        preset = value.normalized
        persist(at: date)
    }
    func pause(at date: Date = .now) { session.pause(at: date); persist(at: date) }
    func resume(at date: Date = .now) { session.resume(at: date); needsRecovery = false; persist(at: date) }
    func switchHand(_ hand: PracticeHand, at date: Date = .now) {
        guard context?.handMode.hands.contains(hand) == true else { return }
        session.switchHand(to: hand, at: date)
        persist(at: date)
    }
    func record(preset: MetronomePreset, at date: Date = .now) {
        guard session.isRunning else { return }
        self.preset = preset.normalized
        session.recordCompletion(for: session.currentHand, preset: preset, at: date)
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
            defaults.set(try JSONEncoder().encode(Draft(session: session, context: context, preset: preset, savedAt: date)), forKey: Self.draftKey)
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func save(division: PracticeEvent, in modelContext: ModelContext) throws -> PracticeAttempt {
        guard let context, context.divisionID == division.id, context.pieceID == division.songID,
              let summary = session.reviewSummary else { throw CoreIntegrationError.wrongDestination }
        guard !summary.completions.isEmpty else { throw CoreFlowError.noRecording }
        let result = try division.commit(summary: summary, in: modelContext,
                                         coreContextData: JSONEncoder().encode(context))
        clear()
        return result.attempt
    }
    func discardEmpty() throws {
        guard count == 0 else { throw CoreFlowError.invalidInput("已有练习记录，请结束并确认保存。") }
        clear()
    }
    private func clear() {
        defaults.removeObject(forKey: Self.draftKey)
        session.reset(); context = nil; needsRecovery = false
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
