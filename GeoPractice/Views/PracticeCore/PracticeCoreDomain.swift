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
    case left, right, both, all
    var hands: [PracticeHand] {
        switch self {
        case .left: [.left]
        case .right: [.right]
        case .both: [.both]
        case .all: [.left, .right, .both]
        }
    }
    var allowsHandSwitching: Bool { self == .all }
    var directInitialHand: PracticeHand? {
        switch self {
        case .left: .left
        case .right: .right
        case .both: .both
        case .all: nil
        }
    }
    var label: String {
        switch self {
        case .left: "仅左手"
        case .right: "仅右手"
        case .both: "仅合手"
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

// Global preference is separate from Goal configuration and from a Session snapshot.
struct CoreLadderActivation: Equatable {
    var enabled: Bool
    var epoch: Int
    init(enabled: Bool = false, isPro: Bool = false, epoch: Int = 0) {
        self.enabled = enabled && isPro; self.epoch = epoch
    }
}

@MainActor final class CorePracticeSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var focusEnabled: Bool
    @Published private(set) var ladderEnabled: Bool
    @Published private(set) var ladderEpoch: Int
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusEnabled = defaults.object(forKey: "rovia.focus.enabled") as? Bool ?? true
        ladderEnabled = defaults.bool(forKey: "rovia.globalLadder.enabled")
        ladderEpoch = defaults.integer(forKey: "rovia.globalLadder.epoch")
    }
    func setFocusEnabled(_ value: Bool, isPro: Bool) {
        guard isPro else { return }
        focusEnabled = value
        defaults.set(value, forKey: "rovia.focus.enabled")
    }
    func focusActivation(isPro: Bool) -> Bool { isPro && focusEnabled }
    func setLadderEnabled(_ value: Bool, isPro: Bool) {
        guard isPro, value != ladderEnabled else { return }
        if value { ladderEpoch += 1 }
        ladderEnabled = value
        defaults.set(ladderEpoch, forKey: "rovia.globalLadder.epoch")
        defaults.set(value, forKey: "rovia.globalLadder.enabled")
    }
    func activation(isPro: Bool) -> CoreLadderActivation {
        CoreLadderActivation(enabled: ladderEnabled, isPro: isPro, epoch: ladderEpoch)
    }
}

struct CoreHandGoal: Codable, Equatable {
    var count: Int?
    var speed: CoreTargetSpeed?
    var ladder: CoreLadderConfiguration?
    // Explicit legacy evidence only. Missing configuration/keys do not imply opt-out.
    var ladderParticipation: Bool?
    var ladderConfigurationConfirmed: Bool?
    var needsLadderConfirmation: Bool { ladderParticipation == false && ladderConfigurationConfirmed != true }
    var isValid: Bool { CoreGoalValidation.isValid(self) }
}

// Shared Basic Goal validity for creation, editing and execution.
enum CoreGoalValidation {
    static func isValid(_ goal: CoreHandGoal, ladderEnabled: Bool = false) -> Bool {
        let basicFieldsValid = (goal.count == nil || goal.count! > 0)
            && (goal.speed == nil || (20...300).contains(goal.speed!.bpm))
        let hasBasicTrainingCondition = goal.count != nil || goal.speed != nil
        let participates = ladderEnabled && goal.ladder != nil
        let ladderValid = !participates || goal.ladder!.isValid(target: goal.speed)
        let openEnded = participates && goal.speed == nil && ladderValid
        return basicFieldsValid && ladderValid && (hasBasicTrainingCondition || openEnded)
    }
}

struct CoreGoal: Codable, Equatable {
    var hands: [PracticeHand: CoreHandGoal]
    var updatedAt: Date?
    var ladderEnabled: Bool?
    var reset: CoreResetConfiguration?
    // Current configuration view only. Stored non-applicable hands remain historical evidence.
    func applicable(to mode: CoreHandMode) -> CoreGoal {
        var value = self
        value.hands = hands.filter { mode.hands.contains($0.key) }
        return value
    }
    func isValid(for mode: CoreHandMode) -> Bool {
        mode.hands.allSatisfy { hand in
            guard let value = hands[hand] else { return false }
            return CoreGoalValidation.isValid(value, ladderEnabled: ladderEnabled == true)
        } && (reset?.isValid ?? true)
    }
}

