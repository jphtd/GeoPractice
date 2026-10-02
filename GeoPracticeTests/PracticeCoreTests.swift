import XCTest
import SwiftData
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
        XCTAssertEqual(try CoreContracts.goalSavedReturn(piece: piece, division: event), .division(piece: piece, division: division))
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
        try runtime.begin(piece: piece, division: division)
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
        nav.request(.editGoal(piece: piece.id, division: event.id))
        var definition = try XCTUnwrap(event.coreDefinition)
        definition.goal = CoreGoal(hands: [.right: CoreHandGoal(count: 10)])
        event.coreDefinitionData = try JSONEncoder().encode(definition)
        try container.mainContext.save()
        try nav.goalSaved(piece: piece.id, division: event)
        XCTAssertTrue(try XCTUnwrap(event.coreDefinition).hasValidGoal)
        XCTAssertEqual(nav.path.count, 2) // no duplicate detail page
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
                XCTAssertEqual(page, .division(piece: piece.id, division: event.id))
                XCTAssertEqual(event.coreDefinition?.handMode, mode)
                XCTAssertEqual(event.coreDefinition?.goal?.hands, goal.hands)
                let nav = CoreNavigation(); nav.request(.editGoal(piece: piece.id, division: event.id))
                try nav.goalSaved(piece: piece.id, division: event)
                XCTAssertEqual(nav.path, [.piece(piece.id), page])
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
                activeSessionID: nil, isPro: true, timing: .current), .division(piece: piece.id, division: event.id))
            XCTAssertEqual(event.coreDefinition?.goal?.hands, edited.hands)
        }
    }
    func testLadderFiniteFinalShortStepAndOpenEndedValidity() {
        let config = CoreLadderConfiguration(startBPM: 100, stepBPM: 3, repsPerLevel: 11)
        XCTAssertEqual(config.finiteLevels(target: CoreTargetSpeed(bpm: 108)), [100, 103, 106, 108])
        XCTAssertTrue(ladderGoal(target: 108, start: 100).isValid(for: .both))
        XCTAssertTrue(ladderGoal(reps: Int.max).isValid(for: .both))
        XCTAssertFalse(ladderGoal(.left).isValid(for: .all))
        XCTAssertEqual(CoreLadderConfiguration(startBPM: 118, stepBPM: 5, repsPerLevel: 1).finiteLevels(target: CoreTargetSpeed(bpm: 120)), [118, 120])
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

    func testRealCreateRecordSaveReopenAndAssociation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoreE2E.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try container(url: url), context = store.mainContext
        let (piece, event) = try makeDivision(context)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start, calendar: calendar)
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
        try original.begin(piece: piece, division: event, at: start)
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
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: midnight.addingTimeInterval(-10), calendar: calendar)
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
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: midnight.addingTimeInterval(60), calendar: calendar)
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
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left))
        runtime.finish(at: start.addingTimeInterval(1))
        XCTAssertThrowsError(try runtime.save(division: event, in: context))
        try runtime.discardEmpty()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PracticeAttempt>()), 0)
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start)
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
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left))
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
            try runtime.begin(piece: piece, division: event, initialHand: .left, at: date, calendar: calendar)
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
        try runtime.begin(piece: piece, division: event, initialHand: .left)
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
            try runtime.begin(piece: piece, division: event, at: start)
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
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event))
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
            try runtime.begin(piece: piece, division: event, initialHand: hand, at: start)
            XCTAssertEqual(runtime.session.currentHand, hand)
            runtime.switchHand(.both)
            try runtime.discardEmpty()
            XCTAssertThrowsError(try runtime.begin(piece: piece, division: event))
            XCTAssertNil(runtime.activeID)
        }
    }

    func testSingleHandRejectsInapplicableExplicitInitialSelectionWithoutMutation() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext, handMode: .both)
        let storage = defaults(), runtime = CoreSessionRuntime(defaults: storage)
        XCTAssertThrowsError(try runtime.begin(piece: piece, division: event, initialHand: .left))
        XCTAssertNil(runtime.context)
        XCTAssertNil(storage.data(forKey: CoreSessionRuntime.draftKey))
    }

    func testSwitchingKeepsIdentityPlaybackBPMCountsAndHistoricalAttribution() throws {
        let store = try container(); let (piece, event) = try makeDivision(store.mainContext)
        let runtime = CoreSessionRuntime(defaults: defaults())
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start)
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
        try runtime.begin(piece: piece, division: event, initialHand: .left, at: start)
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
        try runtime.begin(piece: piece, division: event, at: start.addingTimeInterval(10))
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
        try runtime.begin(piece: piece, division: event, at: start)
        runtime.record(preset: preset(100), at: start.addingTimeInterval(1))
        let restored = CoreSessionRuntime(defaults: storage)
        XCTAssertEqual(restored.activeID, runtime.activeID)
        XCTAssertEqual(restored.context?.handMode, .both)
        XCTAssertEqual(restored.session.currentHand, .both)
        XCTAssertEqual(samples(restored), samples(runtime))
    }

}
