import XCTest
import SwiftData
import SwiftUI
import UIKit
@testable import GeoPractice

@MainActor
final class PracticeCoreTests: XCTestCase {
    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([PracticeSong.self, PracticeEvent.self, PracticeAttempt.self, PracticeDailyGoal.self, PracticeFolder.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    func testGoalValidityUsesEveryApplicableHandAndNotDate() {
        let count = CoreHandGoal(count: 3)
        let speed = CoreHandGoal(speed: CoreTargetSpeed(bpm: 80, noteUnit: .quarter))
        XCTAssertTrue(CoreGoal(hands: [.left: count]).isValid(for: .left))
        XCTAssertFalse(CoreGoal(hands: [.left: count, .right: speed]).isValid(for: .all))
        XCTAssertTrue(CoreGoal(hands: [.left: count, .right: speed, .both: count]).isValid(for: .all))
        XCTAssertFalse(CoreGoal(hands: [.right: CoreHandGoal()]).isValid(for: .right))
        XCTAssertFalse(CoreHandGoal(count: 0).isValid)
        XCTAssertEqual(CoreTargetSpeed(bpm: 160, noteUnit: .eighth).quarterEquivalent, 80)
        XCTAssertEqual(CoreNoteUnit.allCases.count, 8)
    }

    func testHomeRecoveryWinsAndNoGoalNeverCreatesContinue() {
        let recovery = CoreRecovery(sessionID: UUID(), divisionID: UUID(), pieceName: "A", divisionName: "B")
        XCTAssertEqual(CoreHomeState.resolve(pieceCount: 0, recovery: recovery), .recovery(recovery))
        XCTAssertEqual(CoreHomeState.resolve(pieceCount: 2, recovery: nil), .normal)
        XCTAssertEqual(CoreHomeState.resolve(pieceCount: 0, recovery: nil), .empty)
    }

    func testCreatePersistsRangeInheritsModeAndDoesNotCreateGoalOrSession() throws {
        let container = try container()
        let context = container.mainContext
        let piece = PracticeSong(name: "A")
        piece.coreStructureData = try JSONEncoder().encode(CorePieceStructure(mode: .measures, total: 48))
        context.insert(piece)
        try context.save()
        let definition = CoreDivisionDefinition(first: 12, last: 18, handMode: .right)
        let page = try CoreContracts.saveCreatedDivision(piece: piece, definition: definition, context: context, activeSessionID: nil)
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
        XCTAssertEqual(page, .piece(piece.id))
        XCTAssertEqual(saved.name, "第 12–18 小节")
        XCTAssertNil(saved.coreDefinition?.goal)
        XCTAssertNil(saved.goalPlan)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece, definition: definition, context: context, activeSessionID: nil))
        XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 49, last: 50, handMode: .right), context: context, activeSessionID: nil))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeEvent>()), 1)
    }

    func testLegacyMetadataNeverInferredOrAutoArchived() throws {
        let container = try container()
        let piece = PracticeSong(name: "第 3–8 小节", endDate: .distantPast)
        container.mainContext.insert(piece)
        try container.mainContext.save()
        XCTAssertNil(piece.coreStructure)
        XCTAssertFalse(piece.isArchived)
        XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 3, last: 8, handMode: .all), context: container.mainContext, activeSessionID: nil))
    }

    func testStartAndEditorReturnContractsPreserveIdentity() throws {
        let piece = UUID(), division = UUID()
        var definition = CoreDivisionDefinition(first: 1, last: 1, handMode: .left)
        XCTAssertThrowsError(try CoreContracts.startRoute(piece: piece, division: division, definition: definition, activeSessionID: nil))
        definition.goal = CoreGoal(hands: [.left: CoreHandGoal(count: 2)])
        XCTAssertEqual(try CoreContracts.startRoute(piece: piece, division: division, definition: definition, activeSessionID: nil), .startPractice(piece: piece, division: division))
        XCTAssertThrowsError(try CoreContracts.startRoute(piece: piece, division: division, definition: definition, activeSessionID: UUID()))
        let event = PracticeEvent(id: division, songID: piece, name: "A")
        event.coreDefinitionData = try JSONEncoder().encode(definition)
        XCTAssertEqual(try CoreContracts.goalSavedReturn(piece: piece, division: event), .piece(piece))
        XCTAssertThrowsError(try CoreContracts.goalSavedReturn(piece: UUID(), division: event))
        XCTAssertNotEqual(CoreRoute.analyze(.piece(piece)), .analyze(.division(piece: piece, division: division)))
    }

    func testRecoveryReadsSameSessionWithoutRewritingDraft() throws {
        let suite = "PracticeCoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let song = PracticeSong(name: "A"), event = PracticeEvent(name: "B")
        event.songID = song.id
        let controller = PracticeSessionController(defaults: defaults)
        controller.begin(sourceEventID: event.id, preset: .standard)
        controller.recordCompletion(for: .both, preset: .standard)
        controller.persistSnapshot()
        let before = defaults.data(forKey: "practiceSessionDraft.v1")
        let result = CoreDependencies.readRecovery(songs: [song], events: [event], defaults: defaults)
        XCTAssertNil(result.gap)
        XCTAssertEqual(result.recovery?.sessionID, controller.session.sessionID)
        XCTAssertEqual(result.recovery?.divisionID, event.id)
        XCTAssertEqual(before, defaults.data(forKey: "practiceSessionDraft.v1"))
    }

    func testDeferredLegacyRecoveryPreservesBytesSurvivesReloadAndAllowsNewSession() throws {
        let suite = "CoreDeferredRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = try container(), context = db.mainContext
        let song = PracticeSong(name: "帕格尼尼"), event = PracticeEvent(name: "引子")
        event.songID = song.id
        context.insert(song); context.insert(event); try context.save()
        let controller = PracticeSessionController(defaults: defaults)
        controller.begin(sourceEventID: event.id, preset: .standard)
        controller.recordCompletion(for: .both, preset: .standard)
        controller.persistSnapshot()
        let original = try XCTUnwrap(defaults.data(forKey: CoreDependencies.legacyDraftKey))
        XCTAssertNotNil(CoreDependencies.readRecovery(songs: [song], events: [event], defaults: defaults).recovery)
        CoreDependencies.deferLegacyRecovery(defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let result = CoreDependencies.readRecovery(songs: [song], events: [event], defaults: reopened)
        XCTAssertNil(result.recovery); XCTAssertNil(result.gap)
        XCTAssertEqual(CoreHomeState.resolve(pieceCount: 1, recovery: result.recovery), .normal)
        XCTAssertEqual(reopened.data(forKey: CoreDependencies.legacyDraftKey), original)
        let piece = try CoreContracts.savePiece(name: "新测试曲目", structure: CorePieceStructure(mode: .measures, total: 8), context: context, activeSessionID: result.recovery?.sessionID)
        _ = try CoreContracts.saveCreatedDivision(piece: piece, definition: CoreDivisionDefinition(first: 1, last: 8, handMode: .left), context: context, activeSessionID: nil)
        let division = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first { $0.songID == piece.id })
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: CoreGoal(hands: [.left: CoreHandGoal(count: 3)]), context: context, activeSessionID: nil, timing: .current)
        let runtime = CoreSessionRuntime(defaults: reopened)
        try runtime.begin(piece: piece, division: division, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true)
        runtime.record(preset: .standard)
        XCTAssertNotNil(CoreSessionRuntime(defaults: reopened).activeID, "Deferral must not suppress new valid recovery")
        XCTAssertEqual(reopened.data(forKey: CoreDependencies.legacyDraftKey), original)
        // A later change to the old draft requires a new explicit decision.
        controller.recordCompletion(for: .both, preset: .standard)
        controller.persistSnapshot()
        XCTAssertNotNil(CoreDependencies.readRecovery(songs: [song], events: [event], defaults: reopened).recovery)
    }

    func testUnreadableLegacyDraftCanBeDeferredWithoutDeletingIt() throws {
        let suite = "CoreDeferredRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("legacy unreadable payload".utf8)
        defaults.set(bytes, forKey: CoreDependencies.legacyDraftKey)
        XCTAssertNotNil(CoreDependencies.readRecovery(songs: [], events: [], defaults: defaults).gap)
        CoreDependencies.deferLegacyRecovery(defaults: defaults)
        XCTAssertNil(CoreDependencies.readRecovery(songs: [], events: [], defaults: defaults).gap)
        XCTAssertEqual(defaults.data(forKey: CoreDependencies.legacyDraftKey), bytes)
    }

    func testMetadataSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let id: UUID
        do {
            let db = try container(url: url)
            let piece = PracticeSong(name: "A")
            id = piece.id
            piece.coreStructureData = try JSONEncoder().encode(CorePieceStructure(mode: .sections, total: nil))
            db.mainContext.insert(piece)
            _ = try CoreContracts.saveCreatedDivision(piece: piece,
                definition: CoreDivisionDefinition(first: 1, last: 2, handMode: .left), context: db.mainContext, activeSessionID: nil)
        }
        let reopened = try container(url: url)
        let piece = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
        XCTAssertEqual(piece.id, id)
        XCTAssertEqual(piece.coreStructure?.mode, .sections)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<PracticeEvent>()).first?.coreDefinition?.handMode, .left)
    }
    func testCreateAndGoalCompletionActuallyUpdateNavigationStack() throws {
        let container = try container()
        let piece = PracticeSong(name: "A")
        piece.coreStructureData = try JSONEncoder().encode(CorePieceStructure(mode: .sections, total: 6))
        container.mainContext.insert(piece)
        let nav = CoreNavigation()
        nav.path = [.piece(piece.id)]
        nav.request(.createDivision(piece: piece.id, mode: .sections))
        _ = try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 3, last: 3, handMode: .right),
            context: container.mainContext, activeSessionID: nil)
        let event = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<PracticeEvent>()).first)
        try nav.createdDivisionSaved(piece: piece, division: event)
        XCTAssertEqual(nav.path, [.piece(piece.id)])
        XCTAssertNil(nav.pendingRoute)
        XCTAssertFalse(try XCTUnwrap(event.coreDefinition).hasValidGoal)
        nav.request(.editDivision(piece: piece.id, division: event.id))
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.goal = CoreGoal(hands: [.right: CoreHandGoal(count: 10)])
        event.coreDefinitionData = try JSONEncoder().encode(definition)
        try container.mainContext.save()
        try nav.goalSaved(piece: piece.id, division: event)
        XCTAssertTrue(try XCTUnwrap(event.coreDefinition).hasValidGoal)
        XCTAssertEqual(nav.path, [.piece(piece.id)]) // one workspace, no intermediate page
        XCTAssertNil(nav.pendingRoute)
        XCTAssertThrowsError(try nav.goalSaved(piece: piece.id, division: event))
        nav.request(.analyze(.division(piece: piece.id, division: event.id)))
        let previousPath = nav.path
        nav.cancel()
        XCTAssertEqual(nav.path, previousPath)
    }

    func testBackupRoundTripPreservesExplicitMetadata() throws {
        let db = try container()
        let piece = PracticeSong(name: "A", endDate: .distantFuture)
        piece.coreStructureData = try JSONEncoder().encode(CorePieceStructure(mode: .measures, total: 48))
        let event = PracticeEvent(songID: piece.id, name: "第 1 小节")
        event.coreDefinitionData = try JSONEncoder().encode(CoreDivisionDefinition(first: 1, last: 1, handMode: .left))
        db.mainContext.insert(piece)
        db.mainContext.insert(event)
        try db.mainContext.save()
        let store = try PracticeLibraryStore(modelContext: db.mainContext)
        let data = try store.makeBackupData()
        let restored = try container()
        let restoredStore = try PracticeLibraryStore(modelContext: restored.mainContext)
        try restoredStore.restoreBackup(from: data)
        // Restore uses its own context; read a fresh context to avoid stale cache.
        let context = ModelContext(restored)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PracticeSong>()).first?.coreStructureData, piece.coreStructureData)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PracticeEvent>()).first?.coreDefinitionData, event.coreDefinitionData)
    }

    func testCreationAllowsParagraphAndMeasureRangesWithUnassignedGaps() throws {
        for mode in CoreDivisionMode.allCases {
            let db = try container(), context = db.mainContext
            let piece = try CoreContracts.savePiece(name: "Range", structure: CorePieceStructure(mode: mode, total: 14),
                                                    context: context, activeSessionID: nil)
            for (first, last) in [(2, 3), (7, 10)] {
                let page = try CoreContracts.saveCreatedDivision(piece: piece,
                    definition: CoreDivisionDefinition(first: first, last: last, handMode: .both),
                    context: context, activeSessionID: nil)
                XCTAssertEqual(page, .piece(piece.id))
            }
            let events = try context.fetch(FetchDescriptor<PracticeEvent>())
            XCTAssertEqual(events.count, 2)
            XCTAssertTrue(events.contains { $0.name == "第 2–3 \(mode.unit)" })
            XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece,
                definition: CoreDivisionDefinition(first: 3, last: 6, handMode: .both),
                context: context, activeSessionID: nil))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeEvent>()), 2)
        }
    }

    func testCreationWithOptionalBasicGoalForEveryModeReturnsPieceAndNeverStartsSession() throws {
        for mode in CoreHandMode.allCases {
            for withGoal in [false, true] {
                let db = try container(), context = db.mainContext
                let piece = try CoreContracts.savePiece(name: "Create", structure: CorePieceStructure(mode: .sections, total: 14),
                                                        context: context, activeSessionID: nil)
                let goal = withGoal ? CoreGoal(hands: Dictionary(uniqueKeysWithValues: mode.hands.map {
                    ($0, CoreHandGoal(count: 5, speed: CoreTargetSpeed(bpm: 160, noteUnit: .eighth)))
                })) : nil
                let nav = CoreNavigation(); nav.request(.createDivision(piece: piece.id, mode: .sections))
                let storage = UserDefaults(suiteName: "CoreCreate.\(UUID())")!
                let runtime = CoreSessionRuntime(defaults: storage)
                let page = try CoreContracts.saveCreatedDivision(piece: piece,
                    definition: CoreDivisionDefinition(first: 2, last: 3, handMode: mode, goal: goal),
                    context: context, activeSessionID: runtime.activeID)
                let event = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
                XCTAssertEqual(page, .piece(piece.id))
                XCTAssertEqual(event.coreDefinition?.handMode, mode)
                XCTAssertEqual(event.coreDefinition?.goal?.hands, goal?.hands)
                XCTAssertEqual(event.coreDefinition?.hasValidGoal, withGoal)
                XCTAssertNil(runtime.activeID)
                XCTAssertNil(storage.data(forKey: CoreSessionRuntime.draftKey))
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
                try nav.createdDivisionSaved(piece: piece, division: event)
                XCTAssertEqual(nav.path, [.piece(piece.id)])
                XCTAssertNil(nav.pendingRoute)
            }
        }
    }

    func testInvalidOptionalGoalDoesNotPartiallyCreateDivision() throws {
        let db = try container(), context = db.mainContext
        let piece = try CoreContracts.savePiece(name: "Atomic", structure: CorePieceStructure(mode: .sections, total: 14),
                                                context: context, activeSessionID: nil)
        let incomplete = CoreGoal(hands: [.left: CoreHandGoal(count: 5)])
        XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 2, last: 3, handMode: .all, goal: incomplete),
            context: context, activeSessionID: nil))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeEvent>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testSetThenEditBasicGoalReturnsDivisionAndPreservesHandScope() throws {
        for mode in CoreHandMode.allCases {
            let db = try container(), context = db.mainContext
            let piece = try CoreContracts.savePiece(name: "Edit", structure: CorePieceStructure(mode: .measures, total: 32),
                                                    context: context, activeSessionID: nil)
            _ = try CoreContracts.saveCreatedDivision(piece: piece,
                definition: CoreDivisionDefinition(first: 21, last: 32, handMode: mode), context: context, activeSessionID: nil)
            let event = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
            XCTAssertNil(event.coreDefinition?.goal)
            for count in [5, 8] {
                let goal = CoreGoal(hands: Dictionary(uniqueKeysWithValues: mode.hands.map {
                    ($0, CoreHandGoal(count: count, speed: CoreTargetSpeed(bpm: count == 5 ? 100 : 160,
                                                                         noteUnit: count == 5 ? .quarter : .eighth)))
                }))
                let page = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal,
                                                      context: context, activeSessionID: nil, timing: .current)
                XCTAssertEqual(page, .piece(piece.id))
                XCTAssertEqual(event.coreDefinition?.handMode, mode)
                XCTAssertEqual(event.coreDefinition?.goal?.hands, goal.hands)
                let nav = CoreNavigation(); nav.request(.editDivision(piece: piece.id, division: event.id))
                try nav.goalSaved(piece: piece.id, division: event)
                XCTAssertEqual(nav.path, [page])
            }
        }
    }

    func testBasicGoalBPMBoundsAndBlankConditions() {
        for bpm in [20, 300] { XCTAssertTrue(CoreHandGoal(speed: CoreTargetSpeed(bpm: bpm)).isValid) }
        for bpm in [0, 19, 301] { XCTAssertFalse(CoreHandGoal(count: 5, speed: CoreTargetSpeed(bpm: bpm)).isValid) }
        XCTAssertTrue(CoreHandGoal(count: Int.max).isValid)
        XCTAssertFalse(CoreHandGoal().isValid)
        XCTAssertTrue(CoreGoal(hands: [.both: CoreHandGoal(count: 1)]).isValid(for: .both))
        XCTAssertFalse(CoreGoal(hands: [.both: CoreHandGoal(count: 1)]).isValid(for: .all))
    }

    func testGoalEditPreservesLegacyDateEvidenceOutsideCurrentGoalWithoutMigration() throws {
        let db = try container(), context = db.mainContext
        let piece = try CoreContracts.savePiece(name: "Legacy date", structure: CorePieceStructure(mode: .sections, total: 14),
                                                context: context, activeSessionID: nil)
        let originalPieceMetadata = piece.coreStructureData
        let definition = CoreDivisionDefinition(first: 2, last: 3, handMode: .both,
                                               goal: CoreGoal(hands: [.both: CoreHandGoal(count: 5)]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        var oldGoal = try XCTUnwrap(json["goal"] as? [String: Any]); oldGoal["targetDate"] = 123456.0
        json["goal"] = oldGoal
        let event = PracticeEvent(songID: piece.id, name: "第 2–3 段")
        event.coreDefinitionData = try JSONSerialization.data(withJSONObject: json)
        context.insert(event); try context.save()
        let goal = CoreGoal(hands: [.both: CoreHandGoal(count: 8)])
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal, context: context, activeSessionID: nil, timing: .current)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(event.coreDefinitionData)) as? [String: Any])
        XCTAssertNil((saved["goal"] as? [String: Any])?["targetDate"])
        let preserved = try XCTUnwrap(event.coreDefinition?.legacyGoalData)
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: preserved) as? [String: Any])
        XCTAssertEqual(old["targetDate"] as? Double, 123456.0)
        XCTAssertEqual(piece.coreStructureData, originalPieceMetadata)
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal, context: context, activeSessionID: nil, timing: .current)
        XCTAssertEqual(event.coreDefinition?.legacyGoalData, preserved)
    }

    // Node 2B: configuration persistence only; no simulated rung advancement.
    private func ladderGoal(_ mode: CoreHandMode = .both, target: Int? = nil, start: Int = 40,
                            step: Int = 3, reps: Int = 2) -> CoreGoal {
        CoreGoal(hands: Dictionary(uniqueKeysWithValues: mode.hands.map {
            ($0, CoreHandGoal(speed: target.map { CoreTargetSpeed(bpm: $0) },
                             ladder: CoreLadderConfiguration(startBPM: start, stepBPM: step, repsPerLevel: reps)))
        }), ladderEnabled: true, reset: CoreResetConfiguration())
    }
    private func ladderDivision(_ goal: CoreGoal, mode: CoreHandMode = .both) throws -> (ModelContainer, PracticeSong, PracticeEvent) {
        let db = try container(), context = db.mainContext
        let piece = try CoreContracts.savePiece(name: "Ladder", structure: CorePieceStructure(mode: .sections, total: 8), context: context, activeSessionID: nil)
        _ = try CoreContracts.saveCreatedDivision(piece: piece, definition: CoreDivisionDefinition(first: 2, last: 4, handMode: mode, goal: goal),
                                                   context: context, activeSessionID: nil, isPro: true)
        return (db, piece, try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first))
    }
    func testLadderAllFourModesPersistIndependentConfigurations() throws {
        for mode in CoreHandMode.allCases {
            var goal = ladderGoal(mode)
            for (index, hand) in mode.hands.enumerated() { goal.hands[hand]?.ladder?.startBPM = 40 + index * 10 }
            let (db, piece, event) = try ladderDivision(goal, mode: mode)
            XCTAssertEqual(event.coreDefinition?.goal?.hands, goal.hands)
            XCTAssertEqual(Set(event.coreDefinition?.goal?.hands.keys.map { $0 } ?? []), Set(mode.hands))
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
            var edited = goal; edited.hands[mode.hands[0]]?.ladder?.stepBPM = 4
            XCTAssertEqual(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: edited, context: db.mainContext,
                activeSessionID: nil, isPro: true, timing: .current), .piece(piece.id))
            XCTAssertEqual(event.coreDefinition?.goal?.hands, edited.hands)
        }
    }
    func testLadderFiniteFinalShortStepAndOpenEndedValidity() {
        let config = CoreLadderConfiguration(startBPM: 100, stepBPM: 3, repsPerLevel: 11)
        XCTAssertEqual(config.finiteLevels(target: CoreTargetSpeed(bpm: 108)), [100, 103, 106, 108])
        XCTAssertEqual(config.finiteLevels(target: CoreTargetSpeed(bpm: 109)), [100, 103, 106, 109])
        XCTAssertTrue(ladderGoal(target: 108, start: 100).isValid(for: .both))
        XCTAssertTrue(ladderGoal(target: 109, start: 100).isValid(for: .both))
        XCTAssertTrue(config.isValid(target: nil))
        XCTAssertTrue(ladderGoal(reps: Int.max).isValid(for: .both))
        XCTAssertFalse(ladderGoal(.left).isValid(for: .all))
        XCTAssertEqual(CoreLadderConfiguration(startBPM: 118, stepBPM: 5, repsPerLevel: 1).finiteLevels(target: CoreTargetSpeed(bpm: 120)), [118, 120])
        for step in 1...20 {
            let bounded = CoreLadderConfiguration(startBPM: 20, stepBPM: step, repsPerLevel: 1)
            for target in 21...300 {
                let speed = CoreTargetSpeed(bpm: target)
                XCTAssertTrue(bounded.isValid(target: speed))
                let levels = bounded.finiteLevels(target: speed)
                XCTAssertEqual(levels.first, 20); XCTAssertEqual(levels.last, target)
                XCTAssertTrue(levels.allSatisfy { $0 <= target })
                for (index, pair) in zip(levels, levels.dropFirst()).enumerated() {
                    let interval = pair.1 - pair.0
                    if index == levels.count - 2 { XCTAssertTrue((1...step).contains(interval)) }
                    else { XCTAssertEqual(interval, step) }
                }
            }
        }
        XCTAssertFalse(CoreLadderConfiguration(startBPM: 100, stepBPM: 0, repsPerLevel: 1).isValid(target: CoreTargetSpeed(bpm: 108)))
        XCTAssertFalse(config.isValid(target: CoreTargetSpeed(bpm: 108, noteUnit: .eighth)))
    }
    func testLadderInvalidRequiredFieldsBlockAtomicSave() throws {
        let db = try container(), context = db.mainContext
        let piece = try CoreContracts.savePiece(name: "Invalid", structure: CorePieceStructure(mode: .measures), context: context, activeSessionID: nil)
        let invalid = [ladderGoal(start: 19), ladderGoal(start: 301), ladderGoal(step: 0), ladderGoal(step: 21),
                       ladderGoal(reps: 0), ladderGoal(target: 40), ladderGoal(target: 39), ladderGoal(target: 301)]
        for goal in invalid {
            XCTAssertFalse(goal.isValid(for: .both))
            XCTAssertThrowsError(try CoreContracts.saveCreatedDivision(piece: piece,
                definition: CoreDivisionDefinition(first: 1, last: 2, handMode: .both, goal: goal), context: context, activeSessionID: nil, isPro: true))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeEvent>()), 0)
        XCTAssertFalse(context.hasChanges)
    }
    func testLadderOffKeepsSavedConfigurationButNotValidity() throws {
        let goal = ladderGoal(target: 80)
        let (db, piece, event) = try ladderDivision(goal)
        var off = goal; off.ladderEnabled = false; off.hands[.both]?.ladder = nil
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: off, context: db.mainContext, activeSessionID: nil, isPro: true, timing: .current)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.both]?.ladder, goal.hands[.both]?.ladder)
        var soleLadder = ladderGoal(); soleLadder.ladderEnabled = false
        XCTAssertFalse(soleLadder.isValid(for: .both))
        XCTAssertTrue(try XCTUnwrap(event.coreDefinition).hasValidGoal)
    }
    func testLadderFreeCannotCreateOrModifyProConfiguration() throws {
        let (db, piece, event) = try ladderDivision(ladderGoal())
        var edited = try XCTUnwrap(event.coreDefinition?.goal); edited.hands[.both]?.ladder?.stepBPM = 4
        let before = event.coreDefinitionData
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: edited, context: db.mainContext,
            activeSessionID: nil, timing: .current))
        XCTAssertEqual(event.coreDefinitionData, before)
        XCTAssertThrowsError(try CoreContracts.validateGoalAccess(ladderGoal(), previous: nil, isPro: false))
    }
    func testLadderCopyConfigurationDoesNotCopyCountsOrFacts() throws {
        var goal = ladderGoal(.all, target: 80)
        goal.hands[.left]?.count = 8; goal.hands[.right]?.count = 12
        goal.hands[.right]?.ladder?.stepBPM = 9
        let copied = try CoreContracts.copyLeftLadderToRight(in: goal, mode: .all)
        XCTAssertEqual(copied.hands[.left]?.ladder, copied.hands[.right]?.ladder)
        XCTAssertEqual(copied.hands[.right]?.count, 12)
        XCTAssertEqual(copied.hands[.both], goal.hands[.both])
        XCTAssertThrowsError(try CoreContracts.copyLeftLadderToRight(in: goal, mode: .both))
    }
    func testLadderCycleStartLocksOnlyAfterExplicitValidRecordFact() throws {
        let goal = ladderGoal(target: 100)
        let (db, piece, event) = try ladderDivision(goal)
        var definition = try XCTUnwrap(event.coreDefinition)
        let date = Date(timeIntervalSince1970: 1700000000)
        var state = CoreLadderState(cycleStart: date, cycleStartBPM: 40, currentBPM: 70, repsCompleted: 1, noteUnit: .quarter)
        definition.ladderStates = [.both: state]
        event.coreDefinitionData = try JSONEncoder().encode(definition); try db.mainContext.save()
        var changed = goal; changed.hands[.both]?.ladder?.startBPM = 42
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .current)
        state.cycleStartBPM = 42; state.firstValidRecordAt = date
        definition = try XCTUnwrap(event.coreDefinition); definition.ladderStates = [.both: state]
        event.coreDefinitionData = try JSONEncoder().encode(definition); try db.mainContext.save()
        changed.hands[.both]?.ladder?.startBPM = 44
        let before = event.coreDefinitionData
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .current))
        XCTAssertEqual(event.coreDefinitionData, before)
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .next)
        XCTAssertEqual(event.coreDefinition?.ladderStates?[.both], state)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.both]?.ladder?.startBPM, 42)
        XCTAssertEqual(event.coreDefinition?.nextCycleGoal?.hands[.both]?.ladder?.startBPM, 44)
    }
    func testLadderNextCycleRequiresIndependentAnalyzeDecision() throws {
        let (db, piece, event) = try ladderDivision(ladderGoal(target: 100))
        var changed = try XCTUnwrap(event.coreDefinition?.goal); changed.hands[.both]?.speed?.bpm = 108
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true))
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .next))
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .next, analyzeTiming: .immediately)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.both]?.speed?.bpm, 100)
        XCTAssertEqual(event.coreDefinition?.nextCycleGoal?.hands[.both]?.speed?.bpm, 108)
        XCTAssertEqual(event.coreDefinition?.nextCycleAnalyzeTiming, .immediately)
        let encoded = try JSONEncoder().encode(XCTUnwrap(event.coreDefinition))
        let decoded = try JSONDecoder().decode(CoreDivisionDefinition.self, from: encoded)
        XCTAssertEqual(decoded, event.coreDefinition)
    }
    func testLadderSuggestedStartConflictNeedsDecisionAndExplicitStart() throws {
        let (db, piece, event) = try ladderDivision(ladderGoal(target: 160))
        var definition = try XCTUnwrap(event.coreDefinition)
        let state = CoreLadderState(cycleStart: .now, cycleStartBPM: 40, currentBPM: 140, repsCompleted: 1,
            noteUnit: .quarter, firstValidRecordAt: .now, previousValidBPM: 140)
        XCTAssertEqual(state.suggestedStart(in: .quarter), 130)
        XCTAssertNil(CoreLadderState(cycleStart: .now, cycleStartBPM: 40, currentBPM: 40, repsCompleted: 0, noteUnit: .quarter).suggestedStart(in: .quarter))
        definition.ladderStates = [.both: state]
        event.coreDefinitionData = try JSONEncoder().encode(definition); try db.mainContext.save()
        let changed = ladderGoal(target: 108, start: 99)
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .next, analyzeTiming: .nextCycle))
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .next, analyzeTiming: .nextCycle, adjustedStartHands: [.both])
        XCTAssertEqual(event.coreDefinition?.nextCycleGoal?.hands[.both]?.ladder?.startBPM, 99)
        XCTAssertEqual(event.coreDefinition?.nextCycleAdjustedStartHands, [.both])
        let decoded = try JSONDecoder().decode(CoreDivisionDefinition.self, from: XCTUnwrap(event.coreDefinitionData))
        XCTAssertEqual(decoded.nextCycleAdjustedStartHands, [.both])
        XCTAssertEqual(event.coreDefinition?.ladderStates?[.both], state)
    }
    func testLadderLowerCurrentTargetPreservesLockedOriginAndHistory() throws {
        let (db, piece, event) = try ladderDivision(ladderGoal(target: 160, start: 100))
        var definition = try XCTUnwrap(event.coreDefinition)
        let state = CoreLadderState(cycleStart: .now, cycleStartBPM: 100, currentBPM: 140, repsCompleted: 1, noteUnit: .quarter, firstValidRecordAt: .now)
        definition.ladderStates = [.both: state]
        event.coreDefinitionData = try JSONEncoder().encode(definition); try db.mainContext.save()
        let changed = ladderGoal(target: 80, start: 100)
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: changed, context: db.mainContext,
            activeSessionID: nil, isPro: true, timing: .current)
        XCTAssertTrue(try XCTUnwrap(event.coreDefinition).hasValidGoal)
        XCTAssertEqual(event.coreDefinition?.ladderStates?[.both], state)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
    }
    func testLadderResetCadenceSchedulesNextMidnightAndKeepsFacts() throws {
        let (db, piece, event) = try ladderDivision(ladderGoal(target: 80))
        var goal = try XCTUnwrap(event.coreDefinition?.goal)
        XCTAssertTrue(try XCTUnwrap(goal.reset).enabled)
        XCTAssertEqual(CoreResetConfiguration.proDays, [1,3,5,7,14,30,60,90])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1700000000)
        goal.reset?.days = 30
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal, context: db.mainContext, activeSessionID: nil,
            at: date, isPro: true, calendar: calendar)
        let saved = try XCTUnwrap(event.coreDefinition?.goal?.reset)
        XCTAssertEqual(saved.days, 1); XCTAssertEqual(saved.pendingDays, 30)
        XCTAssertEqual(saved.pendingEffectiveAt, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)))
        XCTAssertEqual(event.coreDefinition?.goal?.hands, goal.hands)
        XCTAssertFalse(CoreResetConfiguration(days: 2).isValid)
    }
    func testLadderHistoryFixtureEditPreservesSavedSessionAndInactiveHands() throws {
        let db = try container(), context = db.mainContext
        _ = try CoreFixture.make("ladder-history", context: context)
        let piece = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeSong>()).first)
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
        let attempt = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeAttempt>()).first)
        let contextBytes = attempt.coreContextData, samples = attempt.completions
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.goal?.hands[.left] = CoreHandGoal(count: 11)
        event.coreDefinitionData = try JSONEncoder().encode(definition); try context.save()
        var edited = try XCTUnwrap(definition.goal)
        edited.hands.removeValue(forKey: .left)
        edited.hands[.both]?.ladder?.stepBPM = 4
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: edited, context: context,
            activeSessionID: nil, isPro: true, timing: .current)
        XCTAssertEqual(attempt.coreContextData, contextBytes); XCTAssertEqual(attempt.completions, samples)
        XCTAssertEqual(event.coreDefinition?.ladderStates, definition.ladderStates)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.left]?.count, 11)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
    }
    func testLadderNoteUnitConversionAndLegacyDecode() throws {
        let original = CoreLadderConfiguration(startBPM: 101, stepBPM: 3, repsPerLevel: 12, noteUnit: .quarter)
        let converted = original.converted(to: .dottedQuarter)
        XCTAssertEqual(converted.startBPM, 67); XCTAssertEqual(converted.stepBPM, 2)
        XCTAssertEqual(original.startBPM, 101)
        let encoded = try JSONEncoder().encode(CoreGoal(hands: [.both: CoreHandGoal(count: 5)]))
        let decoded = try JSONDecoder().decode(CoreGoal.self, from: encoded)
        XCTAssertNil(decoded.ladderEnabled); XCTAssertNil(decoded.reset)
        XCTAssertTrue(decoded.isValid(for: .both))
        let (db, piece, event) = try ladderDivision(decoded)
        var unchanged = try XCTUnwrap(event.coreDefinition?.goal)
        unchanged.ladderEnabled = false
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: unchanged, context: db.mainContext,
            activeSessionID: nil)
        XCTAssertTrue(try XCTUnwrap(event.coreDefinition).hasValidGoal)
    }

}

