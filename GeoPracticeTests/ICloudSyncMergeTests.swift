import XCTest
import SwiftData
@testable import GeoPractice

final class ICloudSyncMergeTests: XCTestCase {
    func testAppPersistenceUsesDurableLocalStore() {
        let schema = Schema([
            PracticeSong.self,
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self
        ])
        let configuration = GeoPracticePersistence.localConfiguration(schema: schema)

        XCTAssertFalse(configuration.isStoredInMemoryOnly)
        XCTAssertEqual(configuration.url.lastPathComponent, "default.store")
    }

    @MainActor
    func testLocalStoreRetainsExistingLibraryAndNewSongAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeoPracticeLocalPersistenceTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let existingSongID = UUID()
        let existingSectionID = UUID()
        let newSectionID = UUID()
        let schema = Schema([
            PracticeSong.self,
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self
        ])

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [GeoPracticePersistence.localConfiguration(
                    schema: schema,
                    url: storeURL
                )]
            )
            let context = container.mainContext
            context.insert(PracticeSong(
                id: existingSongID,
                name: "已有曲目",
                endDate: .distantFuture
            ))
            context.insert(PracticeEvent(
                id: existingSectionID,
                songID: existingSongID,
                sectionSortIndex: 0,
                name: "已有段落"
            ))
            try context.save()
        }

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [GeoPracticePersistence.localConfiguration(
                    schema: schema,
                    url: storeURL
                )]
            )
            let store = try PracticeLibraryStore(modelContext: container.mainContext)
            XCTAssertEqual(store.activeSongs.map(\.id), [existingSongID])
            _ = try store.saveSong(
                id: nil,
                name: "新建曲目",
                group: "未分组",
                sections: [PracticeSectionDraft(id: newSectionID, name: "新段落")],
                leftGoal: 1,
                rightGoal: 1,
                bothGoal: 1,
                multiplier: 1,
                resetsDaily: true,
                endDate: .distantFuture,
                archived: false
            )
            XCTAssertEqual(store.activeSongs.count, 2)
        }

        let reopenedContainer = try ModelContainer(
            for: schema,
            configurations: [GeoPracticePersistence.localConfiguration(
                schema: schema,
                url: storeURL
            )]
        )
        let reopenedStore = try PracticeLibraryStore(
            modelContext: reopenedContainer.mainContext
        )
        XCTAssertEqual(Set(reopenedStore.activeSongs.map(\.name)), ["已有曲目", "新建曲目"])
        XCTAssertNotNil(reopenedStore.eventSnapshot(id: existingSectionID))
        XCTAssertNotNil(reopenedStore.eventSnapshot(id: newSectionID))
    }

    func testMergePreservesIndependentEntitiesFromBothDevices() throws {
        let localID = UUID()
        let remoteID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let local = try envelope(
            songs: [song(id: localID, name: "Local", updatedAt: base)],
            modifiedAt: base,
            deviceID: "local"
        )
        let remote = try envelope(
            songs: [song(id: remoteID, name: "Remote", updatedAt: base)],
            modifiedAt: base.addingTimeInterval(1),
            deviceID: "remote"
        )

        let merged = try ICloudBackupMerger.merge(
            local: local,
            remote: remote,
            modifiedAt: base.addingTimeInterval(2),
            deviceID: "local"
        )
        let songs = try ICloudBackupGraph(data: merged.payload).entities(in: "songs")

        XCTAssertEqual(Set(songs.keys), Set([
            localID.uuidString.lowercased(),
            remoteID.uuidString.lowercased()
        ]))
    }

    func testNewerEntityRevisionWinsConcurrentEdit() throws {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        let local = try envelope(
            songs: [song(id: id, name: "Older", updatedAt: base)],
            modifiedAt: base,
            deviceID: "local",
            revisionOverrides: ["songs:\(id.uuidString.lowercased())": base]
        )
        let remote = try envelope(
            songs: [song(id: id, name: "Newer", updatedAt: base)],
            modifiedAt: base.addingTimeInterval(3),
            deviceID: "remote",
            revisionOverrides: [
                "songs:\(id.uuidString.lowercased())": base.addingTimeInterval(3)
            ]
        )

        let merged = try ICloudBackupMerger.merge(
            local: local,
            remote: remote,
            modifiedAt: base.addingTimeInterval(4),
            deviceID: "local"
        )
        let value = try XCTUnwrap(
            ICloudBackupGraph(data: merged.payload)
                .entities(in: "songs")[id.uuidString.lowercased()]
        )
        guard case .object(let object) = value else {
            return XCTFail("Expected a song object")
        }
        XCTAssertEqual(object["name"], .string("Newer"))
    }

    func testLocalDeletionCreatesTombstoneAndDoesNotResurrectRemoteCopy() throws {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 3_000)
        let baseline = try envelope(
            songs: [song(id: id, name: "Delete Me", updatedAt: base)],
            modifiedAt: base,
            deviceID: "local"
        )
        let deletionTime = base.addingTimeInterval(10)
        let local = try ICloudBackupMerger.makeLocalEnvelope(
            payload: try backupData(songs: []),
            baseline: baseline,
            modifiedAt: deletionTime,
            deviceID: "local"
        )

        XCTAssertEqual(
            local.tombstones["songs:\(id.uuidString.lowercased())"],
            deletionTime
        )

        let merged = try ICloudBackupMerger.merge(
            local: local,
            remote: baseline,
            modifiedAt: deletionTime.addingTimeInterval(1),
            deviceID: "local"
        )
        XCTAssertTrue(
            try ICloudBackupGraph(data: merged.payload)
                .entities(in: "songs").isEmpty
        )
    }

    func testRecreatedEntityAfterDeletionWinsWithLaterRevision() throws {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 4_000)
        let key = "songs:\(id.uuidString.lowercased())"
        let deleted = ICloudSyncEnvelope(
            modifiedAt: base,
            deviceID: "remote",
            payload: try backupData(songs: []),
            revisions: [:],
            tombstones: [key: base]
        )
        let recreatedAt = base.addingTimeInterval(5)
        let recreated = try envelope(
            songs: [song(id: id, name: "Recreated", updatedAt: recreatedAt)],
            modifiedAt: recreatedAt,
            deviceID: "local",
            revisionOverrides: [key: recreatedAt]
        )

        let merged = try ICloudBackupMerger.merge(
            local: recreated,
            remote: deleted,
            modifiedAt: recreatedAt.addingTimeInterval(1),
            deviceID: "local"
        )
        XCTAssertNotNil(
            try ICloudBackupGraph(data: merged.payload).entities(in: "songs")[
                id.uuidString.lowercased()
            ]
        )
    }

    func testEnvelopeRoundTripRejectsUnsupportedVersion() throws {
        let data = try backupData(songs: [])
        let invalid = ICloudSyncEnvelope(
            version: 99,
            modifiedAt: .now,
            deviceID: "test",
            payload: data,
            revisions: [:],
            tombstones: [:]
        )
        XCTAssertThrowsError(try ICloudSyncEnvelope.decode(invalid.encoded())) {
            XCTAssertEqual($0 as? ICloudSyncError, .invalidEnvelope)
        }
    }

    func testExportTimestampAloneDoesNotTriggerAnotherSave() throws {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_000)
        let firstPayload = try backupData(
            songs: [song(id: id, name: "Same", updatedAt: base)],
            exportedAt: base
        )
        let secondPayload = try backupData(
            songs: [song(id: id, name: "Same", updatedAt: base)],
            exportedAt: base.addingTimeInterval(60)
        )
        let first = try ICloudBackupMerger.makeLocalEnvelope(
            payload: firstPayload,
            baseline: nil,
            modifiedAt: base,
            deviceID: "local"
        )
        let second = try ICloudBackupMerger.makeLocalEnvelope(
            payload: secondPayload,
            baseline: first,
            modifiedAt: base.addingTimeInterval(60),
            deviceID: "local"
        )

        XCTAssertEqual(
            ICloudBackupMerger.digest(firstPayload),
            ICloudBackupMerger.digest(secondPayload)
        )
        XCTAssertTrue(ICloudBackupMerger.isEquivalent(first, second))
    }

    func testDeletedSongCascadesStaleOrphanEventAndAttempt() throws {
        let songID = UUID()
        let eventID = UUID()
        let attemptID = UUID()
        let sessionID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 6_000)
        let childPayload = try backupData(
            songs: [song(id: songID, name: "Stale", updatedAt: base)],
            events: [[
                "id": eventID.uuidString,
                "songID": songID.uuidString,
                "updatedAt": base.timeIntervalSinceReferenceDate
            ]],
            attempts: [[
                "id": attemptID.uuidString,
                "sessionID": sessionID.uuidString,
                "eventID": eventID.uuidString,
                "createdAt": base.timeIntervalSinceReferenceDate
            ]]
        )
        let remoteBaseline = try ICloudBackupMerger.makeLocalEnvelope(
            payload: childPayload,
            baseline: nil,
            modifiedAt: base,
            deviceID: "remote"
        )
        let deletedAt = base.addingTimeInterval(5)
        let local = try ICloudBackupMerger.makeLocalEnvelope(
            payload: try backupData(songs: []),
            baseline: remoteBaseline,
            modifiedAt: deletedAt,
            deviceID: "local"
        )
        var staleChildRevisions = remoteBaseline.revisions
        staleChildRevisions["events:\(eventID.uuidString.lowercased())"] =
            deletedAt.addingTimeInterval(5)
        staleChildRevisions["attempts:\(attemptID.uuidString.lowercased())"] =
            deletedAt.addingTimeInterval(5)
        let remote = ICloudSyncEnvelope(
            modifiedAt: deletedAt.addingTimeInterval(5),
            deviceID: "remote",
            payload: remoteBaseline.payload,
            revisions: staleChildRevisions,
            tombstones: [:]
        )

        let merged = try ICloudBackupMerger.merge(
            local: local,
            remote: remote,
            modifiedAt: deletedAt.addingTimeInterval(1),
            deviceID: "local"
        )
        let graph = try ICloudBackupGraph(data: merged.payload)
        XCTAssertTrue(try graph.entities(in: "songs").isEmpty)
        XCTAssertTrue(try graph.entities(in: "events").isEmpty)
        XCTAssertTrue(try graph.entities(in: "attempts").isEmpty)
    }

    func testTransactionGuardRetriesWhenSongIsCreatedDuringFetch() throws {
        let capturedEmpty = try backupData(songs: [])
        let createdAt = Date(timeIntervalSinceReferenceDate: 7_000)
        let currentWithSong = try backupData(
            songs: [song(id: UUID(), name: "Created During Fetch", updatedAt: createdAt)],
            exportedAt: createdAt
        )

        XCTAssertTrue(
            ICloudSyncTransactionGuard.hasLocalChanges(
                since: capturedEmpty,
                current: currentWithSong
            )
        )
        XCTAssertEqual(
            ICloudSyncTransactionGuard.commitDecision(
                capturedLocalPayload: capturedEmpty,
                currentLocalPayload: currentWithSong,
                resolvedPayload: capturedEmpty
            ),
            .retryWithFreshSnapshot
        )
    }

    func testTransactionGuardRetriesWhenLocalEditOccursDuringSave() throws {
        let id = UUID()
        let capturedAt = Date(timeIntervalSinceReferenceDate: 8_000)
        let captured = try backupData(
            songs: [song(id: id, name: "Before Save", updatedAt: capturedAt)],
            exportedAt: capturedAt
        )
        let editedAt = capturedAt.addingTimeInterval(1)
        let current = try backupData(
            songs: [song(id: id, name: "Edited During Save", updatedAt: editedAt)],
            exportedAt: editedAt
        )

        XCTAssertEqual(
            ICloudSyncTransactionGuard.commitDecision(
                capturedLocalPayload: captured,
                currentLocalPayload: current,
                resolvedPayload: captured
            ),
            .retryWithFreshSnapshot
        )
    }

    func testTransactionGuardIgnoresExportTimestampButRestoresRemoteChange() throws {
        let id = UUID()
        let updatedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        let captured = try backupData(
            songs: [song(id: id, name: "Local", updatedAt: updatedAt)],
            exportedAt: updatedAt
        )
        let reexported = try backupData(
            songs: [song(id: id, name: "Local", updatedAt: updatedAt)],
            exportedAt: updatedAt.addingTimeInterval(60)
        )
        let resolved = try backupData(
            songs: [song(id: id, name: "Remote", updatedAt: updatedAt)],
            exportedAt: updatedAt.addingTimeInterval(120)
        )

        XCTAssertFalse(
            ICloudSyncTransactionGuard.hasLocalChanges(
                since: captured,
                current: reexported
            )
        )
        XCTAssertEqual(
            ICloudSyncTransactionGuard.commitDecision(
                capturedLocalPayload: captured,
                currentLocalPayload: reexported,
                resolvedPayload: captured
            ),
            .keepCurrentLocalSnapshot
        )
        XCTAssertEqual(
            ICloudSyncTransactionGuard.commitDecision(
                capturedLocalPayload: captured,
                currentLocalPayload: reexported,
                resolvedPayload: resolved
            ),
            .restoreResolvedSnapshot
        )
    }

    @MainActor
    func testUnavailableICloudPreservesLocalDataAndReconnectUploadsIt() async throws {
        let (container, store) = try makeLibraryStore(named: "Local survives unavailable iCloud")
        _ = container
        let before = try store.makeBackupData()
        let backend = ICloudSyncBackendStub(availability: .unavailable)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ICloudSyncService(
            backend: backend,
            localState: ICloudSyncLocalStateStore(rootDirectory: directory)
        )
        service.start(store: store, scheduleImmediately: false)

        await service.synchronizeNow()
        XCTAssertEqual(service.status, .unavailable("请登录 iCloud 并开启 iCloud Drive"))
        XCTAssertEqual(
            ICloudBackupMerger.digest(before),
            ICloudBackupMerger.digest(try store.makeBackupData())
        )

        await backend.setAvailability(.available)
        await service.synchronizeNow()
        guard case .synced = service.status else {
            return XCTFail("Expected a successful sync after iCloud reconnects")
        }
        let reconnectedUpload = await backend.lastSavedEnvelope()
        XCTAssertNotNil(reconnectedUpload)
        XCTAssertEqual(
            ICloudBackupMerger.digest(before),
            ICloudBackupMerger.digest(try store.makeBackupData())
        )
    }

    @MainActor
    func testOfflineFetchFailurePreservesLocalDataAndManualRetryRecovers() async throws {
        let (container, store) = try makeLibraryStore(named: "Local survives offline sync")
        _ = container
        let before = try store.makeBackupData()
        let backend = ICloudSyncBackendStub(availability: .available, isOffline: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ICloudSyncService(
            backend: backend,
            localState: ICloudSyncLocalStateStore(rootDirectory: directory)
        )
        service.start(store: store, scheduleImmediately: false)

        await service.synchronizeNow()
        XCTAssertEqual(service.status, .failed("iCloud 暂时不可用，稍后自动重试"))
        XCTAssertEqual(
            ICloudBackupMerger.digest(before),
            ICloudBackupMerger.digest(try store.makeBackupData())
        )

        await backend.setOffline(false)
        await service.synchronizeNow()
        guard case .synced = service.status else {
            return XCTFail("Expected manual retry to sync after reconnecting")
        }
        let retriedUpload = await backend.lastSavedEnvelope()
        XCTAssertNotNil(retriedUpload)
    }

    @MainActor
    func testActiveSessionDefersCloudAccessWithoutChangingLocalData() async throws {
        let (container, store) = try makeLibraryStore(named: "Protected active session")
        _ = container
        let before = try store.makeBackupData()
        store.protectedEventID = UUID()
        let backend = ICloudSyncBackendStub(availability: .available)
        let service = ICloudSyncService(backend: backend)
        service.start(store: store, scheduleImmediately: false)

        await service.synchronizeNow()

        XCTAssertEqual(service.status, .waitingForPracticeToFinish)
        let accessCount = await backend.accessCount()
        XCTAssertEqual(accessCount, 0)
        XCTAssertEqual(
            ICloudBackupMerger.digest(before),
            ICloudBackupMerger.digest(try store.makeBackupData())
        )
    }

    @MainActor
    func testIndependentGeoBeatEntryActivatesProductionCloudProtection() async throws {
        let planned = CoreSessionRuntime(
            defaults: UserDefaults(suiteName: "P0B.Planned.\(UUID())")!,
            restore: false
        )
        let independent = CoreSessionRuntime(
            defaults: UserDefaults(suiteName: "P0B.Independent.\(UUID())")!,
            restore: false
        )
        XCTAssertTrue(independent.startIndependentPlayback(using: { true }))
        let (container, store) = try makeLibraryStore(named: "Independent protected entry")
        defer { withExtendedLifetime(container) {} }
        store.protectedEventID = CoreSyncProtection.activeEventID(
            planned: planned,
            independent: independent,
            recoveryID: nil
        )
        let backend = ICloudSyncBackendStub(availability: .available)
        let service = ICloudSyncService(backend: backend)
        service.start(store: store, scheduleImmediately: false)

        await service.synchronizeNow()

        XCTAssertEqual(store.protectedEventID, independent.independentActiveID)
        XCTAssertNotNil(store.protectedEventID)
        XCTAssertEqual(service.status, .waitingForPracticeToFinish)
        let accessCount = await backend.accessCount()
        XCTAssertEqual(accessCount, 0)
    }

    @MainActor
    func testConsecutiveFailuresHonorBackoffThenRecover() async throws {
        let (container, store) = try makeLibraryStore(named: "Backoff survives failures")
        defer { withExtendedLifetime(container) {} }
        let backend = ICloudSyncBackendStub(
            availability: .available,
            failuresBeforeSuccess: 2
        )
        let service = ICloudSyncService(
            backend: backend,
            failureRetryDelay: .milliseconds(250)
        )
        XCTAssertEqual(ICloudSyncService(backend: backend).failureRetryDelay, .seconds(30))
        service.start(store: store, scheduleImmediately: false)

        await service.synchronizeNow()
        var fetchCount = await backend.fetchCount()
        XCTAssertEqual(fetchCount, 1)
        try await Task.sleep(for: .milliseconds(120))
        fetchCount = await backend.fetchCount()
        XCTAssertEqual(fetchCount, 1, "Failure must remain in its configured backoff window")

        try await Task.sleep(for: .milliseconds(180))
        fetchCount = await backend.fetchCount()
        XCTAssertEqual(fetchCount, 2)
        guard case .failed = service.status else {
            return XCTFail("Second consecutive failure should remain failed during backoff")
        }

        try await Task.sleep(for: .milliseconds(300))
        fetchCount = await backend.fetchCount()
        XCTAssertEqual(fetchCount, 3)
        guard case .synced = service.status else {
            return XCTFail("Service should recover after the backend becomes available")
        }
    }

    @MainActor
    private func makeLibraryStore(named name: String) throws -> (ModelContainer, PracticeLibraryStore) {
        let container = try ModelContainer(
            for: PracticeSong.self,
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        container.mainContext.insert(PracticeSong(name: name, endDate: .distantFuture))
        try container.mainContext.save()
        return (container, try PracticeLibraryStore(modelContext: container.mainContext))
    }

    private func envelope(
        songs: [[String: Any]],
        modifiedAt: Date,
        deviceID: String,
        revisionOverrides: [String: Date] = [:]
    ) throws -> ICloudSyncEnvelope {
        let payload = try backupData(songs: songs)
        let graph = try ICloudBackupGraph(data: payload)
        var revisions = revisionOverrides
        for (id, value) in try graph.entities(in: "songs") {
            let key = "songs:\(id)"
            if revisions[key] == nil {
                revisions[key] = graph.entityTimestamp(value, field: "updatedAt")
            }
        }
        return ICloudSyncEnvelope(
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            payload: payload,
            revisions: revisions,
            tombstones: [:]
        )
    }

    private func backupData(
        songs: [[String: Any]],
        events: [[String: Any]] = [],
        attempts: [[String: Any]] = [],
        exportedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "exportedAt": exportedAt.timeIntervalSinceReferenceDate,
                "songs": songs,
                "events": events,
                "attempts": attempts,
                "dailyGoals": [],
                "folders": []
            ],
            options: [.sortedKeys]
        )
    }

    private func song(id: UUID, name: String, updatedAt: Date) -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "updatedAt": updatedAt.timeIntervalSinceReferenceDate
        ]
    }
}

