import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// A soft Skip whose Undo offer is open. Its record shrinks when some members leave on their own.
@MainActor final class OpenSoftSkip {
    var record: SoftSkipRecord
    let feedIDs: Set<String>
    init(record: SoftSkipRecord, feedIDs: Set<String>) { self.record = record; self.feedIDs = feedIDs }
}

/// A Skip from Feeds that can be taken back. It retires the episodes at once and keeps their audio
/// until the Undo window closes, so Undo gives back exactly what was there: the same decision, the
/// same audio, the same playback position.
extension WiltedMacModel {
    private static let pendingSoftSkipsKey = "wilted.pendingSoftSkips"

    /// Skips whose audio has not been reclaimed yet. Kept in the preferences so a quit inside the
    /// window cannot leave the audio behind for good: the next launch closes them.
    private var pendingSoftSkips: [SoftSkipRecord] {
        get {
            preferences.data(forKey: Self.pendingSoftSkipsKey)
                .flatMap { try? JSONDecoder().decode([SoftSkipRecord].self, from: $0) } ?? []
        }
        set {
            if newValue.isEmpty { preferences.removeObject(forKey: Self.pendingSoftSkipsKey) }
            else { preferences.set(try? JSONEncoder().encode(newValue), forKey: Self.pendingSoftSkipsKey) }
        }
    }

    /// Records the Skip, then offers Undo. The audio is reclaimed when the offer ends without being
    /// taken (it ran out, or was withdrawn); if no offer can be made, at once.
    func offerSoftSkipUndo(_ record: SoftSkipRecord, rows: [WiltedMacEpisode], changed: Int) {
        let open = OpenSoftSkip(record: record, feedIDs: Set(rows.compactMap(\.feedID)))
        pendingSoftSkips.append(record)
        openSoftSkips.append(open)
        let offered = undoToast.offer(
            message: "Skipped \(changed) episode\(changed == 1 ? "" : "s")",
            actionName: "Skip", subjects: Set(record.retiredIDs.map(\.rawValue)),
            onClose: { [weak self] in self?.closeSoftSkip(open) },
            narrow: { [weak self] gone in self?.narrowSoftSkip(open, removing: gone) },
            undo: { [weak self] in self?.undoSoftSkip(open, rows: rows) ?? .done }
        )
        if offered == nil { closeSoftSkip(open) }
    }

    /// Some members of an open Skip went away on their own (their feed was unsubscribed). Undo and the
    /// cleanup that follows now cover only the rest, so the others are neither lost nor closed early.
    private func narrowSoftSkip(_ open: OpenSoftSkip, removing gone: Set<String>) {
        let goneIDs = Set(gone.compactMap { try? ItemID(rawValue: $0) })
        let old = open.record
        guard let narrowed = old.removing(goneIDs) else { return }
        replacePending(old, with: narrowed)
        open.record = narrowed
    }

    private func replacePending(_ old: SoftSkipRecord, with new: SoftSkipRecord?) {
        var ledger = pendingSoftSkips
        guard let index = ledger.firstIndex(of: old) else {
            if let new { ledger.append(new); pendingSoftSkips = ledger }
            return
        }
        if let new { ledger[index] = new } else { ledger.remove(at: index) }
        pendingSoftSkips = ledger
    }

    /// Runs the undo through the Feed writer, so it commits in order with every other decision.
    /// Something still saving on one of these rows keeps the offer open instead of spending it.
    private func undoSoftSkip(_ open: OpenSoftSkip, rows: [WiltedMacEpisode]) -> WiltedMacUndoResult {
        guard !isClosingTemporaryState else { return .done }
        let members = Set(open.record.retiredIDs.map(\.rawValue))
        let mine = rows.filter { members.contains($0.id) }
        guard pendingFeedDecisionIDs.isDisjoint(with: mine.map(\.id)) else { return .retry }
        decideFeedEpisodes(.undoSkip(open.record), episodes: mine)
        return .done
    }

    /// The offer ended: reclaim the audio, in order after every decision already queued.
    private func closeSoftSkip(_ open: OpenSoftSkip) {
        enqueueFeedWriteAfterDecisions { [weak self] in
            await self?.finishSoftSkip(open)
        }
    }

