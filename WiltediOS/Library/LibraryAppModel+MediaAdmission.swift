import Foundation
import WiltedDomain
import WiltedLibrary

/// The durable mirror identity that owns one cache or playback operation.
struct LibraryMediaContext: Equatable {
    let storeIdentity: ObjectIdentifier
    let ownerToken: String
    let generation: UInt64
}

extension LibraryAppModel {
    static var mediaLibraryScope: String { LibraryEnvironment.containerIdentifier + "/" + LibraryEnvironment.zoneName }

    func mediaContext(live: Bool = false) async -> LibraryMediaContext? {
        let identity = playbackStoreIdentity
        let generation = await transport.operationGeneration()
        let saved = await mediaStoreState()
        guard let owner = saved.ownerToken, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !saved.reviewHold, !accountQuarantined, playbackStoreIdentity == identity else { return nil }
        let context = LibraryMediaContext(storeIdentity: identity, ownerToken: owner, generation: generation)
        return await mediaContextIsCurrent(context, live: live) ? context : nil
    }

    func mediaContextIsCurrent(_ context: LibraryMediaContext, entryID: ItemID? = nil, live: Bool = false) async -> Bool {
        let generation = await transport.operationGeneration()
        let saved = await mediaStoreState()
        let owner = live ? await transport.verifiedOwnerToken() : context.ownerToken
        let finalGeneration = await transport.operationGeneration()
        guard !Task.isCancelled, playbackStoreIdentity == context.storeIdentity,
              generation == context.generation, finalGeneration == context.generation,
              saved.ownerToken == context.ownerToken, owner == context.ownerToken,
              !saved.reviewHold, !accountQuarantined else { return false }
        let final = await mediaStoreState()
        guard playbackStoreIdentity == context.storeIdentity, final.ownerToken == context.ownerToken,
              !final.reviewHold, !accountQuarantined else { return false }
        if let entryID {
            return final.content.entries[entryID] != nil && final.content.entries[entryID] == decisionContent.entries[entryID]
                && final.content.queue.contains { $0.entryID == entryID }
                && queued.contains { $0.id == entryID } && !mediaRevocations.contains(entryID)
        }
        return true
    }

    /// Bind before inventory. An unknown or held mirror cannot promote retained files.
    func bindMediaOwner() async -> LibraryMediaContext? {
        let identity = playbackStoreIdentity
        let saved = await mediaStoreState()
        do {
            try await mediaCache.bindOwner(ownerToken: saved.ownerToken, libraryScope: Self.mediaLibraryScope,
                                          held: saved.reviewHold || accountQuarantined || saved.ownerToken == nil)
        } catch {
            media = media.filter { $0.value != .onPhone }
            mediaAdmissionFailed("The audio cache could not bind to the saved account.")
            return nil
        }
        guard playbackStoreIdentity == identity else { return nil }
        return await mediaContext()
    }

    func cachedProofMatches(_ cached: CachedMedia, entryID: ItemID, context: LibraryMediaContext) -> Bool {
        guard let proof = cached.preparation else { return false }
        let offer = proof.offer
        return proof.ownerToken == context.ownerToken && proof.libraryScope == Self.mediaLibraryScope
            && offer.entryID == entryID && offer.isPrepared && offer.revisionID == cached.revisionID
            && offer.contentHash == cached.contentHash && offer.byteCount == cached.byteCount
            && cached.url.pathExtension == FileMediaCache.fileExtension(for: offer.mediaType)
    }

    /// Inventory permission checks ledger epochs without hashing every cached episode.
    func cachedPreparationIsCurrent(_ cached: CachedMedia, entryID: ItemID, context: LibraryMediaContext) async -> Bool {
        guard cachedProofMatches(cached, entryID: entryID, context: context), let proof = cached.preparation,
              let admission = await mediaCache.admission(entryID: entryID, ownerToken: context.ownerToken,
                libraryScope: Self.mediaLibraryScope, transportGeneration: context.generation),
              admission.ownerEpoch == proof.ownerEpoch,
              admission.entryRevocationEpoch == proof.entryRevocationEpoch else { return false }
        return await mediaCache.permits(admission, for: proof.offer)
    }

    /// Only observed semantic negatives revoke; absence and failed reads preserve offline proof.
    func applyMediaOffers(_ offers: [LibraryMediaOffer], context: LibraryMediaContext) async -> Bool {
        guard await mediaContextIsCurrent(context, live: true) else { return false }
        let cached = await mediaCache.cachedEntries()
        guard await mediaContextIsCurrent(context, live: true) else { return false }
        for offer in offers {
            let prior = cached[offer.entryID]?.preparation?.offer
            let changed = prior.map { offer.isPrepared && !Self.samePreparedIdentity($0, offer) } ?? false
            if offer.state == .notReady || changed {
                guard await revokeMediaPreparation(offer.entryID, context: context) else { return false }
            }
        }
        return await mediaContextIsCurrent(context, live: true)
    }

    static func samePreparedIdentity(_ first: LibraryMediaOffer, _ second: LibraryMediaOffer) -> Bool {
        first.entryID == second.entryID && first.revisionID == second.revisionID
            && first.contentHash == second.contentHash && first.byteCount == second.byteCount
            && first.mediaType == second.mediaType && first.preparation == second.preparation
    }

    func revokeMediaPreparation(_ entryID: ItemID, context: LibraryMediaContext) async -> Bool {
        guard await mediaContextIsCurrent(context, live: true) else { return false }
        mediaRevocations.insert(entryID)
        cancelMediaRequest(entryID: entryID)
        cancelTranscript(entryID: entryID)
        unacknowledgedMedia[entryID] = nil
        transcripts[entryID] = nil
        media[entryID] = .notPrepared
        if handoffState.player?.item?.entryID == entryID { handoffState.player?.invalidateLoadedItem() }
        do { try await mediaCache.revokePreparation(entryID: entryID) }
        catch { mediaAdmissionFailed("The audio preparation withdrawal could not be saved."); return false }
        guard await mediaContextIsCurrent(context, live: true) else { return false }
        mediaRevocations.remove(entryID)
        return true
    }

    func revokeRemovedQueueMedia(previous: Set<ItemID>, current: Set<ItemID>, context: LibraryMediaContext) async -> Bool {
        for entryID in previous.subtracting(current) {
            guard await revokeMediaPreparation(entryID, context: context) else { return false }
        }
        return true
    }
}