private actor ICloudSyncBackendStub: ICloudSyncBackendProtocol {
    private var availabilityValue: ICloudContainerAvailability
    private var offline: Bool
    private var savedEnvelope: ICloudSyncEnvelope?
    private var accesses = 0
    private var remainingFailures: Int
    private var fetches = 0

    init(
        availability: ICloudContainerAvailability,
        isOffline: Bool = false,
        failuresBeforeSuccess: Int = 0
    ) {
        availabilityValue = availability
        offline = isOffline
        remainingFailures = failuresBeforeSuccess
    }

    func availability() -> ICloudContainerAvailability {
        accesses += 1
        return availabilityValue
    }

    func fetchSnapshot() throws -> ICloudRemoteSnapshot? {
        accesses += 1
        fetches += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw CocoaError(.ubiquitousFileUnavailable)
        }
        if offline { throw CocoaError(.ubiquitousFileUnavailable) }
        return nil
    }

    func saveSnapshot(_ envelope: ICloudSyncEnvelope) {
        accesses += 1
        savedEnvelope = envelope
    }

    func setAvailability(_ value: ICloudContainerAvailability) {
        availabilityValue = value
    }

    func setOffline(_ value: Bool) {
        offline = value
    }

    func lastSavedEnvelope() -> ICloudSyncEnvelope? {
        savedEnvelope
    }

    func accessCount() -> Int {
        accesses
    }

    func fetchCount() -> Int {
        fetches
    }
}