// Configuration and saved execution facts are separate. Node 3 owns fact production.
struct CoreLadderConfiguration: Codable, Equatable {
    var startBPM: Int
    var stepBPM: Int
    var repsPerLevel: Int
    var noteUnit: CoreNoteUnit = .quarter
    var retainsLockedOrigin: Bool?
    func isValid(target: CoreTargetSpeed?) -> Bool {
        (20...300).contains(startBPM) && (1...20).contains(stepBPM) && repsPerLevel >= 1
            && (target == nil || ((20...300).contains(target!.bpm) && (startBPM < target!.bpm || retainsLockedOrigin == true) && noteUnit == target!.noteUnit))
    }
    // A finite target is a hard final level, even when the last interval is short.
    func finiteLevels(target: CoreTargetSpeed) -> [Int] {
        guard isValid(target: target) else { return [] }
        return Array(stride(from: startBPM, to: target.bpm, by: stepBPM)) + [target.bpm]
    }
    func converted(to unit: CoreNoteUnit) -> Self {
        let ratio = noteUnit.quarterMultiplier / unit.quarterMultiplier
        return Self(startBPM: Int((Double(startBPM) * ratio).rounded()),
                    stepBPM: Int((Double(stepBPM) * ratio).rounded()), repsPerLevel: repsPerLevel, noteUnit: unit, retainsLockedOrigin: retainsLockedOrigin)
    }
}

struct CoreLadderState: Codable, Equatable {
    var cycleStart: Date
    var cycleStartBPM: Int
    var currentBPM: Int
    var repsCompleted: Int
    var noteUnit: CoreNoteUnit
    var firstValidRecordAt: Date?
    var previousValidBPM: Int?
    var previousNoteUnit: CoreNoteUnit?
    var activationEpoch: Int?
    var startLocked: Bool { firstValidRecordAt != nil }
    func suggestedStart(in unit: CoreNoteUnit) -> Int? {
        guard let previousValidBPM else { return nil }
        let previous = Double(previousValidBPM) * (previousNoteUnit ?? noteUnit).quarterMultiplier / unit.quarterMultiplier
        return max(20, Int(previous.rounded()) - 10)
    }
}

enum CoreGoalEditTiming: String, CaseIterable { case current, next }
enum CoreAnalyzeTiming: String, Codable, CaseIterable { case immediately, nextCycle }
struct CoreResetConfiguration: Codable, Equatable {
    static let proDays = [1, 3, 5, 7, 14, 30, 60, 90]
    var enabled = true
    var days = 1
    var anchor: Date?
    var pendingDays: Int?
    var pendingEffectiveAt: Date?
    var isValid: Bool { Self.proDays.contains(days) && (pendingDays == nil || Self.proDays.contains(pendingDays!)) }
}

struct CoreDivisionDefinition: Codable, Equatable {
    var first: Int
    var last: Int
    var handMode: CoreHandMode
    var goal: CoreGoal?
    // Uninterpreted pre-correction Goal data; never used as current configuration.
    var legacyGoalData: Data?
    var ladderStates: [PracticeHand: CoreLadderState]?
    var executionCycleStart: Date?
    var nextCycleGoal: CoreGoal?
    var nextCycleAnalyzeTiming: CoreAnalyzeTiming?
    var nextCycleAdjustedStartHands: Set<PracticeHand>?
    var ladderConfigurationEpochs: [PracticeHand: Int]?
    var ladderRestartRequired: Set<PracticeHand>?
    func executionGoal(activation: CoreLadderActivation) -> CoreGoal? {
        guard var value = goal?.applicable(to: handMode) else { return nil }
        value.ladderEnabled = activation.enabled
        for hand in handMode.hands {
            guard let configuration = value.hands[hand] else { continue }
            if !activation.enabled || configuration.needsLadderConfirmation ||
                configuration.ladder?.isValid(target: configuration.speed) != true {
                value.hands[hand]?.ladder = nil
            }
        }
        return value
    }
    func canStart(activation: CoreLadderActivation) -> Bool {
        executionGoal(activation: activation)?.isValid(for: handMode) == true
    }
    var applicableLadderStates: [PracticeHand: CoreLadderState] {
        (ladderStates ?? [:]).filter { handMode.hands.contains($0.key) }
    }
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
    case recentlyDeleted
}