@MainActor
final class PracticeCoreE2ETests: XCTestCase {
    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([PracticeSong.self, PracticeEvent.self, PracticeAttempt.self, PracticeDailyGoal.self, PracticeFolder.self])
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }
    private func makeDivision(_ context: ModelContext, handMode: CoreHandMode = .all) throws -> (PracticeSong, PracticeEvent) {
        let piece = try CoreContracts.savePiece(name: "E2E 用户自建曲目",
            structure: CorePieceStructure(mode: .measures, total: 32), context: context, activeSessionID: nil)
        let page = try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 1, last: 8, handMode: handMode), context: context, activeSessionID: nil)
        XCTAssertEqual(page, .piece(piece.id))
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first { $0.songID == piece.id })
        let definition = try XCTUnwrap(event.coreDefinition)
        XCTAssertNil(definition.goal)
        let goal = CoreGoal(hands: Dictionary(uniqueKeysWithValues: handMode.hands.map {
            ($0, CoreHandGoal(count: 3, speed: CoreTargetSpeed(bpm: 100)))
        }))
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal,
            context: context, activeSessionID: nil, at: start.addingTimeInterval(-100), timing: .current)
        return (piece, event)
    }
    private func preset(_ bpm: Int, _ unit: TempoReferenceNote = .quarter) -> MetronomePreset {
        var preset = MetronomePreset.standard; preset.bpm = bpm; preset.referenceNote = unit; return preset
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CoreE2E.\(UUID())")! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var start: Date { Date(timeIntervalSince1970: 1_790_467_200) }

    func testFirstPlayPreservesLongTitleScrollPositionAcrossPracticeAppearances() async throws {
        for focus in [false, true] {
            for dark in [false, true] {
                for largeType in [false, true] {
                    let store = try container()
                    _ = try CoreFixture.make("long", context: store.mainContext)
                    let piece = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
                    let division = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<PracticeEvent>()).first)
                    let runtime = CoreSessionRuntime(defaults: defaults(), restore: false)
                    try runtime.begin(piece: piece, division: division, initialHand: .left,
                                      focusEnabled: focus)
                    let engine = MetronomeEngine()
                    let view = CoreSessionView(runtime: runtime, engine: engine, isGeoBeat: false,
                                               openGeoBeat: {}, finish: {})
                        .preferredColorScheme(dark ? .dark : .light)
                        .modelContainer(store)
                    let host = UIHostingController(rootView: view)
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
                    window.traitOverrides.preferredContentSizeCategory = largeType ? .accessibilityExtraExtraExtraLarge : .large
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    let scroll = try XCTUnwrap(firstScrollView(in: host.view))
                    let maxOffset = scroll.contentSize.height - scroll.bounds.height
                    if largeType { XCTAssertGreaterThan(maxOffset, 80) }
                    let before = maxOffset > 30 ? min(100, maxOffset - 10) : 0
                    scroll.setContentOffset(CGPoint(x: 0, y: before), animated: false)
                    XCTAssertTrue(try runtime.startPlayback { true })
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    XCTAssertTrue(firstScrollView(in: host.view) === scroll, "First play must keep ScrollView identity")
                    XCTAssertEqual(scroll.contentOffset.y, before, accuracy: 3,
                                   "First play must not recreate the \(focus ? "Focus" : "Normal") scroll view")
                    window.isHidden = true
                }
            }
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    func testRealCreateRecordSaveReopenAndAssociation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoreE2E.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try container(url: url), context = store.mainContext
        let (piece, event) = try makeDivision(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, calendar: calendar, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        let sessionID = runtime.activeID
        runtime.record(preset: preset(80), at: start.addingTimeInterval(10))
        runtime.record(preset: preset(160, .eighth), at: start.addingTimeInterval(20))
        runtime.record(preset: preset(120), at: start.addingTimeInterval(30))
        runtime.switchHand(.right, at: start.addingTimeInterval(40))
        runtime.record(preset: preset(90), at: start.addingTimeInterval(50))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        runtime.finish(at: start.addingTimeInterval(60))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0, "Review must not update derived analysis")
        let attempt = try runtime.save(division: event, in: context)
        XCTAssertEqual(attempt.sessionID, sessionID)
        XCTAssertEqual(attempt.coreContext?.pieceID, piece.id)
        XCTAssertEqual(attempt.eventID, event.id)
        XCTAssertEqual(attempt.completions.count, 4)
        XCTAssertNil(runtime.activeID)
        let reopened = try container(url: url)
        let history = CoreAnalysis.planned(try reopened.mainContext.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 80)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .right), 90)
        XCTAssertNil(CoreAnalysis.stable(history, hand: .both))
        XCTAssertEqual(CoreAnalysis.count(history, hand: .left, cycleStart: calendar.startOfDay(for: start)), 3)
        let goal = try XCTUnwrap(event.coreDefinition?.goal)
        XCTAssertEqual(try XCTUnwrap(CoreAnalysis.mastery(history, hand: .left, goal: goal, now: start, calendar: calendar)), 0.85, accuracy: 0.0001)
        XCTAssertNil(CoreAnalysis.divisionMastery(history, definition: try XCTUnwrap(event.coreDefinition)))
        let storedPiece = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
        XCTAssertEqual(storedPiece.coreStructure?.total, 32)
        let storedDivision = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<PracticeEvent>()).first)
        XCTAssertTrue(storedDivision.coreDefinition?.hasValidGoal == true)
    }

    func testRecoverSameSessionPauseClockAndSaveExactlyOnce() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context, handMode: .left)
        let defaults = defaults()
        let original = CoreSessionRuntime(defaults: defaults)
        try original.begin(piece: piece, division: event, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        original.synchronizePlayback(isPlaying: true, at: start)
        original.record(preset: preset(80), at: start.addingTimeInterval(10))
        let recovered = CoreSessionRuntime(defaults: defaults)
        XCTAssertEqual(recovered.activeID, original.activeID)
        XCTAssertTrue(recovered.needsRecovery)
        XCTAssertFalse(recovered.session.isRunning)
        XCTAssertEqual(recovered.session.stats(for: .left, at: start.addingTimeInterval(1000)).durationMilliseconds, 10_000)
        recovered.record(preset: preset(200), at: start.addingTimeInterval(1000))
        XCTAssertEqual(recovered.count, 1, "Paused records are rejected")
        recovered.resume(at: start.addingTimeInterval(1000))
        recovered.record(preset: preset(100), at: start.addingTimeInterval(1005))
        recovered.finish(at: start.addingTimeInterval(1010))
        let summary = try XCTUnwrap(recovered.session.reviewSummary)
        let metadata = try JSONEncoder().encode(XCTUnwrap(recovered.context))
        let saved = try recovered.save(division: event, in: context)
        XCTAssertEqual(saved.stats(for: .left).durationMilliseconds, 20_000)
        let replay = try event.commit(summary: summary, in: context, coreContextData: metadata)
        XCTAssertEqual(replay.attempt.id, saved.id)
        XCTAssertEqual(event.leftCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
        XCTAssertNil(defaults.data(forKey: CoreSessionRuntime.draftKey))
    }

    func testDailyCountGoalEditCrossMidnightAndUnpracticedHandCarry() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        let midnight = calendar.startOfDay(for: start).addingTimeInterval(86400)
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: midnight.addingTimeInterval(-10), calendar: calendar, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: midnight.addingTimeInterval(-10))
        runtime.record(preset: preset(80), at: midnight.addingTimeInterval(20))
        runtime.record(preset: preset(100), at: midnight.addingTimeInterval(30))
        runtime.finish(at: midnight.addingTimeInterval(40))
        _ = try runtime.save(division: event, in: context)
        var history = CoreAnalysis.planned(try context.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(CoreAnalysis.count(history, hand: .left, cycleStart: midnight.addingTimeInterval(-86400)), 2)
        XCTAssertEqual(CoreAnalysis.count(history, hand: .left, cycleStart: midnight), 0)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 90)
        let goal = try XCTUnwrap(event.coreDefinition?.goal)
        let prior = CoreAnalysis.mastery(history, hand: .left, goal: goal, now: midnight.addingTimeInterval(50), calendar: calendar)
        XCTAssertEqual(prior, CoreAnalysis.mastery(history, hand: .left, goal: goal, now: midnight.addingTimeInterval(86400), calendar: calendar))
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: midnight.addingTimeInterval(60), calendar: calendar, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: midnight.addingTimeInterval(60))
        runtime.switchHand(.right, at: midnight.addingTimeInterval(61))
        runtime.record(preset: preset(120), at: midnight.addingTimeInterval(62))
        runtime.finish(at: midnight.addingTimeInterval(63)); _ = try runtime.save(division: event, in: context)
        history = CoreAnalysis.planned(try context.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 90, "Latest session did not practice left hand")
        XCTAssertEqual(CoreAnalysis.mastery(history, hand: .left, goal: goal, now: midnight.addingTimeInterval(70), calendar: calendar), prior)
        var edited = goal; edited.hands[.right]?.count = 15; edited.updatedAt = midnight.addingTimeInterval(70)
        XCTAssertEqual(CoreAnalysis.count(history, hand: .right, cycleStart: midnight), 1)
        let current = CoreAnalysis.mastery(history, hand: .right, goal: edited, now: midnight.addingTimeInterval(71), calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(current), 0.75 + 0.25 / 15, accuracy: 0.0001)
        XCTAssertEqual(current, CoreAnalysis.mastery(history, hand: .right, goal: edited, now: midnight.addingTimeInterval(86400), calendar: calendar))
    }

    func testLegacyExcludedEmptyAndSaveFailurePreserveDraft() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        runtime.finish(at: start.addingTimeInterval(1))
        XCTAssertThrowsError(try runtime.save(division: event, in: context))
        try runtime.discardEmpty()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
        runtime.finish(at: start.addingTimeInterval(2))
        let summary = try XCTUnwrap(runtime.session.reviewSummary)
        enum Failure: Error { case disk }
        XCTAssertThrowsError(try event.commit(summary: summary, in: context, coreContextData: JSONEncoder().encode(runtime.context)) { throw Failure.disk })
        XCTAssertEqual(event.leftCount, 0)
        XCTAssertNotNil(runtime.activeID)
        XCTAssertEqual(runtime.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        let attempt = try runtime.save(division: event, in: context)
        XCTAssertNotNil(attempt.coreContext)
        // Legacy history remains intact, but no implicit planned provenance.
        var other = PracticeSession(); other.begin(sourceEventID: event.id, at: start)
        other.recordCompletion(for: .left, preset: preset(240), at: start)
        let legacy = PracticeAttempt(eventID: event.id, summary: try XCTUnwrap(other.finish(at: start)))
        context.insert(legacy); try context.save()
        let all = try context.fetch(FetchDescriptor<PracticeAttempt>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(CoreAnalysis.planned(all, division: event.id).count, 1)
        XCTAssertEqual(CoreAnalysis.stable(CoreAnalysis.planned(all, division: event.id), hand: .left), 100)
    }

    func testCorruptDraftDoesNotDisappearOrAllowNewSession() throws {
        let defaults = defaults(), bytes = Data("broken".utf8)
        defaults.set(bytes, forKey: CoreSessionRuntime.draftKey)
        let runtime = CoreSessionRuntime(defaults: defaults)
        XCTAssertNotNil(runtime.failure)
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        XCTAssertEqual(defaults.data(forKey: CoreSessionRuntime.draftKey), bytes)
    }
    func testEveryNoteUnitMedianKeepsOutliersAndEvenAverage() {
        for unit in TempoReferenceNote.allCases {
            let sample = PracticeCompletionSample(hand: .left, preset: preset(80, unit), completedAt: start)
            XCTAssertEqual(CoreAnalysis.median([sample]), 80 * unit.durationInQuarterNotes)
        }
        let samples = [20, 80, 100, 240].map { PracticeCompletionSample(hand: .left, preset: preset($0), completedAt: start) }
        XCTAssertEqual(CoreAnalysis.median(samples), 90)
        XCTAssertEqual(TempoReferenceNote.allCases.count, 8)
    }

    func testGoalEditKeepsSavedProgressAndBackupRetainsPlannedSource() throws {
        let database = try container(), context = database.mainContext
        let (piece, event) = try makeDivision(context, handMode: .left)
        let runtime = CoreSessionRuntime(defaults: defaults())
        for index in 0..<2 {
            let date = start.addingTimeInterval(Double(index * 60))
            try runtime.begin(piece: piece, division: event, initialHand: .left, at: date, calendar: calendar, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            runtime.record(preset: preset(80), at: date.addingTimeInterval(1))
            runtime.finish(at: date.addingTimeInterval(2))
            _ = try runtime.save(division: event, in: context)
        }
        let beforeEdit = try context.fetch(FetchDescriptor<PracticeAttempt>())
        let historicalSamples = Dictionary(uniqueKeysWithValues: beforeEdit.map { ($0.id, $0.completions) })
        let historicalContexts = Dictionary(uniqueKeysWithValues: beforeEdit.map { ($0.id, $0.coreContextData) })
        let goal = CoreGoal(hands: [.left: CoreHandGoal(count: 15, speed: CoreTargetSpeed(bpm: 120, noteUnit: .eighth))])
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal, context: context,
                                      activeSessionID: nil, at: start.addingTimeInterval(100), timing: .current)
        let history = CoreAnalysis.planned(try context.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(CoreAnalysis.count(history, hand: .left, cycleStart: calendar.startOfDay(for: start)), 2)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 80)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.left]?.count, 15)
        for attempt in history {
            XCTAssertEqual(attempt.completions, historicalSamples[attempt.id])
            XCTAssertEqual(attempt.coreContextData, historicalContexts[attempt.id]!)
        }
        let library = try PracticeLibraryStore(modelContext: context)
        let backup = try library.makeBackupData()
        let restored = try container(), restoredLibrary = try PracticeLibraryStore(modelContext: restored.mainContext)
        try restoredLibrary.restoreBackup(from: backup)
        let restoredHistory = CoreAnalysis.planned(try ModelContext(restored).fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(restoredHistory.count, 2)
        XCTAssertEqual(restoredHistory.first?.coreContextData, history.first?.coreContextData)
        XCTAssertEqual(CoreAnalysis.count(restoredHistory, hand: .left, cycleStart: calendar.startOfDay(for: start)), 2)
    }

    func testNewEmptyDraftIsNotRestoredAsFormalSession() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        let defaults = defaults(), runtime = CoreSessionRuntime(defaults: defaults)
        try runtime.begin(piece: piece, division: event, initialHand: .left, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true)
        let restored = CoreSessionRuntime(defaults: defaults)
        XCTAssertNil(restored.activeID)
        XCTAssertNil(defaults.data(forKey: CoreSessionRuntime.draftKey))
    }

    private func samples(_ runtime: CoreSessionRuntime) -> [PracticeCompletionSample] {
        PracticeHand.allCases.flatMap { runtime.session.completionSamples(for: $0) }.sorted { $0.completedAt < $1.completedAt }
    }

    func testExactlyFourHandModesAndLegacyRawValues() throws {
        XCTAssertEqual(CoreHandMode.allCases.map(\.rawValue), ["left", "right", "both", "all"])
        for mode in CoreHandMode.allCases {
            let bytes = Data("\"\(mode.rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(CoreHandMode.self, from: bytes), mode)
            XCTAssertEqual(try JSONEncoder().encode(mode), bytes)
        }
        for invalid in ["leftRight", "leftBoth", "rightBoth", "left,right", ""] {
            XCTAssertThrowsError(try JSONDecoder().decode(CoreHandMode.self, from: JSONEncoder().encode(invalid)))
        }
    }

    func testEverySingleHandStartsDirectlyAndCannotSwitch() throws {
        for (mode, hand) in [(CoreHandMode.left, PracticeHand.left), (.right, .right), (.both, .both)] {
            let store = try container()
            let (piece, event) = try makeDivision(store.mainContext, handMode: mode)
            let runtime = CoreSessionRuntime(defaults: defaults())
            XCTAssertFalse(mode.allowsHandSwitching)
            XCTAssertEqual(mode.directInitialHand, hand)
            try runtime.begin(piece: piece, division: event, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: start)
            XCTAssertEqual(runtime.session.currentHand, hand)
            for candidate in PracticeHand.allCases { runtime.switchHand(candidate, at: start) }
            XCTAssertEqual(runtime.session.currentHand, hand)
            runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
            XCTAssertEqual(samples(runtime).map(\.hand), [hand])
        }
    }

    func testMultiHandRequiresExplicitSelectionBeforeSessionOrRecord() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        let storage = defaults(), runtime = CoreSessionRuntime(defaults: storage)
        XCTAssertTrue(CoreHandMode.all.allowsHandSwitching)
        XCTAssertNil(CoreHandMode.all.directInitialHand)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        runtime.record(preset: preset(100))
        XCTAssertNil(runtime.context)
        XCTAssertNil(runtime.activeID)
        XCTAssertEqual(runtime.count, 0)
        XCTAssertNil(storage.data(forKey: CoreSessionRuntime.draftKey))
    }

    func testMultiHandAllThreeExplicitInitialSelectionsAndNoInheritance() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        let runtime = CoreSessionRuntime(defaults: defaults())
        for hand in PracticeHand.allCases {
            try runtime.begin(piece: piece, division: event, initialHand: hand, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: start)
            XCTAssertEqual(runtime.session.currentHand, hand)
            runtime.switchHand(.both)
            try runtime.discardEmpty()
            XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
            XCTAssertNil(runtime.activeID)
        }
    }

    func testSingleHandRejectsInapplicableExplicitInitialSelectionWithoutMutation() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext, handMode: .both)
        let storage = defaults(), runtime = CoreSessionRuntime(defaults: storage)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        XCTAssertNil(runtime.context)
        XCTAssertNil(storage.data(forKey: CoreSessionRuntime.draftKey))
    }

    func testSwitchingKeepsIdentityPlaybackBPMCountsAndHistoricalAttribution() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        let id = runtime.activeID
        runtime.updatePreset(preset(137), at: start)
        runtime.record(preset: runtime.preset, at: start.addingTimeInterval(1))
        let left = samples(runtime)
        for (offset, hand) in [PracticeHand.right, .both].enumerated() {
            runtime.switchHand(hand, at: start.addingTimeInterval(Double(offset * 2 + 2)))
            XCTAssertEqual(runtime.activeID, id)
            XCTAssertTrue(runtime.session.isRunning)
            XCTAssertEqual(runtime.preset.bpm, 137)
            XCTAssertEqual(Array(samples(runtime).prefix(1)), left)
            runtime.record(preset: runtime.preset, at: start.addingTimeInterval(Double(offset * 2 + 3)))
        }
        let records = samples(runtime)
        XCTAssertEqual(records.map(\.hand), [.left, .right, .both])
        runtime.switchHand(.left, at: start.addingTimeInterval(6))
        XCTAssertEqual(runtime.session.completionSamples(for: .left).count, 1)
        XCTAssertEqual(samples(runtime), records)
        runtime.pause(at: start.addingTimeInterval(7))
        runtime.switchHand(.right, at: start.addingTimeInterval(8))
        XCTAssertFalse(runtime.session.isRunning)
        XCTAssertEqual(runtime.activeID, id)
        XCTAssertEqual(runtime.preset.bpm, 137)
        XCTAssertEqual(samples(runtime), records)
    }

    func testTogetherContextKeepsHistoricalLeftRightFactsAndUsesOnlyTogetherGoal() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        runtime.record(preset: preset(80), at: start.addingTimeInterval(1))
        runtime.switchHand(.right, at: start.addingTimeInterval(2))
        runtime.record(preset: preset(90), at: start.addingTimeInterval(3))
        runtime.finish(at: start.addingTimeInterval(4))
        let old = try runtime.save(division: event, in: context)
        let facts = old.completions, metadata = old.coreContextData
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.handMode = .both
        definition.goal = CoreGoal(hands: [.both: CoreHandGoal(count: 1, speed: CoreTargetSpeed(bpm: 100))])
        event.coreDefinitionData = try JSONEncoder().encode(definition)
        try context.save()
        XCTAssertTrue(definition.hasValidGoal, "Left and Right are N/A, not missing goals")
        try runtime.begin(piece: piece, division: event, at: start.addingTimeInterval(10), activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start.addingTimeInterval(10))
        runtime.record(preset: preset(100), at: start.addingTimeInterval(11))
        runtime.finish(at: start.addingTimeInterval(12))
        _ = try runtime.save(division: event, in: context)
        let history = CoreAnalysis.planned(try context.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(old.completions, facts)
        XCTAssertEqual(old.coreContextData, metadata)
        XCTAssertEqual(old.coreContext?.handMode, .all)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 80)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .right), 90)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .both), 100)
        XCTAssertEqual(CoreAnalysis.divisionMastery(history, definition: definition, now: start), 1)
    }

    func testTogetherDraftRestoresItsHandAndRecords() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext, handMode: .both)
        let storage = defaults(), runtime = CoreSessionRuntime(defaults: storage)
        try runtime.begin(piece: piece, division: event, at: start, activation: CoreLadderActivation(enabled: event.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
        let restored = CoreSessionRuntime(defaults: storage)
        XCTAssertEqual(restored.activeID, runtime.activeID)
        XCTAssertEqual(restored.context?.handMode, .both)
        XCTAssertEqual(restored.session.currentHand, .both)
        XCTAssertEqual(samples(restored), samples(runtime))
    }

}

