import Combine
import Foundation
import SwiftData

/// Persisted song-level metadata. Practice sections remain `PracticeEvent`
/// models so their stable UUIDs and immutable attempt history survive edits.
@Model
final class PracticeSong {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Explicit v1.1 metadata; nil means unmapped legacy data (SG-04).
    var coreStructureData: Data?
    var group: String
    var isArchived: Bool
    var deletedAt: Date?
    var deletionExpiresAt: Date? { deletedAt?.addingTimeInterval(7 * 24 * 60 * 60) }
    var multiplier: Int
    var resetsDaily: Bool
    var endDate: Date
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        group: String = "未分组",
        isArchived: Bool = false,
        multiplier: Int = 1,
        resetsDaily: Bool = true,
        endDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now,
        sortIndex: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.group = Self.cleanGroup(group)
        self.isArchived = isArchived
        // Kept in the persisted schema for compatibility with builds that
        // exposed a per-tap multiplier. A completion action is now always +1.
        self.multiplier = 1
        self.resetsDaily = resetsDaily
        self.endDate = endDate
        self.sortIndex = max(0, sortIndex)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func update(
        name: String,
        group: String,
        isArchived: Bool,
        multiplier: Int,
        resetsDaily: Bool,
        endDate: Date,
        sortIndex: Int? = nil,
        at date: Date = .now
    ) {
        self.name = Self.cleanName(name)
        self.group = Self.cleanGroup(group)
        self.isArchived = isArchived
        self.multiplier = 1
        self.resetsDaily = resetsDaily
        self.endDate = endDate
        if let sortIndex { self.sortIndex = max(0, sortIndex) }
        updatedAt = date
    }

    private static func cleanName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名曲目" : cleaned
    }

    private static func cleanGroup(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未分组" : cleaned
    }
}

struct PracticeSectionDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Authoritative all-time duration totals projected from a practice section.
///
/// The legacy `durationMilliseconds` total remains on
/// `PracticeSectionSnapshot` for compatibility. This per-hand projection is
/// what filtered statistics use so selecting one hand never inherits time
/// recorded by another hand.
struct PracticeHandDurationSnapshot: Equatable, Sendable {
    let left: Int64
    let right: Int64
    let both: Int64

    init(left: Int64 = 0, right: Int64 = 0, both: Int64 = 0) {
        self.left = max(0, left)
        self.right = max(0, right)
        self.both = max(0, both)
    }

    func value(for hand: PracticeHand) -> Int64 {
        switch hand {
        case .left: left
        case .right: right
        case .both: both
        }
    }

    var total: Int64 {
        Self.saturatedAdd(Self.saturatedAdd(left, right), both)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int64.max : sum
    }
}

struct PracticeSectionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let songID: UUID
    let name: String
    let sortIndex: Int
    let preset: MetronomePreset
    let counts: PracticeGoalCounts
    let durationMilliseconds: Int64
    let durationByHand: PracticeHandDurationSnapshot
    let lastPracticed: Date?
    let goalProgress: PracticeGoalProgress?
    /// The current goal must not claim attempts recorded before it existed.
    let goalEnabledAt: Date?

    init(
        id: UUID,
        songID: UUID,
        name: String,
        sortIndex: Int,
        preset: MetronomePreset,
        counts: PracticeGoalCounts,
        durationMilliseconds: Int64,
        durationByHand: PracticeHandDurationSnapshot = PracticeHandDurationSnapshot(),
        lastPracticed: Date?,
        goalProgress: PracticeGoalProgress?,
        goalEnabledAt: Date?
    ) {
        self.id = id
        self.songID = songID
        self.name = name
        self.sortIndex = sortIndex
        self.preset = preset
        self.counts = counts
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.durationByHand = durationByHand
        self.lastPracticed = lastPracticed
        self.goalProgress = goalProgress
        self.goalEnabledAt = goalEnabledAt
    }

    var completedCount: Int { goalProgress?.completed.total ?? counts.total }
    var target: Int? { goalProgress?.targets.total }
    var bpm: Int { preset.bpm }
    var beats: Int { preset.beats }
    var note: String { preset.subdivisionTitle }

    func durationMilliseconds(for hand: PracticeHand) -> Int64 {
        durationByHand.value(for: hand)
    }
}

struct PracticeSongSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let group: String
    let sections: [PracticeSectionSnapshot]
    let resetsDaily: Bool
    let endDate: Date
    let sortIndex: Int
    let createdAt: Date
    let updatedAt: Date
    let isArchived: Bool

    private var representativeTargets: PracticeGoalCounts {
        sections.first?.goalProgress?.targets ?? PracticeGoalCounts()
    }

    var leftGoal: Int { representativeTargets.left }
    var rightGoal: Int { representativeTargets.right }
    var bothGoal: Int { representativeTargets.both }
}

/// Period completion is deliberately song-weighted instead of target-weighted.
///
/// Each active song with at least one effective target first earns its own
/// integer percentage (with every section/hand capped at its corresponding
/// target). The displayed total is then the arithmetic mean of those song
/// percentages. Archived songs and songs without targets never enter the
/// denominator.
enum PracticePeriodCompletionStatistics {
    static func percentage(
        songs: [PracticeSongSnapshot],
        records: [PracticeHistoryRecordSnapshot],
        selectedSongID: UUID? = nil,
        interval: DateInterval
    ) -> Int? {
        let scopedSongs = songs.filter { song in
            !song.isArchived && (selectedSongID == nil || song.id == selectedSongID)
        }

        let recordsByEventID = Dictionary(grouping: records.compactMap { record in
            record.sourceEventID.map { ($0, record) }
        }, by: { $0.0 })

        let songPercentages = scopedSongs.compactMap { song -> Int? in
            var creditedTotal = 0
            var targetTotal = 0

            for section in song.sections {
                guard let goal = section.goalProgress,
                      goal.targets.total > 0
                else { continue }

                let completed = (recordsByEventID[section.id] ?? [])
                    .lazy
                    .map(\.1)
                    .filter { record in
                        record.finishedAt >= interval.start
                            && record.finishedAt < interval.end
                            && (section.goalEnabledAt.map {
                                record.finishedAt >= $0
                            } ?? true)
                    }
                    .reduce(PracticeGoalCounts()) { partial, record in
                        partial.adding(PracticeGoalCounts(
                            left: record.leftCount,
                            right: record.rightCount,
                            both: record.bothCount
                        ))
                    }

                targetTotal = saturatedAdd(targetTotal, goal.targets.total)
                creditedTotal = saturatedAdd(
                    creditedTotal,
                    completed.capped(to: goal.targets).total
                )
            }

            guard targetTotal > 0 else { return nil }
            let percentage = Double(creditedTotal) / Double(targetTotal) * 100
            return min(100, max(0, Int(percentage.rounded())))
        }

        guard !songPercentages.isEmpty else { return nil }
        let sum = songPercentages.reduce(0, saturatedAdd)
        return min(
            100,
            max(0, Int((Double(sum) / Double(songPercentages.count)).rounded()))
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(max(0, rhs))
        return overflowed ? Int.max : sum
    }
}

enum PracticeLibraryStoreError: LocalizedError, Equatable {
    case notConfigured
    case songNotFound
    case eventNotFound
    case emptySongName
    case emptySectionName
    case duplicateSection
    case activeSessionProtected
    case invalidBackup
    case historyRecordNotFound
    case emptyHistoryRecord
    case invalidHistoryRecordTime
    case historyCompletionNotFound
    case historySummaryNotFound

    var errorDescription: String? {
        switch self {
        case .notConfigured: "练习资料库尚未连接到本地数据。"
        case .songNotFound: "找不到这首曲目。"
        case .eventNotFound: "找不到这个练习段落。"
        case .emptySongName: "请输入曲目名称。"
        case .emptySectionName: "每个练习段落都需要填写名称。"
        case .duplicateSection: "练习段落数据重复，请重新打开编辑页面后再试。"
        case .activeSessionProtected: "该曲目正在练习中，请结束当前练习后再删除。"
        case .invalidBackup: "备份文件无效或版本不受支持。"
        case .historyRecordNotFound: "这条历史记录已经不存在。"
        case .emptyHistoryRecord: "记录至少需要保留一次完成或一段有效时长；如需移除请使用删除。"
        case .invalidHistoryRecordTime: "记录的开始时间不能晚于结束时间。"
        case .historyCompletionNotFound: "这次完成记录已经不存在。"
        case .historySummaryNotFound: "这条汇总记录已经变化或不存在，请重新打开历史记录。"
        }
    }
}

/// Main-actor projection and mutation boundary for the persisted practice
/// library. SwiftData is the only source of truth; published values are fresh
/// immutable snapshots rebuilt after every successful transaction.
@MainActor
final class PracticeLibraryStore: ObservableObject {
    @Published private(set) var songs: [PracticeSongSnapshot] = []
    @Published private(set) var records: [PracticeHistoryRecordSnapshot] = []
    @Published private(set) var lastErrorMessage: String?