enum CoreAnalyzeContext: Hashable {
    case overall, piece(UUID), division(piece: UUID, division: UUID)
}

// Typed outgoing contracts; a request alone NEVER starts a session or changes data.
enum CoreRoute: Equatable {
    case addPiece, allPieces, archivedPieces, deleteAllArchivedPieces, settings
    case createDivision(piece: UUID, mode: CoreDivisionMode)
    case editDivision(piece: UUID, division: UUID)
    case archivePiece(UUID), unarchivePiece(UUID), deletePiece(UUID)
    case startPractice(piece: UUID, division: UUID)
    case freePractice
    case geoBeat(activeSession: UUID?)
    case analyze(CoreAnalyzeContext)
    case resumeSession(UUID)
}

// Exit retains the original request; no intermediate Result destination is introduced.
enum CoreExitRequest: Equatable {
    case ordinary
    case transition(CoreRoute)
    var saveOnly: Bool {
        if case .transition(.editDivision) = self { return true }
        return false
    }
}
enum CoreExitChoice { case save, discard, cancel }
enum CoreExitDestination: Equatable {
    case piece(UUID)
    case route(CoreRoute)
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
        case .invalidGoal: "请检查每个适用手型的目标配置。"
        case .wrongDestination: "返回的对象与当前操作不一致。"
        }
    }
}