extension PracticeCoreTests {
    private func ladderSetup(start: Int = 40, step: Int = 2, target: Int? = 44, reps: Int = 1,
                             mode: CoreHandMode = .all, date: Date = Date(timeIntervalSince1970: 1_790_928_000))
        throws -> (ModelContainer, PracticeSong, PracticeEvent, CoreSessionRuntime, UserDefaults, Date) {
        let store = try container()
        let piece = PracticeSong(name: "Node 3")
        piece.coreStructureData = try JSONEncoder().encode(CorePieceStructure(mode: .sections, total: 6))
        let division = PracticeEvent(songID: piece.id, name: "1")
        let goal = CoreGoal(hands: Dictionary(uniqueKeysWithValues: mode.hands.map {
            ($0, CoreHandGoal(count: 5, speed: target.map { CoreTargetSpeed(bpm: $0) },
                ladder: CoreLadderConfiguration(startBPM: start, stepBPM: step, repsPerLevel: reps)))
        }), ladderEnabled: true, reset: CoreResetConfiguration(anchor: Calendar.current.startOfDay(for: date)))
        division.coreDefinitionData = try JSONEncoder().encode(CoreDivisionDefinition(first: 1, last: 1, handMode: mode, goal: goal))
        store.mainContext.insert(piece); store.mainContext.insert(division); try store.mainContext.save()
        let defaults = UserDefaults(suiteName: "Node3.\(UUID())")!
        return (store, piece, division, CoreSessionRuntime(defaults: defaults, restore: false), defaults, date)
    }
    private func record(_ runtime: CoreSessionRuntime, _ bpm: Int, unit: TempoReferenceNote = .quarter, date: Date) {
        var preset = MetronomePreset.standard; preset.bpm = bpm; preset.referenceNote = unit
        runtime.record(preset: preset, at: date)
    }

