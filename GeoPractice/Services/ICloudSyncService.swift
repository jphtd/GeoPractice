import Combine
import CryptoKit
import Foundation

/// User-facing state for the automatic private-iCloud library sync.
enum ICloudSyncStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    case waitingForPracticeToFinish
    case unavailable(String)
    case failed(String)

    var detail: String {
        switch self {
        case .idle:
            "等待首次同步"
        case .syncing:
            "正在合并本机与 iCloud 数据…"
        case .synced(let date):
            "已自动同步 · \(Self.relativeTime(from: date))"
        case .waitingForPracticeToFinish:
            "本轮练习结束后自动同步"
        case .unavailable(let reason), .failed(let reason):
            reason
        }
    }

    var badgeTitle: String {
        switch self {
        case .idle: "待同步"
        case .syncing: "同步中"
        case .synced: "已开启"
        case .waitingForPracticeToFinish: "稍后"
        case .unavailable: "不可用"
        case .failed: "重试中"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .synced, .syncing, .waitingForPracticeToFinish: true
        case .idle, .unavailable, .failed: false
        }
    }

    private static func relativeTime(from date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}

/// Coordinates local SwiftData snapshots with a conflict-aware document in
/// the user's private iCloud container. The app remains fully local-first: a
/// missing account, an offline device, or an iCloud error never blocks local
/// reads or writes. Local mutations are debounced and retried on foreground.
@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()

    @Published private(set) var status: ICloudSyncStatus = .idle

    private weak var store: PracticeLibraryStore?
    private var storeChanges: AnyCancellable?
    /// Only the not-yet-started debounce/retry task is retained here. Once a
    /// sync pass begins it must not be cancelled by a new local mutation: the
    /// pass may already be inside coordinated iCloud I/O, and cancelling it
    /// would otherwise leave a stale snapshot eligible for restore.
    private var scheduledSyncTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var isSynchronizing = false
    private var needsAnotherSync = false

    private let backend: any ICloudSyncBackendProtocol
    private let localState: ICloudSyncLocalStateStore
    private let deviceID: String
    let failureRetryDelay: Duration

    init(
        backend: any ICloudSyncBackendProtocol = ICloudSyncBackend(),
        localState: ICloudSyncLocalStateStore = ICloudSyncLocalStateStore(),
        failureRetryDelay: Duration = .seconds(30)
    ) {
        self.backend = backend
        self.localState = localState
        self.failureRetryDelay = failureRetryDelay
        let key = "practice.icloudSync.deviceID.v1"
        if let persisted = UserDefaults.standard.string(forKey: key),
           UUID(uuidString: persisted) != nil {
            deviceID = persisted
        } else {
            let value = UUID().uuidString.lowercased()
            UserDefaults.standard.set(value, forKey: key)
            deviceID = value
        }
    }

    func start(store: PracticeLibraryStore, scheduleImmediately: Bool = true) {
        guard self.store !== store else {
            if scheduleImmediately { scheduleSync(after: .zero) }
            return
        }
        self.store = store
        storeChanges = store.objectWillChange
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleSync(after: .zero)
            }
        if scheduleImmediately { scheduleSync(after: .zero) }
        startPollingIfNeeded()
    }

    func syncWhenAppBecomesActive() {
        scheduleSync(after: .zero)
    }

    func syncBeforeBackgrounding() {
        scheduleSync(after: .zero)
    }

    func retryNow() {
        scheduleSync(after: .zero)
    }

    /// Runs one pass immediately. The shipping UI uses the debounced retry
    /// entry point; this deterministic entry point verifies lifecycle and
    /// reconnect behavior without waiting for timers.
    func synchronizeNow() async {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        await synchronize()
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard let self else { return }
                self.scheduleSync(after: .zero)
            }
        }
    }

    private func scheduleSync(after delay: Duration) {
        if isSynchronizing {
            needsAnotherSync = true
            return
        }

        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.scheduledSyncTask = nil
            await self.synchronize()
        }
    }

    private func synchronize() async {
        guard let store else { return }
        guard store.protectedEventID == nil else {
            status = .waitingForPracticeToFinish
            return
        }
        if isSynchronizing {
            needsAnotherSync = true
            return
        }

        isSynchronizing = true
        status = .syncing
        var failureDelay: Duration?
        defer {
            isSynchronizing = false
            if let failureDelay {
                needsAnotherSync = false
                scheduleSync(after: failureDelay)
            } else if needsAnotherSync {
                needsAnotherSync = false
                scheduleSync(after: .seconds(1))
            }
        }

        do {
            let availability = await backend.availability()
            guard availability == .available else {
                status = .unavailable(availability.message)
                return
            }

            let capturedLocalPayload = try store.makeBackupData()
            let baseline = try localState.loadBaseline()
            let remote = try await backend.fetchSnapshot()

            // `fetchSnapshot()` yields the main actor. A song/event can be
            // created, edited, or deleted while the coordinated read is in
            // flight. Never merge or restore from the snapshot captured
            // before that mutation; simply run another pass with fresh data.
            let localPayloadAfterFetch = try store.makeBackupData()
            guard !ICloudSyncTransactionGuard.hasLocalChanges(
                since: capturedLocalPayload,
                current: localPayloadAfterFetch
            ) else {
                needsAnotherSync = true
                return
            }

            let now = Date.now
            let localEnvelope = try ICloudBackupMerger.makeLocalEnvelope(
                payload: localPayloadAfterFetch,
                baseline: baseline,
                modifiedAt: now,
                deviceID: deviceID
            )
            var candidate = localEnvelope
            for remoteEnvelope in remote?.envelopes ?? [] {
                candidate = try ICloudBackupMerger.merge(
                    local: candidate,
                    remote: remoteEnvelope,
                    modifiedAt: .now,
                    deviceID: deviceID
                )
            }

            let resolvedEnvelope: ICloudSyncEnvelope
            if let remote,
               remote.envelopes.count == 1,
               ICloudBackupMerger.isEquivalent(candidate, remote.envelopes[0]) {
                resolvedEnvelope = remote.envelopes[0]
            } else {
                // NSFileCoordinator serializes local access. If two devices
                // still write concurrently, iCloud preserves both as
                // NSFileVersion conflicts; the next read merges every version
                // before marking those conflicts resolved.
                try await backend.saveSnapshot(candidate)
                resolvedEnvelope = candidate
            }

            // Saving also yields. In particular, a newly-created song must
            // remain authoritative if it was committed while the upload was
            // underway. Do not restore the old merged graph and do not advance
            // the baseline, because either would turn that local creation into
            // a deletion/tombstone on the next pass.
            let currentLocalPayload = try store.makeBackupData()
            let commitDecision = ICloudSyncTransactionGuard.commitDecision(
                capturedLocalPayload: localPayloadAfterFetch,
                currentLocalPayload: currentLocalPayload,
                resolvedPayload: resolvedEnvelope.payload
            )
            guard commitDecision != .retryWithFreshSnapshot else {
                needsAnotherSync = true
                return
            }
            guard store.protectedEventID == nil else {
                status = .waitingForPracticeToFinish
                return
            }

            if commitDecision == .restoreResolvedSnapshot {
                // Use the latest export, not the pre-fetch snapshot, for the
                // recovery copy so even same-pass local changes are recoverable.
                try localState.saveRecoveryCopy(currentLocalPayload, at: .now)
                try store.restoreBackup(from: resolvedEnvelope.payload)
            }
            try localState.saveBaseline(resolvedEnvelope)
            status = .synced(.now)
        } catch is CancellationError {
            return
        } catch let error as CocoaError {
            status = Self.status(for: error)
            failureDelay = failureRetryDelay
        } catch {
            status = .failed("同步暂未完成，本机数据已保留")
            failureDelay = failureRetryDelay
        }
    }

    private static func status(for error: CocoaError) -> ICloudSyncStatus {
        switch error.code {
        case .fileReadNoSuchFile:
            .failed("iCloud 文件仍在下载，稍后自动重试")
        case .fileWriteOutOfSpace:
            .unavailable("iCloud 储存空间不足")
        case .ubiquitousFileUnavailable:
            .failed("iCloud 暂时不可用，稍后自动重试")
        default:
            .failed("同步暂未完成，本机数据已保留")
        }
    }
}

