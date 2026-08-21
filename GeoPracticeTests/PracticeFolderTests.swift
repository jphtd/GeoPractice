import SwiftData
import XCTest
@testable import GeoPractice

final class PracticeFolderTests: XCTestCase {
    func testPracticeEventDragPayloadRoundTripsItsIdentifier() throws {
        let payload = PracticeEventDragPayload(eventID: UUID())
        let encoded = try JSONEncoder().encode(payload)

        XCTAssertEqual(
            try JSONDecoder().decode(
                PracticeEventDragPayload.self,
                from: encoded
            ),
            payload
        )
    }

    func testFolderAndEventRoutesRemainDistinctForTheSameIdentifier() {
        let sharedID = UUID()

        XCTAssertNotEqual(
            PracticeNavigationRoute.folder(sharedID),
            PracticeNavigationRoute.event(sharedID)
        )
        XCTAssertEqual(
            Set([
                PracticeNavigationRoute.folder(sharedID),
                PracticeNavigationRoute.event(sharedID)
            ]).count,
            2
        )
    }

    func testMovingEventKeepsExactlyOneFolderMembership() {
        let eventID = UUID()
        let first = PracticeFolder(name: "肖邦", sortIndex: 0)
        let second = PracticeFolder(name: "李斯特", sortIndex: 1)

        PracticeFolder.move(
            eventID: eventID,
            to: first,
            among: [first, second]
        )
        XCTAssertTrue(first.contains(eventID: eventID))
        XCTAssertFalse(second.contains(eventID: eventID))

        PracticeFolder.move(
            eventID: eventID,
            to: second,
            among: [first, second]
        )
        XCTAssertFalse(first.contains(eventID: eventID))
        XCTAssertTrue(second.contains(eventID: eventID))

        PracticeFolder.move(
            eventID: eventID,
            to: nil,
            among: [first, second]
        )
        XCTAssertNil(
            PracticeFolder.folder(
                containing: eventID,
                in: [first, second]
            )
        )
    }

    func testClassifyingUnclassifiedEventRejectsStaleDrops() {
        let eventID = UUID()
        let initialUpdate = Date(timeIntervalSince1970: 100)
        let firstDropDate = Date(timeIntervalSince1970: 200)
        let duplicateDropDate = Date(timeIntervalSince1970: 300)
        let destination = PracticeFolder(
            name: "目标目录",
            updatedAt: initialUpdate
        )
        let other = PracticeFolder(name: "其他目录")
        let folders = [destination, other]
        let missingEventID = UUID()

        XCTAssertEqual(
            PracticeFolder.classifyUnclassified(
                eventID: missingEventID,
                toFolderID: destination.id,
                knownEventIDs: [eventID],
                among: folders
            ),
            .eventNotFound
        )
        XCTAssertTrue(destination.eventIDs.isEmpty)

        XCTAssertEqual(
            PracticeFolder.classifyUnclassified(
                eventID: eventID,
                toFolderID: UUID(),
                knownEventIDs: [eventID],
                among: folders
            ),
            .folderNotFound
        )
        XCTAssertTrue(destination.eventIDs.isEmpty)

        XCTAssertEqual(
            PracticeFolder.classifyUnclassified(
                eventID: eventID,
                toFolderID: destination.id,
                knownEventIDs: [eventID],
                among: folders,
                now: firstDropDate
            ),
            .moved
        )
        XCTAssertTrue(destination.contains(eventID: eventID))
        XCTAssertEqual(destination.updatedAt, firstDropDate)

        XCTAssertEqual(
            PracticeFolder.classifyUnclassified(
                eventID: eventID,
                toFolderID: other.id,
                knownEventIDs: [eventID],
                among: folders,
                now: duplicateDropDate
            ),
            .alreadyClassified
        )
        XCTAssertTrue(destination.contains(eventID: eventID))
        XCTAssertFalse(other.contains(eventID: eventID))
        XCTAssertEqual(destination.updatedAt, firstDropDate)
    }