    func testNode3ControlledExecutionRealRecordsAndTargetHold() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup()
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        XCTAssertEqual(runtime.preset.bpm, 40) // A09: entry adopts the selected Hand's current rung.
        XCTAssertEqual(runtime.preset.referenceNote, .quarter)
        record(runtime, 40, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.currentBPM, 42)
        XCTAssertEqual(runtime.preset.bpm, 42) // A09: rung completion hands off Actual BPM.
        record(runtime, 42, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.currentBPM, 44)
        record(runtime, 44, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.currentBPM, 44)
        XCTAssertEqual(runtime.count, 3)
        XCTAssertTrue(runtime.session.isRunning)
        record(runtime, 44, date: date); record(runtime, 44, date: date)
        XCTAssertEqual(runtime.count, 5)
        XCTAssertTrue(runtime.session.isRunning)
        runtime.finish(at: date.addingTimeInterval(5))
        let attempt = try runtime.save(division: division, in: store.mainContext)
        XCTAssertEqual(attempt.completions.map { $0.preset.bpm }, [40, 42, 44, 44, 44])
        XCTAssertEqual(division.coreDefinition?.ladderStates?[.left]?.currentBPM, 44)
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: date.addingTimeInterval(10), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date.addingTimeInterval(10))
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.currentBPM, 44)
        XCTAssertEqual(runtime.preset.bpm, 44, "Entry resumes saved rung, not Start BPM")
    }

    func testNode3MismatchIsolationEquivalenceAndRecovery() throws {
        let (store, piece, division, runtime, defaults, date) = try ladderSetup(reps: 2)
        defer { withExtendedLifetime(store) {} }
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 39, date: date)
        XCTAssertFalse(runtime.execution!.ladderStates![.left]!.startLocked)
        record(runtime, 80, unit: .eighth, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.repsCompleted, 1)
        XCTAssertTrue(runtime.execution!.ladderStates![.left]!.startLocked)
        for hand in [PracticeHand.right, .both] {
            runtime.switchHand(hand, at: date)
            XCTAssertEqual(runtime.preset.bpm, 40) // A09: selected Hand owns BPM and Note Unit.
            XCTAssertEqual(runtime.preset.referenceNote, .quarter)
            XCTAssertEqual(runtime.execution?.ladderStates?[hand]?.repsCompleted, 0)
            record(runtime, 80, unit: .eighth, date: date)
        }
        runtime.switchHand(.left, at: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.repsCompleted, 1)
        record(runtime, 40, date: date)
        record(runtime, 40, date: date) // old rung cannot receive another rep
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.currentBPM, 42)
        XCTAssertEqual(runtime.execution?.ladderStates?[.left]?.repsCompleted, 0)
        XCTAssertEqual(runtime.execution?.ladderStates?[.right]?.repsCompleted, 1)
        let recovered = CoreSessionRuntime(defaults: defaults)
        XCTAssertTrue(recovered.needsRecovery)
        XCTAssertEqual(recovered.execution, runtime.execution)
        XCTAssertEqual(recovered.count, 6)
        XCTAssertEqual(recovered.session.completionSamples(for: .left).map { $0.preset.bpm }, [39, 80, 40, 40])
    }

    func testNode3ShortStepAndOpenEndedCeiling() throws {
        for target in [Int?.some(108), Int?.some(109), nil] {
            let (store, piece, division, runtime, _, date) = try ladderSetup(start: target == nil ? 298 : 100, step: 3, target: target, mode: .both)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            defer { withExtendedLifetime(store) {} }
            let bpms = target.map { [100, 103, 106, $0, $0] } ?? [298, 300, 300]
            for bpm in bpms {
                XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, bpm)
                XCTAssertEqual(runtime.preset.bpm, bpm)
                record(runtime, bpm, date: date)
                XCTAssertLessThanOrEqual(try XCTUnwrap(runtime.execution?.ladderStates?[.both]?.currentBPM), target ?? 300)
            }
            XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, target ?? 300)
            XCTAssertEqual(runtime.preset.bpm, target ?? 300)
            XCTAssertNil(runtime.session.reviewSummary, "Target / execution ceiling is not Session end")
            XCTAssertTrue(runtime.session.isRunning)
            XCTAssertEqual(runtime.session.completionSamples(for: .both).map { $0.preset.bpm }, bpms)
            if target == nil { XCTAssertNil(runtime.context?.goal.hands[.both]?.speed) }
        }
    }

    func testNode3OnlyHandsOffAndActualRange() throws {
        for mode in [CoreHandMode.left, .right, .both] {
            let (store, piece, division, runtime, _, date) = try ladderSetup(mode: mode)
            defer { withExtendedLifetime(store) {} }
            var definition = division.coreDefinition!
            definition.goal?.ladderEnabled = false
            division.coreDefinitionData = try JSONEncoder().encode(definition)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            for bpm in [40, 241, 299, 300] { record(runtime, bpm, date: date) }
            XCTAssertNil(runtime.execution?.ladderStates)
            XCTAssertEqual(runtime.session.completionSamples(for: mode.hands[0]).map { $0.preset.bpm }, [40, 241, 299, 300])
        }
        XCTAssertNil(TempoScrubModel.validatedBPMInput("301"))
        let engine = MetronomeEngine()
        engine.setBPM(300)
        XCTAssertEqual(engine.effectivePlaybackPreset.bpm, 300)
    }

    func testNode3CyclePendingAndSessionAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_790_928_000)
        let (store, piece, division, runtime, _, _) = try ladderSetup(mode: .both, date: date)
        var definition = division.coreDefinition!
        definition.goal?.reset?.anchor = calendar.startOfDay(for: date)
        var pending = definition.goal!
        pending.hands[.both]?.ladder?.startBPM = 30
        pending.hands[.both]?.speed?.bpm = 38
        definition.nextCycleGoal = pending
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        try runtime.begin(piece: piece, division: division, at: date, calendar: calendar, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        let oldCycle = runtime.context!.cycleStart
        record(runtime, 42, date: date.addingTimeInterval(86_400))
        XCTAssertEqual(runtime.context?.cycleStart, oldCycle)
        XCTAssertEqual(runtime.context?.goal.hands[.both]?.speed?.bpm, 44)
        runtime.finish(at: date.addingTimeInterval(86_401))
        _ = try runtime.save(division: division, in: store.mainContext)
        try runtime.begin(piece: piece, division: division, at: date.addingTimeInterval(86_402), calendar: calendar, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date.addingTimeInterval(86_402))
        XCTAssertEqual(runtime.context?.goal.hands[.both]?.speed?.bpm, 38)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 30)
        XCTAssertFalse(runtime.execution!.ladderStates![.both]!.startLocked)
        XCTAssertNil(runtime.execution?.nextCycleGoal)
    }

    func testNode3NewCycleRequiresConfirmedStartAndPreservesHistory() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        runtime.finish(at: date.addingTimeInterval(1))
        let attempt = try runtime.save(division: division, in: store.mainContext)
        let history = attempt.completions
        let next = date.addingTimeInterval(86_400)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: division, at: next, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        XCTAssertNil(runtime.context)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: division, at: next, confirmedStarts: [.both: 41], activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
        try runtime.begin(piece: piece, division: division, at: next, confirmedStarts: [.both: 30], activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: next)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 30)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, 0)
        XCTAssertFalse(runtime.execution!.ladderStates![.both]!.startLocked)
        XCTAssertEqual(attempt.completions, history)
    }

    func testNode3CadenceEditDoesNotResetToday() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        runtime.finish(at: date.addingTimeInterval(1))
        _ = try runtime.save(division: division, in: store.mainContext)
        var goal = division.coreDefinition!.goal!; goal.reset?.days = 7
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal, context: store.mainContext,
            activeSessionID: nil, at: date.addingTimeInterval(2), isPro: true)
        let today = try CoreSessionRuntime.prepare(division: division, at: date.addingTimeInterval(3), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        XCTAssertTrue(today.needsStart.isEmpty)
        XCTAssertEqual(today.definition.ladderStates?[.both]?.currentBPM, 42)
        let tomorrow = try CoreSessionRuntime.prepare(division: division, at: date.addingTimeInterval(86_400), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        XCTAssertEqual(tomorrow.definition.goal?.reset?.days, 7)
        XCTAssertEqual(tomorrow.needsStart, [.both])
    }
    func testNode3CurrentEditsPreserveProgressAndStartLock() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        runtime.finish(at: date.addingTimeInterval(1))
        let saved = try runtime.save(division: division, in: store.mainContext)
        let facts = saved.completions
        var goal = division.coreDefinition!.goal!
        goal.hands[.both]?.ladder?.startBPM = 38
        XCTAssertThrowsError(try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
            context: store.mainContext, activeSessionID: nil, at: date, isPro: true, timing: .current))
        goal.hands[.both]?.ladder?.startBPM = 40
        goal.hands[.both]?.speed?.bpm = 39
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
            context: store.mainContext, activeSessionID: nil, at: date, isPro: true, timing: .current)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 42, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 42)
        XCTAssertEqual(saved.completions, facts)
    }

    func testNode3ReenableUsesNewConfirmedOriginWithoutBackfill() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        runtime.finish(at: date.addingTimeInterval(1))
        _ = try runtime.save(division: division, in: store.mainContext)
        var goal = division.coreDefinition!.goal!; goal.ladderEnabled = false
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
            context: store.mainContext, activeSessionID: nil, at: date, isPro: true, timing: .current)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 42, date: date)
        runtime.finish(at: date.addingTimeInterval(1))
        _ = try runtime.save(division: division, in: store.mainContext)
        goal.ladderEnabled = true; goal.hands[.both]?.ladder?.startBPM = 30
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
            context: store.mainContext, activeSessionID: nil, at: date, isPro: true, timing: .current)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 30)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, 0)
        XCTAssertFalse(runtime.execution!.ladderStates![.both]!.startLocked)
        XCTAssertEqual(try store.mainContext.fetch(FetchDescriptor<PracticeAttempt>()).count, 2)
    }

    func testNode3UnitMigrationResetsOnlyRoundedRungProgress() throws {
        for unit in [CoreNoteUnit.eighth, .dottedQuarter] {
            let (store, piece, division, runtime, _, date) = try ladderSetup(start: 41, target: 80, reps: 2, mode: .both)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            record(runtime, 41, date: date)
            runtime.finish(at: date.addingTimeInterval(1))
            _ = try runtime.save(division: division, in: store.mainContext)
            var goal = division.coreDefinition!.goal!
            let converted = goal.hands[.both]!.ladder!.converted(to: unit)
            goal.hands[.both]?.ladder = converted
            goal.hands[.both]?.speed = CoreTargetSpeed(bpm: Int((80 / unit.quarterMultiplier).rounded()), noteUnit: unit)
            _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
                context: store.mainContext, activeSessionID: nil, at: date, isPro: true, timing: .current)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, unit == .eighth ? 1 : 0)
            XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.previousValidBPM, 41)
        }
    }

}


extension PracticeCoreTests {
    func testNode4OrdinarySaveDiscardCancelAndFormalLadderRollback() throws {
        for choice in [CoreExitChoice.save, .discard, .cancel] {
            let (store, piece, division, runtime, defaults, date) = try ladderSetup(mode: .both)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            record(runtime, 35, date: date)
            runtime.finish(at: date.addingTimeInterval(1))
            let prior = try runtime.save(division: division, in: store.mainContext)
            let baseline = division.coreDefinitionData
            let priorRecords = prior.completions
            try runtime.begin(piece: piece, division: division, at: date.addingTimeInterval(2), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date.addingTimeInterval(2))
            record(runtime, 40, date: date.addingTimeInterval(3))
            record(runtime, 42, date: date.addingTimeInterval(4))
            XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 44)
            let temporary = runtime.execution
            let activeID = runtime.activeID
            try runtime.requestExit(.ordinary)
            XCTAssertEqual(runtime.activeID, activeID)
            let destination = try runtime.resolveExit(choice, division: division, in: store.mainContext, at: date.addingTimeInterval(5))
            XCTAssertEqual(prior.completions, priorRecords)
            if choice == .cancel {
                XCTAssertNil(destination)
                XCTAssertEqual(runtime.activeID, activeID)
                XCTAssertEqual(runtime.execution, temporary)
                XCTAssertEqual(runtime.count, 2)
                XCTAssertTrue(runtime.session.isRunning)
                XCTAssertEqual(division.coreDefinitionData, baseline)
                XCTAssertNil(runtime.exitRequest)
            } else {
                XCTAssertEqual(destination, .piece(piece.id))
                XCTAssertNil(runtime.activeID)
                XCTAssertNil(defaults.data(forKey: CoreSessionRuntime.draftKey))
                XCTAssertNil(CoreSessionRuntime(defaults: defaults).activeID)
                XCTAssertEqual(division.bothCount, choice == .save ? 3 : 1)
                XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), choice == .save ? 2 : 1)
                if choice == .discard { XCTAssertEqual(division.coreDefinitionData, baseline) }
                try runtime.begin(piece: piece, division: division, at: date.addingTimeInterval(6), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
                runtime.synchronizePlayback(isPlaying: true, at: date.addingTimeInterval(6))
                XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, choice == .save ? 44 : 40)
                XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, 0)
            }
        }
    }

    func testNode4A05RetainsOriginalActionForEveryDecision() throws {
        for action in 0..<4 {
            for choice in [CoreExitChoice.save, .discard, .cancel] {
                let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
                let route: CoreRoute
                switch action {
                case 0: route = .startPractice(piece: UUID(), division: UUID())
                case 1: route = .startPractice(piece: piece.id, division: UUID())
                case 2: route = .archivePiece(piece.id)
                default: route = .deletePiece(piece.id)
                }
                try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
                runtime.synchronizePlayback(isPlaying: true, at: date)
                record(runtime, 40, date: date)
                try runtime.requestExit(.transition(route))
                let result = try runtime.resolveExit(choice, division: division, in: store.mainContext, at: date)
                XCTAssertEqual(result, choice == .cancel ? nil : .route(route))
                XCTAssertEqual(runtime.activeID != nil, choice == .cancel)
                XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), choice == .save ? 1 : 0)
                XCTAssertFalse(piece.isArchived)
                XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeSong>()), 1, "Guard never performs Delete itself")
            }
        }
    }

    func testNode4Hand05RejectsDiscardAndAllowsSaveOrCancel() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        let route = CoreRoute.editDivision(piece: piece.id, division: division.id)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        try runtime.requestExit(.transition(route))
        XCTAssertTrue(runtime.exitRequest!.saveOnly)
        XCTAssertThrowsError(try runtime.resolveExit(.discard, division: division, in: store.mainContext))
        XCTAssertEqual(runtime.count, 1)
        XCTAssertNotNil(runtime.activeID)
        XCTAssertNil(try runtime.resolveExit(.cancel, division: division, in: store.mainContext))
        try runtime.requestExit(.transition(route))
        XCTAssertEqual(try runtime.resolveExit(.save, division: division, in: store.mainContext, at: date), .route(route))
        XCTAssertNil(runtime.activeID)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
    }

    func testNode4EmptySaveCreatesNoFakeHistoryOrRecovery() throws {
        let (store, piece, division, runtime, defaults, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        try runtime.requestExit(.ordinary)
        XCTAssertEqual(try runtime.resolveExit(.save, division: division, in: store.mainContext, at: date), .piece(piece.id))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertNil(defaults.data(forKey: CoreSessionRuntime.draftKey))
        XCTAssertNil(CoreSessionRuntime(defaults: defaults).activeID)
    }

    func testNode4FailedExitKeepsGuardAndProvisionalState() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        let original = runtime.execution
        try runtime.requestExit(.ordinary)
        let wrong = PracticeEvent(songID: piece.id, name: "wrong")
        XCTAssertThrowsError(try runtime.resolveExit(.save, division: wrong, in: store.mainContext))
        XCTAssertNotNil(runtime.activeID)
        XCTAssertEqual(runtime.exitRequest, .ordinary)
        XCTAssertEqual(runtime.execution, original)
        XCTAssertTrue(runtime.session.isRunning)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
    }
    func testNode4TransactionFailureRetainsActiveSessionAndAllowsRetry() throws {
        let (store, piece, division, runtime, defaults, date) = try ladderSetup(mode: .both)
        let before = division.coreDefinitionData
        try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        record(runtime, 40, date: date)
        let id = runtime.activeID
        try runtime.requestExit(.ordinary)
        enum DiskError: Error { case unavailable }
        XCTAssertThrowsError(try runtime.resolveExit(.save, division: division, in: store.mainContext, at: date,
            saving: { throw DiskError.unavailable }))
        XCTAssertEqual(runtime.activeID, id)
        XCTAssertTrue(runtime.session.isRunning)
        XCTAssertEqual(runtime.count, 1)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 42)
        XCTAssertEqual(runtime.exitRequest, .ordinary)
        XCTAssertEqual(division.coreDefinitionData, before)
        XCTAssertEqual(division.bothCount, 0)
        XCTAssertNotNil(defaults.data(forKey: CoreSessionRuntime.draftKey))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertEqual(try runtime.resolveExit(.save, division: division, in: store.mainContext, at: date), .piece(piece.id))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
    }

}