enum ICloudSyncError: LocalizedError, Equatable {
    case invalidEnvelope
    case invalidBackupGraph

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "iCloud 同步快照格式无效。"
        case .invalidBackupGraph: "练习资料备份结构无效。"
        }
    }
}

enum ICloudSyncCommitDecision: Equatable {
    /// Local SwiftData changed while an iCloud await was in flight. Discard
    /// every decision derived from the captured snapshot and start over.
    case retryWithFreshSnapshot
    /// The resolved cloud graph is already the same as the current local graph.
    case keepCurrentLocalSnapshot
    /// Local stayed unchanged and the merged cloud graph should be imported.
    case restoreResolvedSnapshot
}

/// Pure transaction guard used at every actor re-entrancy boundary in a sync
/// pass. Semantic digests deliberately ignore `exportedAt`, so merely exporting
/// SwiftData again does not create a false stale-snapshot result.
enum ICloudSyncTransactionGuard {
    static func hasLocalChanges(since captured: Data, current: Data) -> Bool {
        ICloudBackupMerger.digest(captured) != ICloudBackupMerger.digest(current)
    }

    static func commitDecision(
        capturedLocalPayload: Data,
        currentLocalPayload: Data,
        resolvedPayload: Data
    ) -> ICloudSyncCommitDecision {
        guard !hasLocalChanges(
            since: capturedLocalPayload,
            current: currentLocalPayload
        ) else {
            return .retryWithFreshSnapshot
        }
        return ICloudBackupMerger.digest(currentLocalPayload)
            == ICloudBackupMerger.digest(resolvedPayload)
            ? .keepCurrentLocalSnapshot
            : .restoreResolvedSnapshot
    }
}

