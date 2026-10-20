import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    // MARK: - Continue from Mac

    /// Recomputes the banner from fresh device records. Runs on every sync, so it covers app
    /// activation, pull to refresh and silent pushes.
    func updateContinuation(from records: LibraryDeviceRecords) async {
        // The fetch that produced `records` replaced the own positions with what the server holds, which
        // for a position saved offline is older: put the saved ones back once they are settled or kept.
        let pending = handoffState.unpublished
        await republishUnpublishedPositions()
        for (entryID, saved) in pending { await rememberOwnPosition(entryID, position: saved.position) }
        if let own = records.nowPlaying.first(where: { $0.record.deviceID == deviceID }),
           let offset = HandoffResolver.clockOffset(of: own) { handoffState.clockOffset = offset }
        if handoffState.player?.isPlaying == true { continuation = nil; return }
        let inventory = await continuationInventory()
        var plan = LibraryContinuationPlanner.plan(
            records: records, deviceID: deviceID, cachedRevisions: inventory.revisions, durations: entryDurations,
            now: now(), clockOffset: handoffState.clockOffset,
            entries: Array(decisionContent.entries.values), mediaOffers: inventory.offers)
        if case let .needsAudio(entryID, revision, source) = plan, handoffState.refusedRevisions[entryID] == revision {
            plan = .refused(entryID: entryID, reason: Self.offerMismatchReason, source: source)
        }
        // Publish each existing sync observation so the displayed record age stays current.
        continuation = plan
    }

    static let offerMismatchReason = "The Mac has a different version of this episode ready than the one it is playing."

    /// The title shown for a continuation.
    func continuationTitle(_ entryID: ItemID) -> String {
        decisionContent.entries[entryID]?.title ?? "Episode"
    }

    /// Continues what the Mac plays. Always re-reads the records so the position is current.
    /// When the audio is not on the phone it requests it first, refusing a revision that does
    /// not match what the Mac plays; the transfer shows on the episode's row.
    func continueFromMac() async {
        guard let player = handoffState.player, !handoffState.continueInFlight else { return }
        // The newest command owns playback: a row chosen while this fetches or downloads wins.
        let token = beginExternalStart()
        handoffState.continueInFlight = true
        defer { handoffState.continueInFlight = false }
        guard var planned = await freshPlan() else { continuation = nil; return }
        if case let .needsAudio(entryID, revision, source) = planned.plan {
            guard await fetchAudio(entryID, revision: revision, source: source) else { return }
            guard let replanned = await freshPlan() else { continuation = nil; return }
            planned = replanned
        }
        let plan = planned.plan
        switch plan {
        case let .ready(entryID, position, rate, _, _, source):
            // The record fetch in the plan supplies this position and rate, so it stays first. The
            // plan's own cache walk then serves the verification and the resume check.
            guard let cached = await verifiedCachedMedia(entryID, token: token, walked: planned.walked) else { return }
            let inventory = await continuationInventory(walked: planned.walked)
            let target = HandoffResolver.resumeTarget(observed: [source], localDeviceID: deviceID,
                entries: Array(decisionContent.entries.values), localRevision: { inventory.revisions[$0] },
                mediaOffer: { inventory.offers[$0] }, now: now(), clockOffset: handoffState.clockOffset,
                durationSeconds: { self.entryDurations[$0] })
            guard case let .resume(resume) = target, resume.entryID == entryID,
                  resume.revision == cached.revisionID else { handoffMessage = Self.offerMismatchReason; return }
            // Re-admit the file verified above: every fence runs again, with no walk or second hash.
            guard let final = await verifiedCachedMedia(entryID, token: token, walked: [entryID: cached]),
                  final == cached else { return }
            let entry = decisionContent.entries[logicalEntryID(entryID)]
            let item = LibraryPlayer.Item(
                entryID: entryID, title: entry?.title ?? "Episode",
                showTitle: entry.map {
                    $0.kind == .audiobook
                        ? LibraryRowBuilder.showTitle($0, sources: decisionContent.sources)
                        : decisionContent.sources[$0.sourceID]?.title ?? ""
                } ?? "",
                fileURL: cached.url, artworkURL: LibraryRowBuilder.artworkURL(entry?.artworkRef),
                chapters: entry.map(LibraryRowBuilder.chapters) ?? [])
            let forwardSequence = manualForwardSuffix(from: entryID)
            guard commandState.token == token else { return }
            continuation = nil
            // Loading applies phone defaults; the winning Mac rate belongs to this continuation.
            if player.start(item, at: position, autoplay: false) {
                player.setRate(rate)
                if player.playAdmitted() { handoffState.forwardSequenceIDs = forwardSequence }
            }
        case let .refused(_, reason, _):
            handoffMessage = reason
            continuation = plan
        case .needsAudio:
            break
        }
    }

    /// The plan from freshly fetched device records, with the cache walk it was planned against.
    private func freshPlan() async -> (plan: LibraryContinuation, walked: [ItemID: CachedMedia])? {
        guard let records = try? await transport.fetchDeviceRecords() else {
            handoffMessage = "Could not read the Mac's playback. Check your connection."
            return nil
        }
        let walked = await mediaCache.cachedEntries()
        let inventory = await continuationInventory(walked: walked)
        guard let plan = LibraryContinuationPlanner.plan(
            records: records, deviceID: deviceID, cachedRevisions: inventory.revisions, durations: entryDurations,
            now: now(), clockOffset: handoffState.clockOffset,
            entries: Array(decisionContent.entries.values), mediaOffers: inventory.offers) else { return nil }
        return (plan, walked)
    }

    /// Requests the audio and waits for it. Returns false when it did not arrive on the phone or
    /// the Mac offers a different revision than the one being continued.
    private func fetchAudio(_ entryID: ItemID, revision: RevisionID, source: ObservedPlayback) async -> Bool {
        if let offers = try? await transport.mediaOffers(),
           let offer = offers.first(where: { $0.entryID == entryID }), offer.isPrepared,
           let offered = offer.revisionID, offered != revision {
            handoffState.refusedRevisions[entryID] = revision
            continuation = .refused(entryID: entryID, reason: Self.offerMismatchReason, source: source)
            handoffMessage = Self.offerMismatchReason
            return false
        }
        startMediaRequest(entryID: entryID)
        await waitForMedia(entryID: entryID)
        guard mediaState(for: entryID) == .onPhone else { return false }
        return true
    }
}