    /// Reclaims the audio of every member still retired from this Skip, withdraws their waiting
    /// preparation, and lets the feed's next waiting episode into the slot they free. A member the
    /// player has loaded keeps its audio and stays on the ledger for the next launch. A failure keeps
    /// the record, so the next launch tries again.
    func finishSoftSkip(_ open: OpenSoftSkip) async {
        guard let store, !isClosingTemporaryState else { return }
        let record = open.record
        do {
            let close = try await store.finalizeSoftSkip(
                record.retiredIDs, at: record.retiredAt, protecting: livePlaybackEpisodeIDs())
            openSoftSkips.removeAll { $0 === open }
            replacePending(record, with: record.keeping(Set(close.held)))
            guard !isClosingTemporaryState else { return }
            for id in close.finished { withdrawPreparationRequest(for: id.rawValue) }
            if !close.finished.isEmpty { await releaseWaitingEpisodes(feedIDs: open.feedIDs) }
        } catch {
            podcastOperationMessage = "Skipped audio could not be cleared; it will be tried again."
        }
    }

    /// The episodes the player has loaded or the model names as playing, with their linked members.
    /// Audio starts before any of it is saved, so a cleanup that deletes audio reads this at the last
    /// moment and passes it to the store, which cannot see the live player.
    func livePlaybackEpisodeIDs() -> Set<ItemID> {
        let named = [playback?.itemID?.rawValue, currentPodcastEpisodeID].compactMap { $0 }
        return Set(named.flatMap { logicalMemberIDs($0) }.compactMap { try? ItemID(rawValue: $0) })
    }

    /// Closes every Skip an earlier launch left open. No offer exists any more, so none can be taken
    /// back. A Skip whose offer is still open in this run is left to that offer.
    func closeAbandonedSoftSkips(in store: LocalLibraryStore) async {
        for record in pendingSoftSkips where !openSoftSkips.contains(where: { $0.record == record }) {
            guard let close = try? await store.finalizeSoftSkip(
                record.retiredIDs, at: record.retiredAt, protecting: livePlaybackEpisodeIDs()) else { continue }
            replacePending(record, with: record.keeping(Set(close.held)))
        }
    }

    /// Takes back a soft Skip in the store and reloads what shows it. The undo changes only members
    /// whose decision is still this Skip's own; a newer action on any member is left as it stands.
    func commitUndoSoftSkip(_ record: SoftSkipRecord, rows: [WiltedMacEpisode], store: LocalLibraryStore) async throws -> Set<String> {
        let restored = Set(try await store.undoSoftSkip(record).map(\.rawValue))
        if !restored.isEmpty {
            libraryReadEpoch &+= 1
            lastAppliedLibraryReadEpoch = libraryReadEpoch
            podcastQueueRefreshGeneration &+= 1
        }
        await feedDecisionAfterDurableCommitForTesting?()
        guard !isClosingTemporaryState, !Task.isCancelled else { return restored }
        await refreshPodcastQueueState()
        guard !isClosingTemporaryState, !Task.isCancelled else { return restored }
        await reloadLibraryRows()
        // A member the undo could not restore (changed since) is still retired from this Skip: close it.
        if let open = openSoftSkips.first(where: { $0.record == record }) { await finishSoftSkip(open) }
        return restored
    }

    /// Queues one write behind every Feed decision already admitted, without marking rows pending.
    func enqueueFeedWriteAfterDecisions(_ body: @escaping @MainActor () async -> Void) {
        guard !isClosingTemporaryState else { return }
        let token = UUID()
        let predecessor = feedDecisionWriteTailToken.flatMap { subscriptionWriteTasks[$0] }
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.subscriptionWriteTasks[token] = nil
                    if self.feedDecisionWriteTailToken == token { self.feedDecisionWriteTailToken = nil }
                }
            }
            if let predecessor { await predecessor.value }
            guard let self, !self.isClosingTemporaryState, !Task.isCancelled else { return }
            await body()
        }
        subscriptionWriteTasks[token] = task
        feedDecisionWriteTailToken = token
    }
}
#endif