@MainActor
enum CoreContracts {
    static func archivePiece(piece: PracticeSong, context: ModelContext,
                             activeSessionID: UUID?, at date: Date = .now) throws {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard piece.deletedAt == nil else { throw CoreIntegrationError.wrongDestination }
        guard !piece.isArchived else { return }
        piece.isArchived = true
        piece.updatedAt = date
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    static func deleteAllArchivedPieces(context: ModelContext, activeSessionID: UUID?,
                                        isPro: Bool, at date: Date = .now) throws {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        let pieces = try context.fetch(FetchDescriptor<PracticeSong>())
            .filter { $0.isArchived && $0.deletedAt == nil }
        do {
            for piece in pieces {
                if isPro {
                    try movePieceToRecentlyDeleted(piece: piece, context: context,
                        activeSessionID: nil, isPro: true, at: date, saveChanges: false)
                } else {
                    try permanentlyDeletePiece(piece: piece, context: context,
                        activeSessionID: nil, saveChanges: false)
                }
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    
    static func archivePiece(
        piece: PracticeSong,
        context: ModelContext,
        activeSessionID: UUID?
    ) throws {
        guard activeSessionID == nil else {
            throw CoreIntegrationError.activeSession
        }

        guard piece.deletedAt == nil else {
            throw CoreIntegrationError.wrongDestination
        }

        piece.isArchived = true
        piece.updatedAt = .now

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
    static func unarchivePiece(
        piece: PracticeSong,
        context: ModelContext,
        at date: Date = .now
    ) throws {
        guard piece.deletedAt == nil else {
            throw CoreIntegrationError.wrongDestination
        }

        guard piece.isArchived else { return }

        piece.isArchived = false
        piece.updatedAt = date

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
    static func movePieceToRecentlyDeleted(
        piece: PracticeSong,
        context: ModelContext,
        activeSessionID: UUID?,
        isPro: Bool,
        at date: Date = .now,
        saveChanges: Bool = true
    ) throws {
        guard isPro else { throw CoreFlowError.invalidInput("此操作需要 Pro 权限。") }
        guard activeSessionID == nil else {
            throw CoreIntegrationError.activeSession
        }

        guard piece.deletedAt == nil else { return }
        piece.deletedAt = date
        piece.updatedAt = date

        do {
            if saveChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }

    static func restoreRecentlyDeletedPiece(
        piece: PracticeSong,
        context: ModelContext,
        isPro: Bool,
        at date: Date = .now
    ) throws {
        guard isPro else { throw CoreFlowError.invalidInput("此操作需要 Pro 权限。") }
        guard let expiration = piece.deletionExpiresAt else { return }
        guard date < expiration else {
            try permanentlyDeletePiece(piece: piece, context: context, activeSessionID: nil)
            throw CoreFlowError.invalidInput("保留期已结束，此曲目已永久删除。")
        }
        piece.deletedAt = nil
        piece.updatedAt = date

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
    static func expireDeletedPieces(in context: ModelContext, at date: Date = .now) throws {
        let pieces = try context.fetch(FetchDescriptor<PracticeSong>())
        for piece in pieces where piece.deletionExpiresAt.map({ $0 <= date }) == true {
            try permanentlyDeletePiece(piece: piece, context: context, activeSessionID: nil)
        }
    }

    static func permanentlyDeletePiece(
        piece: PracticeSong,
        context: ModelContext,
        activeSessionID: UUID?,
        saveChanges: Bool = true
    ) throws {
        guard activeSessionID == nil else {
            throw CoreIntegrationError.activeSession
        }

        let pieceID = piece.id

        do {
            let events = try context.fetch(
                FetchDescriptor<PracticeEvent>(
                    predicate: #Predicate { $0.songID == pieceID }
                )
            )

            let folders = try context.fetch(FetchDescriptor<PracticeFolder>())

            for event in events {
                PracticeFolder.move(
                    eventID: event.id,
                    to: nil,
                    among: folders
                )

                try PracticeAttempt.deleteAll(
                    for: event.id,
                    in: context
                )

                try PracticeDailyGoal.deleteAll(
                    for: event.id,
                    in: context
                )

                context.delete(event)
            }

            context.delete(piece)
            if saveChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }
    static func savePiece(name: String, structure: CorePieceStructure, context: ModelContext,
                          activeSessionID: UUID?, composer: String = "") throws -> PracticeSong {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, structure.isValid else { throw CoreFlowError.invalidInput("请填写曲目名称，并检查总数是否为正整数。") }
        let piece = PracticeSong(name: name, endDate: .distantFuture)
        let rawComposer = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        piece.composerText = rawComposer.isEmpty ? nil : composer
        piece.composerCanonicalID = LocalComposerCatalog.match(piece.composerText)?.id
        piece.coreStructureData = try JSONEncoder().encode(structure)
        context.insert(piece)
        do { try context.save() } catch { context.rollback(); throw error }
        return piece
    }

    static func updateComposer(piece: PracticeSong, text: String, context: ModelContext,
                               at date: Date = .now) throws {
        let oldText = piece.composerText, oldID = piece.composerCanonicalID, oldDate = piece.updatedAt
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        piece.composerText = trimmed.isEmpty ? nil : text
        piece.composerCanonicalID = LocalComposerCatalog.match(piece.composerText)?.id
        piece.updatedAt = date
        do { try context.save() }
        catch {
            piece.composerText = oldText
            piece.composerCanonicalID = oldID
            piece.updatedAt = oldDate
            throw error
        }
    }

    static func saveGoal(piece: UUID, division: PracticeEvent, goal: CoreGoal,
                         context: ModelContext, activeSessionID: UUID?, at date: Date = .now,
                         isPro: Bool = false, timing: CoreGoalEditTiming? = nil,
                         analyzeTiming: CoreAnalyzeTiming? = nil, adjustedStartHands: Set<PracticeHand> = [],
                         calendar: Calendar = .current, saveChanges: Bool = true, globalActivation: Bool = false) throws -> CorePage {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard division.songID == piece, var definition = division.coreDefinition else { throw CoreIntegrationError.wrongDestination }
        var value = goal
        for hand in definition.handMode.hands {
            value.hands[hand]?.ladderParticipation = definition.goal?.hands[hand]?.ladderParticipation
            value.hands[hand]?.ladderConfigurationConfirmed = definition.goal?.hands[hand]?.ladderConfigurationConfirmed
        }
        for (hand, historical) in definition.goal?.hands ?? [:] where !definition.handMode.hands.contains(hand) {
            value.hands[hand] = historical
        }
        value.reset = value.reset ?? definition.goal?.reset ?? CoreResetConfiguration(anchor: calendar.startOfDay(for: date))
        try validateGoalAccess(value, previous: definition.goal, isPro: isPro)
        let previous = definition.goal
        let structureChanged = previous.map { $0.hands != value.hands || (!globalActivation && ($0.ladderEnabled == true) != (value.ladderEnabled == true)) } ?? false
        if structureChanged && previous != nil && timing == nil {
            throw CoreFlowError.invalidInput("请选择本周期生效或下周期生效。")
        }
        let targetsChanged = definition.handMode.hands.contains {
            previous?.hands[$0]?.count != value.hands[$0]?.count || previous?.hands[$0]?.speed != value.hands[$0]?.speed
        }
        if timing == .next && targetsChanged && analyzeTiming == nil {
            throw CoreFlowError.invalidInput("请选择分析标准立即切换或跟随下周期切换。")
        }
        for hand in definition.handMode.hands where value.ladderEnabled == true {
            guard var ladder = value.hands[hand]?.ladder else { continue }
            ladder.retainsLockedOrigin = nil
            let state = definition.ladderStates?[hand]
            let wasParticipating = previous?.ladderEnabled == true && previous?.hands[hand]?.ladder != nil
            if timing != .next, wasParticipating, let state, state.startLocked {
                let expected = Int((Double(state.cycleStartBPM) * state.noteUnit.quarterMultiplier / ladder.noteUnit.quarterMultiplier).rounded())
                guard ladder.startBPM == expected else { throw CoreFlowError.invalidInput("\(hand.title)：本周期起始 BPM 已锁定。") }
                if let target = value.hands[hand]?.speed, target.bpm <= expected {
                    ladder.retainsLockedOrigin = true
                }
            }
            value.hands[hand]?.ladder = ladder
            if timing == .next, let state, let previousBPM = state.previousValidBPM {
                let ceiling = Int((Double(previousBPM) * (state.previousNoteUnit ?? state.noteUnit).quarterMultiplier / ladder.noteUnit.quarterMultiplier).rounded())
                let target = value.hands[hand]?.speed?.bpm
                guard ladder.startBPM <= min(300, target ?? ceiling) else {
                    throw CoreFlowError.invalidInput("\(hand.title)：下周期起始 BPM 超出允许范围。")
                }
                if let target, let suggested = state.suggestedStart(in: ladder.noteUnit), suggested > target,
                   !adjustedStartHands.contains(hand) {
                    throw CoreFlowError.invalidInput("\(hand.title)：请先决定是否调整建议起始速度，并确认真实起始速度。")
                }
            }
            // Inactive per-hand facts remain untouched; edits never manufacture records.
        }
        guard value.isValid(for: definition.handMode) else { throw CoreIntegrationError.invalidGoal }
        // Preserve disabled configurations so Off never destroys saved configuration evidence.
        if value.ladderEnabled != true {
            for (hand, old) in previous?.hands ?? [:] where value.hands[hand] != nil {
                value.hands[hand]?.ladder = old.ladder
            }
        }
        if var reset = value.reset {
            let old = previous?.reset ?? CoreResetConfiguration()
            if previous == nil && reset.enabled && reset.anchor == nil { reset.anchor = calendar.startOfDay(for: date) }
            if reset.enabled && !old.enabled {
                reset.anchor = calendar.startOfDay(for: date)
                reset.pendingDays = nil; reset.pendingEffectiveAt = nil
            } else if reset.enabled && old.enabled && reset.days != old.days {
                reset.pendingDays = reset.days
                reset.days = old.days; reset.anchor = old.anchor
                reset.pendingEffectiveAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            }
            if !reset.enabled { reset.pendingDays = nil; reset.pendingEffectiveAt = nil }
            value.reset = reset
        }
        // Keep legacy date evidence outside the current Goal; no inferred Piece date migration.
        if definition.legacyGoalData == nil, let data = division.coreDefinitionData,
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oldGoal = json["goal"] as? [String: Any], oldGoal["targetDate"] != nil {
            definition.legacyGoalData = try JSONSerialization.data(withJSONObject: oldGoal, options: [.sortedKeys])
        }
        value.updatedAt = date
        if timing == .next && structureChanged {
            // Reset edits have their own next-midnight schedule, independent of Goal timing.
            definition.goal?.reset = value.reset
            definition.nextCycleGoal = value
            definition.nextCycleAnalyzeTiming = analyzeTiming
            definition.nextCycleAdjustedStartHands = adjustedStartHands
        } else {
            // Re-enabling begins a new user-confirmed origin, without backfilling Off records.
            for hand in definition.handMode.hands where value.ladderEnabled == true {
                if !globalActivation, let config = value.hands[hand]?.ladder,
                   previous?.ladderEnabled != true || previous?.hands[hand]?.ladder == nil {
                    let old = definition.ladderStates?[hand]
                    definition.ladderStates?[hand] = CoreLadderState(
                        cycleStart: old?.cycleStart ?? calendar.startOfDay(for: date),
                        cycleStartBPM: config.startBPM, currentBPM: config.startBPM, repsCompleted: 0,
                        noteUnit: config.noteUnit, previousValidBPM: old?.previousValidBPM,
                        previousNoteUnit: old?.previousNoteUnit ?? old?.noteUnit)
                }
            }
            definition.goal = value
            definition.nextCycleGoal = nil
            definition.nextCycleAnalyzeTiming = nil
            definition.nextCycleAdjustedStartHands = nil
        }
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        division.updatedAt = date
        if saveChanges { do { try context.save() } catch { context.rollback(); throw error } }
        return .piece(piece)
    }

    static func copyLeftLadderToRight(in goal: CoreGoal, mode: CoreHandMode) throws -> CoreGoal {
        guard mode.hands.contains(.left), mode.hands.contains(.right), goal.ladderEnabled == true,
              let left = goal.hands[.left], let ladder = left.ladder, ladder.isValid(target: left.speed) else {
            throw CoreFlowError.invalidInput("复制要求左右手均适用，且左手阶梯配置合法。")
        }
        var result = goal
        if result.hands[.right] == nil { result.hands[.right] = CoreHandGoal() }
        result.hands[.right]?.ladder = ladder
        result.hands[.right]?.speed = left.speed
        return result
    }

    static func validateGoalAccess(_ goal: CoreGoal, previous: CoreGoal?, isPro: Bool) throws {
        guard !isPro else { return }
        let advancedChanged = (goal.ladderEnabled == true) != (previous?.ladderEnabled == true)
            || goal.hands.contains { $0.value.ladder != previous?.hands[$0.key]?.ladder }
        guard !advancedChanged else { throw CoreFlowError.invalidInput("速度阶梯配置需要 Pro。") }
        if let reset = goal.reset, reset.enabled, reset.days != 1,
           reset != previous?.reset {
            throw CoreFlowError.invalidInput("Free 周期重置仅支持 1 天。")
        }
    }

    static func validateDivision(_ definition: CoreDivisionDefinition, structure: CorePieceStructure,
                                 existing: [CoreDivisionDefinition]) throws {
        guard definition.fits(structure) else { throw CoreIntegrationError.invalidRange }
        guard !existing.contains(where: { $0.first <= definition.last && definition.first <= $0.last }) else {
            throw CoreIntegrationError.overlappingRange
        }
    }

    // Explicit, atomic Division + optional Basic Goal commit; UI 04 returns Piece Detail.
    static func saveCreatedDivision(piece: PracticeSong, definition: CoreDivisionDefinition,
                                    context: ModelContext, activeSessionID: UUID?, isPro: Bool = false, activation: CoreLadderActivation = CoreLadderActivation()) throws -> CorePage {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard let structure = piece.coreStructure else { throw CoreIntegrationError.missingMetadata }
        let pieceID = piece.id
        let existing = try context.fetch(FetchDescriptor<PracticeEvent>(predicate: #Predicate { $0.songID == pieceID }))
        guard existing.allSatisfy({ $0.coreDefinition != nil }) else { throw CoreIntegrationError.missingMetadata }
        try validateDivision(definition, structure: structure, existing: existing.compactMap(\.coreDefinition))
        var value = definition
        if var goal = value.goal {
            try validateGoalAccess(goal, previous: nil, isPro: isPro)
            for hand in goal.hands.keys { goal.hands[hand]?.ladder?.retainsLockedOrigin = nil }
            goal.reset = goal.reset ?? CoreResetConfiguration()
            if goal.reset?.enabled == true && goal.reset?.anchor == nil { goal.reset?.anchor = Calendar.current.startOfDay(for: .now) }
            guard goal.isValid(for: value.handMode) else { throw CoreIntegrationError.invalidGoal }
            goal.updatedAt = .now
            value.goal = goal
        }
        if activation.enabled {
            value.ladderConfigurationEpochs = Dictionary(uniqueKeysWithValues: value.handMode.hands.compactMap { hand in
                value.goal?.hands[hand]?.ladder == nil ? nil : (hand, activation.epoch)
            })
        }
        let event = PracticeEvent(songID: piece.id, name: value.label(mode: structure.mode))
        event.coreDefinitionData = try JSONEncoder().encode(value)
        context.insert(event)
        do { try context.save() } catch { context.delete(event); throw error }
        return .piece(piece.id)
    }
    
    static func saveEditedDivision(
        piece: PracticeSong,
        division: PracticeEvent,
        definition: CoreDivisionDefinition,
        context: ModelContext,
        activeSessionID: UUID?,
        saveChanges: Bool = true
    ) throws -> CorePage {
        guard activeSessionID == nil else {
            throw CoreIntegrationError.activeSession
        }

        guard let structure = piece.coreStructure else {
            throw CoreIntegrationError.missingMetadata
        }

        let pieceID = piece.id

        let existing = try context.fetch(
            FetchDescriptor<PracticeEvent>(
                predicate: #Predicate { $0.songID == pieceID }
            )
        )

        guard existing.allSatisfy({ $0.coreDefinition != nil }) else {
            throw CoreIntegrationError.missingMetadata
        }

        let otherDefinitions = existing
            .filter { $0.id != division.id }
            .compactMap(\.coreDefinition)

        try validateDivision(
            definition,
            structure: structure,
            existing: otherDefinitions
        )

        division.name = definition.label(mode: structure.mode)
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        division.updatedAt = .now

        do {
            if saveChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }

        return .piece(piece.id)
    }

    // One transaction for the shared editor; existing Goal timing/lock rules remain authoritative.
    static func saveDivisionAndGoal(piece: PracticeSong, division: PracticeEvent,
        first: Int, last: Int, handMode: CoreHandMode, editedGoal: CoreGoal?,
        context: ModelContext, activeSessionID: UUID?, isPro: Bool = false,
        timing: CoreGoalEditTiming? = nil, analyzeTiming: CoreAnalyzeTiming? = nil,
        adjustedStartHands: Set<PracticeHand> = [],
        activation: CoreLadderActivation = CoreLadderActivation(),
        confirmedHands: Set<PracticeHand> = [], saving: (() throws -> Void)? = nil) throws -> CorePage {
        guard activeSessionID == nil else { throw CoreIntegrationError.activeSession }
        guard division.songID == piece.id, var definition = division.coreDefinition else {
            throw CoreIntegrationError.wrongDestination
        }
        definition.first = first; definition.last = last; definition.handMode = handMode
        do {
            _ = try saveEditedDivision(piece: piece, division: division, definition: definition,
                context: context, activeSessionID: nil, saveChanges: false)
            if let editedGoal {
                _ = try saveGoal(piece: piece.id, division: division, goal: editedGoal, context: context,
                    activeSessionID: nil, isPro: isPro, timing: timing, analyzeTiming: analyzeTiming,
                    adjustedStartHands: adjustedStartHands, saveChanges: false, globalActivation: true)
            }
            if !confirmedHands.isEmpty || (editedGoal != nil && activation.enabled) {
                guard var updated = division.coreDefinition else { throw CoreIntegrationError.missingMetadata }
                for hand in confirmedHands {
                    guard isPro, activation.enabled, handMode.hands.contains(hand),
                          let value = updated.goal?.hands[hand], value.needsLadderConfirmation,
                          value.ladder?.isValid(target: value.speed) == true else {
                        throw CoreFlowError.invalidInput("\(hand.title)：请检查待确认的速度阶梯配置。")
                    }
                    updated.goal?.hands[hand]?.ladderConfigurationConfirmed = true
                    updated.nextCycleGoal?.hands[hand]?.ladderConfigurationConfirmed = true
                    if updated.ladderRestartRequired == nil { updated.ladderRestartRequired = [] }
                    updated.ladderRestartRequired?.insert(hand)
                }
                if activation.enabled, let editedGoal {
                    for hand in handMode.hands where editedGoal.hands[hand]?.ladder != nil {
                        if updated.ladderConfigurationEpochs == nil { updated.ladderConfigurationEpochs = [:] }
                        // Never relabel an old execution rung as the new activation.
                        if definition.goal?.hands[hand]?.ladder == nil {
                            updated.ladderConfigurationEpochs?[hand] = activation.epoch
                        }
                    }
                }
                division.coreDefinitionData = try JSONEncoder().encode(updated)
            }
            try (saving ?? { try context.save() })()
            return .piece(piece.id)
        } catch { context.rollback(); throw error }
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
        return .piece(piece)
    }
}

/// Inbound/outbound navigation contract shared by the three accepted screens.
/// Target UIs remain external; only a matching successful return changes the stack.
@MainActor
final class CoreNavigation: ObservableObject {
    @Published var path: [CorePage] = []
    @Published private(set) var pendingRoute: CoreRoute?
    private(set) var editorSource: CorePage?
    private(set) var practiceSource: CorePage?

    func request(_ route: CoreRoute) {
        if case .editDivision(let piece, let division) = route, pendingRoute != route {
            editorSource = sourcePage(piece: piece, division: division)
        }
        pendingRoute = route
    }
    func cancel() { pendingRoute = nil }

    private func sourcePage(piece: UUID, division: UUID) -> CorePage {
        let detail = CorePage.division(piece: piece, division: division)
        return path.last == detail ? detail : .piece(piece)
    }

    func enteredPractice(piece: UUID, division: UUID) {
        practiceSource = sourcePage(piece: piece, division: division)
        path = []
        cancel()
    }

    func returnedBeforePlayback(piece: UUID) {
        returnTo(practiceSource ?? .piece(piece))
        practiceSource = nil
        cancel()
    }

    func editorSaved(_ page: CorePage) {
        if case .editDivision = pendingRoute, let editorSource { returnTo(editorSource) }
        else { returnTo(page) }
        editorSource = nil
        cancel()
    }

    private func returnTo(_ page: CorePage) {
        if case .division(let piece, _) = page { path = [.piece(piece), page] }
        else { path = [page] }
    }

    func createdDivisionSaved(piece: PracticeSong, division: PracticeEvent) throws {
        guard case .createDivision(let pieceID, let mode) = pendingRoute,
              piece.id == pieceID, piece.coreStructure?.mode == mode,
              division.songID == pieceID,
              let structure = piece.coreStructure, let definition = division.coreDefinition,
              definition.fits(structure), (definition.goal == nil || definition.hasValidGoal) else {
            throw CoreIntegrationError.wrongDestination
        }
        path = [.piece(pieceID)]
        pendingRoute = nil
    }

    func goalSaved(piece: UUID, division: PracticeEvent) throws {
        guard pendingRoute == .editDivision(piece: piece, division: division.id) else {
            throw CoreIntegrationError.wrongDestination
        }
        let destination = try CoreContracts.goalSavedReturn(piece: piece, division: division)
        editorSaved(destination)
    }
}
