import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let finishedHereLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryFinishedHere")

/// The episodes the listener finished on this phone, kept in a file of the phone's own.
///
/// Written with `LibraryFileProtection` so the car's play button reads it while the phone is locked.
struct LibraryFinishedHereStore: Sendable {
    private struct Item: Codable {
        let entryID: ItemID
        let at: Date
    }

    private struct File: Codable {
        var ownerToken: String?
        var items: [Item]
    }

    /// nil keeps the set in memory only (tests, previews).
    let url: URL?

    func load() -> (ownerToken: String?, entries: [ItemID: Date]) {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return (nil, [:]) }
        return (file.ownerToken, Dictionary(file.items.map { ($0.entryID, $0.at) }, uniquingKeysWith: max))
    }

    /// Best-effort: a failed write costs the memory across a relaunch, never playback.
    func save(ownerToken: String?, entries: [ItemID: Date]) {
        guard let url else { return }
        let items = entries.map { Item(entryID: $0.key, at: $0.value) }.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
        guard let data = try? JSONEncoder().encode(File(ownerToken: ownerToken, items: items)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }
}

/// The model's side of `LibraryFinishedHereStore`; owned by `LibraryAppModel+FinishedHere`.
@MainActor
final class LibraryFinishedHereState {
    let store: LibraryFinishedHereStore
    /// Raw entry ids, with when the listener finished each.
    var entries: [ItemID: Date]
    /// The library owner the set was made under; nil before the mirror knew one.
    var ownerToken: String?

    init(store: LibraryFinishedHereStore) {
        self.store = store
        (ownerToken, entries) = store.load()
    }
}

/// What the phone remembers by itself about episodes the listener finished on it, so none of them
/// starts again unasked.
///
/// A finish (Mark completed, Remove from Larder, an episode played to its end) is a request to the Mac,
/// and the Larder shows the Mac's library. Between the request and the library that shows its result
/// the phone's own tracking has gaps: an unanswered decision reverts to "Pending on Mac" after
/// `LibraryDecisionTiming.confirmationTimeout`, an applied one is forgotten after the same wait whether
/// or not the library caught up, and a sent one is not in the outbox, so a relaunch forgets it at once.
/// In each gap the episode is listed and downloaded again, and auto-continue or the car's play button
/// started it (2026-11-18). This set closes them all: it is consulted wherever an episode starts unasked
/// (`remoteResumeRow`, `autoContinue`, Siri's unnamed play), and never changes what a row shows.
///
/// An entry leaves the set when the question is settled another way:
/// - the phone's library shows the episode off the Larder, removed or completed (the Mac's state then
///   decides alone, also when the Mac later puts the episode back);
/// - the listener plays it again, restores it, or stops waiting for the Mac;
/// - the Mac declines the request;
/// - `IntentRetention.maximumAge` has passed, after which the Mac no longer applies the request.
extension LibraryAppModel {
    /// True when the listener finished this episode here and nothing has settled it since.
    func isFinishedHere(_ entryID: ItemID) -> Bool {
        let entries = finishedHereState.entries
        guard !entries.isEmpty else { return false }
        return finishedHereMembers(entryID).contains { entries[$0] != nil }
    }

    /// `finished` with the episodes finished here laid over it, for a list that picks an episode for
    /// the listener (Siri's "play something").
    var finishedIncludingHere: [ItemID: Date] {
        finished.merging(finishedHereState.entries) { max($0, $1) }
    }

    func rememberFinishedHere(_ entryID: ItemID) {
        let at = now()
        for id in finishedHereMembers(entryID) { finishedHereState.entries[id] = at }
        finishedHereLog.notice("Finished here, not started unasked from now on: \(entryID.rawValue, privacy: .public)")
        journal?.note("finished-here action=remember entry=\(entryID.rawValue)")
        persistFinishedHere()
    }

    func forgetFinishedHere(_ entryID: ItemID, because reason: String) {
        let members = finishedHereMembers(entryID).filter { finishedHereState.entries[$0] != nil }
        guard !members.isEmpty else { return }
        for id in members { finishedHereState.entries[id] = nil }
        finishedHereLog.notice("No longer held back (\(reason, privacy: .public)): \(entryID.rawValue, privacy: .public)")
        journal?.note("finished-here action=forget entry=\(entryID.rawValue) reason=\"\(reason)\"")
        persistFinishedHere()
    }

    /// Drops what the fetched library has settled and what the Mac can no longer apply. Call only once
    /// `decisionContent` holds the saved or fetched library: an entry the library does not hold is kept.
    func pruneFinishedHere() {
        let state = finishedHereState
        guard !state.entries.isEmpty else { return }
        let content = decisionContent, current = now()
        let kept = state.entries.filter { id, at in
            guard current.timeIntervalSince(at) <= IntentRetention.maximumAge else { return false }
            guard let entry = content.entries[id] else { return true }
            return entry.removal == LibraryRemoval.none && content.slots[id] != nil
                && content.listening[id]?.isCompleted != true
        }
        guard kept.count != state.entries.count else { return }
        state.entries = kept
        persistFinishedHere()
    }

    /// The set belongs to one library owner: another account's library starts with none.
    func finishedHereOwnerSeen(_ owner: String?) {
        let state = finishedHereState
        guard let owner, state.ownerToken != owner else { return }
        if state.ownerToken != nil { state.entries = [:] }
        state.ownerToken = owner
        persistFinishedHere()
    }

    func discardFinishedHereAfterAccountChange() {
        finishedHereState.entries = [:]
        finishedHereState.ownerToken = nil
        persistFinishedHere()
    }

    private func finishedHereMembers(_ entryID: ItemID) -> [ItemID] { episodeGroup(entryID)?.memberIDs ?? [entryID] }

    private func persistFinishedHere() {
        finishedHereState.store.save(ownerToken: finishedHereState.ownerToken, entries: finishedHereState.entries)
    }
}
