import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    private static let listenNextPlaybackLedgerKey = "wilted.listenNext.playback.v1"
    static let listenNextPlaybackHoldKey = "wilted.listenNext.playback.hold.v1"
    static let listenNextPlaybackHeldKey = "wilted.listenNext.playback.held.v1"

    func recordStoryListenNext(_ snapshot: LibraryListenNextRequestSnapshot, holdEpoch: UInt64) throws {
        guard snapshot.requesterDeviceID == deviceID,
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return }
        var ledger = storyPlaybackLedger(for: snapshot)
        ledger.record(
            requestID: snapshot.requestID, storyID: storyID, requesterDeviceID: snapshot.requesterDeviceID,
            ownerToken: snapshot.ownerToken, operationGeneration: snapshot.operationGeneration,
            anchorID: snapshot.anchorID, createdAt: snapshot.createdAt, holdEpoch: holdEpoch,
            phase: queuePhase(for: snapshot.status))
        guard let store = storyPlaybackLedgerStore(for: snapshot) else { return }
        if let player = handoffState.player, player.status == .ended,
           player.item?.storyRequestID == nil, let anchorID = player.item?.entryID,
           snapshot.anchorID == anchorID {
            let autoPlayNext = preferences.object(forKey: LibrarySettingsStore.autoPlayNextKey) as? Bool ?? true
            ledger.recordNaturalBoundary(
                boundaryID: "\(anchorID.rawValue):\(player.transportCount)",
                continuation: ListenNextContinuation(
                    kind: .phoneForwardSequence, anchorID: anchorID,
                    entryIDs: continuationIDs(after: anchorID),
                    allowsAutomaticContinuation: autoPlayNext),
                holdEpoch: player.storyAutoStartEpoch)
        }
        try store.save(ledger)
    }

    func refreshStoryQueueSnapshots(_ snapshots: [LibraryListenNextRequestSnapshot]) {
        for snapshot in snapshots where snapshot.requesterDeviceID == deviceID {
            guard let storyID = try? ItemID(rawValue: snapshot.storyID) else { continue }
            guard let store = storyPlaybackLedgerStore(for: snapshot) else { continue }
            var ledger = store.load()
            if !ledger.entries.contains(where: { $0.requestID == snapshot.requestID }) {
                guard snapshot.status != .selected, snapshot.status != .playing,
                      snapshot.status != .completed else { continue }
                ledger.record(
                    requestID: snapshot.requestID, storyID: storyID,
                    requesterDeviceID: snapshot.requesterDeviceID, ownerToken: snapshot.ownerToken,
                    operationGeneration: snapshot.operationGeneration, anchorID: snapshot.anchorID,
                    createdAt: snapshot.createdAt, holdEpoch: handoffState.player?.storyAutoStartEpoch ?? 0,
                    phase: queuePhase(for: snapshot.status))
            } else {
                ledger.updateRequestPhase(requestID: snapshot.requestID, phase: queuePhase(for: snapshot.status))
            }
            try? store.save(ledger)
        }
    }

    func storyAudioBecameReady(_ snapshot: LibraryListenNextRequestSnapshot, fileURL: URL) throws {
        guard snapshot.requesterDeviceID == deviceID,
              snapshot.status == .ready, snapshot.audioOffer != nil,
              fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let store = storyPlaybackLedgerStore(for: snapshot) else { return }
        var ledger = store.load()
        ledger.setReadyMedia(
            requestID: snapshot.requestID, fileURL: fileURL,
            audioOfferIdentity: audioOfferIdentity(for: snapshot))
        try store.save(ledger)
        Task { @MainActor [weak self] in
            await self?.startStoryIfPlayerIsStillAtSavedEnd(for: snapshot)
        }
    }

    func storyRequestCancelled(_ snapshot: LibraryListenNextRequestSnapshot) throws {
        updateStoryRequest(snapshot, phase: .cancelled)
    }

    func storyRequestFailed(_ snapshot: LibraryListenNextRequestSnapshot) throws {
        updateStoryRequest(snapshot, phase: .failed)
    }

    func saveStoryPlaybackPosition(requestID: String, positionSeconds: Double) {
        guard let entry = storyPlaybackLedgerEntry(requestID: requestID) else { return }
        guard let store = storyPlaybackLedgerStore(for: entry) else { return }
        var ledger = store.load()
        ledger.savePosition(requestID: requestID, positionSeconds: positionSeconds)
        try? store.save(ledger)
    }

    /// A natural episode end captures the exact ordinary suffix before any
    /// story admission. If no successor is playing, a later audio-ready event
    /// may still start at this boundary.
    func startStoryAtNaturalBoundary(
        after endedID: ItemID, completion: LibraryPlayer.NaturalCompletion, autoPlayNext: Bool
    ) async -> Bool {
        guard let player = handoffState.player, player.owns(completion) else { return false }
        let continuationIDs = continuationIDs(after: endedID)
        let continuation = ListenNextContinuation(
            kind: .phoneForwardSequence, anchorID: endedID, entryIDs: continuationIDs,
            allowsAutomaticContinuation: autoPlayNext)
        let snapshots = await listenNextSnapshots()
        refreshStoryQueueSnapshots(snapshots)
        guard let identity = snapshots.first(where: { $0.requesterDeviceID == deviceID }),
              let store = storyPlaybackLedgerStore(for: identity) else { return false }
        var ledger = store.load()
        let boundaryID = "\(endedID.rawValue):\(player.transportCount)"
        ledger.recordNaturalBoundary(
            boundaryID: boundaryID, continuation: continuation,
            holdEpoch: player.storyAutoStartEpoch)
        guard let selected = ledger.selectAtNaturalBoundary(
            boundaryID: boundaryID, continuation: continuation,
            currentHoldEpoch: player.storyAutoStartEpoch) else {
            try? store.save(ledger)
            return false
        }
        guard let snapshot = snapshots.first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready,
              let url = storyPlaybackAudioURL(for: snapshot),
              await playerStillOwnsNaturalEnd(player, completion) else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            return false
        }
        return await startStory(snapshot, fileURL: url, selected: selected, ledger: ledger,
                                completion: completion, store: store)
    }

    private func startStoryIfPlayerIsStillAtSavedEnd(for readySnapshot: LibraryListenNextRequestSnapshot) async {
        guard let player = handoffState.player, player.status == .ended,
              let endedID = player.item?.entryID,
              let completion = player.naturalCompletion(after: endedID),
              let store = storyPlaybackLedgerStore(for: readySnapshot) else { return }
        var ledger = store.load()
        guard ledger.hasUnchangedNaturalBoundary,
              let boundaryID = ledger.latestBoundaryID,
              let continuation = ledger.latestContinuation,
              ledger.latestHoldEpoch == player.storyAutoStartEpoch,
              let selected = ledger.selectAtNaturalBoundary(
                boundaryID: boundaryID, continuation: continuation,
                currentHoldEpoch: player.storyAutoStartEpoch),
              let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready,
              let url = storyPlaybackAudioURL(for: snapshot) else {
            try? store.save(ledger)
            return
        }
        _ = await startStory(snapshot, fileURL: url, selected: selected, ledger: ledger,
                             completion: completion, store: store)
    }

    private func startStory(
        _ snapshot: LibraryListenNextRequestSnapshot, fileURL: URL,
        selected: ListenNextPlaybackLedger.Entry, ledger sourceLedger: ListenNextPlaybackLedger,
        completion: LibraryPlayer.NaturalCompletion,
        store: ListenNextPlaybackLedgerStore
    ) async -> Bool {
        guard let player = handoffState.player,
              player.owns(completion), player.status == .ended,
              player.storyAutoStartEpoch == selected.holdEpoch,
              FileManager.default.fileExists(atPath: fileURL.path),
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return false }
        var ledger = sourceLedger
        ledger.markStarting(requestID: selected.requestID)
        do { try store.save(ledger) } catch { return false }
        guard let selectedSnapshot = await setListenNextStatus(snapshot, to: .selected) else {
            await returnAbandonedStoryStartToQueue(snapshot, requestID: selected.requestID, store: store)
            return false
        }
        guard player.owns(completion), player.storyAutoStartEpoch == selected.holdEpoch,
              player.status == .ended else {
            await returnAbandonedStoryStartToQueue(selectedSnapshot, requestID: selected.requestID, store: store)
            return false
        }
        guard let verifiedURL = await listenNextAudioURL(for: selectedSnapshot),
              verifiedURL.standardizedFileURL == fileURL.standardizedFileURL,
              player.owns(completion), player.storyAutoStartEpoch == selected.holdEpoch,
              player.status == .ended else {
            await returnAbandonedStoryStartToQueue(selectedSnapshot, requestID: selected.requestID, store: store)
            return false
        }

        let item = LibraryPlayer.Item(
            entryID: storyID, title: snapshot.story.title, showTitle: snapshot.story.publisherName,
            fileURL: fileURL, storyRequestID: snapshot.requestID)
        guard player.start(item, at: selected.positionSeconds, automatic: true) else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            _ = await setListenNextStatus(selectedSnapshot, to: .failed)
            return false
        }
        ledger.markPlaying(requestID: selected.requestID, positionSeconds: selected.positionSeconds)
        do { try store.save(ledger) } catch { return false }
        _ = await setListenNextStatus(selectedSnapshot, to: .playing)
        return true
    }

    private func returnAbandonedStoryStartToQueue(
        _ snapshot: LibraryListenNextRequestSnapshot, requestID: String,
        store: ListenNextPlaybackLedgerStore
    ) async {
        let readySnapshot: LibraryListenNextRequestSnapshot?
        if snapshot.status == .selected {
            readySnapshot = await setListenNextStatus(snapshot, to: .ready)
        } else {
            readySnapshot = snapshot.status == .ready ? snapshot : nil
        }
        guard readySnapshot?.status == .ready else { return }
        var ledger = store.load()
        ledger.returnAbandonedStartToReady(requestID: requestID)
        try? store.save(ledger)
    }

    func finishStoryPlayback(requestID: String, autoPlayNext: Bool) async {
        guard let entry = storyPlaybackLedgerEntry(requestID: requestID),
              let player = handoffState.player,
              player.item?.storyRequestID == requestID,
              let completion = player.naturalCompletion(after: entry.storyID),
              let store = storyPlaybackLedgerStore(for: entry) else { return }
        var ledger = store.load()
        if let savedContinuation = ledger.entries.first(where: { $0.requestID == requestID })?.continuation {
            ledger.updateContinuation(requestID: requestID, continuation: ListenNextContinuation(
                kind: savedContinuation.kind, anchorID: savedContinuation.anchorID,
                entryIDs: savedContinuation.entryIDs, nextIndex: savedContinuation.nextIndex,
                playlistID: savedContinuation.playlistID,
                allowsAutomaticContinuation: autoPlayNext))
        }
        ledger.markCompleted(requestID: requestID)
        do { try store.save(ledger) }
        catch { return }
        if let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == requestID }) {
            let completedSnapshot: LibraryListenNextRequestSnapshot?
            if snapshot.status == .completed {
                completedSnapshot = snapshot
            } else if snapshot.status == .playing {
                completedSnapshot = await setListenNextStatus(snapshot, to: .completed)
            } else {
                completedSnapshot = nil
            }
            if let completedSnapshot, completedSnapshot.status == .completed {
                await discardCompletedListenNextAudio(completedSnapshot)
            }
        }
        guard player.owns(completion),
              let continuation = ledger.continuationAfterCompletion(requestID: requestID) else { return }
        guard continuation.shouldAutomaticallyContinue else {
            try? store.save(ledger)
            return
        }
        let storyBoundaryID = "story:\(requestID):\(player.transportCount)"
        ledger.recordNaturalBoundary(
            boundaryID: storyBoundaryID, continuation: continuation,
            holdEpoch: player.storyAutoStartEpoch)
        if let selected = ledger.selectAtNaturalBoundary(
            boundaryID: storyBoundaryID, continuation: continuation,
            currentHoldEpoch: player.storyAutoStartEpoch),
           selected.requestID != requestID,
           let nextSnapshot = (await listenNextSnapshots()).first(where: { $0.requestID == selected.requestID }),
           nextSnapshot.status == .ready,
           let url = storyPlaybackAudioURL(for: nextSnapshot),
           await playerStillOwnsNaturalEnd(player, completion),
           await startStory(nextSnapshot, fileURL: url, selected: selected, ledger: ledger,
                            completion: completion, store: store) {
            return
        }
        try? store.save(ledger)
        guard autoPlayNext, player.owns(completion) else { return }
        await resumePhoneContinuation(continuation, completion: completion)
    }

    func rearmStoryQueueAfterExplicitStart(at holdEpoch: UInt64) {
        preferences.set(holdEpoch, forKey: Self.listenNextPlaybackHoldKey)
        preferences.set(false, forKey: Self.listenNextPlaybackHeldKey)
        let key = storyPlaybackLedgerKey
        guard let data = preferences.data(forKey: key),
              var ledger = try? JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data),
              ledger.requesterDeviceID == deviceID else { return }
        ledger.releaseHold(onExplicitStartAt: holdEpoch)
        if let encoded = try? ledger.encoded() { preferences.set(encoded, forKey: key) }
    }

    /// A committed Listen next request is explicit intent to release a prior hold.
    func rearmStoryQueueForExplicitListenNext() {
        guard preferences.bool(forKey: Self.listenNextPlaybackHeldKey) else { return }
        if let player = handoffState.player {
            player.rearmStoryQueueForExplicitListenNext()
        } else {
            rearmStoryQueueAfterExplicitStart(
                at: (preferences.object(forKey: Self.listenNextPlaybackHoldKey) as? UInt64 ?? 0) &+ 1)
        }
    }

    func persistStoryQueueHold(at holdEpoch: UInt64) {
        preferences.set(holdEpoch, forKey: Self.listenNextPlaybackHoldKey)
        preferences.set(true, forKey: Self.listenNextPlaybackHeldKey)
    }

    /// Drops only playback metadata; request-owned audio cleanup stays with the request cache.
    func discardStoryPlaybackLedgerAfterAccountChange() {
        if handoffState.player?.item?.storyRequestID != nil {
            handoffState.player?.stop(reason: .accountChanged)
        }
        preferences.removeObject(forKey: Self.listenNextPlaybackLedgerKey)
        preferences.removeObject(forKey: Self.listenNextPlaybackHoldKey)
        preferences.removeObject(forKey: Self.listenNextPlaybackHeldKey)
    }

    private func updateStoryRequest(_ snapshot: LibraryListenNextRequestSnapshot, phase: ListenNextPlaybackPhase) {
        guard let store = storyPlaybackLedgerStore(for: snapshot) else { return }
        var ledger = store.load()
        if phase == .cancelled { ledger.markCancelled(requestID: snapshot.requestID) }
        else { ledger.markFailed(requestID: snapshot.requestID) }
        try? store.save(ledger)
    }

    func queuePhase(for status: LibraryListenNextRequestSnapshot.Status) -> ListenNextPlaybackPhase {
        switch status {
        case .pending: .pending
        case .sent: .sent
        case .preparing: .preparing
        case .ready: .ready
        case .selected: .selected
        case .playing: .playing
        case .failed: .failed
        case .cancelled: .cancelled
        case .completed: .completed
        }
    }

    func storyPlaybackLedgerStore(
        for snapshot: LibraryListenNextRequestSnapshot
    ) -> ListenNextPlaybackLedgerStore? {
        guard snapshot.requesterDeviceID == deviceID else { return nil }
        return ListenNextPlaybackLedgerStore(
            defaults: preferences, key: storyPlaybackLedgerKey, requesterDeviceID: deviceID,
            ownerToken: snapshot.ownerToken, operationGeneration: snapshot.operationGeneration)
    }

    private func storyPlaybackLedgerStore(
        for entry: ListenNextPlaybackLedger.Entry
    ) -> ListenNextPlaybackLedgerStore? {
        guard entry.requesterDeviceID == deviceID else { return nil }
        return ListenNextPlaybackLedgerStore(
            defaults: preferences, key: storyPlaybackLedgerKey, requesterDeviceID: deviceID,
            ownerToken: entry.ownerToken, operationGeneration: entry.operationGeneration)
    }

    private func durableStoryURL(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Confirms the device, account, request, and exact ready audio value
    /// before the request adapter performs its file hash and size check.
    func storyPlaybackAudioURL(for snapshot: LibraryListenNextRequestSnapshot) -> URL? {
        guard snapshot.requesterDeviceID == deviceID,
              snapshot.status == .ready || snapshot.status == .selected || snapshot.status == .playing,
              let offerIdentity = audioOfferIdentity(for: snapshot),
              let store = storyPlaybackLedgerStore(for: snapshot),
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return nil }
        let ledger = store.load()
        guard let entry = ledger.entries.first(where: { $0.requestID == snapshot.requestID }),
              entry.storyID == storyID, entry.requesterDeviceID == snapshot.requesterDeviceID,
              entry.ownerToken == snapshot.ownerToken,
              entry.operationGeneration == snapshot.operationGeneration,
              entry.audioOfferIdentity == offerIdentity,
              entry.phase == .ready || entry.phase == .selected || entry.phase == .starting || entry.phase == .playing,
              let path = entry.mediaFilePath else { return nil }
        return durableStoryURL(path)
    }

    func audioOfferIdentity(
        for snapshot: LibraryListenNextRequestSnapshot
    ) -> ListenNextAudioOfferIdentity? {
        guard let offer = snapshot.audioOffer else { return nil }
        return ListenNextAudioOfferIdentity(
            audioRevisionID: offer.audioRevision.rawValue, contentHash: offer.contentHash,
            byteCount: offer.byteCount, mediaType: offer.mediaType,
            durationSeconds: offer.durationSeconds)
    }

    private var storyPlaybackLedgerKey: String { Self.listenNextPlaybackLedgerKey }

    private func storyPlaybackLedger(for snapshot: LibraryListenNextRequestSnapshot) -> ListenNextPlaybackLedger {
        storyPlaybackLedgerStore(for: snapshot)?.load()
            ?? ListenNextPlaybackLedger(requesterDeviceID: deviceID, ownerToken: snapshot.ownerToken,
                                        operationGeneration: snapshot.operationGeneration)
    }

    private func storyPlaybackLedgerEntry(requestID: String) -> ListenNextPlaybackLedger.Entry? {
        guard let data = preferences.data(forKey: storyPlaybackLedgerKey),
              let ledger = try? JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data),
              ledger.requesterDeviceID == deviceID else { return nil }
        return ledger.entries.first { $0.requestID == requestID }
    }

    func authorizesStoryPlayback(requestID: String, item: LibraryPlayer.Item) async -> Bool {
        guard let entry = storyPlaybackLedgerEntry(requestID: requestID), entry.phase == .playing,
              entry.storyID == item.entryID, entry.mediaFilePath == item.fileURL.standardizedFileURL.path,
              entry.requesterDeviceID == deviceID,
              FileManager.default.fileExists(atPath: item.fileURL.path), !accountQuarantined,
              await transport.verifiedOwnerToken() == entry.ownerToken,
              await transport.operationGeneration() == entry.operationGeneration else { return false }
        let snapshots = await listenNextSnapshots()
        let current = snapshots.first { $0.requestID == requestID }
        guard current?.requesterDeviceID == entry.requesterDeviceID
            && current?.ownerToken == entry.ownerToken
            && current?.operationGeneration == entry.operationGeneration
            && (current?.status == .playing || current?.status == .selected),
              let current,
              let verifiedURL = await listenNextAudioURL(for: current) else { return false }
        return verifiedURL.standardizedFileURL == item.fileURL.standardizedFileURL
    }

    private func playerStillOwnsNaturalEnd(
        _ player: LibraryPlayer, _ completion: LibraryPlayer.NaturalCompletion
    ) async -> Bool {
        await Task.yield()
        return handoffState.player === player && player.owns(completion)
    }

    private func continuationIDs(after endedID: ItemID) -> [ItemID] {
        if listOrder == .mac {
            return playOrderRows.filter { !sameLogicalEpisode($0.id, endedID) && $0.kind != .audiobook }.map(\.id)
        }
        guard let index = handoffState.forwardSequenceIDs.firstIndex(where: { sameLogicalEpisode($0, endedID) }) else { return [] }
        return Array(handoffState.forwardSequenceIDs.dropFirst(index + 1))
    }

    private func resumePhoneContinuation(
        _ continuation: ListenNextContinuation, completion: LibraryPlayer.NaturalCompletion
    ) async {
        guard let player = handoffState.player, player.owns(completion) else { return }
        let cached = await mediaCache.cachedEntries()
        guard player.owns(completion) else { return }
        let queuedByID = Dictionary(uniqueKeysWithValues: logicalQueued.map { ($0.id, $0) })
        for id in continuation.remainingEntryIDs {
            guard player.owns(completion), let row = queuedByID[id], automaticContinuationIsEligible(id),
                  cached[backingEntryID(for: id)] != nil else { continue }
            let outcome = await startCached(row, kind: .automatic) { current in
                current.owns(completion) && self.automaticContinuationIsEligible(id)
            }
            if outcome == .started || outcome == .resumed {
                player.setRate(completion.rate)
                return
            }
            guard player.owns(completion) else { return }
        }
    }

}