extension PracticeCoreTests {
    func testPieceDeletionRestorePreservesStateAndHistory() throws {
        for archived in [false, true] {
            let (db, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
            piece.isArchived = archived; piece.endDate = .distantFuture
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            record(runtime, 40, date: date); runtime.finish(at: date.addingTimeInterval(1))
            _ = try runtime.save(division: division, in: db.mainContext)
            let originalDefinition = division.coreDefinitionData
            let originalAttempts = try db.mainContext.fetch(FetchDescriptor<PracticeAttempt>()).map(\.id)
            XCTAssertThrowsError(try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: UUID(), isPro: true, at: date))
            XCTAssertNil(piece.deletedAt)
            XCTAssertThrowsError(try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: false, at: date))
            try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date)
            // Repeated deletion cannot extend retention.
            try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date.addingTimeInterval(50))
            XCTAssertEqual(piece.deletedAt, date)
            XCTAssertThrowsError(try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
            let library = try PracticeLibraryStore(modelContext: db.mainContext)
            XCTAssertTrue(library.songs.isEmpty); XCTAssertTrue(library.records.isEmpty)
            XCTAssertThrowsError(try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: db.mainContext, isPro: false, at: date))
            try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: db.mainContext, isPro: true, at: date.addingTimeInterval(604799))
            XCTAssertNil(piece.deletedAt); XCTAssertEqual(piece.isArchived, archived)
            XCTAssertEqual(division.coreDefinitionData, originalDefinition)
            XCTAssertEqual(try db.mainContext.fetch(FetchDescriptor<PracticeAttempt>()).map(\.id), originalAttempts)
            try library.reload(); XCTAssertEqual(library.songs.count, 1); XCTAssertEqual(library.records.count, 1)
        }
    }

    func testPieceDeletionExpirationAndFreeDeleteRemoveGraph() throws {
        for expires in [false, true] {
            let (db, piece, division, runtime, _, date) = try ladderSetup(mode: .both)
            try runtime.begin(piece: piece, division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            runtime.synchronizePlayback(isPlaying: true, at: date)
            record(runtime, 40, date: date); runtime.finish(at: date.addingTimeInterval(1))
            _ = try runtime.save(division: division, in: db.mainContext)
            if expires {
                try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date)
                try CoreContracts.expireDeletedPieces(in: db.mainContext, at: date.addingTimeInterval(604799))
                XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeSong>()), 1)
                try CoreContracts.expireDeletedPieces(in: db.mainContext, at: date.addingTimeInterval(604800))
            } else {
                try CoreContracts.permanentlyDeletePiece(piece: piece, context: db.mainContext, activeSessionID: nil)
            }
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeSong>()), 0)
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeEvent>()), 0)
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
            XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeDailyGoal>()), 0)
        }
    }

    func testPieceDeletionExpiredRestoreCannotResurrect() throws {
        let (db, piece, _, _, _, date) = try ladderSetup()
        try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date)
        XCTAssertThrowsError(try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: db.mainContext, isPro: true, at: date.addingTimeInterval(604800)))
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PracticeSong>()), 0)
    }

    func testPieceDeletionBackupAndCloudMergePreserveDeletionAndRestore() throws {
        let (db, piece, _, _, _, _) = try ladderSetup()
        piece.endDate = .distantFuture; piece.isArchived = true
        let date = Date.now.addingTimeInterval(10)
        let library = try PracticeLibraryStore(modelContext: db.mainContext)
        let original = try library.makeBackupData()
        let baseline = try ICloudBackupMerger.makeLocalEnvelope(payload: original, baseline: nil, modifiedAt: date, deviceID: "A")
        try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date)
        let deleted = try ICloudBackupMerger.makeLocalEnvelope(payload: library.makeBackupData(), baseline: baseline, modifiedAt: date.addingTimeInterval(1), deviceID: "A")
        let merged = try ICloudBackupMerger.merge(local: baseline, remote: deleted, modifiedAt: date.addingTimeInterval(2), deviceID: "B")
        let other = try container(); let otherLibrary = try PracticeLibraryStore(modelContext: other.mainContext)
        try otherLibrary.restoreBackup(from: merged.payload)
        let imported = try XCTUnwrap(other.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
        XCTAssertEqual(imported.deletedAt, date); XCTAssertTrue(imported.isArchived)
        XCTAssertTrue(otherLibrary.songs.isEmpty)
        try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: db.mainContext, isPro: true, at: date.addingTimeInterval(3))
        let restored = try ICloudBackupMerger.makeLocalEnvelope(payload: library.makeBackupData(), baseline: deleted, modifiedAt: date.addingTimeInterval(3), deviceID: "A")
        let restoredMerge = try ICloudBackupMerger.merge(local: deleted, remote: restored, modifiedAt: date.addingTimeInterval(4), deviceID: "B")
        try otherLibrary.restoreBackup(from: restoredMerge.payload)
        let restoredPiece = try XCTUnwrap(other.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
        XCTAssertNil(restoredPiece.deletedAt); XCTAssertTrue(restoredPiece.isArchived)
        try CoreContracts.permanentlyDeletePiece(piece: piece, context: db.mainContext, activeSessionID: nil)
        let removed = try ICloudBackupMerger.makeLocalEnvelope(payload: library.makeBackupData(), baseline: restored, modifiedAt: date.addingTimeInterval(5), deviceID: "A")
        let final = try ICloudBackupMerger.merge(local: deleted, remote: removed, modifiedAt: date.addingTimeInterval(6), deviceID: "B")
        try otherLibrary.restoreBackup(from: final.payload)
        XCTAssertEqual(try other.mainContext.fetchCount(FetchDescriptor<PracticeSong>()), 0)
        // Earlier backups without deletedAt remain readable.
        try otherLibrary.restoreBackup(from: original)
        XCTAssertNil(try other.mainContext.fetch(FetchDescriptor<PracticeSong>()).first?.deletedAt)
    }

    func testPieceDeletionSurvivesPersistentStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("piece.store")
        let date = Date.now
        do {
            let db = try container(url: url)
            let piece = PracticeSong(name: "Deleted archived", isArchived: true)
            db.mainContext.insert(piece)
            try CoreContracts.movePieceToRecentlyDeleted(piece: piece, context: db.mainContext, activeSessionID: nil, isPro: true, at: date)
        }
        do {
            let db = try container(url: url)
            let piece = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
            XCTAssertEqual(piece.deletedAt, date); XCTAssertTrue(piece.isArchived)
            try CoreContracts.restoreRecentlyDeletedPiece(piece: piece, context: db.mainContext, isPro: true, at: date.addingTimeInterval(1))
        }
        let db = try container(url: url)
        let piece = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<PracticeSong>()).first)
        XCTAssertNil(piece.deletedAt); XCTAssertTrue(piece.isArchived)
    }
}


extension PracticeCoreTests {
    func testHandSyncApplicableViewsExcludeDormantGoalAndLadderWithoutMutatingStorage() throws {
        let (store, _, division, _, _, date) = try ladderSetup()
        defer { withExtendedLifetime(store) {} }
        var definition = try XCTUnwrap(division.coreDefinition)
        definition.handMode = .both
        let historical = CoreLadderState(cycleStart: date, cycleStartBPM: 40, currentBPM: 42,
            repsCompleted: 1, noteUnit: .quarter, firstValidRecordAt: date)
        definition.ladderStates = [.left: historical, .right: historical]
        let storedGoal = try XCTUnwrap(definition.goal)
        let currentGoal = storedGoal.applicable(to: .both)
        XCTAssertEqual(Set(currentGoal.hands.keys), [.both])
        XCTAssertTrue(currentGoal.isValid(for: .both))
        XCTAssertTrue(definition.applicableLadderStates.isEmpty, "Historical locks must not lock current Hands Together")
        XCTAssertEqual(Set(storedGoal.hands.keys), [.left, .right, .both])
        XCTAssertEqual(definition.ladderStates?[.left], historical)
        XCTAssertEqual(definition.ladderStates?[.right], historical)
        XCTAssertThrowsError(try CoreContracts.copyLeftLadderToRight(in: storedGoal, mode: .both))
    }

    func testHandSyncDormantLadderDoesNotChooseCurrentCycleOrRequireStartConfirmation() throws {
        let (store, _, division, _, _, date) = try ladderSetup(mode: .both)
        defer { withExtendedLifetime(store) {} }
        var definition = try XCTUnwrap(division.coreDefinition)
        let historical = CoreLadderState(cycleStart: date.addingTimeInterval(-86400), cycleStartBPM: 40,
            currentBPM: 42, repsCompleted: 1, noteUnit: .quarter, firstValidRecordAt: date.addingTimeInterval(-86400))
        definition.ladderStates = [.left: historical, .right: historical]
        definition.goal?.reset = CoreResetConfiguration(enabled: false)
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        let prepared = try CoreSessionRuntime.prepare(division: division, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        XCTAssertEqual(prepared.cycle, Calendar.current.startOfDay(for: date))
        XCTAssertTrue(prepared.needsStart.isEmpty)
        XCTAssertEqual(prepared.definition.ladderStates, definition.ladderStates)
    }

    func testHandSyncEditToTogetherPreservesHistoricalFactsAndOnlyExecutesTogetherLadder() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(reps: 2)
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        for hand in PracticeHand.allCases {
            runtime.switchHand(hand, at: date)
            record(runtime, 40, date: date)
        }
        runtime.finish(at: date.addingTimeInterval(1))
        let historicalSession = try runtime.save(division: division, in: store.mainContext)
        let originalSamples = historicalSession.completions
        let originalContext = historicalSession.coreContextData
        var definition = try XCTUnwrap(division.coreDefinition)
        let historicalGoal = try XCTUnwrap(definition.goal)
        let historicalStates = try XCTUnwrap(definition.ladderStates)
        definition.handMode = .both
        _ = try CoreContracts.saveEditedDivision(piece: piece, division: division, definition: definition,
                                                 context: store.mainContext, activeSessionID: nil)
        var currentGoal = historicalGoal.applicable(to: .both)
        currentGoal.hands[.both]?.count = 7
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: currentGoal,
            context: store.mainContext, activeSessionID: nil, at: date.addingTimeInterval(2), isPro: true, timing: .current)
        let saved = try XCTUnwrap(division.coreDefinition)
        for hand in [PracticeHand.left, .right] {
            XCTAssertEqual(saved.goal?.hands[hand], historicalGoal.hands[hand])
            XCTAssertEqual(saved.ladderStates?[hand], historicalStates[hand])
        }
        try runtime.begin(piece: piece, division: division, at: date.addingTimeInterval(3), activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date.addingTimeInterval(3))
        XCTAssertEqual(runtime.session.currentHand, .both)
        XCTAssertEqual(Set(try XCTUnwrap(runtime.context?.goal.hands).keys), [.both])
        XCTAssertEqual(Set(try XCTUnwrap(runtime.execution).applicableLadderStates.keys), [.both])
        runtime.switchHand(.left, at: date.addingTimeInterval(4))
        XCTAssertEqual(runtime.session.currentHand, .both)
        record(runtime, 40, date: date.addingTimeInterval(5))
        XCTAssertEqual(runtime.session.completionSamples(for: .both).count, 1)
        XCTAssertTrue(runtime.session.completionSamples(for: .left).isEmpty)
        XCTAssertTrue(runtime.session.completionSamples(for: .right).isEmpty)
        runtime.finish(at: date.addingTimeInterval(6))
        _ = try runtime.save(division: division, in: store.mainContext)
        for hand in [PracticeHand.left, .right] {
            XCTAssertEqual(division.coreDefinition?.goal?.hands[hand], historicalGoal.hands[hand])
            XCTAssertEqual(division.coreDefinition?.ladderStates?[hand], historicalStates[hand])
        }
        XCTAssertEqual(historicalSession.completions, originalSamples)
        XCTAssertEqual(historicalSession.coreContextData, originalContext)
    }
}


extension PracticeCoreTests {
    func testA09HandoffAcceptanceSequenceKeepsIndependentRungsAndSession() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup()
        defer { withExtendedLifetime(store) {} }
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        let id = runtime.activeID
        record(runtime, 40, date: date)
        record(runtime, 42, date: date)
        let leftFacts = runtime.session.completionSamples(for: .left)
        XCTAssertEqual(runtime.preset.bpm, 44)
        runtime.switchHand(.right, at: date)
        XCTAssertEqual(runtime.preset.bpm, 40)
        record(runtime, 40, date: date)
        XCTAssertEqual(runtime.preset.bpm, 42)
        for (hand, bpm) in [(PracticeHand.both, 40), (.right, 42), (.left, 44)] {
            runtime.switchHand(hand, at: date)
            XCTAssertEqual(runtime.preset.bpm, bpm)
            XCTAssertEqual(runtime.execution?.ladderStates?[hand]?.currentBPM, bpm)
            XCTAssertEqual(runtime.activeID, id)
            XCTAssertTrue(runtime.session.isRunning)
            XCTAssertEqual(runtime.session.completionSamples(for: .left), leftFacts)
        }
        XCTAssertEqual(runtime.session.completionSamples(for: .right).count, 1)
        XCTAssertTrue(runtime.session.completionSamples(for: .both).isEmpty)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
    }

    func testA09NonParticipatingHandIgnoresDormantRungOnEntryAndSwitch() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup()
        defer { withExtendedLifetime(store) {} }
        var definition = try XCTUnwrap(division.coreDefinition)
        definition.goal?.hands[.right]?.ladder = nil
        let dormant = CoreLadderState(cycleStart: Calendar.current.startOfDay(for: date), cycleStartBPM: 88,
            currentBPM: 88, repsCompleted: 1, noteUnit: .half)
        definition.ladderStates = [.right: dormant]
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        try runtime.begin(piece: piece, division: division, initialHand: .right, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        XCTAssertEqual(runtime.preset, division.preset.normalized)
        runtime.switchHand(.left, at: date)
        XCTAssertEqual(runtime.preset.bpm, 40)
        var manual = runtime.preset; manual.bpm = 117; manual.referenceNote = .eighth
        runtime.updatePreset(manual, at: date)
        runtime.switchHand(.right, at: date)
        XCTAssertEqual(runtime.preset, manual.normalized, "Non-Ladder hand retains Actual BPM / Note Unit")
        runtime.record(preset: manual, at: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.right], dormant)
        XCTAssertEqual(runtime.session.completionSamples(for: .right).map { $0.preset.bpm }, [117])
    }

    func testA09EquivalentRungAdvanceHandoffsStandardUnitAndManualMismatchDoesNotProgress() throws {
        let (store, piece, division, runtime, _, date) = try ladderSetup(target: 88, reps: 2)
        defer { withExtendedLifetime(store) {} }
        var definition = try XCTUnwrap(division.coreDefinition)
        definition.goal?.hands[.right]?.ladder = CoreLadderConfiguration(startBPM: 80, stepBPM: 2, repsPerLevel: 2, noteUnit: .eighth)
        definition.goal?.hands[.right]?.speed = CoreTargetSpeed(bpm: 88, noteUnit: .eighth)
        division.coreDefinitionData = try JSONEncoder().encode(definition)
        try runtime.begin(piece: piece, division: division, initialHand: .right, at: date, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: date)
        XCTAssertEqual(runtime.preset.bpm, 80)
        XCTAssertEqual(runtime.preset.referenceNote, .eighth)
        record(runtime, 160, unit: .sixteenth, date: date)
        XCTAssertEqual(runtime.execution?.ladderStates?[.right]?.repsCompleted, 1)
        record(runtime, 160, unit: .sixteenth, date: date)
        XCTAssertEqual(runtime.preset.bpm, 82)
        XCTAssertEqual(runtime.preset.referenceNote, .eighth)
        let engine = MetronomeEngine(); engine.apply(runtime.preset)
        XCTAssertEqual(engine.effectivePlaybackPreset.bpm, 82)
        XCTAssertEqual(engine.effectivePlaybackPreset.referenceNote, .eighth)
        let state = runtime.execution?.ladderStates?[.right]
        record(runtime, 99, unit: .quarter, date: date)
        XCTAssertEqual(runtime.preset.bpm, 99, "Manual Actual BPM remains editable")
        XCTAssertEqual(runtime.execution?.ladderStates?[.right], state)
        runtime.switchHand(.left, at: date)
        XCTAssertEqual(runtime.preset.bpm, 40)
        XCTAssertEqual(runtime.preset.referenceNote, .quarter)
        runtime.switchHand(.right, at: date)
        XCTAssertEqual(runtime.preset.bpm, 82)
        XCTAssertEqual(runtime.preset.referenceNote, .eighth)
        XCTAssertEqual(runtime.session.completionSamples(for: .right).map { $0.preset.bpm }, [160, 160, 99])
        XCTAssertEqual(runtime.session.completionSamples(for: .right).map { $0.preset.referenceNote }, [.sixteenth, .sixteenth, .quarter])
    }
}


