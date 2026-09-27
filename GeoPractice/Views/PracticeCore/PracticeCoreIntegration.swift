import Foundation
import SwiftData

// Temporary E2E destinations are in PracticeCoreFlowViews (not FROZEN UI).
// Do not call the old editors: they invent legacy defaults, delete history,
// auto-archive by endDate, or start goal-less planned sessions (EG-01…03).
enum CoreDependencies {
    static let legacyDraftKey = "practiceSessionDraft.v1"
    private static let deferredDraftKey = "rovia.practice.core.deferredLegacyDraft.v1"

    /// Explicitly defer only this exact legacy payload. The original is never
    /// deleted, rewritten, or promoted to a new planned Session. A changed
    /// legacy draft is a new recovery decision, not silently ignored.
    static func deferLegacyRecovery(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: legacyDraftKey) else { return }
        defaults.set(data, forKey: deferredDraftKey)
    }

    private struct LegacyDraft: Decodable {
        let session: PracticeSession
        let savedAt: Date
    }
    @MainActor static func readRecovery(songs: [PracticeSong], events: [PracticeEvent], defaults: UserDefaults = .standard)
        -> (recovery: CoreRecovery?, gap: String?) {
        guard let data = defaults.data(forKey: legacyDraftKey) else { return (nil, nil) }
        guard defaults.data(forKey: deferredDraftKey) != data else { return (nil, nil) }
        guard let draft = try? JSONDecoder().decode(LegacyDraft.self, from: data) else {
            return (nil, "原有练习草稿暂时无法读取，草稿已保留。")
        }
        let session = draft.session
        guard session.phase != .idle else { return (nil, nil) }
        guard session.phase != .finished else { return (nil, "原有练习结果待确认，但缺少新计划练习的归属与周期信息，不能自动迁移。草稿已保留。") }
        guard let eventID = session.sourceEventID,
              let event = events.first(where: { $0.id == eventID }),
              let song = songs.first(where: { $0.id == event.songID }) else {
            return (nil, "原有练习草稿的归属尚未确认，草稿已保留。")
        }
        let hasRecords = PracticeHand.allCases.contains { !session.completionSamples(for: $0).isEmpty }
        guard hasRecords else { return (nil, "原有草稿没有有效记录，不计入正式练习。旧草稿处理仍待兼容确认，资料已保留。") }
        // Read-only projection: never instantiate the legacy controller, whose
        // initializer rewrites the draft. No timer accrues while this shell is open.
        return (CoreRecovery(sessionID: session.sessionID, divisionID: eventID,
                             pieceName: song.name, divisionName: event.name), nil)
    }
}

// Debug-only isolated QA fixtures. Never seed or migrate a user's local store.
struct CoreFixture {
    var path: [CorePage] = []
    var recovery: CoreRecovery?
#if DEBUG
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-practice-core-fixture"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    @MainActor static func make(_ name: String, context: ModelContext) throws -> CoreFixture {
        if name == "empty" { return CoreFixture() }
        let piece = PracticeSong(name: name == "long" ? "很长的曲目名称：练习曲 Op.10 No.4 — 左右手独立性与完整乐句的练习" : "九儿")
        let structure = CorePieceStructure(mode: .sections, total: 6)
        piece.coreStructureData = try JSONEncoder().encode(structure)
        context.insert(piece)
        if name == "no-division" { try context.save(); return CoreFixture(path: [.piece(piece.id)]) }
        let event = PracticeEvent(songID: piece.id, name: "第 3 段")
        let goal: CoreGoal? = ["valid-goal", "long"].contains(name) ? CoreGoal(hands: [
            .left: CoreHandGoal(count: 10), .right: CoreHandGoal(speed: CoreTargetSpeed(bpm: 80)),
            .both: CoreHandGoal(count: 10)
        ]) : nil
        event.coreDefinitionData = try JSONEncoder().encode(CoreDivisionDefinition(first: 3, last: 3, handMode: .all, goal: goal))
        context.insert(event)
        try context.save()
        switch name {
        case "piece": return CoreFixture(path: [.piece(piece.id)])
        case "no-goal", "valid-goal", "long":
            return CoreFixture(path: [.piece(piece.id), .division(piece: piece.id, division: event.id)])
        case "recovery":
            return CoreFixture(recovery: CoreRecovery(sessionID: UUID(), divisionID: event.id, pieceName: piece.name, divisionName: event.name))
        default: return CoreFixture()
        }
    }
#endif
}
