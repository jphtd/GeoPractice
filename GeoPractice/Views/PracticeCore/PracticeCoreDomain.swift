import Combine
import Foundation
import SwiftData

// Frozen Product DIV-01 / HAND-01 / GOAL-01…03,07. No legacy inference.
enum CoreDivisionMode: String, Codable, CaseIterable {
    case measures, sections
    var unit: String { self == .measures ? "小节" : "段" }
    var label: String { self == .measures ? "按小节" : "按段落" }
}

struct CorePieceStructure: Codable, Equatable {
    var mode: CoreDivisionMode
    var total: Int?
    var isValid: Bool { total == nil || total! > 0 }
    var label: String {
        guard let total, total > 0 else { return mode.label }
        return "\(mode.label) · 共 \(total) \(mode.unit)"
    }
}

enum CoreHandMode: String, Codable, CaseIterable {
    case left, right, all
    var hands: [PracticeHand] {
        switch self {
        case .left: [.left]
        case .right: [.right]
        case .all: [.left, .right, .both]
        }
    }
    var label: String {
        switch self {
        case .left: "仅左手"
        case .right: "仅右手"
        case .all: "左手 + 右手 + 合手"
        }
    }
}

enum CoreNoteUnit: String, Codable, CaseIterable {
    case whole, half, dottedHalf, quarter, dottedQuarter, eighth, dottedEighth, sixteenth
    var quarterMultiplier: Double {
        switch self {
        case .whole: 4
        case .half: 2
        case .dottedHalf: 3
        case .quarter: 1
        case .dottedQuarter: 1.5
        case .eighth: 0.5
        case .dottedEighth: 0.75
        case .sixteenth: 0.25
        }
    }
}

struct CoreTargetSpeed: Codable, Equatable {
    var bpm: Int
    var noteUnit: CoreNoteUnit = .quarter
    var quarterEquivalent: Double { Double(bpm) * noteUnit.quarterMultiplier }
}

struct CoreHandGoal: Codable, Equatable {
    var count: Int?
    var speed: CoreTargetSpeed?
    var isValid: Bool {
        // No invented upper limits. Non-positive supplied values are invalid.
        (count == nil || count! > 0) && (speed == nil || speed!.bpm > 0)
            && (count != nil || speed != nil)
    }
}

struct CoreGoal: Codable, Equatable {
    var hands: [PracticeHand: CoreHandGoal]
    var targetDate: Date?
    var updatedAt: Date?
    func isValid(for mode: CoreHandMode) -> Bool {
        mode.hands.allSatisfy { hands[$0]?.isValid == true }
    }
}

struct CoreDivisionDefinition: Codable, Equatable {
    var first: Int
    var last: Int
    var handMode: CoreHandMode
    var goal: CoreGoal?
    var hasValidGoal: Bool { goal?.isValid(for: handMode) == true }
    func label(mode: CoreDivisionMode) -> String {
        "第 \(first == last ? String(first) : "\(first)–\(last)") \(mode.unit)"
    }
    func fits(_ structure: CorePieceStructure) -> Bool {
        structure.isValid && first > 0 && last >= first && (structure.total == nil || last <= structure.total!)
    }
}

extension PracticeSong {
    var coreStructure: CorePieceStructure? {
        guard let coreStructureData else { return nil }
        return try? JSONDecoder().decode(CorePieceStructure.self, from: coreStructureData)
    }
}
extension PracticeEvent {
    var coreDefinition: CoreDivisionDefinition? {
        guard let coreDefinitionData else { return nil }
        return try? JSONDecoder().decode(CoreDivisionDefinition.self, from: coreDefinitionData)
    }
}

enum CorePage: Hashable {
    case piece(UUID)
    case division(piece: UUID, division: UUID)
}

enum CoreAnalyzeContext: Hashable {
    case overall, piece(UUID), division(piece: UUID, division: UUID)
}

// Typed outgoing contracts; a request alone NEVER starts a session or changes data.
enum CoreRoute: Equatable {
    case addPiece, allPieces
    case pieceSettings(UUID)
    case createDivision(piece: UUID, mode: CoreDivisionMode)
    case editGoal(piece: UUID, division: UUID)
    case startPractice(piece: UUID, division: UUID)
    case freePractice
    case geoBeat(activeSession: UUID?)
    case analyze(CoreAnalyzeContext)
    case resumeSession(UUID)
}

struct CoreRecovery: Equatable {
    var sessionID: UUID
    var divisionID: UUID
    var pieceName: String
    var divisionName: String
}

enum CoreHomeState: Equatable {
    case normal, empty, recovery(CoreRecovery)
    static func resolve(pieceCount: Int, recovery: CoreRecovery?) -> Self {
        if let recovery { return .recovery(recovery) }
        return pieceCount == 0 ? .empty : .normal
    }
}