    /// The live session controller updates this value. Song deletion refuses
    /// to remove any child event matching it.
    var protectedEventID: UUID?

    private var modelContext: ModelContext?
    private var songIDByEventID: [UUID: UUID] = [:]

    init() {}

    init(modelContext: ModelContext) throws {
        try configure(modelContext: modelContext)
    }

    var activeSongs: [PracticeSongSnapshot] {
        songs.filter { !$0.isArchived }
    }

    var archivedSongs: [PracticeSongSnapshot] {
        songs.filter(\.isArchived)
    }

    var sections: [PracticeSectionSnapshot] {
        songs.flatMap(\.sections)
    }

    func configure(modelContext: ModelContext) throws {
        if let current = self.modelContext,
           current.container === modelContext.container {
            // `onAppear` may run again after sheets, scene transitions, or an
            // appearance change. Keep the store-owned context selected by a
            // completed import instead of switching back to a stale SwiftUI
            // environment context from the same container.
            try reload()
            return
        }
        self.modelContext = modelContext
        do {
            try bootstrap()
        } catch {
            self.modelContext = nil
            throw error
        }
    }

    /// Migrates every pre-song event one-to-one without replacing its UUID or
    /// touching its attempts. Folder membership supplies the initial group.
    func bootstrap() throws {
        let context = try requireContext()
        let events = try context.fetch(FetchDescriptor<PracticeEvent>())
        var persistedSongs = try context.fetch(FetchDescriptor<PracticeSong>())
        let folders = try context.fetch(FetchDescriptor<PracticeFolder>())
        var knownSongIDs = Set(persistedSongs.map(\.id))
        var nextSortIndex = (persistedSongs.map(\.sortIndex).max() ?? -1) + 1
        var changed = false

        // Older prototype builds allowed a single completion tap to add N
        // samples. Normalize that retired setting during migration so beat
        // count and practice count can never be confused again.
        for song in persistedSongs where song.multiplier != 1 {
            song.multiplier = 1
            changed = true
        }

        for event in events.sorted(by: Self.eventOrder) {
            if let songID = event.songID, knownSongIDs.contains(songID) {
                if event.sectionSortIndex == nil {
                    event.sectionSortIndex = 0
                    changed = true
                }
                continue
            }

            let group = PracticeFolder.folder(containing: event.id, in: folders)?.name ?? "未分组"
            let song = PracticeSong(
                name: event.name,
                group: group,
                // Legacy events only had long-running plan goals. Treating
                // them as daily goals would make their visible progress drop
                // to zero immediately after migration.
                resetsDaily: false,
                // Older releases had no song end date. Giving migrated data
                // the new-song one-month default would silently hide an
                // existing practice item a month after upgrading.
                endDate: .distantFuture,
                sortIndex: nextSortIndex,
                createdAt: event.createdAt,
                updatedAt: event.updatedAt
            )
            nextSortIndex += 1
            context.insert(song)
            persistedSongs.append(song)
            knownSongIDs.insert(song.id)
            event.songID = song.id
            event.sectionSortIndex = 0
            changed = true
        }

        if changed {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
        try reload()
    }

    func reload() throws {
        let context = try requireContext()
        let songModels = try context.fetch(FetchDescriptor<PracticeSong>())
        let now = Date.now
        let calendar = Calendar.autoupdatingCurrent
        var didAutoArchive = false
        for song in songModels where song.deletedAt == nil && !song.isArchived
            && Self.hasPassedEndDate(song.endDate, now: now, calendar: calendar) {
            song.isArchived = true
            song.updatedAt = now
            didAutoArchive = true
        }
        if didAutoArchive {
            do {
                try context.save()
            } catch {
                context.rollback()
                record(error)
                throw error
            }
        }
        let eventModels = try context.fetch(FetchDescriptor<PracticeEvent>())
        let attempts = try context.fetch(FetchDescriptor<PracticeAttempt>())
        let eventsByID = Dictionary(uniqueKeysWithValues: eventModels.map { ($0.id, $0) })
        let attemptsByEvent = Dictionary(grouping: attempts, by: \.eventID)

        songIDByEventID = eventModels.reduce(into: [:]) { result, event in
            if let songID = event.songID { result[event.id] = songID }
        }
        let deletedSongIDs = Set(songModels.filter { $0.deletedAt != nil }.map(\.id))
        records = attempts.filter { attempt in
            guard let songID = eventsByID[attempt.eventID]?.songID else { return true }
            return !deletedSongIDs.contains(songID)
        }.map { attempt in
            attempt.makeStatisticsSnapshot(
                eventNameFallback: eventsByID[attempt.eventID]?.name ?? "未命名练习"
            )
        }
        .sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        songs = songModels.filter { $0.deletedAt == nil }.map { song in
            let childEvents = eventModels
                .filter { $0.songID == song.id }
                .sorted(by: Self.eventOrder)
            let sectionSnapshots = childEvents.map { event in
                let eventAttempts = attemptsByEvent[event.id] ?? []
                return Self.makeSectionSnapshot(
                    event: event,
                    song: song,
                    attempts: eventAttempts,
                    now: now,
                    calendar: calendar
                )
            }
            return PracticeSongSnapshot(
                id: song.id,
                name: song.name,
                group: song.group,
                sections: sectionSnapshots,
                resetsDaily: song.resetsDaily,
                endDate: song.endDate,
                sortIndex: song.sortIndex,
                createdAt: song.createdAt,
                updatedAt: song.updatedAt,
                isArchived: song.isArchived
            )
        }
        .sorted(by: Self.songOrder)
        lastErrorMessage = nil
    }

    func song(id: UUID) -> PracticeSongSnapshot? {
        songs.first { $0.id == id }
    }

    func song(forEventID eventID: UUID) -> PracticeSongSnapshot? {
        songIDByEventID[eventID].flatMap { song(id: $0) }
    }

    func songID(forEventID eventID: UUID) -> UUID? {
        songIDByEventID[eventID]
    }

    func eventSnapshot(id: UUID) -> PracticeSectionSnapshot? {
        sections.first { $0.id == id }
    }

    func event(id: UUID) -> PracticeEvent? {
        guard let context = modelContext else { return nil }
        return try? fetchEvent(id: id, in: context)
    }

    func songModel(id: UUID) -> PracticeSong? {
        guard let context = modelContext else { return nil }
        return try? fetchSong(id: id, in: context)
    }

    func records(for songID: UUID) -> [PracticeHistoryRecordSnapshot] {
        let eventIDs = Set(song(id: songID)?.sections.map(\.id) ?? [])
        return records.filter { record in
            record.sourceEventID.map(eventIDs.contains) ?? false
        }
    }

    func records(forEventID eventID: UUID) -> [PracticeHistoryRecordSnapshot] {
        records.filter { $0.sourceEventID == eventID }
    }

    func hasAttemptToday(
        eventID: UUID,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        records(forEventID: eventID).contains {
            calendar.isDate($0.finishedAt, inSameDayAs: now)
        }
    }

    func activeDays(for songID: UUID) -> Int {
        PracticeStatisticsEngine.summary(
            records: records(for: songID),
            calendar: .autoupdatingCurrent
        ).activeDayCount
    }

    func weekCounts(for songID: UUID, now: Date = .now) -> [Int] {
        let calendar = Calendar.autoupdatingCurrent
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            return records(for: songID)
                .filter { calendar.isDate($0.finishedAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.totalCount }
        }
    }

    /// Aggregate completion credits every event/hand only up to its own goal.
    func completionPercentage(songID: UUID?) -> Int? {
        let scoped = songs.filter { song in
            !song.isArchived && (songID == nil || song.id == songID)
        }
        let progresses = scoped.flatMap(\.sections).compactMap(\.goalProgress)
        let targetTotal = progresses.reduce(0) { $0 + $1.targets.total }
        guard targetTotal > 0 else { return nil }
        let credited = progresses.reduce(0) { $0 + $1.creditedCompletedTotal }
        return min(100, max(0, Int((Double(credited) / Double(targetTotal) * 100).rounded())))
    }

    /// Completion for a dated statistics period. Unlike the legacy current
    /// plan projection above, this derives every numerator from immutable,
    /// persisted attempts inside the requested half-open interval.
    func completionPercentage(
        songID: UUID?,
        within interval: DateInterval
    ) -> Int? {
        PracticePeriodCompletionStatistics.percentage(
            songs: songs,
            records: records,
            selectedSongID: songID,
            interval: interval
        )
    }

    func launch(song: PracticeSongSnapshot, section: PracticeSectionSnapshot) -> PrototypePracticeLaunch {
        makeLaunch(song: song, section: section)
    }

    func launch(eventID: UUID) -> PrototypePracticeLaunch? {
        guard let song = song(forEventID: eventID),
              let section = song.sections.first(where: { $0.id == eventID })
        else { return nil }
        return makeLaunch(song: song, section: section)
    }

    func goalLaunchContext(
        eventID: UUID,
        at date: Date = .now,
        timeZone: TimeZone = .current
    ) throws -> PracticeGoalLaunchContext? {
        let context = try requireContext()
        do {
            guard let event = try fetchEvent(id: eventID, in: context) else {
                throw PracticeLibraryStoreError.eventNotFound
            }
            let song: PracticeSong?
            if let songID = event.songID {
                song = try fetchSong(id: songID, in: context)
            } else {
                song = nil
            }
            let dailyGoal: PracticeDailyGoal?
            if song?.resetsDaily == true, let plan = event.goalPlan {
                dailyGoal = try PracticeDailyGoal.create(
                    for: event.id,
                    planID: plan.id,
                    targets: plan.targets,
                    at: date,
                    timeZone: timeZone,
                    in: context
                )
            } else {
                dailyGoal = nil
            }
            let launchContext = try PracticeGoalLaunchContext.capture(
                for: event,
                dailyGoal: dailyGoal,
                launchedAt: date,
                timeZone: timeZone,
                in: context
            )
            if context.hasChanges {
                try context.save()
            }
            return launchContext
        } catch {
            context.rollback()
            record(error)
            throw error
        }
    }

    @discardableResult
    func setArchived(_ id: UUID, _ archived: Bool) throws -> Bool {
        let context = try requireContext()
        guard let song = try fetchSong(id: id, in: context) else { return false }
        song.isArchived = archived
        if !archived,
           Self.hasPassedEndDate(
               song.endDate,
               now: .now,
               calendar: .autoupdatingCurrent
           ) {
            // Restoring an expired song means the user intends to continue it;
            // grant a fresh month instead of immediately re-archiving it in
            // the following reload.
            song.endDate = Calendar.autoupdatingCurrent.date(
                byAdding: .month,
                value: 1,
                to: .now
            ) ?? .now
        }
        song.updatedAt = .now
        do {
            try context.save()
            reloadAfterCommittedMutation()
            return true
        } catch {
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Creates or edits a song. Section draft UUIDs are authoritative, so a
    /// rename updates the existing `PracticeEvent` and retains all attempts.
    @discardableResult
    func saveSong(
        id: UUID?,
        name: String,
        group: String,
        sections sectionDrafts: [PracticeSectionDraft],
        leftGoal: Int,
        rightGoal: Int,
        bothGoal: Int,
        multiplier: Int,
        resetsDaily: Bool,
        endDate: Date,
        archived: Bool,
        newSectionPreset: MetronomePreset = .standard
    ) throws -> UUID {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { throw PracticeLibraryStoreError.emptySongName }
        let context = try requireContext()
        let now = Date.now
        let drafts = try Self.normalizedDrafts(sectionDrafts)
        let goalTargets = PracticeGoalCounts(
            left: leftGoal,
            right: rightGoal,
            both: bothGoal
        )
        do {
            let song: PracticeSong
            let existingEvents: [PracticeEvent]
            let nextSortIndex: Int
            if let id {
                guard let model = try fetchSong(id: id, in: context) else {
                    throw PracticeLibraryStoreError.songNotFound
                }
                song = model
                existingEvents = try events(for: id, in: context)
                nextSortIndex = model.sortIndex
            } else {
                let allSongs = try context.fetch(FetchDescriptor<PracticeSong>())
                nextSortIndex = (allSongs.map(\.sortIndex).max() ?? -1) + 1
                song = PracticeSong(
                    name: cleanedName,
                    group: group,
                    isArchived: archived,
                    multiplier: 1,
                    resetsDaily: resetsDaily,
                    endDate: endDate,
                    sortIndex: nextSortIndex,
                    createdAt: now,
                    updatedAt: now
                )
                existingEvents = []
            }

            let retainedIDs = Set(drafts.map(\.id))
            let removedEvents = existingEvents.filter { !retainedIDs.contains($0.id) }
            if let protectedEventID,
               removedEvents.contains(where: { $0.id == protectedEventID }) {
                throw PracticeLibraryStoreError.activeSessionProtected
            }
            // Complete every throwing fetch before staging model mutations.
            let folders = try context.fetch(FetchDescriptor<PracticeFolder>())

            if id == nil {
                context.insert(song)
            } else {
                song.update(
                    name: cleanedName,
                    group: group,
                    isArchived: archived,
                    multiplier: 1,
                    resetsDaily: resetsDaily,
                    endDate: endDate,
                    sortIndex: nextSortIndex,
                    at: now
                )
            }

            let existingByID = Dictionary(
                uniqueKeysWithValues: existingEvents.map { ($0.id, $0) }
            )
            for (index, draft) in drafts.enumerated() {
                let event: PracticeEvent
                if let existing = existingByID[draft.id] {
                    event = existing
                    event.name = draft.name
                    event.songID = song.id
                    event.sectionSortIndex = index
                    event.updatedAt = now
                } else {
                    event = PracticeEvent(
                        id: draft.id,
                        songID: song.id,
                        sectionSortIndex: index,
                        name: draft.name,
                        preset: newSectionPreset.normalized,
                        createdAt: now,
                        updatedAt: now
                    )
                    context.insert(event)
                }
                if goalTargets.total > 0 {
                    event.updateGoalPlanTargets(goalTargets, at: now)
                } else {
                    event.disableGoalPlan(at: now)
                }
            }

            for event in removedEvents {
                try deleteEventGraph(event, folders: folders, in: context)
            }
            try context.save()
            reloadAfterCommittedMutation()
            return song.id
        } catch {
            context.rollback()
            record(error)
            throw error
        }
    }

    @discardableResult
    func deleteSong(_ id: UUID) throws -> Bool {
        let context = try requireContext()
        do {
            guard let song = try fetchSong(id: id, in: context) else { return false }
            let childEvents = try events(for: id, in: context)
            if let protectedEventID,
               childEvents.contains(where: { $0.id == protectedEventID }) {
                throw PracticeLibraryStoreError.activeSessionProtected
            }
            let folders = try context.fetch(FetchDescriptor<PracticeFolder>())
            for event in childEvents {
                try deleteEventGraph(event, folders: folders, in: context)
            }
            context.delete(song)
            try context.save()
            reloadAfterCommittedMutation()
            return true
        } catch {
            context.rollback()
            record(error)
            throw error
        }
    }

    @discardableResult
    func commit(summary: PracticeSessionSummary) throws -> PracticeAttemptCommitResult {
        let context = try requireContext()
        guard let eventID = summary.sourceEventID,
              let event = try fetchEvent(id: eventID, in: context)
        else { throw PracticeLibraryStoreError.eventNotFound }
        do {
            let result = try event.commit(summary: summary, in: context)
            reloadAfterCommittedMutation()
            return result
        } catch {
            record(error)
            throw error
        }
    }

    /// Atomically updates one persisted attempt and the event-level aggregate
    /// that powers section progress and all statistics screens.
    func updateHistoryRecord(_ edit: PracticeHistoryRecordEditDraft) throws {
        guard edit.startedAt <= edit.finishedAt else {
            throw PracticeLibraryStoreError.invalidHistoryRecordTime
        }
        guard edit.totalCount > 0 || edit.totalDurationMilliseconds > 0 else {
            throw PracticeLibraryStoreError.emptyHistoryRecord
        }
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: edit.id, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context)
        else { throw PracticeLibraryStoreError.historyRecordNotFound }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldDurations = (
            attempt.stats(for: .left).durationMilliseconds,
            attempt.stats(for: .right).durationMilliseconds,
            attempt.stats(for: .both).durationMilliseconds
        )
        let oldFinishedAt = attempt.finishedAt
        let newCounts = PracticeGoalCounts(
            left: edit.value(for: .left).count,
            right: edit.value(for: .right).count,
            both: edit.value(for: .both).count
        )
        do {
            attempt.applyHistoryEdit(edit)
            Self.replaceAttemptAggregate(
                on: event,
                removing: (
                    left: oldCounts.left,
                    right: oldCounts.right,
                    both: oldCounts.both
                ),
                adding: (newCounts.left, newCounts.right, newCounts.both),
                removingDuration: oldDurations,
                addingDuration: (
                    edit.value(for: .left).durationMilliseconds,
                    edit.value(for: .right).durationMilliseconds,
                    edit.value(for: .both).durationMilliseconds
                )
            )
            if let oldPlan {
                let oldBaselineContribution = oldFinishedAt < oldPlan.enabledAt
                    ? oldCounts
                    : PracticeGoalCounts()
                let newBaselineContribution = edit.finishedAt < oldPlan.enabledAt
                    ? newCounts
                    : PracticeGoalCounts()
                event.setGoalPlan(
                    PracticeGoalPlan(
                        id: oldPlan.id,
                        targets: oldPlan.targets,
                        baseline: oldPlan.baseline
                            .subtractingFloorAtZero(oldBaselineContribution)
                            .adding(newBaselineContribution),
                        enabledAt: oldPlan.enabledAt
                    ),
                    at: .now
                )
            }
            try context.save()
            reloadAfterCommittedMutation()
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Deletes only after the caller's confirmation action invokes this
    /// method. There is deliberately no optimistic removal from `records`.
    @discardableResult
    func deleteHistoryRecord(id: UUID) throws -> Bool {
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: id, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context)
        else { return false }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldDurations = (
            attempt.stats(for: .left).durationMilliseconds,
            attempt.stats(for: .right).durationMilliseconds,
            attempt.stats(for: .both).durationMilliseconds
        )
        do {
            Self.replaceAttemptAggregate(
                on: event,
                removing: (oldCounts.left, oldCounts.right, oldCounts.both),
                adding: (0, 0, 0),
                removingDuration: oldDurations,
                addingDuration: (0, 0, 0)
            )
            if let oldPlan, attempt.finishedAt < oldPlan.enabledAt {
                event.setGoalPlan(
                    PracticeGoalPlan(
                        id: oldPlan.id,
                        targets: oldPlan.targets,
                        baseline: oldPlan.baseline.subtractingFloorAtZero(oldCounts),
                        enabledAt: oldPlan.enabledAt
                    ),
                    at: .now
                )
            }
            context.delete(attempt)
            try context.save()
            reloadAfterCommittedMutation()
            return true
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    func updateHistoryCompletion(
        _ edit: PracticeHistoryCompletionEditDraft
    ) throws {
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: edit.recordID, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context),
              let oldSample = attempt.completions.first(where: { $0.id == edit.id })
        else { throw PracticeLibraryStoreError.historyCompletionNotFound }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldFinishedAt = attempt.finishedAt
        do {
            guard attempt.applyHistoryCompletionEdit(edit) else {
                throw PracticeLibraryStoreError.historyCompletionNotFound
            }
            let newCounts = PracticeGoalCounts(attempt: attempt)
            if oldSample.hand != edit.hand {
                Self.replaceAttemptAggregate(
                    on: event,
                    removing: (
                        left: oldSample.hand == .left ? 1 : 0,
                        right: oldSample.hand == .right ? 1 : 0,
                        both: oldSample.hand == .both ? 1 : 0
                    ),
                    adding: (
                        left: edit.hand == .left ? 1 : 0,
                        right: edit.hand == .right ? 1 : 0,
                        both: edit.hand == .both ? 1 : 0
                    ),
                    removingDuration: (0, 0, 0),
                    addingDuration: (0, 0, 0)
                )
            }
            if let oldPlan {
                let oldBaselineContribution = oldFinishedAt < oldPlan.enabledAt
                    ? oldCounts
                    : PracticeGoalCounts()
                let newBaselineContribution = attempt.finishedAt < oldPlan.enabledAt
                    ? newCounts
                    : PracticeGoalCounts()
                event.setGoalPlan(
                    PracticeGoalPlan(
                        id: oldPlan.id,
                        targets: oldPlan.targets,
                        baseline: oldPlan.baseline
                            .subtractingFloorAtZero(oldBaselineContribution)
                            .adding(newBaselineContribution),
                        enabledAt: oldPlan.enabledAt
                    ),
                    at: .now
                )
            }
            try context.save()
            reloadAfterCommittedMutation()
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    @discardableResult
    func deleteHistoryCompletion(
        recordID: UUID,
        completionID: UUID
    ) throws -> Bool {
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: recordID, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context),
              let sample = attempt.completions.first(where: { $0.id == completionID })
        else { return false }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldFinishedAt = attempt.finishedAt
        do {
            guard attempt.removeHistoryCompletion(id: completionID) else {
                throw PracticeLibraryStoreError.historyCompletionNotFound
            }
            Self.replaceAttemptAggregate(
                on: event,
                removing: (
                    left: sample.hand == .left ? 1 : 0,
                    right: sample.hand == .right ? 1 : 0,
                    both: sample.hand == .both ? 1 : 0
                ),
                adding: (0, 0, 0),
                removingDuration: (0, 0, 0),
                addingDuration: (0, 0, 0)
            )
            let newCounts = PracticeGoalCounts(attempt: attempt)
            if let oldPlan {
                let oldBaselineContribution = oldFinishedAt < oldPlan.enabledAt
                    ? oldCounts
                    : PracticeGoalCounts()
                let newBaselineContribution = attempt.finishedAt < oldPlan.enabledAt
                    ? newCounts
                    : PracticeGoalCounts()
                event.setGoalPlan(
                    PracticeGoalPlan(
                        id: oldPlan.id,
                        targets: oldPlan.targets,
                        baseline: oldPlan.baseline
                            .subtractingFloorAtZero(oldBaselineContribution)
                            .adding(newBaselineContribution),
                        enabledAt: oldPlan.enabledAt
                    ),
                    at: .now
                )
            }
            if attempt.leftCount == 0,
               attempt.rightCount == 0,
               attempt.bothCount == 0,
               attempt.leftDurationMilliseconds == 0,
               attempt.rightDurationMilliseconds == 0,
               attempt.bothDurationMilliseconds == 0 {
                context.delete(attempt)
            }
            try context.save()
            reloadAfterCommittedMutation()
            return true
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Updates one manual/legacy aggregate row while preserving unrelated
    /// live completion samples in the same attempt.
    func updateHistoryUnitemized(
        _ edit: PracticeHistoryUnitemizedEditDraft
    ) throws {
        guard edit.count > 0 else {
            throw PracticeLibraryStoreError.emptyHistoryRecord
        }
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: edit.recordID, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context)
        else { throw PracticeLibraryStoreError.historySummaryNotFound }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldDurations = (
            attempt.stats(for: .left).durationMilliseconds,
            attempt.stats(for: .right).durationMilliseconds,
            attempt.stats(for: .both).durationMilliseconds
        )
        let oldFinishedAt = attempt.finishedAt
        do {
            guard attempt.applyHistoryUnitemizedEdit(edit) else {
                throw PracticeLibraryStoreError.historySummaryNotFound
            }
            let newCounts = PracticeGoalCounts(attempt: attempt)
            let newDurations = (
                attempt.stats(for: .left).durationMilliseconds,
                attempt.stats(for: .right).durationMilliseconds,
                attempt.stats(for: .both).durationMilliseconds
            )
            Self.replaceAttemptAggregate(
                on: event,
                removing: (oldCounts.left, oldCounts.right, oldCounts.both),
                adding: (newCounts.left, newCounts.right, newCounts.both),
                removingDuration: oldDurations,
                addingDuration: newDurations
            )
            Self.reconcileGoalBaseline(
                on: event,
                plan: oldPlan,
                oldCounts: oldCounts,
                oldFinishedAt: oldFinishedAt,
                newCounts: newCounts,
                newFinishedAt: attempt.finishedAt
            )
            try context.save()
            reloadAfterCommittedMutation()
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Removes an unitemized row only when the confirmation action calls this
    /// method. When that row represents the complete attempt, its duration is
    /// deleted with the attempt; hybrid records keep unrelated samples intact.
    @discardableResult
    func deleteHistoryUnitemized(
        _ edit: PracticeHistoryUnitemizedEditDraft
    ) throws -> Bool {
        let context = try requireContext()
        guard let attempt = try PracticeAttempt.find(id: edit.recordID, in: context),
              let event = try fetchEvent(id: attempt.eventID, in: context)
        else { return false }

        let targetIDs = Set(edit.completionIDs)
        let isWholeSampleBatch = !targetIDs.isEmpty
            && targetIDs == Set(attempt.completions.map(\.id))
            && edit.originalCount == PracticeGoalCounts(attempt: attempt).total
        if isWholeSampleBatch {
            return try deleteHistoryRecord(id: edit.recordID)
        }

        let eventSnapshot = event.aggregateSnapshot()
        let oldPlan = event.goalPlan
        let oldCounts = PracticeGoalCounts(attempt: attempt)
        let oldDurations = (
            attempt.stats(for: .left).durationMilliseconds,
            attempt.stats(for: .right).durationMilliseconds,
            attempt.stats(for: .both).durationMilliseconds
        )
        let oldFinishedAt = attempt.finishedAt
        var deletion = edit
        deletion.hand = edit.originalHand
        deletion.count = 0
        deletion.durationMilliseconds = nil
        do {
            guard attempt.applyHistoryUnitemizedEdit(deletion) else {
                throw PracticeLibraryStoreError.historySummaryNotFound
            }
            let newCounts = PracticeGoalCounts(attempt: attempt)
            let newDurations = (
                attempt.stats(for: .left).durationMilliseconds,
                attempt.stats(for: .right).durationMilliseconds,
                attempt.stats(for: .both).durationMilliseconds
            )
            Self.replaceAttemptAggregate(
                on: event,
                removing: (oldCounts.left, oldCounts.right, oldCounts.both),
                adding: (newCounts.left, newCounts.right, newCounts.both),
                removingDuration: oldDurations,
                addingDuration: newDurations
            )
            Self.reconcileGoalBaseline(
                on: event,
                plan: oldPlan,
                oldCounts: oldCounts,
                oldFinishedAt: oldFinishedAt,
                newCounts: newCounts,
                newFinishedAt: attempt.finishedAt
            )
            if newCounts.total == 0,
               newDurations.0 == 0,
               newDurations.1 == 0,
               newDurations.2 == 0 {
                context.delete(attempt)
            }
            try context.save()
            reloadAfterCommittedMutation()
            return true
        } catch {
            context.rollback()
            event.restoreAggregate(from: eventSnapshot)
            event.setGoalPlan(oldPlan, at: eventSnapshot.updatedAt)
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Persists a manual record through the exact same atomic summary/commit
    /// path as a live metronome session.
    @discardableResult
    func addRecord(
        songID: UUID,
        sectionID: UUID?,
        date: Date,
        hand: PrototypePracticeHand,
        bpm: Int,
        note: String,
        duration: TimeInterval,
        count: Int
    ) throws -> PracticeAttemptCommitResult {
        let context = try requireContext()
        guard let sectionID,
              songIDByEventID[sectionID] == songID,
              let event = try fetchEvent(id: sectionID, in: context)
        else { throw PracticeLibraryStoreError.eventNotFound }
        var preset = event.preset
        preset.bpm = bpm
        preset.subdivision = Self.subdivision(for: note)
        preset = preset.normalized
        let safeCount = max(1, count)
        let durationMilliseconds = Int64(max(0, duration) * 1_000)
        let stats = HandPracticeStats(count: safeCount, durationMilliseconds: durationMilliseconds)
        // A manual entry is one aggregate operation, not a reconstructed
        // tap-by-tap timeline. Keep every credited count on the exact entered
        // boundary and mark its provenance explicitly.
        let completions = PracticeCompletionSample.manualBackfillBatch(
            hand: hand.practiceHand,
            preset: preset,
            count: safeCount,
            completedAt: date
        )
        let previousPlan = event.goalPlan
        let previousUpdatedAt = event.updatedAt
        do {
            if let plan = previousPlan, date < plan.enabledAt {
                let backfilledCounts = PracticeGoalCounts(
                    left: hand == .left ? safeCount : 0,
                    right: hand == .right ? safeCount : 0,
                    both: hand == .both ? safeCount : 0
                )
                event.setGoalPlan(
                    PracticeGoalPlan(
                        id: plan.id,
                        targets: plan.targets,
                        baseline: plan.baseline.adding(backfilledCounts),
                        enabledAt: plan.enabledAt
                    ),
                    at: previousUpdatedAt
                )
            }

            let effectivePlan = event.goalPlan
            let song: PracticeSong?
            if let linkedSongID = event.songID {
                song = try fetchSong(id: linkedSongID, in: context)
            } else {
                song = nil
            }
            let dailyGoal: PracticeDailyGoal?
            if song?.resetsDaily == true, let effectivePlan {
                dailyGoal = try PracticeDailyGoal.create(
                    for: event.id,
                    planID: effectivePlan.id,
                    targets: effectivePlan.targets,
                    at: date,
                    timeZone: .current,
                    in: context
                )
            } else {
                dailyGoal = nil
            }
            let launchContext = try PracticeGoalLaunchContext.capture(
                for: event,
                dailyGoal: dailyGoal,
                launchedAt: date,
                timeZone: .current,
                in: context
            )
            let sessionCompleted = PracticeGoalCounts(
                left: hand == .left ? safeCount : 0,
                right: hand == .right ? safeCount : 0,
                both: hand == .both ? safeCount : 0
            )
            let goalReport = launchContext.map {
                PracticeGoalReportSnapshot(
                    launchContext: $0,
                    sessionCompleted: sessionCompleted,
                    generatedAt: date
                )
            }
            let summary = PracticeSessionSummary(
                sourceEventID: sectionID,
                startedAt: date.addingTimeInterval(-max(0, duration)),
                finishedAt: date,
                left: hand == .left ? stats : HandPracticeStats(),
                right: hand == .right ? stats : HandPracticeStats(),
                both: hand == .both ? stats : HandPracticeStats(),
                completions: completions,
                leftPreset: hand == .left ? preset : nil,
                rightPreset: hand == .right ? preset : nil,
                bothPreset: hand == .both ? preset : nil,
                goalLaunchContext: launchContext,
                goalReport: goalReport
            )
            let result = try event.commit(summary: summary, in: context)
            reloadAfterCommittedMutation()
            return result
        } catch {
            context.rollback()
            event.setGoalPlan(previousPlan, at: previousUpdatedAt)
            // Keep the live model consistent with the durable row after the
            // explicit restore above; the second rollback clears that restore
            // from the context's pending-change set.
            context.rollback()
            record(error)
            throw error
        }
    }

    /// Exports the complete persisted practice graph as a versioned JSON
    /// document. Preferences are deliberately not included: this backup is
    /// the user's song library and immutable practice history.
    func makeBackupData() throws -> Data {
        let context = try requireContext()
        let document = PracticeLibraryBackupDocument(
            version: PracticeLibraryBackupDocument.currentVersion,
            exportedAt: .now,
            songs: try context.fetch(FetchDescriptor<PracticeSong>())
                .map(PracticeLibraryBackupDocument.Song.init),
            events: try context.fetch(FetchDescriptor<PracticeEvent>())
                .map(PracticeLibraryBackupDocument.Event.init),
            attempts: try context.fetch(FetchDescriptor<PracticeAttempt>())
                .map(PracticeLibraryBackupDocument.Attempt.init),
            dailyGoals: try context.fetch(FetchDescriptor<PracticeDailyGoal>())
                .map(PracticeLibraryBackupDocument.DailyGoal.init),
            folders: try context.fetch(FetchDescriptor<PracticeFolder>())
                .map(PracticeLibraryBackupDocument.Folder.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Atomically replaces the current practice graph with a validated backup.
    /// Import is staged in a disposable context. A failed import therefore
    /// cannot leave partially overwritten live models registered in the
    /// context used by the rest of the app.
    func restoreBackup(from data: Data) throws {
        let liveContext = try requireContext()
        guard protectedEventID == nil else {
            throw PracticeLibraryStoreError.activeSessionProtected
        }
        let document: PracticeLibraryBackupDocument
        do {
            document = try JSONDecoder().decode(
                PracticeLibraryBackupDocument.self,
                from: data
            )
            try document.validate()
        } catch let error as PracticeLibraryStoreError {
            throw error
        } catch {
            throw PracticeLibraryStoreError.invalidBackup
        }

        let context = ModelContext(liveContext.container)
        context.autosaveEnabled = false
        let oldSongs = try context.fetch(FetchDescriptor<PracticeSong>())
        let oldEvents = try context.fetch(FetchDescriptor<PracticeEvent>())
        let oldAttempts = try context.fetch(FetchDescriptor<PracticeAttempt>())
        let oldDailyGoals = try context.fetch(FetchDescriptor<PracticeDailyGoal>())
        let oldFolders = try context.fetch(FetchDescriptor<PracticeFolder>())

        // Reconcile models in place where identities match. This keeps a
        // single atomic save while avoiding a delete+insert collision on the
        // models' unique UUID/session/key attributes.
        let songsByID = Dictionary(uniqueKeysWithValues: oldSongs.map { ($0.id, $0) })
        var retainedSongIDs = Set<UUID>()
        for value in document.songs {
            if let existing = songsByID[value.id] {
                value.apply(to: existing)
            } else {
                context.insert(value.makeModel())
            }
            retainedSongIDs.insert(value.id)
        }
        for value in oldSongs where !retainedSongIDs.contains(value.id) {
            context.delete(value)
        }

        let eventsByID = Dictionary(uniqueKeysWithValues: oldEvents.map { ($0.id, $0) })
        var retainedEventIDs = Set<UUID>()
        for value in document.events {
            if let existing = eventsByID[value.id] {
                value.apply(to: existing)
            } else {
                context.insert(value.makeModel())
            }
            retainedEventIDs.insert(value.id)
        }
        for value in oldEvents where !retainedEventIDs.contains(value.id) {
            context.delete(value)
        }

        let attemptsByID = Dictionary(uniqueKeysWithValues: oldAttempts.map { ($0.id, $0) })
        let attemptsBySessionID = Dictionary(
            uniqueKeysWithValues: oldAttempts.map { ($0.sessionID, $0) }
        )
        var retainedAttempts = Set<ObjectIdentifier>()
        for value in document.attempts {
            if let existing = attemptsByID[value.id] ?? attemptsBySessionID[value.sessionID] {
                value.apply(to: existing)
                retainedAttempts.insert(ObjectIdentifier(existing))
            } else {
                context.insert(value.makeModel())
            }
        }
        for value in oldAttempts
            where !retainedAttempts.contains(ObjectIdentifier(value)) {
            context.delete(value)
        }

        let goalsByID = Dictionary(uniqueKeysWithValues: oldDailyGoals.map { ($0.id, $0) })
        let goalsByKey = Dictionary(uniqueKeysWithValues: oldDailyGoals.map { ($0.key, $0) })
        var retainedGoals = Set<ObjectIdentifier>()
        for value in document.dailyGoals {
            if let existing = goalsByID[value.id] ?? goalsByKey[value.key] {
                value.apply(to: existing)
                retainedGoals.insert(ObjectIdentifier(existing))
            } else {
                context.insert(value.makeModel())
            }
        }
        for value in oldDailyGoals
            where !retainedGoals.contains(ObjectIdentifier(value)) {
            context.delete(value)
        }

        let foldersByID = Dictionary(uniqueKeysWithValues: oldFolders.map { ($0.id, $0) })
        var retainedFolderIDs = Set<UUID>()
        for value in document.folders {
            if let existing = foldersByID[value.id] {
                value.apply(to: existing)
            } else {
                context.insert(value.makeModel())
            }
            retainedFolderIDs.insert(value.id)
        }
        for value in oldFolders where !retainedFolderIDs.contains(value.id) {
            context.delete(value)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            record(error)
            throw error
        }
        // All subsequent mutations and projections use the clean context that
        // committed the replacement graph. The previous context has no staged
        // changes and can be discarded safely.
        modelContext = context
        reloadAfterCommittedMutation()
    }

    private func makeLaunch(
        song: PracticeSongSnapshot,
        section: PracticeSectionSnapshot
    ) -> PrototypePracticeLaunch {
        let completed = section.goalProgress?.completed ?? section.counts
        let targets = section.goalProgress?.targets ?? PracticeGoalCounts()
        return PrototypePracticeLaunch(
            songID: song.id,
            eventID: section.id,
            pieceName: song.name,
            sectionName: section.name,
            bpm: section.preset.bpm,
            beats: section.preset.beats,
            trainingNote: section.preset.subdivisionTitle,
            referenceNote: section.preset.referenceNote.title,
            completedByHand: [
                .left: completed.left,
                .right: completed.right,
                .both: completed.both
            ],
            targetByHand: [
                .left: targets.left,
                .right: targets.right,
                .both: targets.both
            ],
            // A section owns one live metronome configuration. Per-hand
            // historical values stay in immutable attempts for statistics;
            // they must never drive playback when selecting a hand.
            presetSnapshot: section.preset
        )
    }

    private func requireContext() throws -> ModelContext {
        guard let modelContext else { throw PracticeLibraryStoreError.notConfigured }
        return modelContext
    }

    private func fetchSong(id: UUID, in context: ModelContext) throws -> PracticeSong? {
        let target = id
        var descriptor = FetchDescriptor<PracticeSong>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchEvent(id: UUID, in context: ModelContext) throws -> PracticeEvent? {
        let target = id
        var descriptor = FetchDescriptor<PracticeEvent>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func events(for songID: UUID, in context: ModelContext) throws -> [PracticeEvent] {
        try context.fetch(FetchDescriptor<PracticeEvent>())
            .filter { $0.songID == songID }
            .sorted(by: Self.eventOrder)
    }

    private func deleteEventGraph(
        _ event: PracticeEvent,
        folders: [PracticeFolder],
        in context: ModelContext
    ) throws {
        PracticeFolder.move(eventID: event.id, to: nil, among: folders)
        try PracticeAttempt.deleteAll(for: event.id, in: context)
        try PracticeDailyGoal.deleteAll(for: event.id, in: context)
        context.delete(event)
    }

    private static func replaceAttemptAggregate(
        on event: PracticeEvent,
        removing: (left: Int, right: Int, both: Int),
        adding: (left: Int, right: Int, both: Int),
        removingDuration: (left: Int64, right: Int64, both: Int64),
        addingDuration: (left: Int64, right: Int64, both: Int64)
    ) {
        for hand in PracticeHand.controlOrder {
            let removedCount: Int
            let addedCount: Int
            let removedDuration: Int64
            let addedDuration: Int64
            switch hand {
            case .left:
                removedCount = removing.left
                addedCount = adding.left
                removedDuration = removingDuration.left
                addedDuration = addingDuration.left
            case .right:
                removedCount = removing.right
                addedCount = adding.right
                removedDuration = removingDuration.right
                addedDuration = addingDuration.right
            case .both:
                removedCount = removing.both
                addedCount = adding.both
                removedDuration = removingDuration.both
                addedDuration = addingDuration.both
            }
            event.setCount(
                replacingAggregate(
                    event.count(for: hand),
                    removing: removedCount,
                    adding: addedCount
                ),
                for: hand
            )
            event.setDurationMilliseconds(
                replacingAggregate(
                    event.durationMilliseconds(for: hand),
                    removing: removedDuration,
                    adding: addedDuration
                ),
                for: hand
            )
        }
        event.updatedAt = .now
    }

    private static func reconcileGoalBaseline(
        on event: PracticeEvent,
        plan: PracticeGoalPlan?,
        oldCounts: PracticeGoalCounts,
        oldFinishedAt: Date,
        newCounts: PracticeGoalCounts,
        newFinishedAt: Date
    ) {
        guard let plan else { return }
        let oldContribution = oldFinishedAt < plan.enabledAt
            ? oldCounts
            : PracticeGoalCounts()
        let newContribution = newFinishedAt < plan.enabledAt
            ? newCounts
            : PracticeGoalCounts()
        event.setGoalPlan(
            PracticeGoalPlan(
                id: plan.id,
                targets: plan.targets,
                baseline: plan.baseline
                    .subtractingFloorAtZero(oldContribution)
                    .adding(newContribution),
                enabledAt: plan.enabledAt
            ),
            at: .now
        )
    }

    private static func replacingAggregate<T: FixedWidthInteger>(
        _ current: T,
        removing: T,
        adding: T
    ) -> T {
        let base = current > removing ? current - removing : 0
        let (result, overflowed) = base.addingReportingOverflow(max(0, adding))
        return overflowed ? T.max : result
    }

    private func record(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    /// A successful `ModelContext.save()` is the transaction boundary. A
    /// projection refresh can still fail afterwards (for example because the
    /// persistent store becomes temporarily unavailable), but reporting the
    /// mutation itself as failed would invite the caller to retry an operation
    /// that is already durable. Preserve that success and surface the refresh
    /// problem separately through `lastErrorMessage`.
    private func reloadAfterCommittedMutation() {
        do {
            try reload()
        } catch {
            // A save can be durable even if this context's projection refresh
            // fails or has a stale query generation. Retry once from a clean
            // context so the UI does not remain empty while rows exist on disk.
            let firstError = error
            guard let current = modelContext else {
                record(firstError)
                return
            }
            let replacement = ModelContext(current.container)
            replacement.autosaveEnabled = false
            modelContext = replacement
            do {
                try reload()
            } catch {
                modelContext = current
                record(error)
            }
        }
    }

    private static func normalizedDrafts(
        _ values: [PracticeSectionDraft]
    ) throws -> [PracticeSectionDraft] {
        var seen = Set<UUID>()
        var cleaned: [PracticeSectionDraft] = []
        for draft in values {
            guard seen.insert(draft.id).inserted else {
                throw PracticeLibraryStoreError.duplicateSection
            }
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw PracticeLibraryStoreError.emptySectionName
            }
            cleaned.append(PracticeSectionDraft(id: draft.id, name: name))
        }
        return cleaned.isEmpty ? [PracticeSectionDraft(name: "完整练习")] : cleaned
    }

    private static func makeSectionSnapshot(
        event: PracticeEvent,
        song: PracticeSong,
        attempts: [PracticeAttempt],
        now: Date,
        calendar: Calendar
    ) -> PracticeSectionSnapshot {
        let aggregate = PracticeGoalCounts(
            left: event.leftCount,
            right: event.rightCount,
            both: event.bothCount
        )
        let progress: PracticeGoalProgress?
        if let plan = event.goalPlan {
            let completed: PracticeGoalCounts
            if song.resetsDaily {
                let localDay = PracticeDailyGoal.localDay(
                    containing: now,
                    timeZone: .current
                )
                let key = PracticeDailyGoal.makeKey(
                    eventID: event.id,
                    planID: plan.id,
                    localDay: localDay
                )
                completed = attempts
                    .filter { $0.dailyGoalKey == key }
                    .reduce(PracticeGoalCounts()) {
                        $0.adding(PracticeGoalCounts(attempt: $1))
                    }
            } else {
                completed = aggregate.subtractingFloorAtZero(plan.baseline)
            }
            progress = PracticeGoalProgress(targets: plan.targets, completed: completed)
        } else {
            progress = nil
        }
        return PracticeSectionSnapshot(
            id: event.id,
            songID: song.id,
            name: event.name,
            sortIndex: max(0, event.sectionSortIndex ?? 0),
            preset: event.preset,
            counts: aggregate,
            durationMilliseconds: event.totalDurationMilliseconds,
            durationByHand: PracticeHandDurationSnapshot(
                left: event.durationMilliseconds(for: .left),
                right: event.durationMilliseconds(for: .right),
                both: event.durationMilliseconds(for: .both)
            ),
            lastPracticed: attempts.map(\.finishedAt).max(),
            goalProgress: progress,
            goalEnabledAt: event.goalPlan?.enabledAt
        )
    }

    private static func subdivision(for title: String) -> Int {
        if title.contains("十六") { return 4 }
        if title.contains("八") { return 2 }
        if title.contains("二分") { return 0 }
        return 1
    }

    private static func hasPassedEndDate(
        _ endDate: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let start = calendar.startOfDay(for: endDate)
        let deadline = calendar.date(byAdding: .day, value: 1, to: start) ?? endDate
        return now >= deadline
    }

    private static func eventOrder(_ lhs: PracticeEvent, _ rhs: PracticeEvent) -> Bool {
        let left = lhs.sectionSortIndex ?? Int.max
        let right = rhs.sectionSortIndex ?? Int.max
        if left != right { return left < right }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func songOrder(_ lhs: PracticeSongSnapshot, _ rhs: PracticeSongSnapshot) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct PracticeLibraryBackupDocument: Codable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let songs: [Song]
    let events: [Event]
    let attempts: [Attempt]
    let dailyGoals: [DailyGoal]
    let folders: [Folder]

    struct Song: Codable {
        let id: UUID
        let name: String
        let coreStructureData: Data?
        let group: String
        let isArchived: Bool
        let deletedAt: Date?
        let multiplier: Int
        let resetsDaily: Bool
        let endDate: Date
        let sortIndex: Int
        let createdAt: Date
        let updatedAt: Date

        init(_ value: PracticeSong) {
            id = value.id
            name = value.name
            coreStructureData = value.coreStructureData
            group = value.group
            isArchived = value.isArchived
            deletedAt = value.deletedAt
            multiplier = 1
            resetsDaily = value.resetsDaily
            endDate = value.endDate
            sortIndex = value.sortIndex
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }

        func makeModel() -> PracticeSong {
            let value = PracticeSong(
                id: id,
                name: name,
                group: group,
                isArchived: isArchived,
                multiplier: 1,
                resetsDaily: resetsDaily,
                endDate: endDate,
                sortIndex: sortIndex,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            value.deletedAt = deletedAt
            value.coreStructureData = coreStructureData
            return value
        }

        func apply(to value: PracticeSong) {
            value.deletedAt = deletedAt
            value.coreStructureData = coreStructureData
            value.id = id
            value.name = name
            value.group = group
            value.isArchived = isArchived
            value.multiplier = 1
            value.resetsDaily = resetsDaily
            value.endDate = endDate
            value.sortIndex = max(0, sortIndex)
            value.createdAt = createdAt
            value.updatedAt = updatedAt
        }
    }

    struct Event: Codable {
        let id: UUID
        let songID: UUID?
        let sectionSortIndex: Int?
        let name: String
        let coreDefinitionData: Data?
        let leftCount: Int
        let rightCount: Int
        let bothCount: Int
        let leftDurationMilliseconds: Int64?
        let rightDurationMilliseconds: Int64?
        let bothDurationMilliseconds: Int64?
        let preset: MetronomePreset
        let goalPlan: PracticeGoalPlan?
        let createdAt: Date
        let updatedAt: Date

        init(_ value: PracticeEvent) {
            id = value.id
            songID = value.songID
            sectionSortIndex = value.sectionSortIndex
            name = value.name
            coreDefinitionData = value.coreDefinitionData
            leftCount = value.leftCount
            rightCount = value.rightCount
            bothCount = value.bothCount
            leftDurationMilliseconds = value.leftDurationMilliseconds
            rightDurationMilliseconds = value.rightDurationMilliseconds
            bothDurationMilliseconds = value.bothDurationMilliseconds
            preset = value.preset
            goalPlan = value.goalPlan
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }

        func makeModel() -> PracticeEvent {
            let value = PracticeEvent(
                id: id,
                songID: songID,
                sectionSortIndex: sectionSortIndex,
                name: name,
                leftCount: leftCount,
                rightCount: rightCount,
                bothCount: bothCount,
                leftDurationMilliseconds: leftDurationMilliseconds,
                rightDurationMilliseconds: rightDurationMilliseconds,
                bothDurationMilliseconds: bothDurationMilliseconds,
                preset: preset,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            value.coreDefinitionData = coreDefinitionData
            value.setGoalPlan(goalPlan, at: updatedAt)
            return value
        }

        func apply(to value: PracticeEvent) {
            value.id = id
            value.songID = songID
            value.sectionSortIndex = sectionSortIndex
            value.name = name
            value.leftCount = max(0, leftCount)
            value.rightCount = max(0, rightCount)
            value.bothCount = max(0, bothCount)
            value.leftDurationMilliseconds = leftDurationMilliseconds.map { max(0, $0) }
            value.rightDurationMilliseconds = rightDurationMilliseconds.map { max(0, $0) }
            value.bothDurationMilliseconds = bothDurationMilliseconds.map { max(0, $0) }
            value.apply(preset: preset)
            value.createdAt = createdAt
            value.coreDefinitionData = coreDefinitionData
            value.setGoalPlan(goalPlan, at: updatedAt)
        }
    }

    struct Attempt: Codable {
        let id: UUID
        let sessionID: UUID
        let eventID: UUID
        let coreContextData: Data?
        let eventNameSnapshot: String?
        let startedAt: Date
        let finishedAt: Date
        let createdAt: Date
        let dailyGoalKey: String?
        let left: HandPracticeStats
        let right: HandPracticeStats
        let both: HandPracticeStats
        let completions: [PracticeCompletionSample]
        let leftSpeed: PracticeHandSpeedSummary
        let rightSpeed: PracticeHandSpeedSummary
        let bothSpeed: PracticeHandSpeedSummary
        /// Optional additive fields keep version-1 backups from earlier
        /// builds valid while preserving timed sessions with no completions.
        let leftSessionPreset: MetronomePreset?
        let rightSessionPreset: MetronomePreset?
        let bothSessionPreset: MetronomePreset?
        let goalLaunchContext: PracticeGoalLaunchContext?
        let goalReport: PracticeGoalReportSnapshot?

        init(_ value: PracticeAttempt) {
            id = value.id
            sessionID = value.sessionID
            eventID = value.eventID
            coreContextData = value.coreContextData
            eventNameSnapshot = value.eventNameSnapshot
            startedAt = value.startedAt
            finishedAt = value.finishedAt
            createdAt = value.createdAt
            dailyGoalKey = value.dailyGoalKey
            left = value.stats(for: .left)
            right = value.stats(for: .right)
            both = value.stats(for: .both)
            completions = value.completions
            leftSpeed = value.speedSummary(for: .left)
            rightSpeed = value.speedSummary(for: .right)
            bothSpeed = value.speedSummary(for: .both)
            leftSessionPreset = value.sessionPreset(for: .left)
            rightSessionPreset = value.sessionPreset(for: .right)
            bothSessionPreset = value.sessionPreset(for: .both)
            goalLaunchContext = value.goalLaunchContext
            goalReport = value.goalReport
        }

        func makeModel() -> PracticeAttempt {
            let summary = PracticeSessionSummary(
                sessionID: sessionID,
                sourceEventID: eventID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                left: left,
                right: right,
                both: both,
                completions: completions,
                leftPreset: leftSessionPreset,
                rightPreset: rightSessionPreset,
                bothPreset: bothSessionPreset,
                goalLaunchContext: goalLaunchContext,
                goalReport: goalReport
            )
            let value = PracticeAttempt(
                id: id,
                eventID: eventID,
                eventNameSnapshot: eventNameSnapshot,
                summary: summary,
                createdAt: createdAt
            )
            // The encoded speed records can legitimately outlive their raw
            // completion samples in backups created from migrated stores.
            // Restore them directly instead of expanding completionCount into
            // an unbounded synthetic array.
            apply(to: value)
            return value
        }

        func apply(to value: PracticeAttempt) {
            value.coreContextData = coreContextData
            value.replacePersistedStateForRestore(
                id: id,
                sessionID: sessionID,
                eventID: eventID,
                eventNameSnapshot: eventNameSnapshot,
                startedAt: startedAt,
                finishedAt: finishedAt,
                createdAt: createdAt,
                dailyGoalKey: dailyGoalKey,
                left: left,
                right: right,
                both: both,
                completions: completions,
                leftSpeed: leftSpeed,
                rightSpeed: rightSpeed,
                bothSpeed: bothSpeed,
                goalLaunchContext: goalLaunchContext,
                goalReport: goalReport,
                leftSessionPreset: leftSessionPreset,
                rightSessionPreset: rightSessionPreset,
                bothSessionPreset: bothSessionPreset
            )
        }

        var hasValidNumericPayload: Bool {
            let stats = [left, right, both]
            guard stats.allSatisfy({
                $0.count >= 0 && $0.durationMilliseconds >= 0
            }) else { return false }

            // This is far above any plausible repetitions at 240 BPM while
            // still providing a hard boundary for corrupted/untrusted JSON.
            let maximumCompletionCount = 1_000_000
            let speedRecords = [leftSpeed, rightSpeed, bothSpeed].flatMap {
                [$0.mostPracticed, $0.maximumAttempt].compactMap { $0 }
            }
            return speedRecords.allSatisfy {
                (1...maximumCompletionCount).contains($0.completionCount)
            }
        }
    }

    struct DailyGoal: Codable {
        let id: UUID
        let key: String
        let eventID: UUID
        let planID: UUID?
        let localDay: String
        let timeZoneIdentifier: String
        let timeZoneSecondsFromGMT: Int
        let targets: PracticeGoalCounts
        let createdAt: Date
        let updatedAt: Date

        init(_ value: PracticeDailyGoal) {
            id = value.id
            key = value.key
            eventID = value.eventID
            planID = value.planID
            localDay = value.localDay
            timeZoneIdentifier = value.timeZoneIdentifier
            timeZoneSecondsFromGMT = value.timeZoneSecondsFromGMT
            targets = value.targets
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }

        func makeModel() -> PracticeDailyGoal {
            let timeZone = TimeZone(identifier: timeZoneIdentifier)
                ?? TimeZone(secondsFromGMT: timeZoneSecondsFromGMT)
                ?? TimeZone(secondsFromGMT: 0)!
            let value = PracticeDailyGoal(
                id: id,
                eventID: eventID,
                planID: planID,
                targets: targets,
                date: createdAt,
                timeZone: timeZone,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            value.key = key
            value.localDay = localDay
            value.timeZoneIdentifier = timeZoneIdentifier
            value.timeZoneSecondsFromGMT = timeZoneSecondsFromGMT
            return value
        }

        func apply(to value: PracticeDailyGoal) {
            value.id = id
            value.key = key
            value.eventID = eventID
            value.planID = planID
            value.localDay = localDay
            value.timeZoneIdentifier = timeZoneIdentifier
            value.timeZoneSecondsFromGMT = timeZoneSecondsFromGMT
            value.leftTarget = targets.left
            value.rightTarget = targets.right
            value.bothTarget = targets.both
            value.createdAt = createdAt
            value.updatedAt = updatedAt
        }
    }

    struct Folder: Codable {
        let id: UUID
        let name: String
        let sortIndex: Int
        let eventIDs: [UUID]
        let createdAt: Date
        let updatedAt: Date

        init(_ value: PracticeFolder) {
            id = value.id
            name = value.name
            sortIndex = value.sortIndex
            eventIDs = value.eventIDs
            createdAt = value.createdAt
            updatedAt = value.updatedAt
        }

        func makeModel() -> PracticeFolder {
            PracticeFolder(
                id: id,
                name: name,
                sortIndex: sortIndex,
                eventIDs: eventIDs,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        func apply(to value: PracticeFolder) {
            value.id = id
            value.name = name
            value.sortIndex = max(0, sortIndex)
            value.setEventIDs(eventIDs, now: updatedAt)
            value.createdAt = createdAt
            value.updatedAt = updatedAt
        }
    }

    func validate() throws {
        guard version == Self.currentVersion,
              Self.hasUnique(songs.map(\.id)),
              Self.hasUnique(events.map(\.id)),
              Self.hasUnique(attempts.map(\.id)),
              Self.hasUnique(attempts.map(\.sessionID)),
              attempts.allSatisfy(\.hasValidNumericPayload),
              Self.hasUnique(dailyGoals.map(\.id)),
              Self.hasUnique(dailyGoals.map(\.key)),
              Self.hasUnique(folders.map(\.id))
        else { throw PracticeLibraryStoreError.invalidBackup }

        let songIDs = Set(songs.map(\.id))
        let eventIDs = Set(events.map(\.id))
        guard events.allSatisfy({ event in
            event.songID.map(songIDs.contains) == true
        }), attempts.allSatisfy({ eventIDs.contains($0.eventID) }),
        dailyGoals.allSatisfy({ eventIDs.contains($0.eventID) }),
        folders.allSatisfy({ folder in
            folder.eventIDs.allSatisfy(eventIDs.contains)
        }) else {
            throw PracticeLibraryStoreError.invalidBackup
        }
    }

    private static func hasUnique<T: Hashable>(_ values: [T]) -> Bool {
        Set(values).count == values.count
    }
}