extension PracticeCoreTests {
    func testSkeletonCreateEditDivisionAndGoalAllReturnSinglePieceWorkspace() throws {
        let store = try container(), context = store.mainContext
        let piece = try CoreContracts.savePiece(name: "Workspace", structure: CorePieceStructure(mode: .sections, total: 8),
            context: context, activeSessionID: nil)
        let destination = CorePage.piece(piece.id)
        XCTAssertEqual(try CoreContracts.saveCreatedDivision(piece: piece,
            definition: CoreDivisionDefinition(first: 2, last: 3, handMode: .both), context: context, activeSessionID: nil), destination)
        let division = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
        var definition = try XCTUnwrap(division.coreDefinition)
        definition.last = 4
        XCTAssertEqual(try CoreContracts.saveEditedDivision(piece: piece, division: division, definition: definition,
            context: context, activeSessionID: nil), destination)
        let nav = CoreNavigation()
        for count in [5, 8] {
            let goal = CoreGoal(hands: [.both: CoreHandGoal(count: count)])
            XCTAssertEqual(try CoreContracts.saveGoal(piece: piece.id, division: division, goal: goal,
                context: context, activeSessionID: nil, timing: .current), destination)
            XCTAssertEqual(try CoreContracts.goalSavedReturn(piece: piece.id, division: division), destination)
            nav.path = [destination]
            nav.request(.editDivision(piece: piece.id, division: division.id))
            try nav.goalSaved(piece: piece.id, division: division)
            XCTAssertEqual(nav.path, [destination])
            XCTAssertNil(nav.pendingRoute)
            XCTAssertEqual(division.coreDefinition?.goal?.hands[.both]?.count, count)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertEqual(try CoreContracts.startRoute(piece: piece.id, division: division.id,
            definition: XCTUnwrap(division.coreDefinition), activeSessionID: nil), .startPractice(piece: piece.id, division: division.id))
    }
}

extension PracticeCoreE2ETests {
    func testRevisionUnifiedEditorCommitsRangeHandAndGoalPreservingDormantFacts() throws {
        let store = try container(), context = store.mainContext
        let (piece, division) = try makeDivision(context, handMode: .all)
        let original = try XCTUnwrap(division.coreDefinition)
        let result = try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
            first: 2, last: 3, handMode: .both,
            editedGoal: CoreGoal(hands: [.both: CoreHandGoal(count: 7, speed: CoreTargetSpeed(bpm: 120, noteUnit: .eighth))]),
            context: context, activeSessionID: nil, timing: .current)
        XCTAssertEqual(result, .piece(piece.id))
        let saved = try XCTUnwrap(division.coreDefinition)
        XCTAssertEqual(saved.first, 2); XCTAssertEqual(saved.last, 3)
        XCTAssertEqual(saved.handMode, .both)
        XCTAssertEqual(saved.goal?.hands[.both]?.count, 7)
        XCTAssertEqual(saved.goal?.hands[.both]?.speed?.noteUnit, .eighth)
        XCTAssertEqual(saved.goal?.hands[.left], original.goal?.hands[.left])
        XCTAssertEqual(saved.goal?.hands[.right], original.goal?.hands[.right])
        XCTAssertEqual(saved.ladderStates, original.ladderStates)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
    }

    func testRevisionUnifiedEditorNoGoalCanSaveRangeOrCreateGoal() throws {
        let store = try container(), context = store.mainContext
        let piece = try CoreContracts.savePiece(name: "Combined", structure: CorePieceStructure(mode: .sections, total: 8),
            context: context, activeSessionID: nil)
        _ = try CoreContracts.saveCreatedDivision(piece: piece, definition: CoreDivisionDefinition(first: 1, last: 1, handMode: .both),
            context: context, activeSessionID: nil)
        let division = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: division, first: 2, last: 3, handMode: .both,
            editedGoal: nil, context: context, activeSessionID: nil)
        XCTAssertNil(division.coreDefinition?.goal)
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: division, first: 2, last: 4, handMode: .both,
            editedGoal: CoreGoal(hands: [.both: CoreHandGoal(count: 5)]), context: context, activeSessionID: nil)
        XCTAssertTrue(division.coreDefinition?.hasValidGoal == true)
        XCTAssertEqual(division.coreDefinition?.last, 4)
    }

    func testRevisionUnifiedEditorAtomicFailureAndHAND05() throws {
        let store = try container(), context = store.mainContext
        let (piece, division) = try makeDivision(context, handMode: .both)
        let original = division.coreDefinitionData, name = division.name
        let valid = CoreGoal(hands: [.both: CoreHandGoal(count: 9)])
        for injected in [false, true] {
            XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
                first: 2, last: 3, handMode: .both,
                editedGoal: injected ? valid : CoreGoal(hands: [.both: CoreHandGoal(count: 0)]),
                context: context, activeSessionID: nil, timing: .current,
                saving: { throw CoreFlowError.invalidInput("Injected save failure") }))
            XCTAssertEqual(division.coreDefinitionData, original)
            XCTAssertEqual(division.name, name)
            let fresh = ModelContext(store)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<PracticeEvent>()).first?.coreDefinitionData, original)
        }
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: true, at: start)
        runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
        let route = CoreRoute.editDivision(piece: piece.id, division: division.id)
        try runtime.requestExit(.transition(route))
        XCTAssertTrue(runtime.exitRequest?.saveOnly == true)
        XCTAssertThrowsError(try runtime.resolveExit(.discard, division: division, in: context))
        XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: division, first: 2, last: 3,
            handMode: .both, editedGoal: valid, context: context, activeSessionID: runtime.activeID))
        XCTAssertEqual(try runtime.resolveExit(.save, division: division, in: context, at: start.addingTimeInterval(2)), .route(route))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
    }

    func testRevisionEveryHandEntersPausedAndBackLeavesNoDraftOrFormalFacts() throws {
        for mode in CoreHandMode.allCases {
            let store = try container(), context = store.mainContext
            let (piece, division) = try makeDivision(context, handMode: mode)
            let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
            if mode == .all {
                XCTAssertThrowsError(try runtime.begin(piece: piece, division: division, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true)))
                XCTAssertNil(runtime.context)
            }
            try runtime.begin(piece: piece, division: division, initialHand: mode == .all ? .right : nil, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            XCTAssertFalse(runtime.session.isRunning)
            XCTAssertFalse(runtime.hasStartedPlayback)
            XCTAssertEqual(runtime.session.stats(for: runtime.session.currentHand, at: start.addingTimeInterval(30)).durationMilliseconds, 0)
            runtime.record(preset: preset(100), at: start.addingTimeInterval(30))
            XCTAssertEqual(runtime.count, 0)
            runtime.persist()
            XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
            XCTAssertEqual(try runtime.cancelBeforePlayback(), piece.id)
            XCTAssertNil(runtime.activeID)
            XCTAssertNil(runtime.exitRequest)
            XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        }
    }

    func testRevisionPlaybackCommitPauseResumeAndRecordTiming() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
        try runtime.begin(piece: piece, division: division, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.synchronizePlayback(isPlaying: false, at: start.addingTimeInterval(10)) // unsuccessful start
        XCTAssertFalse(runtime.hasStartedPlayback)
        XCTAssertEqual(runtime.session.stats(for: .both, at: start.addingTimeInterval(20)).durationMilliseconds, 0)
        runtime.synchronizePlayback(isPlaying: true, at: start.addingTimeInterval(20))
        let id = runtime.activeID
        XCTAssertTrue(runtime.hasStartedPlayback)
        XCTAssertTrue(runtime.session.isRunning)
        XCTAssertNotNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
        XCTAssertThrowsError(try runtime.cancelBeforePlayback())
        runtime.record(preset: preset(100), at: start.addingTimeInterval(22))
        runtime.synchronizePlayback(isPlaying: false, at: start.addingTimeInterval(25))
        runtime.record(preset: preset(100), at: start.addingTimeInterval(28))
        XCTAssertEqual(runtime.count, 1)
        XCTAssertEqual(runtime.session.stats(for: .both, at: start.addingTimeInterval(40)).durationMilliseconds, 5_000)
        runtime.synchronizePlayback(isPlaying: true, at: start.addingTimeInterval(40))
        runtime.synchronizePlayback(isPlaying: false, at: start.addingTimeInterval(43))
        XCTAssertEqual(runtime.activeID, id)
        XCTAssertEqual(runtime.session.stats(for: .both, at: start.addingTimeInterval(100)).durationMilliseconds, 8_000)
        let restored = CoreSessionRuntime(defaults: preferences)
        XCTAssertTrue(restored.hasStartedPlayback)
        XCTAssertFalse(restored.session.isRunning)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.session.stats(for: .both, at: start.addingTimeInterval(100)).durationMilliseconds, 8_000)
    }
}


extension PracticeCoreE2ETests {
    func testPhase01AProvisionalAndFailedPlaybackHaveNoSessionIdentityOrSideEffects() throws {
        for mode in CoreHandMode.allCases {
            let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: mode)
            let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
            let original = division.coreDefinitionData
            let hand = mode.directInitialHand ?? .right
            try runtime.begin(piece: piece, division: division, initialHand: hand, at: start, calendar: calendar, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            XCTAssertNil(runtime.activeID)
            XCTAssertNil(runtime.session.startedAt)
            XCTAssertNil(runtime.session.sourceEventID)
            XCTAssertEqual(runtime.session.phase, .idle)
            XCTAssertEqual(runtime.currentHand, hand)
            XCTAssertThrowsError(try runtime.requestExit(.ordinary))
            runtime.resume(at: start.addingTimeInterval(5))
            runtime.record(preset: preset(100), at: start.addingTimeInterval(10))
            var startupCalls = 0
            XCTAssertFalse(try runtime.startPlayback(at: start.addingTimeInterval(20)) {
                startupCalls += 1
                return false // Audio startup failed, not merely a Play tap.
            })
            XCTAssertEqual(startupCalls, 1)
            XCTAssertNil(runtime.activeID)
            XCTAssertNil(runtime.session.startedAt)
            XCTAssertFalse(runtime.hasStartedPlayback)
            XCTAssertEqual(runtime.count, 0)
            XCTAssertEqual(runtime.session.stats(for: hand, at: start.addingTimeInterval(50)).durationMilliseconds, 0)
            XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
            XCTAssertEqual(division.coreDefinitionData, original)
            XCTAssertEqual(try runtime.cancelBeforePlayback(), piece.id)
            XCTAssertNil(runtime.context)
            XCTAssertNil(runtime.exitRequest)
            XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        }
    }

    func testPhase01ACommitTimeIdentityHandClockAndRecoveryUseSuccessfulPlayback() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext)
        let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: start, calendar: calendar, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        runtime.switchHand(.right, at: start.addingTimeInterval(10))
        XCTAssertNil(runtime.activeID)
        XCTAssertEqual(runtime.currentHand, .right)
        let commit = start.addingTimeInterval(20)
        XCTAssertTrue(try runtime.startPlayback(at: commit) { true })
        let identity = try XCTUnwrap(runtime.activeID)
        XCTAssertEqual(runtime.session.startedAt, commit)
        XCTAssertEqual(runtime.session.sourceEventID, division.id)
        runtime.record(preset: preset(100), at: commit.addingTimeInterval(2))
        runtime.synchronizePlayback(isPlaying: true, at: commit.addingTimeInterval(3))
        runtime.pause(at: commit.addingTimeInterval(5))
        runtime.record(preset: preset(100), at: commit.addingTimeInterval(10))
        XCTAssertEqual(runtime.count, 1)
        XCTAssertEqual(runtime.session.stats(for: .right, at: commit.addingTimeInterval(20)).durationMilliseconds, 5_000)
        XCTAssertTrue(try runtime.startPlayback(at: commit.addingTimeInterval(20)) { true })
        runtime.switchHand(.left, at: commit.addingTimeInterval(22))
        runtime.record(preset: preset(80), at: commit.addingTimeInterval(23))
        runtime.pause(at: commit.addingTimeInterval(24))
        XCTAssertEqual(runtime.activeID, identity)
        XCTAssertEqual(runtime.session.startedAt, commit)
        XCTAssertEqual(runtime.session.stats(for: .right, at: commit.addingTimeInterval(50)).durationMilliseconds, 7_000)
        XCTAssertEqual(runtime.session.stats(for: .left, at: commit.addingTimeInterval(50)).durationMilliseconds, 2_000)
        let recovered = CoreSessionRuntime(defaults: preferences)
        XCTAssertEqual(recovered.activeID, identity)
        XCTAssertEqual(recovered.currentHand, .left)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertFalse(recovered.session.isRunning)
        try recovered.requestExit(.ordinary)
        _ = try recovered.resolveExit(.save, division: division, in: store.mainContext, at: commit.addingTimeInterval(60))
        let saved = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<PracticeAttempt>()).first)
        XCTAssertEqual(saved.sessionID, identity)
        XCTAssertEqual(saved.startedAt, commit)
        XCTAssertEqual(saved.completions.map(\.hand), [.right, .left])
        XCTAssertEqual(saved.stats(for: .right).durationMilliseconds, 7_000)
        XCTAssertEqual(saved.stats(for: .left).durationMilliseconds, 2_000)
    }

    func testPhase01APlayedWithoutRecordStillUsesSES04NoHistoryRule() throws {
        for choice in [CoreExitChoice.save, .discard, .cancel] {
            let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
            let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
            try runtime.begin(piece: piece, division: division, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            XCTAssertTrue(try runtime.startPlayback(at: start.addingTimeInterval(20)) { true })
            let identity = runtime.activeID
            try runtime.requestExit(.ordinary)
            _ = try runtime.resolveExit(choice, division: division, in: store.mainContext, at: start.addingTimeInterval(50))
            XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
            if choice == .cancel {
                XCTAssertEqual(runtime.activeID, identity)
                XCTAssertTrue(runtime.session.isRunning)
            } else {
                XCTAssertNil(runtime.activeID)
                XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
            }
        }
    }

    func testPhase01AFirstPlayRevalidatesCycleAfterProvisionalMidnight() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let runtime = CoreSessionRuntime(defaults: defaults())
        let midnight = calendar.startOfDay(for: start)
        let entry = midnight.addingTimeInterval(86_399)
        let commit = midnight.addingTimeInterval(86_405)
        try runtime.begin(piece: piece, division: division, at: entry, calendar: calendar, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
        XCTAssertEqual(runtime.context?.cycleStart, midnight)
        XCTAssertTrue(try runtime.startPlayback(at: commit) { true })
        XCTAssertEqual(runtime.context?.cycleStart, calendar.startOfDay(for: commit))
        XCTAssertEqual(runtime.session.startedAt, commit)
        XCTAssertEqual(runtime.session.stats(for: .both, at: commit).durationMilliseconds, 0)
    }

    func testPhase01AAtomicEditorFailureRetryAndBothSourceReturnsPreserveHistory() throws {
        for fromDivision in [false, true] {
            let store = try container(), context = store.mainContext
            let (piece, division) = try makeDivision(context, handMode: .all)
            let runtime = CoreSessionRuntime(defaults: defaults())
            try runtime.begin(piece: piece, division: division, initialHand: .left, at: start, activation: CoreLadderActivation(enabled: division.coreDefinition?.goal?.ladderEnabled == true, isPro: true))
            XCTAssertTrue(try runtime.startPlayback(at: start) { true })
            runtime.record(preset: preset(90), at: start.addingTimeInterval(1))
            runtime.finish(at: start.addingTimeInterval(2))
            let history = try runtime.save(division: division, in: context)
            let historicalContext = history.coreContextData, samples = history.completions
            let before = division.coreDefinitionData
            let source: CorePage = fromDivision ? .division(piece: piece.id, division: division.id) : .piece(piece.id)
            let navigation = CoreNavigation()
            navigation.path = fromDivision ? [.piece(piece.id), source] : [source]
            let sourcePath = navigation.path
            navigation.request(.editDivision(piece: piece.id, division: division.id))
            let goal = CoreGoal(hands: [.both: CoreHandGoal(count: 8, speed: CoreTargetSpeed(bpm: 120))])
            XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
                first: 2, last: 4, handMode: .both, editedGoal: goal, context: context,
                activeSessionID: nil, timing: .current, saving: { throw CoreFlowError.invalidInput("Disk unavailable") }))
            XCTAssertEqual(division.coreDefinitionData, before)
            XCTAssertEqual(navigation.path, sourcePath)
            XCTAssertNotNil(navigation.pendingRoute)
            var saves = 0
            let page = try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
                first: 2, last: 4, handMode: .both, editedGoal: goal, context: context,
                activeSessionID: nil, timing: .current, saving: {
                    saves += 1
                    XCTAssertEqual(try ModelContext(store).fetch(FetchDescriptor<PracticeEvent>()).first?.coreDefinitionData, before)
                    try context.save()
                })
            navigation.editorSaved(page)
            XCTAssertEqual(saves, 1)
            XCTAssertEqual(navigation.path, sourcePath)
            XCTAssertNil(navigation.pendingRoute)
            XCTAssertEqual(division.coreDefinition?.first, 2)
            XCTAssertEqual(division.coreDefinition?.last, 4)
            XCTAssertEqual(division.coreDefinition?.handMode, .both)
            XCTAssertEqual(division.coreDefinition?.goal?.hands[.both]?.count, 8)
            XCTAssertEqual(history.coreContextData, historicalContext)
            XCTAssertEqual(history.completions, samples)
            XCTAssertEqual(CoreAnalysis.stable([history], hand: .left), 90)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
            navigation.enteredPractice(piece: piece.id, division: division.id)
            XCTAssertEqual(navigation.path, [])
            navigation.returnedBeforePlayback(piece: piece.id)
            XCTAssertEqual(navigation.path, sourcePath)
        }
    }
}