enum CoreIntegrationError: LocalizedError {
    case missingMetadata, invalidRange, overlappingRange, activeSession, invalidGoal, wrongDestination
    var errorDescription: String? {
        switch self {
        case .missingMetadata: "此曲目的练习结构尚未确认，暂时无法打开。原有资料保持不变。"
        case .invalidRange: "练习划分范围不符合当前曲目结构。"
        case .overlappingRange: "练习划分不能与现有划分重叠。"
        case .activeSession: "请先结束并确认保存当前练习。"
        case .invalidGoal: "每个适用手型都需要目标次数或练习目标速度。"
        case .wrongDestination: "返回的对象与当前操作不一致。"
        }
    }
}

@MainActor
enum CoreContracts {
    static func savePiece(name: String, structure: CorePieceStructure, context: ModelContext,
                          activeSessionID: UUID?) throws -> PracticeSong {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, structure.isValid else { throw CoreFlowError.invalidInput("请填写曲目名称，并检查总数是否为正整数。") }
        let piece = PracticeSong(name: name, endDate: .distantFuture)
        piece.coreStructureData = try JSONEncoder().encode(structure)
        context.insert(piece)
        do { try context.save() } catch { context.rollback(); throw error }
        return piece
    }

    static func saveGoal(piece: UUID, division: PracticeEvent, goal: CoreGoal,
                         context: ModelContext, activeSessionID: UUID?, at date: Date = .now) throws -> CorePage {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard division.songID == piece, var definition = division.coreDefinition else { throw CoreIntegrationError.wrongDestination }
        guard goal.isValid(for: definition.handMode) else { throw CoreIntegrationError.invalidGoal }
        var value = goal; value.updatedAt = date
        definition.goal = value
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        division.updatedAt = date
        do { try context.save() } catch { context.rollback(); throw error }
        return .division(piece: piece, division: division.id)
    }

    static func validateDivision(_ definition: CoreDivisionDefinition, structure: CorePieceStructure,
                                 existing: [CoreDivisionDefinition]) throws {
        guard definition.fits(structure) else { throw CoreIntegrationError.invalidRange }
        guard !existing.contains(where: { $0.first <= definition.last && definition.first <= $0.last }) else {
            throw CoreIntegrationError.overlappingRange
        }
    }

    // Called by the temporary Create Flow only after its explicit save.
    // Amendment 01: inherit mode; persist no Goal; return new Division Detail.
    static func saveCreatedDivision(piece: PracticeSong, definition: CoreDivisionDefinition,
                                    context: ModelContext, activeSessionID: UUID?) throws -> CorePage {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard let structure = piece.coreStructure else { throw CoreIntegrationError.missingMetadata }
        let pieceID = piece.id
        let existing = try context.fetch(FetchDescriptor<PracticeEvent>(predicate: #Predicate { $0.songID == pieceID }))
        guard existing.allSatisfy({ $0.coreDefinition != nil }) else { throw CoreIntegrationError.missingMetadata }
        try validateDivision(definition, structure: structure, existing: existing.compactMap(\.coreDefinition))
        var value = definition
        value.goal = nil
        let event = PracticeEvent(songID: piece.id, name: value.label(mode: structure.mode))
        event.coreDefinitionData = try JSONEncoder().encode(value)
        context.insert(event)
        do { try context.save() } catch { context.delete(event); throw error }
        return .division(piece: piece.id, division: event.id)
    }

    static func startRoute(piece: UUID, division: UUID, definition: CoreDivisionDefinition,
                           activeSessionID: UUID?) throws -> CoreRoute {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard definition.hasValidGoal else { throw CoreIntegrationError.invalidGoal }
        return .startPractice(piece: piece, division: division)
    }

    static func goalSavedReturn(piece: UUID, division: PracticeEvent) throws -> CorePage {
        guard division.songID == piece else { throw CoreIntegrationError.wrongDestination }
        guard division.coreDefinition?.hasValidGoal == true else { throw CoreIntegrationError.invalidGoal }
        return .division(piece: piece, division: division.id)
    }
}

/// Inbound/outbound navigation contract shared by the three accepted screens.
/// Target UIs remain external; only a matching successful return changes the stack.
@MainActor
final class CoreNavigation: ObservableObject {
    @Published var path: [CorePage] = []
    @Published private(set) var pendingRoute: CoreRoute?

    func request(_ route: CoreRoute) { pendingRoute = route }
    func cancel() { pendingRoute = nil }

    func createdDivisionSaved(piece: PracticeSong, division: PracticeEvent) throws {
        guard case .createDivision(let pieceID, let mode) = pendingRoute,
              piece.id == pieceID, piece.coreStructure?.mode == mode,
              division.songID == pieceID,
              let structure = piece.coreStructure, let definition = division.coreDefinition,
              definition.fits(structure), definition.goal == nil else {
            throw CoreIntegrationError.wrongDestination
        }
        path = [.piece(pieceID), .division(piece: pieceID, division: division.id)]
        pendingRoute = nil
    }

    func goalSaved(piece: UUID, division: PracticeEvent) throws {
        guard pendingRoute == .editGoal(piece: piece, division: division.id) else {
            throw CoreIntegrationError.wrongDestination
        }
        let destination = try CoreContracts.goalSavedReturn(piece: piece, division: division)
        path = [.piece(piece), destination]
        pendingRoute = nil
    }
}