    @MainActor
    func testClassifyingEventPreservesItsDataAndAttemptHistory() throws {
        let schema = Schema([
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = container.mainContext
        let event = PracticeEvent(
            name: "德彪西练习",
            leftCount: 2,
            rightCount: 3,
            bothCount: 4
        )
        let folder = PracticeFolder(name: "印象派")
        context.insert(event)
        context.insert(folder)
        _ = try event.commit(
            summary: PracticeSessionSummary(
                sourceEventID: event.id,
                left: HandPracticeStats(count: 1)
            ),
            in: context
        )
        try context.save()
        let originalCounts = (
            left: event.leftCount,
            right: event.rightCount,
            both: event.bothCount
        )
        let originalAttempts = try PracticeAttempt.history(
            for: event.id,
            in: context
        ).map(\.id)

        XCTAssertEqual(
            PracticeFolder.classifyUnclassified(
                eventID: event.id,
                toFolderID: folder.id,
                knownEventIDs: [event.id],
                among: [folder]
            ),
            .moved
        )
        try context.save()

        XCTAssertTrue(folder.contains(eventID: event.id))
        XCTAssertEqual(event.leftCount, originalCounts.left)
        XCTAssertEqual(event.rightCount, originalCounts.right)
        XCTAssertEqual(event.bothCount, originalCounts.both)
        XCTAssertEqual(
            try PracticeAttempt.history(for: event.id, in: context).map(\.id),
            originalAttempts
        )
    }

    func testMembershipEncodingDeduplicatesIdentifiers() {
        let firstID = UUID()
        let secondID = UUID()
        let folder = PracticeFolder(
            name: "音阶",
            eventIDs: [firstID, firstID, secondID]
        )

        XCTAssertEqual(folder.eventIDs, [firstID, secondID])
    }

    @MainActor
    func testDeletingFolderPreservesEventAndAttemptHistory() throws {
        let schema = Schema([
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = container.mainContext
        let event = PracticeEvent(name: "练习曲")
        let folder = PracticeFolder(name: "肖邦")
        context.insert(event)
        context.insert(folder)
        folder.add(eventID: event.id)
        _ = try event.commit(
            summary: PracticeSessionSummary(
                sourceEventID: event.id,
                left: HandPracticeStats(count: 1)
            ),
            in: context
        )
        try context.save()

        context.delete(folder)
        try context.save()

        let restoredEvents = try context.fetch(FetchDescriptor<PracticeEvent>())
        XCTAssertEqual(restoredEvents.map(\.id), [event.id])
        XCTAssertEqual(
            try PracticeAttempt.history(for: event.id, in: context).count,
            1
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<PracticeFolder>()).isEmpty)
    }

    @MainActor
    func testAddingFolderSchemaLeavesExistingEventsUnclassifiedAndIntact() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeoPracticeFolderMigrationTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("GeoPractice.store")
        let eventID = UUID()

        do {
            let oldSchema = Schema([
                PracticeEvent.self,
                PracticeAttempt.self
            ])
            let oldConfiguration = ModelConfiguration(
                "GeoPractice",
                schema: oldSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let oldContainer = try ModelContainer(
                for: oldSchema,
                configurations: [oldConfiguration]
            )
            oldContainer.mainContext.insert(
                PracticeEvent(
                    id: eventID,
                    name: "升级前未分类练习",
                    leftCount: 7
                )
            )
            try oldContainer.mainContext.save()
        }

        let upgradedSchema = Schema([
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self
        ])
        let upgradedConfiguration = ModelConfiguration(
            "GeoPractice",
            schema: upgradedSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let upgradedContainer = try ModelContainer(
            for: upgradedSchema,
            configurations: [upgradedConfiguration]
        )
        let context = upgradedContainer.mainContext
        let restored = try XCTUnwrap(
            context.fetch(FetchDescriptor<PracticeEvent>()).first {
                $0.id == eventID
            }
        )
        let folders = try context.fetch(FetchDescriptor<PracticeFolder>())

        XCTAssertEqual(restored.name, "升级前未分类练习")
        XCTAssertEqual(restored.leftCount, 7)
        XCTAssertTrue(folders.isEmpty)
        XCTAssertNil(
            PracticeFolder.folder(containing: restored.id, in: folders)
        )
    }
}