extension PracticeCoreE2ETests {
    private func globalFixture(_ context: ModelContext, pending: Bool = false, openOnly: Bool = false) throws -> (PracticeSong, PracticeEvent) {
        let (piece, event) = try makeDivision(context, handMode: .both)
        var value = try XCTUnwrap(event.coreDefinition)
        value.goal = CoreGoal(hands: [.both: CoreHandGoal(count: openOnly ? nil : 5,
            speed: openOnly ? nil : CoreTargetSpeed(bpm: 108),
            ladder: CoreLadderConfiguration(startBPM: 100, stepBPM: 3, repsPerLevel: 2),
            ladderParticipation: pending ? false : nil)], ladderEnabled: true)
        value.ladderStates = [.both: CoreLadderState(cycleStart: calendar.startOfDay(for: start), cycleStartBPM: 100,
            currentBPM: 106, repsCompleted: 1, noteUnit: .quarter, firstValidRecordAt: start,
            previousValidBPM: 106, activationEpoch: 1)]
        event.coreDefinitionData = try JSONEncoder().encode(value); try context.save()
        return (piece, event)
    }
    private var globalOn: CoreLadderActivation { CoreLadderActivation(enabled: true, isPro: true, epoch: 1) }

    func testPhase01BGlobalDefaultOffProGatePersistenceAndEpoch() {
        let preferences = defaults(), settings = CorePracticeSettings(defaults: preferences)
        XCTAssertFalse(settings.ladderEnabled); XCTAssertEqual(settings.ladderEpoch, 0)
        settings.setLadderEnabled(true, isPro: false)
        XCTAssertFalse(settings.ladderEnabled)
        settings.setLadderEnabled(true, isPro: true)
        XCTAssertTrue(settings.activation(isPro: true).enabled)
        XCTAssertFalse(settings.activation(isPro: false).enabled)
        XCTAssertEqual(CorePracticeSettings(defaults: preferences).ladderEpoch, 1)
        settings.setLadderEnabled(false, isPro: true)
        settings.setLadderEnabled(true, isPro: true)
        XCTAssertEqual(settings.ladderEpoch, 2)
    }

    func testPhase01BOffOpenOnlyBlockedWithoutDeletingConfiguration() throws {
        let store = try container(), (piece, event) = try globalFixture(store.mainContext, openOnly: true)
        let bytes = event.coreDefinitionData, runtime = CoreSessionRuntime(defaults: defaults())
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, at: start, activation: CoreLadderActivation()))
        XCTAssertNil(runtime.activeID); XCTAssertNil(runtime.context)
        XCTAssertEqual(event.coreDefinitionData, bytes)
        try runtime.begin(piece: piece, division: event, at: start, activation: globalOn)
        XCTAssertEqual(runtime.preset.bpm, 106)
        XCTAssertFalse(runtime.hasStartedPlayback)
    }

    func testPhase01BActiveSnapshotOffRecordingAndRestartNewOrigin() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try globalFixture(context)
        let runtime = CoreSessionRuntime(defaults: defaults()), preferences = CorePracticeSettings(defaults: defaults())
        preferences.setLadderEnabled(true, isPro: true)
        try runtime.begin(piece: piece, division: event, at: start, activation: preferences.activation(isPro: true))
        XCTAssertTrue(try runtime.startPlayback(at: start, using: { true }))
        preferences.setLadderEnabled(false, isPro: true)
        runtime.record(preset: preset(106), at: start.addingTimeInterval(1))
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 108)
        try runtime.requestExit(.ordinary)
        _ = try runtime.resolveExit(.save, division: event, in: context, at: start.addingTimeInterval(2))
        let formal = event.coreDefinition?.ladderStates
        try runtime.begin(piece: piece, division: event, at: start.addingTimeInterval(3), activation: preferences.activation(isPro: true))
        XCTAssertFalse(runtime.context?.goal.ladderEnabled == true)
        XCTAssertNil(runtime.context?.goal.hands[.both]?.ladder)
        _ = try runtime.startPlayback(at: start.addingTimeInterval(3), using: { true })
        runtime.record(preset: preset(150), at: start.addingTimeInterval(4))
        try runtime.requestExit(.ordinary)
        _ = try runtime.resolveExit(.save, division: event, in: context, at: start.addingTimeInterval(5))
        XCTAssertEqual(event.coreDefinition?.ladderStates, formal)
        preferences.setLadderEnabled(true, isPro: true)
        let onAgain = preferences.activation(isPro: true)
        XCTAssertEqual(try CoreSessionRuntime.prepare(division: event, at: start, activation: onAgain).needsStart, [.both])
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, at: start, activation: onAgain))
        try runtime.begin(piece: piece, division: event, at: start, confirmedStarts: [.both: 90], activation: onAgain)
        XCTAssertEqual(runtime.preset.bpm, 90)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, 0)
        XCTAssertNil(runtime.execution?.ladderStates?[.both]?.firstValidRecordAt)
        XCTAssertEqual(event.coreDefinition?.ladderStates, formal)
        _ = try runtime.cancelBeforePlayback()
        XCTAssertEqual(event.coreDefinition?.ladderStates, formal)
    }

    func testPhase01BLegacyPendingOnlyExplicitAtomicConfirmationWithFailureRetry() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try globalFixture(context, pending: true)
        let state = event.coreDefinition?.ladderStates
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, at: start, activation: globalOn)
        XCTAssertNil(runtime.context?.goal.hands[.both]?.ladder)
        _ = try runtime.cancelBeforePlayback()
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: event, first: 1, last: 8, handMode: .both,
            editedGoal: nil, context: context, activeSessionID: nil, isPro: true, activation: globalOn)
        XCTAssertTrue(event.coreDefinition?.goal?.hands[.both]?.needsLadderConfirmation == true)
        let original = event.coreDefinitionData
        XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: event, first: 2, last: 8, handMode: .both,
            editedGoal: nil, context: context, activeSessionID: nil, isPro: true, activation: globalOn,
            confirmedHands: [.both], saving: { throw CoreFlowError.invalidInput("Injected disk failure") }))
        XCTAssertEqual(event.coreDefinitionData, original)
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: event, first: 2, last: 8, handMode: .both,
            editedGoal: nil, context: context, activeSessionID: nil, isPro: true, activation: globalOn, confirmedHands: [.both])
        XCTAssertFalse(event.coreDefinition?.goal?.hands[.both]?.needsLadderConfirmation == true)
        XCTAssertEqual(event.coreDefinition?.ladderStates, state)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, at: start, activation: globalOn))
        try runtime.begin(piece: piece, division: event, at: start, confirmedStarts: [.both: 95], activation: globalOn)
        XCTAssertEqual(runtime.preset.bpm, 95); XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.repsCompleted, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
    }

    func testPhase01BLegacyOpenOnlyPendingCannotExecuteAndNilIsNotOptOut() throws {
        let store = try container(), (piece, event) = try globalFixture(store.mainContext, pending: true, openOnly: true)
        XCTAssertFalse(try XCTUnwrap(event.coreDefinition).canStart(activation: globalOn))
        XCTAssertThrowsError(try CoreSessionRuntime(defaults: defaults()).begin(piece: piece, division: event, at: start, activation: globalOn))
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.goal?.hands[.both]?.ladderParticipation = nil
        XCTAssertTrue(definition.canStart(activation: globalOn), "Missing legacy evidence is not an explicit opt-out")
        let data = try JSONEncoder().encode(definition)
        XCTAssertNil(try JSONDecoder().decode(CoreDivisionDefinition.self, from: data).goal?.hands[.both]?.ladderParticipation)
    }

    func testPhase01BConfirmationIsolationCopyAndInvalidAtomicRollback() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context, handMode: .all)
        var definition = try XCTUnwrap(event.coreDefinition)
        let ladder = CoreLadderConfiguration(startBPM: 40, stepBPM: 2, repsPerLevel: 3)
        definition.goal = CoreGoal(hands: Dictionary(uniqueKeysWithValues: PracticeHand.allCases.map {
            ($0, CoreHandGoal(count: 5, ladder: ladder, ladderParticipation: false))
        }), ladderEnabled: true)
        event.coreDefinitionData = try JSONEncoder().encode(definition); try context.save()
        var copy = try CoreContracts.copyLeftLadderToRight(in: XCTUnwrap(definition.goal), mode: .all)
        XCTAssertTrue(copy.hands[.right]?.needsLadderConfirmation == true)
        XCTAssertNil(copy.hands[.right]?.ladderConfigurationConfirmed)
        copy.hands[.left]?.ladder?.stepBPM = 21
        XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: event, first: 1, last: 8,
            handMode: .all, editedGoal: copy, context: context, activeSessionID: nil, isPro: true,
            timing: .current, activation: globalOn, confirmedHands: [.left]))
        XCTAssertEqual(event.coreDefinition, definition)
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: event, first: 1, last: 8,
            handMode: .all, editedGoal: nil, context: context, activeSessionID: nil, isPro: true,
            activation: globalOn, confirmedHands: [.left])
        XCTAssertFalse(event.coreDefinition?.goal?.hands[.left]?.needsLadderConfirmation == true)
        XCTAssertTrue(event.coreDefinition?.goal?.hands[.right]?.needsLadderConfirmation == true)
        XCTAssertTrue(event.coreDefinition?.goal?.hands[.both]?.needsLadderConfirmation == true)
    }

    func testPhase01BGlobalOverridesGoalSwitchButKeepsFreeGateAndPerHandHandoff() throws {
        let store = try container(), context = store.mainContext
        let (piece, event) = try makeDivision(context, handMode: .all)
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.goal = CoreGoal(hands: [
            .left: CoreHandGoal(count: 5, ladder: CoreLadderConfiguration(startBPM: 40, stepBPM: 2, repsPerLevel: 3)),
            .right: CoreHandGoal(count: 5, ladder: CoreLadderConfiguration(startBPM: 70, stepBPM: 4, repsPerLevel: 2)),
            .both: CoreHandGoal(count: 5)
        ], ladderEnabled: false)
        definition.ladderConfigurationEpochs = [.left: 1, .right: 1]
        event.coreDefinitionData = try JSONEncoder().encode(definition); try context.save()
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, activation: globalOn)
        XCTAssertEqual(runtime.preset.bpm, 40)
        _ = try runtime.startPlayback(at: start, using: { true })
        let id = runtime.activeID
        runtime.switchHand(.right, at: start)
        XCTAssertEqual(runtime.preset.bpm, 70)
        runtime.switchHand(.both, at: start)
        XCTAssertEqual(runtime.preset.bpm, 70, "No configured Ladder means no BPM handoff")
        XCTAssertEqual(runtime.activeID, id)
        try runtime.requestExit(.ordinary)
        _ = try runtime.resolveExit(.discard, division: event, in: context)
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start,
            activation: CoreLadderActivation(enabled: true, isPro: false, epoch: 1))
        XCTAssertNil(runtime.context?.goal.hands[.left]?.ladder)
    }
}


extension PracticeCoreE2ETests {
    func testAuthorityCorrectionFinalShortStepAtomicSaveRetryPreservesHistory() throws {
        let store = try container(), context = store.mainContext
        let (piece, division) = try globalFixture(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, activation: globalOn)
        _ = try runtime.startPlayback(at: start, using: { true })
        runtime.record(preset: preset(106), at: start.addingTimeInterval(1))
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 108)
        try runtime.requestExit(.ordinary)
        _ = try runtime.resolveExit(.save, division: division, in: context, at: start.addingTimeInterval(2))
        let history = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeAttempt>()).first)
        let samples = history.completions, historicalContext = history.coreContextData
        let original = division.coreDefinitionData, states = division.coreDefinition?.ladderStates
        var edited = try XCTUnwrap(division.coreDefinition?.goal)
        edited.hands[.both]?.count = 7
        XCTAssertTrue(edited.hands[.both]?.ladder?.isValid(target: CoreTargetSpeed(bpm: 108)) == true)
        XCTAssertThrowsError(try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
            first: 2, last: 8, handMode: .both, editedGoal: edited, context: context,
            activeSessionID: nil, isPro: true, timing: .current, activation: globalOn,
            saving: { throw CoreFlowError.invalidInput("Injected disk failure") }))
        XCTAssertEqual(division.coreDefinitionData, original)
        XCTAssertEqual(history.completions, samples); XCTAssertEqual(history.coreContextData, historicalContext)
        _ = try CoreContracts.saveDivisionAndGoal(piece: piece, division: division,
            first: 2, last: 8, handMode: .both, editedGoal: edited, context: context,
            activeSessionID: nil, isPro: true, timing: .current, activation: globalOn)
        XCTAssertEqual(division.coreDefinition?.first, 2)
        XCTAssertEqual(division.coreDefinition?.goal?.hands[.both]?.count, 7)
        XCTAssertEqual(division.coreDefinition?.goal?.hands[.both]?.speed?.bpm, 108)
        XCTAssertEqual(division.coreDefinition?.ladderStates, states)
        XCTAssertEqual(history.completions, samples); XCTAssertEqual(history.coreContextData, historicalContext)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testAuthorityCorrectionSavedFinalShortStepConfigurationRemainsExecutableWithoutRewrite() throws {
        let store = try container(), context = store.mainContext
        let (piece, division) = try globalFixture(context)
        let definition = try XCTUnwrap(division.coreDefinition)
        let bytes = division.coreDefinitionData, facts = definition.ladderStates
        XCTAssertTrue(try XCTUnwrap(definition.goal).isValid(for: .both))
        XCTAssertNotNil(definition.executionGoal(activation: globalOn)?.hands[.both]?.ladder)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, activation: globalOn)
        XCTAssertEqual(runtime.preset.bpm, 106)
        XCTAssertNotNil(runtime.context?.goal.hands[.both]?.ladder)
        _ = try runtime.cancelBeforePlayback()
        XCTAssertEqual(division.coreDefinitionData, bytes)
        XCTAssertEqual(division.coreDefinition?.ladderStates, facts)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertFalse(context.hasChanges)
    }
}

