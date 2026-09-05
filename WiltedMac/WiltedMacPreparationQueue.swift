import Foundation

/// One preparation waiting for the single run slot.
struct WiltedMacWaitingPreparation: Identifiable, Equatable, Sendable {
    /// The item's id, so the row can be matched to its episode and stopped.
    let id: String
    let title: String
    /// The show or publication the item came from.
    let source: String
}

/// The order preparations will run in, for the surface that shows them.
///
/// `WiltedPreparationGate` counts the callers waiting behind the admitted one
/// and hands the slot to the longest-waiting, but it never learns what they
/// are, so nothing could name them. Prep lists what the journal recorded, and
/// a waiting run has journalled nothing, so it listed nothing either: three
/// episodes downloaded together showed one preparing, one queued and one
/// apparently idle.
///
/// This is that list. A caller enters at the moment it is told it will wait --
/// which is one main-actor hop before it actually suspends on the gate -- and
/// leaves when it is admitted or gives up.
struct WiltedMacPreparationQueue: Equatable, Sendable {
    /// Waiting preparations, nearest turn first.
    private(set) var entries: [WiltedMacWaitingPreparation] = []

    var isEmpty: Bool { entries.isEmpty }

    /// The items waiting, for a caller matching rows rather than listing them.
    var itemIDs: Set<String> { Set(entries.map(\.id)) }

    /// Takes a place in line, keeping the first place an item was given.
    /// Preparation refuses a second run for an item that already has one, so a
    /// second entry for the same id could only ever be a phantom row.
    mutating func enter(_ entry: WiltedMacWaitingPreparation) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }

    /// Leaves the queue, whether by being admitted or by giving up.
    mutating func leave(_ id: String) {
        entries.removeAll { $0.id == id }
    }
}
