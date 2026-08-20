import Foundation
import SwiftData

/// A single-level organizational folder for practice events.
///
/// Membership is stored by event identifier instead of a cascading SwiftData
/// relationship. That keeps folders purely organizational: moving or deleting
/// a folder can never delete an event or its immutable attempt history, and
/// stores created before folders existed migrate additively with every existing
/// event naturally appearing in “未分类”.
@Model
final class PracticeFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int
    private(set) var eventIDsRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        eventIDs: [UUID] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortIndex = max(0, sortIndex)
        self.eventIDsRaw = Self.encode(eventIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var eventIDs: [UUID] {
        Self.decode(eventIDsRaw)
    }

    func contains(eventID: UUID) -> Bool {
        eventIDs.contains(eventID)
    }

    func add(eventID: UUID, now: Date = .now) {
        var ids = eventIDs
        guard !ids.contains(eventID) else { return }
        ids.append(eventID)
        setEventIDs(ids, now: now)
    }

    func remove(eventID: UUID, now: Date = .now) {
        let ids = eventIDs.filter { $0 != eventID }
        guard ids.count != eventIDs.count else { return }
        setEventIDs(ids, now: now)
    }

    /// Used both for deterministic membership changes and for restoring the
    /// visible models if a SwiftData save fails.
    func setEventIDs(_ eventIDs: [UUID], now: Date = .now) {
        let encoded = Self.encode(eventIDs)
        guard encoded != eventIDsRaw else { return }
        eventIDsRaw = encoded
        updatedAt = now
    }

    static func folder(
        containing eventID: UUID,
        in folders: [PracticeFolder]
    ) -> PracticeFolder? {
        folders.first { $0.contains(eventID: eventID) }
    }

    /// Moves an event to exactly one folder. Passing `nil` means 未分类.
    /// The event itself and its attempt history are deliberately untouched.
    static func move(
        eventID: UUID,
        to destination: PracticeFolder?,
        among folders: [PracticeFolder],
        now: Date = .now
    ) {
        for folder in folders where folder.id != destination?.id {
            folder.remove(eventID: eventID, now: now)
        }
        destination?.add(eventID: eventID, now: now)
    }

    private static func encode(_ eventIDs: [UUID]) -> String {
        var seen = Set<UUID>()
        return eventIDs
            .filter { seen.insert($0).inserted }
            .map(\.uuidString)
            .joined(separator: ",")
    }

    private static func decode(_ rawValue: String) -> [UUID] {
        rawValue
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }
}