extension PracticeCoreE2ETests {
    func testFocusDefaultProGatePersistenceAndCapturedSessionSetting() throws {
        let preferences = defaults(), settings = CorePracticeSettings(defaults: preferences)
        XCTAssertTrue(settings.focusActivation(isPro: true))
        XCTAssertFalse(settings.focusActivation(isPro: false))
        settings.setFocusEnabled(false, isPro: false)
        XCTAssertTrue(settings.focusEnabled)
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: settings.focusActivation(isPro: true))
        settings.setFocusEnabled(false, isPro: true)
        XCTAssertFalse(CorePracticeSettings(defaults: preferences).focusEnabled)
        XCTAssertTrue(try runtime.startPlayback(at: start) { true })
        XCTAssertTrue(runtime.isFocusEnabled)
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(10)), 10_000)
        let next = CoreSessionRuntime(defaults: defaults())
        try next.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: settings.focusActivation(isPro: true))
        XCTAssertTrue(try next.startPlayback(at: start) { true })
        XCTAssertEqual(next.focusDurationMilliseconds(at: start.addingTimeInterval(10)), 0)
        XCTAssertEqual(next.practiceDurationMilliseconds(at: start.addingTimeInterval(10)), 10_000)
    }

    func testFocusFirstSuccessfulPlayPauseResumeAndHandContinuity() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, initialHand: .left, at: start, calendar: calendar, focusEnabled: true)
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), 0)
        XCTAssertFalse(try runtime.startPlayback(at: start.addingTimeInterval(10)) { false })
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), 0)
        XCTAssertTrue(try runtime.startPlayback(at: start.addingTimeInterval(20)) { true })
        let id = runtime.activeID
        runtime.synchronizePlayback(isPlaying: true, at: start.addingTimeInterval(22))
        runtime.switchHand(.right, at: start.addingTimeInterval(25))
        runtime.pause(at: start.addingTimeInterval(30))
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(60)), 10_000)
        runtime.resume(at: start.addingTimeInterval(60))
        runtime.switchHand(.both, at: start.addingTimeInterval(65))
        runtime.pause(at: start.addingTimeInterval(70))
        XCTAssertEqual(runtime.activeID, id)
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), 20_000)
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), runtime.practiceDurationMilliseconds(at: start.addingTimeInterval(100)))
    }

    func testFocusRecoveryExcludesDowntimeAndRetainsSnapshot() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: true)
        XCTAssertTrue(try runtime.startPlayback(at: start) { true })
        runtime.record(preset: preset(100), at: start.addingTimeInterval(2))
        runtime.persist(at: start.addingTimeInterval(7))
        let restored = CoreSessionRuntime(defaults: preferences)
        XCTAssertEqual(restored.activeID, runtime.activeID)
        XCTAssertTrue(restored.isFocusEnabled)
        XCTAssertFalse(restored.session.isRunning)
        XCTAssertEqual(restored.focusDurationMilliseconds(at: start.addingTimeInterval(1000)), 7_000)
        restored.resume(at: start.addingTimeInterval(1000))
        restored.pause(at: start.addingTimeInterval(1003))
        XCTAssertEqual(restored.focusDurationMilliseconds(at: start.addingTimeInterval(2000)), 10_000)
    }

    func testFocusSavedFactPersistenceFailureRetryAndLegacyAbsence() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: true)
        XCTAssertTrue(try runtime.startPlayback(at: start) { true })
        runtime.record(preset: preset(100), at: start.addingTimeInterval(2))
        runtime.pause(at: start.addingTimeInterval(8))
        try runtime.requestExit(.ordinary)
        XCTAssertThrowsError(try runtime.resolveExit(.save, division: division, in: store.mainContext, at: start.addingTimeInterval(20), saving: { throw CoreFlowError.noRecording }))
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(25)), 8_000)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        _ = try runtime.resolveExit(.save, division: division, in: store.mainContext, at: start.addingTimeInterval(30))
        let saved = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<PracticeAttempt>()).first)
        XCTAssertEqual(saved.coreContext?.focusDurationMilliseconds, 8_000)
        XCTAssertEqual(saved.coreContext?.focusEnabled, true)
        let original = saved.coreContextData
        CorePracticeSettings(defaults: defaults()).setFocusEnabled(false, isPro: true)
        XCTAssertEqual(saved.coreContextData, original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original)) as? [String: Any])
        legacy.removeValue(forKey: "focusEnabled"); legacy.removeValue(forKey: "focusDurationMilliseconds")
        let decoded = try JSONDecoder().decode(CoreSessionContext.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.focusEnabled); XCTAssertNil(decoded.focusDurationMilliseconds)
    }

    func testFocusCancelDiscardAndPreplayBackDoNotManufactureFacts() throws {
        let store = try container(), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
        let preferences = defaults(), runtime = CoreSessionRuntime(defaults: preferences)
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: true)
        _ = try runtime.cancelBeforePlayback()
        XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: true)
        XCTAssertTrue(try runtime.startPlayback(at: start) { true })
        runtime.record(preset: preset(100), at: start.addingTimeInterval(2))
        runtime.pause(at: start.addingTimeInterval(5))
        try runtime.requestExit(.ordinary)
        XCTAssertNil(try runtime.resolveExit(.cancel, division: division, in: store.mainContext))
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(50)), 5_000)
        try runtime.requestExit(.ordinary)
        _ = try runtime.resolveExit(.discard, division: division, in: store.mainContext)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        XCTAssertNil(preferences.data(forKey: CoreSessionRuntime.draftKey))
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), 0)
    }
}

extension PracticeCoreE2ETests {
    func testFocusOnPreservesLadderProgressionAndIndependentPlaybackPause() throws {
        let store = try container(), (piece, division) = try globalFixture(store.mainContext)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, activation: globalOn, focusEnabled: true)
        XCTAssertTrue(try runtime.startPlayback(at: start) { true })
        let id = runtime.activeID
        runtime.record(preset: preset(106), at: start.addingTimeInterval(1))
        XCTAssertEqual(runtime.preset.bpm, 108) // Final short step still holds.
        runtime.pause(at: start.addingTimeInterval(4)) // Explicit independent detachment boundary.
        let independent = CoreSessionRuntime(defaults: defaults())
        independent.synchronizePlayback(isPlaying: true, at: start.addingTimeInterval(5))
        independent.record(preset: preset(200), at: start.addingTimeInterval(7))
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(50)), 4_000)
        XCTAssertEqual(runtime.count, 1); XCTAssertEqual(independent.count, 0)
        runtime.resume(at: start.addingTimeInterval(50))
        runtime.pause(at: start.addingTimeInterval(52))
        XCTAssertEqual(runtime.activeID, id)
        XCTAssertEqual(runtime.focusDurationMilliseconds(at: start.addingTimeInterval(100)), 6_000)
        XCTAssertEqual(runtime.execution?.ladderStates?[.both]?.currentBPM, 108)
    }

    func testFocusSavedFactSurvivesDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Focus.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        do {
            let store = try container(url: url), (piece, division) = try makeDivision(store.mainContext, handMode: .both)
            let runtime = CoreSessionRuntime(defaults: defaults())
            try runtime.begin(piece: piece, division: division, at: start, calendar: calendar, focusEnabled: true)
            XCTAssertTrue(try runtime.startPlayback(at: start) { true })
            runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
            runtime.pause(at: start.addingTimeInterval(3))
            try runtime.requestExit(.ordinary)
            _ = try runtime.resolveExit(.save, division: division, in: store.mainContext, at: start.addingTimeInterval(10))
        }
        let reopened = try container(url: url)
        let facts = try reopened.mainContext.fetch(FetchDescriptor<PracticeAttempt>())
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.coreContext?.focusDurationMilliseconds, 3_000)
        XCTAssertEqual(facts.first?.coreContext?.focusEnabled, true)
    }
}

@MainActor
final class CoreTargetCompletionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }
    private var day: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_467_200)) }
    private func definition(_ mode: CoreHandMode = .both, count: Int? = 5, speed: Int? = 100) -> CoreDivisionDefinition {
        CoreDivisionDefinition(first: 1, last: 8, handMode: mode,
            goal: CoreGoal(hands: Dictionary(uniqueKeysWithValues: mode.hands.map {
                ($0, CoreHandGoal(count: count, speed: speed.map { CoreTargetSpeed(bpm: $0) }))
            }), reset: CoreResetConfiguration(anchor: day)), executionCycleStart: day)
    }
    private func attempt(_ definition: CoreDivisionDefinition, hand: PracticeHand = .both,
                         count: Int = 3, bpm: Int = 100, cycle: Date? = nil, source: String = "planned") throws -> PracticeAttempt {
        let cycle = cycle ?? day
        let id = UUID()
        var preset = MetronomePreset.standard; preset.bpm = bpm
        let samples = (0..<count).map { PracticeCompletionSample(hand: hand, preset: preset, completedAt: cycle.addingTimeInterval(Double($0 + 1))) }
        let attempt = PracticeAttempt(eventID: id, summary: PracticeSessionSummary(startedAt: cycle,
            finishedAt: cycle.addingTimeInterval(10),
            left: HandPracticeStats(count: hand == .left ? count : 0),
            right: HandPracticeStats(count: hand == .right ? count : 0),
            both: HandPracticeStats(count: hand == .both ? count : 0), completions: samples))
        attempt.coreContextData = try JSONEncoder().encode(CoreSessionContext(pieceID: UUID(), divisionID: id,
            pieceName: "Test", divisionName: "Test", handMode: definition.handMode, goal: definition.goal!,
            cycleStart: cycle, timeZoneID: calendar.timeZone.identifier, source: source))
        return attempt
    }

    func testT06DualFiniteMissingDimensionNeverReweightsOrZeroFills() {
        let target = CoreHandGoal(count: 5, speed: CoreTargetSpeed(bpm: 100))
        let value = CoreTargetCompletion.hand(target: target, actualCount: 3, stableSpeed: nil)
        XCTAssertEqual(value.count, 0.6)
        XCTAssertNil(value.speed); XCTAssertNil(value.combined)
        XCTAssertEqual(CoreTargetCompletion.percentage(value.combined), "暂无法计算（N/A）")
        XCTAssertEqual(CoreTargetCompletion.percentage(value.count), "60%")
        XCTAssertNil(CoreTargetCompletion.hand(target: target, actualCount: nil, stableSpeed: 100).combined)
    }

    func testFiniteDimensionsCapIndependentlyAndRetainActualOverrun() throws {
        let target = CoreHandGoal(count: 5, speed: CoreTargetSpeed(bpm: 100))
        let value = CoreTargetCompletion.hand(target: target, actualCount: 7, stableSpeed: 50)
        XCTAssertEqual(value.actualCount, 7); XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value.speed, 0.5); XCTAssertEqual(value.combined, 0.75)
        XCTAssertEqual(CoreTargetCompletion.hand(target: target, actualCount: 7, stableSpeed: 200).combined, 1)
    }

    func testSingleFiniteTargetsOpenEndedAndInvalidInputs() {
        XCTAssertEqual(CoreTargetCompletion.hand(target: CoreHandGoal(count: 5), actualCount: 3, stableSpeed: nil).combined, 0.6)
        XCTAssertEqual(CoreTargetCompletion.hand(target: CoreHandGoal(speed: CoreTargetSpeed(bpm: 160, noteUnit: .eighth)), actualCount: nil, stableSpeed: 40).combined, 0.5)
        let open = CoreHandGoal(ladder: CoreLadderConfiguration(startBPM: 80, stepBPM: 4, repsPerLevel: 3))
        XCTAssertNil(CoreTargetCompletion.hand(target: open, actualCount: 20, stableSpeed: 100).combined)
        XCTAssertNil(CoreTargetCompletion.hand(target: CoreHandGoal(count: 0), actualCount: 1, stableSpeed: 100).combined)
        for value in [Double.nan, Double.infinity, 0, -1] {
            XCTAssertNil(CoreTargetCompletion.hand(target: CoreHandGoal(speed: CoreTargetSpeed(bpm: 100)), actualCount: 0, stableSpeed: value).combined)
        }
        XCTAssertEqual(CoreTargetCompletion.hand(target: CoreHandGoal(count: 5), actualCount: 0, stableSpeed: nil).combined, 0)
    }

    func testT07ApplicableHandsPropagateNAAndTogetherIgnoresDormantHands() throws {
        let all = definition(.all)
        let saved = try attempt(all)
        let result = CoreTargetCompletion.division(definition: all, attempts: [saved], now: day.addingTimeInterval(30), calendar: calendar)
        XCTAssertNotNil(result.hands[.both]?.combined); XCTAssertNil(result.hands[.left]?.combined)
        XCTAssertNil(result.combined)
        var together = all; together.handMode = .both
        let single = CoreTargetCompletion.division(definition: together, attempts: [saved], now: day.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(single.hands.count, 1); XCTAssertEqual(single.combined, 0.8)
        XCTAssertNil(CoreTargetCompletion.division(definition: together, attempts: [saved], isCurrent: false).combined)
    }

    func testMultiHandCompletionUsesEqualWeightsAndDoesNotChangeWeakness() throws {
        let d = definition(.all, count: nil)
        let saved = try [attempt(d, hand: .left, bpm: 20), attempt(d, hand: .right, bpm: 40), attempt(d, hand: .both, bpm: 100)]
        let before = CoreAnalysis.divisionMastery(saved, definition: d, now: day.addingTimeInterval(30))
        let completion = CoreTargetCompletion.division(definition: d, attempts: saved, now: day.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(completion.combined), (0.2 + 0.4 + 1) / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(before), 0.65, accuracy: 0.00001)
        XCTAssertEqual(CoreAnalysis.divisionMastery(saved, definition: d, now: day.addingTimeInterval(30)), before)
    }

    func testResetMultiDayOffAndCrossMidnightUseCapturedCycle() throws {
        var d = definition(count: 5, speed: nil)
        let saved = try attempt(d)
        let tomorrow = day.addingTimeInterval(86400 + 30)
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: tomorrow, calendar: calendar).combined, 0)
        d.goal?.reset?.days = 3
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: tomorrow, calendar: calendar).combined, 0.6)
        d.goal?.reset?.enabled = false
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: day.addingTimeInterval(10 * 86400), calendar: calendar).combined, 0.6)
        // A completion saved after midnight still belongs to its captured cycle.
        saved.finishedAt = tomorrow
        d.goal?.reset?.enabled = true; d.goal?.reset?.days = 1
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: tomorrow, calendar: calendar).combined, 0)
    }

    func testPendingAnalyzeChoiceAndCycleProjectionNeverMutateFacts() throws {
        var d = definition(count: 5, speed: nil)
        let saved = try attempt(d)
        d.nextCycleGoal = CoreGoal(hands: [.both: CoreHandGoal(count: 10)])
        d.nextCycleAnalyzeTiming = .nextCycle
        let bytes = saved.coreContextData
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: day.addingTimeInterval(30), calendar: calendar).combined, 0.6)
        d.nextCycleAnalyzeTiming = .immediately
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [saved], now: day.addingTimeInterval(30), calendar: calendar).combined, 0.3)
        XCTAssertEqual(saved.coreContextData, bytes); XCTAssertEqual(d.goal?.hands[.both]?.count, 5)
    }

    func testPieceFullCoverageWeightedAndGapOverlapUnknownOrNARejectPercent() throws {
        var first = definition(count: 5, speed: nil); first.last = 2
        var second = first; second.first = 3; second.last = 8
        let half = CoreDivisionTargetCompletion(goal: first.goal, hands: [:], combined: 0.5)
        let done = CoreDivisionTargetCompletion(goal: second.goal, hands: [:], combined: 1)
        let missing = CoreDivisionTargetCompletion(goal: second.goal, hands: [:], combined: nil)
        let structure = CorePieceStructure(mode: .measures, total: 8)
        let result = CoreTargetCompletion.piece(structure: structure, divisions: [(first, half), (second, done)])
        XCTAssertEqual(result.combined, 0.875); XCTAssertEqual(result.achievedCount, 1); XCTAssertEqual(result.inProgressCount, 1)
        let na = CoreTargetCompletion.piece(structure: structure, divisions: [(first, half), (second, missing)])
        XCTAssertNil(na.combined); XCTAssertEqual(na.unavailableCount, 1)
        XCTAssertNil(CoreTargetCompletion.piece(structure: structure, divisions: [(first, done)]).combined)
        second.first = 2
        XCTAssertNil(CoreTargetCompletion.piece(structure: structure, divisions: [(first, done), (second, done)]).combined)
        XCTAssertNil(CoreTargetCompletion.piece(structure: CorePieceStructure(mode: .sections), divisions: [(first, done)]).combined)
        XCTAssertNil(CoreTargetCompletion.piece(structure: structure, divisions: [(first, done)], isCurrent: false).combined)
    }

    func testT06T07PersistedCountWithoutSpeedEvidenceRendersNAForFreeAndPro() async throws {
        let schema = Schema([PracticeSong.self, PracticeEvent.self, PracticeAttempt.self, PracticeDailyGoal.self, PracticeFolder.self])
        let store = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let piece = try CoreContracts.savePiece(name: "A12 完成度验证", structure: CorePieceStructure(mode: .measures, total: 8), context: store.mainContext, activeSessionID: nil)
        var d = definition(); d.goal?.reset?.enabled = false
        _ = try CoreContracts.saveCreatedDivision(piece: piece, definition: d, context: store.mainContext, activeSessionID: nil)
        let event = try XCTUnwrap(store.mainContext.fetch(FetchDescriptor<PracticeEvent>()).first)
        let record = PracticeAttempt(eventID: event.id, summary: PracticeSessionSummary(startedAt: day,
            finishedAt: day.addingTimeInterval(10), both: HandPracticeStats(count: 3)))
        record.coreContextData = try JSONEncoder().encode(CoreSessionContext(pieceID: piece.id, divisionID: event.id,
            pieceName: piece.name, divisionName: event.name, handMode: .both, goal: d.goal!, cycleStart: day,
            timeZoneID: calendar.timeZone.identifier))
        store.mainContext.insert(record); try store.mainContext.save()
        let facts = record.coreContextData
        let result = CoreTargetCompletion.division(definition: d, attempts: [record], now: day.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(result.hands[.both]?.count, 0.6)
        XCTAssertNil(result.hands[.both]?.speed); XCTAssertNil(result.hands[.both]?.combined); XCTAssertNil(result.combined)
        let pieceResult = CoreTargetCompletion.piece(piece, events: [event], attempts: [record], now: day.addingTimeInterval(30), calendar: calendar)
        XCTAssertNil(pieceResult.combined); XCTAssertEqual(pieceResult.unavailableCount, 1)
        for (name, pro, large) in [("Free", false, false), ("Pro", true, false), ("Free-Large", false, true)] {
            let defaults = UserDefaults(suiteName: "TargetCompletionUI.\(UUID())")!
            defaults.set(pro, forKey: "rovia.debug.testProEnabled")
            let subscription = SubscriptionStore(observesTransactions: false, defaults: defaults)
            let host = UIHostingController(rootView: CoreAnalyzeView(scope: .piece(piece.id))
                .modelContainer(store).environmentObject(subscription).preferredColorScheme(.light)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: large ? 320 : 390, height: 1600))
            window.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraExtraLarge : .large
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Phase02A-T06-T07-\(name)"; attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(image.size.width, 0)
            window.isHidden = true
        }
        XCTAssertEqual(record.coreContextData, facts)
        XCTAssertEqual(record.bothCount, 3)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PracticeAttempt>()), 1)
    }

    func testIndependentLegacyAndFutureFactsDoNotEnterCurrentCompletion() throws {
        let d = definition(count: 5, speed: nil)
        let independent = try attempt(d, source: "independent")
        let legacy = try attempt(d); legacy.coreContextData = nil
        let future = try attempt(d, cycle: day.addingTimeInterval(86400))
        XCTAssertEqual(CoreTargetCompletion.division(definition: d, attempts: [independent, legacy, future], now: day.addingTimeInterval(30), calendar: calendar).combined, 0)
    }
}
