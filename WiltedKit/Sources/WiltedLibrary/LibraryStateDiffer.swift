import Foundation
import WiltedDomain

/// The replicated content of the library: everything a follower mirrors.
public struct LibrarySnapshot: Sendable, Equatable {
    public var sources: [ItemID: LibrarySource]
    public var entries: [ItemID: LibraryEntry]
    public var slots: [ItemID: QueueSlot]
    public var listening: [ItemID: ListeningRecord]

    public init(
        sources: [LibrarySource] = [],
        entries: [LibraryEntry] = [],
        slots: [QueueSlot] = [],
        listening: [ListeningRecord] = []
    ) {
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.slots = Dictionary(slots.map { ($0.entryID, $0) }, uniquingKeysWith: { _, last in last })
        self.listening = Dictionary(listening.map { ($0.itemID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Larder in queue order.
    public var queue: [QueueSlot] { QueueSlot.ordered(Array(slots.values)) }
}

/// Diffs a full Mac snapshot against the last one published, so a publisher sends only
/// what moved. Output order is deterministic: sources, entries, slot upserts, slot
/// removals, listening.
///
/// Entries and sources are never hard-deleted from a snapshot; disappearance is expressed
/// by removal state, so an entry missing from `current` produces no change.
public enum LibraryStateDiffer {
    public static func diff(from previous: LibrarySnapshot?, to current: LibrarySnapshot) -> [LibraryChange] {
        let old = previous ?? LibrarySnapshot()
        var changes: [LibraryChange] = []

        for id in sortedKeys(current.sources) where old.sources[id] != current.sources[id] {
            if let source = current.sources[id] { changes.append(.source(source)) }
        }
        for id in sortedKeys(current.entries) {
            guard let entry = current.entries[id], old.entries[id] != entry else { continue }
            if let previousEntry = old.entries[id], isRemovalOnly(from: previousEntry, to: entry) {
                changes.append(.removal(entryID: id, state: entry.removal))
            } else {
                changes.append(.entry(entry))
            }
        }
        for id in sortedKeys(current.slots) where old.slots[id] != current.slots[id] {
            if let slot = current.slots[id] { changes.append(.slot(slot)) }
        }
        for id in sortedKeys(old.slots) where current.slots[id] == nil {
            changes.append(.slotRemoved(entryID: id))
        }
        for id in sortedKeys(current.listening) where old.listening[id] != current.listening[id] {
            if let record = current.listening[id] { changes.append(.listening(record)) }
        }
        return changes
    }

    private static func isRemovalOnly(from old: LibraryEntry, to new: LibraryEntry) -> Bool {
        old.removal != new.removal && (try? old.applyingRemoval(new.removal)) == new
    }

    private static func sortedKeys<V>(_ dictionary: [ItemID: V]) -> [ItemID] {
        dictionary.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
