import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// The episodes on the phone in the one play order CarPlay, Siri and auto-continue share.
    var playOrderRows: [LibraryRow] {
        LibraryListing.rows(
            queued, offered: [], onPhone: preparedIDs.onPhone, filter: .onPhone, query: "",
            progress: progress, finished: finished)
    }

    /// An episode played to its end: remember it as played out and saved at its end (local and unsent,
    /// so the next sync publishes it even when the player has moved on), then continue if asked to.
    func episodeFinished(_ endedID: ItemID, autoPlayNext: Bool) async {
        guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
        playedOut[endedID] = now().addingTimeInterval(handoffState.clockOffset)
        handoffState.unpublished[endedID] = (player.duration, now())
        await rememberOwnPosition(endedID, position: player.duration)
        // The completion was accepted above, before the first await, so it stays durable even
        // when a command arrives while the final position was being remembered: the Mac is still
        // told the episode played out. Only the advance is cancelled, and `autoContinue` does
        // that on its own.
        Task { await markPlayedOut(endedID) }
        if autoPlayNext { await autoContinue(after: endedID) }
    }

    /// Tells the Mac an episode played to its end, so it records the completion (W-INV-011). The saved
    /// position alone cannot: the file can run a few seconds short of the feed's length, which left the Mac
    /// showing "10 seconds left". It is the Mark completed intent the Larder sends, so the Mac completes the
    /// episode the way its own finish does and takes it off the Larder; one write now, the Mac's answer read by
    /// the next sync round, and an unsent one retried there. It is silent (the row changes when the Mac does,
    /// as before) and is not donated to Siri as a shortcut.
    private func markPlayedOut(_ entryID: ItemID) async {
        guard decisionContent.listening[entryID]?.isCompleted != true else { return }
        await IntentDonor.shared.withoutDonatingMark(of: entryID) {
            await decide(.markDone, entryID: entryID, requiresOffer: false, silent: true)
        }
    }

    /// Starts the next episode after `endedID` finished: walks the saved forward sequence suffix,
    /// skipping completed, removed, and cache-missing candidates, without wrapping backwards.
    /// A candidate whose file disappears between the initial snapshot and the start's own lookup
    /// is skipped the same way, by trying the one after it. Preserves playback speed and stops
    /// cleanly when none remain. A command given meanwhile (pause, play, seek, another start)
    /// cancels it.
    func autoContinue(after endedID: ItemID) async {
        guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
        refreshProgress()
        let forward = handoffState.forwardSequenceIDs
        guard let endedIndex = forward.firstIndex(of: endedID) else { return }
        let suffixIDs = forward[forward.index(after: endedIndex)...]
        guard !suffixIDs.isEmpty else { return }

        let cached = await mediaCache.cachedEntries()
        guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }

        let queuedByID = Dictionary(uniqueKeysWithValues: queued.map { ($0.id, $0) })
        // The snapshot only prunes candidates that are already gone; a file can still disappear
        // before a candidate's own start lookup, so everyone cached here stays in the walk.
        let candidates = suffixIDs.compactMap { id -> LibraryRow? in
            guard cached[id] != nil else { return nil }
            return queuedByID[id]
        }.filter { LibraryListing.completionDate($0, finished: finished) == nil }
        let rate = player.rate
        for candidate in candidates {
            // Re-read after every await: a command given while the previous candidate was
            // looked at cancels the whole walk.
            guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
            let started = await startCached(candidate, togglingIfLoaded: false, isManual: false) { player in
                // The last look before the start itself: the candidate is still queued and
                // still unfinished, and nothing has been commanded since the end.
                player.item?.entryID == endedID && player.isUntouchedSinceEnd
                    && self.queued.contains { $0.id == candidate.id }
                    && LibraryListing.completionDate(candidate, finished: self.finished) == nil
            }
            if started {
                player.setRate(rate)
                return
            }
            // A command still cancels the walk. A decision can also make this candidate
            // ineligible during the start lookup; skip it even when its file remains cached.
            guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
            if !queued.contains(where: { $0.id == candidate.id })
                || LibraryListing.completionDate(candidate, finished: finished) != nil { continue }

            let remainingCache = await mediaCache.cachedEntries()
            // Recheck both playback intent and candidate eligibility after the cache await.
            guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
            if !queued.contains(where: { $0.id == candidate.id })
                || LibraryListing.completionDate(candidate, finished: finished) != nil { continue }
            // A missing file is a stale cache snapshot; an eligible cached candidate that failed
            // to start for another reason remains the end of this attempt.
            guard remainingCache[candidate.id] == nil else { return }
        }
    }
}
