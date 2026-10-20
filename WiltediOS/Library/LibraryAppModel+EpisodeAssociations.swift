import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// Content mutations invalidate membership; optimistic decisions only change
    /// group metadata. Both projections belong to this model's current mirror.
    func refreshEpisodeProjection() {
        if episodeAssociationsDirty {
            episodeAssociationGroups = LibraryEpisodeAssociation.coherentGroups(in: Array(decisionContent.entries.values))
            episodeGroupsByMember = Dictionary(episodeAssociationGroups.flatMap { group in
                group.memberIDs.map { ($0, group) }
            }, uniquingKeysWith: { first, _ in first })
            episodeAssociationResolutionCount += 1
            episodeAssociationsDirty = false
        }
        guard episodeProjectionDirty else { return }
        projectedEpisodeContent = LibraryDecisionOverlay.apply(decisions, to: decisionContent)
        projectedEpisodeGroupsByMember = episodeGroupsByMember.mapValues { group in
            projectedEpisodeContent.entries[group.representativeID]?.episodeAssociation ?? group
        }
        episodeProjectionDirty = false
        logicalEpisodeRowsDirty = true
    }

    func episodeGroup(_ id: ItemID) -> LibraryEpisodeAssociation? {
        refreshEpisodeProjection()
        return episodeGroupsByMember[id]
    }

    func logicalEntryID(_ id: ItemID) -> ItemID { episodeGroup(id)?.representativeID ?? id }

    func sameLogicalEpisode(_ first: ItemID?, _ second: ItemID) -> Bool {
        first.map { logicalEntryID($0) == logicalEntryID(second) } ?? false
    }

    /// Display identity never replaces the raw queue or the owner-bound cache identity.
    var logicalQueued: [LibraryRow] {
        refreshEpisodeProjection()
        if logicalEpisodeRowsDirty {
            projectedLogicalEpisodeRows = LibraryRowBuilder.logicalRows(queued, content: projectedEpisodeContent,
                checkpoints: checkpoints, clock: clockFormat, started: startedEntries,
                groupsByMember: projectedEpisodeGroupsByMember)
            projectedLogicalRowsByID = Dictionary(projectedLogicalEpisodeRows.map { ($0.id, $0) },
                                                  uniquingKeysWith: { first, _ in first })
            logicalEpisodeRowsDirty = false
        }
        return projectedLogicalEpisodeRows
    }

    func logicalRow(for id: ItemID) -> LibraryRow? {
        _ = logicalQueued
        guard let row = projectedLogicalRowsByID[logicalEntryID(id)] else { return nil }
        let ids = effectiveLarderMediaIDs(prepared: preparedIDs)
        return row.withMediaAvailability(offered: ids.offered, onPhone: ids.onPhone)
    }

    func logicalIDs(_ ids: Set<ItemID>, groupsByMember: [ItemID: LibraryEpisodeAssociation]? = nil) -> Set<ItemID> {
        refreshEpisodeProjection()
        let groups = groupsByMember ?? episodeGroupsByMember
        return Set(ids.map { groups[$0]?.representativeID ?? $0 })
    }

    var logicalProgress: [ItemID: EpisodeProgress] {
        refreshEpisodeProjection()
        var mapped = progress
        for group in episodeAssociationGroups {
            if let loaded = handoffState.player?.item?.entryID, group.memberIDs.contains(loaded), let current = progress[loaded] {
                mapped[group.representativeID] = current
            } else if let newest = group.memberIDs.compactMap({ progress[$0] }).max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) {
                mapped[group.representativeID] = newest
            }
        }
        return mapped
    }

    var logicalFinished: [ItemID: Date] {
        refreshEpisodeProjection()
        var mapped = finished
        for group in episodeAssociationGroups {
            if let latest = group.memberIDs.compactMap({ finished[$0] }).max() { mapped[group.representativeID] = latest }
        }
        return mapped
    }

    /// Choose only a raw queued backing. On-phone is presentation; admission still verifies
    /// owner, generation, preparation, epochs and bytes before this source can reach the player.
    func backingEntryID(for id: ItemID) -> ItemID {
        let members = episodeGroup(id)?.memberIDs ?? [id]
        let eligible = members.filter { member in queued.contains { $0.id == member } }
        if let loaded = handoffState.player?.item?.entryID,
           eligible.contains(loaded), media[loaded] == .onPhone { return loaded }
        if let cached = eligible.first(where: { media[$0] == .onPhone }) { return cached }
        if let offered = eligible.first(where: { readyOffers.contains($0) }) { return offered }
        return eligible.first ?? id
    }

    func associatedStartPosition(_ id: ItemID, revision: RevisionID, walked: [ItemID: CachedMedia]? = nil) async -> Double? {
        guard let group = episodeGroup(id) else { return resumeStart(for: id, cachedRevision: revision) }
        let candidates = group.memberIDs.flatMap { [checkpoints[$0], handoffState.ownPositions[$0]].compactMap { $0 } }
        guard !candidates.isEmpty else { return 0 }
        let inventory = await continuationInventory(walked: walked)
        let target = HandoffResolver.resumeTarget(observed: candidates, localDeviceID: "",
            entries: Array(decisionContent.entries.values), localRevision: { $0 == id ? inventory.revisions[$0] : nil },
            mediaOffer: { inventory.offers[$0] }, now: now(), clockOffset: handoffState.clockOffset,
            durationSeconds: { self.entryDurations[$0] })
        guard case let .resume(resume) = target, resume.entryID == id, resume.revision == revision else { return nil }
        return resume.positionSeconds
    }

    /// Only currently admitted cached proof participates in alias position translation. `walked` is an
    /// inventory the caller already read; its proofs are still checked against the current ledger.
    func continuationInventory(walked: [ItemID: CachedMedia]? = nil) async
        -> (revisions: [ItemID: RevisionID], offers: [ItemID: LibraryMediaOffer]) {
        guard let context = await mediaContext() else { return ([:], [:]) }
        let cached: [ItemID: CachedMedia]
        if let walked { cached = walked } else { cached = await mediaCache.cachedEntries() }
        var revisions: [ItemID: RevisionID] = [:]
        var offers = tickState.offers
        for (id, candidate) in cached {
            guard await cachedPreparationIsCurrent(candidate, entryID: id, context: context),
                  await mediaContextIsCurrent(context, entryID: id), let proof = candidate.preparation else { continue }
            if let current = offers[id], current.state == .notReady ||
                (current.isPrepared && !Self.samePreparedIdentity(current, proof.offer)) { continue }
            revisions[id] = candidate.revisionID
            offers[id] = proof.offer
        }
        guard await mediaContextIsCurrent(context) else { return ([:], [:]) }
        return (revisions, offers)
    }
}