struct ICloudSyncEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let modifiedAt: Date
    let deviceID: String
    let payload: Data
    let revisions: [String: Date]
    let tombstones: [String: Date]

    init(
        version: Int = currentVersion,
        modifiedAt: Date,
        deviceID: String,
        payload: Data,
        revisions: [String: Date],
        tombstones: [String: Date]
    ) {
        self.version = version
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.payload = payload
        self.revisions = revisions
        self.tombstones = tombstones
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ICloudSyncEnvelope {
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        guard value.version == currentVersion else {
            throw ICloudSyncError.invalidEnvelope
        }
        _ = try ICloudBackupGraph(data: value.payload)
        return value
    }
}

/// Pure, deterministic backup merger. Keeping iCloud I/O and SwiftData out of
/// this type makes conflict behavior directly testable.
enum ICloudBackupMerger {
    static func makeLocalEnvelope(
        payload: Data,
        baseline: ICloudSyncEnvelope?,
        modifiedAt: Date,
        deviceID: String
    ) throws -> ICloudSyncEnvelope {
        let current = try ICloudBackupGraph(data: payload)
        let previous = try baseline.map { try ICloudBackupGraph(data: $0.payload) }
        var revisions = baseline?.revisions ?? [:]
        var tombstones = baseline?.tombstones ?? [:]

        for spec in ICloudBackupGraph.collectionSpecs {
            let currentItems = try current.entities(in: spec.name)
            let previousItems = try previous?.entities(in: spec.name) ?? [:]
            let allIDs = Set(currentItems.keys).union(previousItems.keys)

            for id in allIDs {
                let key = spec.entityKey(id)
                switch (currentItems[id], previousItems[id]) {
                case let (.some(currentValue), .some(previousValue)):
                    if currentValue != previousValue {
                        revisions[key] = modifiedAt
                    } else if revisions[key] == nil {
                        revisions[key] = current.entityTimestamp(
                            currentValue,
                            field: spec.timestampField
                        ) ?? modifiedAt
                    }
                case let (.some(currentValue), .none):
                    revisions[key] = baseline == nil
                        ? current.entityTimestamp(currentValue, field: spec.timestampField) ?? modifiedAt
                        : modifiedAt
                case (.none, .some):
                    tombstones[key] = max(tombstones[key] ?? .distantPast, modifiedAt)
                    revisions.removeValue(forKey: key)
                case (.none, .none):
                    break
                }
            }
        }

        return ICloudSyncEnvelope(
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            payload: payload,
            revisions: revisions,
            tombstones: tombstones
        )
    }

