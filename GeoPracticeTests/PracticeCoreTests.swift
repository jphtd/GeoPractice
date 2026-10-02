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
        XCTAssertFalse(CoreGoal(hands: [.right: CoreHandGoal()], targetDate: .now).isValid(for: .right))
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
        let definition = CoreDivisionDefinition(first: 12, last: 18, handMode: .right,
            goal: CoreGoal(hands: [.right: CoreHandGoal(count: 10)]))
        let page = try CoreContracts.saveCreatedDivision(piece: piece, definition: definition, context: context, activeSessionID: nil)
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first)
        XCTAssertEqual(page, .division(piece: piece.id, division: saved.id))
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
        _ = try CoreContracts.saveGoal(piece: piece.id, division: division, goal: CoreGoal(hands: [.left: CoreHandGoal(count: 3)]), context: context, activeSessionID: nil)
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
        XCTAssertEqual(nav.path, [.piece(piece.id), .division(piece: piece.id, division: event.id)])
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
        guard case .division(_, let id) = page else { throw CoreIntegrationError.wrongDestination }
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<PracticeEvent>()).first { $0.id == id })
        let definition = try XCTUnwrap(event.coreDefinition)
        XCTAssertNil(definition.goal)
        let goal = CoreGoal(hands: Dictionary(uniqueKeysWithValues: handMode.hands.map {
            ($0, CoreHandGoal(count: 3, speed: CoreTargetSpeed(bpm: 100)))
        }))
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal,
            context: context, activeSessionID: nil, at: start.addingTimeInterval(-100))
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
        let goal = CoreGoal(hands: [.left: CoreHandGoal(count: 15, speed: CoreTargetSpeed(bpm: 120, noteUnit: .eighth))])
        _ = try CoreContracts.saveGoal(piece: piece.id, division: event, goal: goal, context: context,
                                      activeSessionID: nil, at: start.addingTimeInterval(100))
        let history = CoreAnalysis.planned(try context.fetch(FetchDescriptor<PracticeAttempt>()), division: event.id)
        XCTAssertEqual(CoreAnalysis.count(history, hand: .left, cycleStart: calendar.startOfDay(for: start)), 2)
        XCTAssertEqual(CoreAnalysis.stable(history, hand: .left), 80)
        XCTAssertEqual(event.coreDefinition?.goal?.hands[.left]?.count, 15)
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