    static func merge(
        local: ICloudSyncEnvelope,
        remote: ICloudSyncEnvelope,
        modifiedAt: Date,
        deviceID: String
    ) throws -> ICloudSyncEnvelope {
        guard local.version == ICloudSyncEnvelope.currentVersion,
              remote.version == ICloudSyncEnvelope.currentVersion
        else { throw ICloudSyncError.invalidEnvelope }

        let localGraph = try ICloudBackupGraph(data: local.payload)
        let remoteGraph = try ICloudBackupGraph(data: remote.payload)
        var mergedGraph = local.modifiedAt >= remote.modifiedAt ? localGraph : remoteGraph
        var mergedRevisions: [String: Date] = [:]
        var mergedTombstones = local.tombstones
        for (key, date) in remote.tombstones {
            mergedTombstones[key] = max(mergedTombstones[key] ?? .distantPast, date)
        }

        for spec in ICloudBackupGraph.collectionSpecs {
            let localItems = try localGraph.entities(in: spec.name)
            let remoteItems = try remoteGraph.entities(in: spec.name)
            var mergedItems: [String: ICloudJSONValue] = [:]

            for id in Set(localItems.keys).union(remoteItems.keys) {
                let key = spec.entityKey(id)
                let localRevision = local.revisions[key]
                    ?? localItems[id].flatMap {
                        localGraph.entityTimestamp($0, field: spec.timestampField)
                    }
                    ?? .distantPast
                let remoteRevision = remote.revisions[key]
                    ?? remoteItems[id].flatMap {
                        remoteGraph.entityTimestamp($0, field: spec.timestampField)
                    }
                    ?? .distantPast

                let winner: (value: ICloudJSONValue, revision: Date)?
                switch (localItems[id], remoteItems[id]) {
                case let (.some(localValue), .some(remoteValue)):
                    if localValue == remoteValue {
                        winner = (localValue, max(localRevision, remoteRevision))
                    } else if localRevision != remoteRevision {
                        winner = localRevision > remoteRevision
                            ? (localValue, localRevision)
                            : (remoteValue, remoteRevision)
                    } else {
                        // A stable content ordering makes identical-timestamp
                        // conflicts converge on every device.
                        winner = canonicalData(localValue).lexicographicallyPrecedes(
                            canonicalData(remoteValue)
                        ) ? (remoteValue, remoteRevision) : (localValue, localRevision)
                    }
                case let (.some(value), .none):
                    winner = (value, localRevision)
                case let (.none, .some(value)):
                    winner = (value, remoteRevision)
                case (.none, .none):
                    winner = nil
                }

                if let winner,
                   (mergedTombstones[key] ?? .distantPast) < winner.revision {
                    mergedItems[id] = winner.value
                    mergedRevisions[key] = winner.revision
                }
            }
            try mergedGraph.replaceEntities(mergedItems, in: spec.name)
        }

        try mergedGraph.reconcileIntegrity(
            revisions: &mergedRevisions,
            tombstones: &mergedTombstones,
            modifiedAt: modifiedAt
        )

        mergedGraph.setExportedAt(modifiedAt)
        return ICloudSyncEnvelope(
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            payload: try mergedGraph.encoded(),
            revisions: mergedRevisions,
            tombstones: mergedTombstones
        )
    }

    static func isEquivalent(
        _ lhs: ICloudSyncEnvelope,
        _ rhs: ICloudSyncEnvelope
    ) -> Bool {
        digest(lhs.payload) == digest(rhs.payload)
            && lhs.revisions == rhs.revisions
            && lhs.tombstones == rhs.tombstones
    }

    static func digest(_ data: Data) -> String {
        let normalized: Data
        if var graph = try? ICloudBackupGraph(data: data) {
            // `makeBackupData()` intentionally stamps every export with `.now`.
            // That metadata must not turn a read-only 60-second poll into a
            // new upload. Entity arrays are also sorted by stable UUID so a
            // different SwiftData fetch order remains semantically equal.
            graph.setExportedAt(Date(timeIntervalSinceReferenceDate: 0))
            for spec in ICloudBackupGraph.collectionSpecs {
                if let entities = try? graph.entities(in: spec.name) {
                    try? graph.replaceEntities(entities, in: spec.name)
                }
            }
            normalized = (try? graph.encoded()) ?? data
        } else {
            normalized = data
        }
        return SHA256.hash(data: normalized)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalData(_ value: ICloudJSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}

struct ICloudBackupCollectionSpec: Sendable {
    let name: String
    let timestampField: String

    func entityKey(_ id: String) -> String { "\(name):\(id.lowercased())" }
}

struct ICloudBackupGraph: Sendable {
    static let collectionSpecs = [
        ICloudBackupCollectionSpec(name: "songs", timestampField: "updatedAt"),
        ICloudBackupCollectionSpec(name: "events", timestampField: "updatedAt"),
        ICloudBackupCollectionSpec(name: "attempts", timestampField: "createdAt"),
        ICloudBackupCollectionSpec(name: "dailyGoals", timestampField: "updatedAt"),
        ICloudBackupCollectionSpec(name: "folders", timestampField: "updatedAt")
    ]

    private(set) var root: [String: ICloudJSONValue]

    init(data: Data) throws {
        let value = try JSONDecoder().decode(ICloudJSONValue.self, from: data)
        guard case .object(let root) = value,
              root["version"] != nil,
              Self.collectionSpecs.allSatisfy({
                  if case .array = root[$0.name] { return true }
                  return false
              })
        else { throw ICloudSyncError.invalidBackupGraph }
        self.root = root
        for spec in Self.collectionSpecs {
            _ = try entities(in: spec.name)
        }
    }

    func entities(in collection: String) throws -> [String: ICloudJSONValue] {
        guard case .array(let values) = root[collection] else {
            throw ICloudSyncError.invalidBackupGraph
        }
        var result: [String: ICloudJSONValue] = [:]
        for value in values {
            guard case .object(let object) = value,
                  case .string(let id)? = object["id"],
                  UUID(uuidString: id) != nil,
                  result[id.lowercased()] == nil
            else { throw ICloudSyncError.invalidBackupGraph }
            result[id.lowercased()] = value
        }
        return result
    }

    mutating func replaceEntities(
        _ values: [String: ICloudJSONValue],
        in collection: String
    ) throws {
        guard root[collection] != nil else {
            throw ICloudSyncError.invalidBackupGraph
        }
        root[collection] = .array(values.keys.sorted().compactMap { values[$0] })
    }

    func entityTimestamp(_ value: ICloudJSONValue, field: String) -> Date? {
        guard case .object(let object) = value,
              case .number(let seconds)? = object[field],
              seconds.isFinite
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A parent deletion must win over a stale child edit. This pass also
    /// resolves natural-key collisions (`sessionID` and daily-goal `key`) that
    /// can arise when two offline devices independently replay the same
    /// operation. The resulting graph always satisfies the backup importer's
    /// referential-integrity rules before it is written to iCloud.
    mutating func reconcileIntegrity(
        revisions: inout [String: Date],
        tombstones: inout [String: Date],
        modifiedAt: Date
    ) throws {
        let songs = try entities(in: "songs")
        let songIDs = Set(songs.keys)
        var events = try entities(in: "events")
        var attempts = try entities(in: "attempts")
        var dailyGoals = try entities(in: "dailyGoals")
        var folders = try entities(in: "folders")
        var removedKeys = Set<String>()

        events = events.filter { id, value in
            guard let songID = value.stringField("songID")?.lowercased(),
                  songIDs.contains(songID)
            else {
                removedKeys.insert("events:\(id)")
                return false
            }
            return true
        }
        let eventIDs = Set(events.keys)

        attempts = attempts.filter { id, value in
            guard let eventID = value.stringField("eventID")?.lowercased(),
                  eventIDs.contains(eventID)
            else {
                removedKeys.insert("attempts:\(id)")
                return false
            }
            return true
        }
        attempts = deduplicated(
            attempts,
            collection: "attempts",
            uniqueField: "sessionID",
            revisions: revisions,
            removedKeys: &removedKeys
        )

        dailyGoals = dailyGoals.filter { id, value in
            guard let eventID = value.stringField("eventID")?.lowercased(),
                  eventIDs.contains(eventID)
            else {
                removedKeys.insert("dailyGoals:\(id)")
                return false
            }
            return true
        }
        dailyGoals = deduplicated(
            dailyGoals,
            collection: "dailyGoals",
            uniqueField: "key",
            revisions: revisions,
            removedKeys: &removedKeys
        )

        for (id, value) in Array(folders) {
            guard let membership = value.stringArrayField("eventIDs") else {
                throw ICloudSyncError.invalidBackupGraph
            }
            let filtered = membership.filter { eventIDs.contains($0.lowercased()) }
            if filtered != membership {
                folders[id] = try value.replacingStringArrayField(
                    "eventIDs",
                    with: filtered
                )
                revisions["folders:\(id)"] = modifiedAt
            }
        }

        for key in removedKeys {
            revisions.removeValue(forKey: key)
            tombstones[key] = max(tombstones[key] ?? .distantPast, modifiedAt)
        }
        try replaceEntities(events, in: "events")
        try replaceEntities(attempts, in: "attempts")
        try replaceEntities(dailyGoals, in: "dailyGoals")
        try replaceEntities(folders, in: "folders")
    }

    private func deduplicated(
        _ values: [String: ICloudJSONValue],
        collection: String,
        uniqueField: String,
        revisions: [String: Date],
        removedKeys: inout Set<String>
    ) -> [String: ICloudJSONValue] {
        var winnerByNaturalKey: [String: (id: String, value: ICloudJSONValue)] = [:]
        for id in values.keys.sorted() {
            guard let value = values[id],
                  let naturalKey = value.stringField(uniqueField)?.lowercased()
            else {
                removedKeys.insert("\(collection):\(id)")
                continue
            }
            guard let existing = winnerByNaturalKey[naturalKey] else {
                winnerByNaturalKey[naturalKey] = (id, value)
                continue
            }
            let candidateRevision = revisions["\(collection):\(id)"] ?? .distantPast
            let existingRevision = revisions["\(collection):\(existing.id)"] ?? .distantPast
            if candidateRevision > existingRevision
                || (candidateRevision == existingRevision && id > existing.id) {
                removedKeys.insert("\(collection):\(existing.id)")
                winnerByNaturalKey[naturalKey] = (id, value)
            } else {
                removedKeys.insert("\(collection):\(id)")
            }
        }
        return Dictionary(uniqueKeysWithValues: winnerByNaturalKey.values.map {
            ($0.id, $0.value)
        })
    }

    mutating func setExportedAt(_ date: Date) {
        root["exportedAt"] = .number(date.timeIntervalSinceReferenceDate)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ICloudJSONValue.object(root))
    }
}

indirect enum ICloudJSONValue: Codable, Equatable, Sendable {
    case object([String: ICloudJSONValue])
    case array([ICloudJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ICloudJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ICloudJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension ICloudJSONValue {
    func stringField(_ name: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value)? = object[name]
        else { return nil }
        return value
    }

    func stringArrayField(_ name: String) -> [String]? {
        guard case .object(let object) = self,
              case .array(let values)? = object[name]
        else { return nil }
        let strings = values.compactMap { value -> String? in
            guard case .string(let string) = value else { return nil }
            return string
        }
        return strings.count == values.count ? strings : nil
    }

    func replacingStringArrayField(
        _ name: String,
        with strings: [String]
    ) throws -> ICloudJSONValue {
        guard case .object(var object) = self else {
            throw ICloudSyncError.invalidBackupGraph
        }
        object[name] = .array(strings.map(ICloudJSONValue.string))
        return .object(object)
    }
}

struct ICloudRemoteSnapshot: Sendable {
    /// The current document plus every unresolved iCloud file version. The
    /// caller must merge all of them before saving a resolved document.
    let envelopes: [ICloudSyncEnvelope]
}

enum ICloudContainerAvailability: Equatable, Sendable {
    case available
    case unavailable

    var message: String {
        switch self {
        case .available: "iCloud 已连接"
        case .unavailable: "请登录 iCloud 并开启 iCloud Drive"
        }
    }
}

protocol ICloudSyncBackendProtocol: Sendable {
    func availability() async -> ICloudContainerAvailability
    func fetchSnapshot() async throws -> ICloudRemoteSnapshot?
    func saveSnapshot(_ envelope: ICloudSyncEnvelope) async throws
}

actor ICloudSyncBackend: ICloudSyncBackendProtocol {
    static let containerIdentifier = "iCloud.com.kuoxiyu.GeoPractice"
    static let relativeDocumentPath = "Documents/GeoPractice/library-sync-v1.plist"

    private let containerIdentifier: String
    private let fileManager: FileManager

    init(
        containerIdentifier: String = containerIdentifier,
        fileManager: FileManager = .default
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
    }

    func availability() -> ICloudContainerAvailability {
        containerURL() == nil ? .unavailable : .available
    }

    func fetchSnapshot() async throws -> ICloudRemoteSnapshot? {
        guard let url = documentURL() else { return nil }
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        // Ask iCloud Drive to materialize an evicted document. Coordinated
        // reading below either succeeds immediately or reports a recoverable
        // error that the scheduler retries without touching local data.
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        var envelopes = [try coordinatedRead(from: url)]
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            envelopes.append(try coordinatedRead(from: version.url))
        }
        return ICloudRemoteSnapshot(envelopes: envelopes)
    }

    func saveSnapshot(_ envelope: ICloudSyncEnvelope) async throws {
        guard let url = documentURL() else {
            throw CocoaError(.ubiquitousFileUnavailable)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try envelope.encoded()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }

        // A new device can finish uploading a conflict between our fetch and
        // this write. Resolve only versions whose complete entity/tombstone
        // state is already contained in the document we just saved. Any late
        // branch remains unresolved and is merged by the next sync pass.
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        var canRemoveOtherVersions = true
        for version in conflicts {
            do {
                let conflict = try coordinatedRead(from: version.url)
                let verification = try ICloudBackupMerger.merge(
                    local: envelope,
                    remote: conflict,
                    modifiedAt: max(envelope.modifiedAt, conflict.modifiedAt),
                    deviceID: envelope.deviceID
                )
                if ICloudBackupMerger.isEquivalent(verification, envelope) {
                    version.isResolved = true
                } else {
                    canRemoveOtherVersions = false
                }
            } catch {
                canRemoveOtherVersions = false
            }
        }
        if canRemoveOtherVersions {
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }

    private func coordinatedRead(from url: URL) throws -> ICloudSyncEnvelope {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
            }
        }
        if let coordinationError { throw coordinationError }
        guard let operationResult else {
            throw CocoaError(.fileReadUnknown)
        }
        return try ICloudSyncEnvelope.decode(operationResult.get())
    }

    private func containerURL() -> URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private func documentURL() -> URL? {
        containerURL()?.appendingPathComponent(Self.relativeDocumentPath)
    }
}

struct ICloudSyncLocalStateStore: Sendable {
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.rootDirectory = applicationSupport
                .appendingPathComponent("GeoPractice/CloudSync", isDirectory: true)
        }
    }

    func loadBaseline() throws -> ICloudSyncEnvelope? {
        let url = rootDirectory.appendingPathComponent("baseline.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ICloudSyncEnvelope.decode(Data(contentsOf: url))
    }

    func saveBaseline(_ envelope: ICloudSyncEnvelope) throws {
        try ensureDirectory(rootDirectory)
        try envelope.encoded().write(
            to: rootDirectory.appendingPathComponent("baseline.plist"),
            options: [.atomic, .completeFileProtection]
        )
    }

    func saveRecoveryCopy(_ payload: Data, at date: Date) throws {
        let recoveryDirectory = rootDirectory.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try ensureDirectory(recoveryDirectory)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let name = "before-cloud-\(stamp)-\(ICloudBackupMerger.digest(payload).prefix(10)).geopracticebackup"
        try payload.write(
            to: recoveryDirectory.appendingPathComponent(name),
            options: [.atomic, .completeFileProtection]
        )

        let copies = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "geopracticebackup" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for oldCopy in copies.dropLast(5) {
            try? FileManager.default.removeItem(at: oldCopy)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}
