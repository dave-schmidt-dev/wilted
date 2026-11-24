import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// Restores only a still-authorized active story at its request-scoped checkpoint.
    func restoreStoryPlaybackAfterRelaunch() async {
        guard !accountQuarantined, let player = handoffState.player, player.item == nil else { return }
        let restoreTransportCount = player.transportCount
        let restoreHoldEpoch = player.storyAutoStartEpoch
        let snapshots = await listenNextSnapshots()
        guard canRecoverStoryQueue(player, transportCount: restoreTransportCount, holdEpoch: restoreHoldEpoch,
                                   allowHeld: true) else { return }
        refreshStoryQueueSnapshots(snapshots)
        for snapshot in snapshots where snapshot.requesterDeviceID == deviceID {
            guard let store = storyPlaybackLedgerStore(for: snapshot) else { continue }
            var ledger = store.load()
            guard let entry = ledger.activeEntry, entry.requestID == snapshot.requestID,
                  entry.phase == .playing || entry.phase == .starting || entry.phase == .selected,
                  entry.ownerToken == snapshot.ownerToken,
                  entry.operationGeneration == snapshot.operationGeneration,
                  snapshot.status == .playing || snapshot.status == .selected,
                  let url = await listenNextAudioURL(for: snapshot),
                  await authorizesRestoredStory(entry, snapshot: snapshot, url: url),
                  canRecoverStoryQueue(player, transportCount: restoreTransportCount, holdEpoch: restoreHoldEpoch,
                                      allowHeld: true),
                  let storyID = try? ItemID(rawValue: snapshot.storyID) else { continue }
            ledger.markStarting(requestID: entry.requestID)
            ledger.markPlaying(requestID: entry.requestID, positionSeconds: entry.positionSeconds)
            try? store.save(ledger)
            let item = LibraryPlayer.Item(
                entryID: storyID, title: snapshot.story.title, showTitle: snapshot.story.publisherName,
                fileURL: url, storyRequestID: snapshot.requestID)
            guard player.start(item, at: entry.positionSeconds, autoplay: false, automatic: true) else {
                ledger.markFailed(requestID: entry.requestID)
                try? store.save(ledger)
                _ = await setListenNextStatus(snapshot, to: .failed)
                return
            }
            _ = await setListenNextStatus(snapshot, to: .playing)
            return
        }

        await recoverCompletedStoryAfterRelaunch(
            snapshots, player: player, transportCount: restoreTransportCount, holdEpoch: restoreHoldEpoch)
    }

    /// Closes the crash window after local completion but before the request status
    /// reaches `.completed`, then resumes only the continuation saved at that end.
    private func recoverCompletedStoryAfterRelaunch(
        _ snapshots: [LibraryListenNextRequestSnapshot], player: LibraryPlayer,
        transportCount: Int, holdEpoch: UInt64
    ) async {
        for snapshot in snapshots.reversed() where snapshot.requesterDeviceID == deviceID {
            guard snapshot.status == .playing || snapshot.status == .completed,
                  let store = storyPlaybackLedgerStore(for: snapshot) else { continue }
            var ledger = store.load()
            guard let completed = ledger.entries.first(where: {
                    $0.requestID == snapshot.requestID && $0.phase == .completed
                  }),
                  completed.requesterDeviceID == deviceID,
                  completed.ownerToken == snapshot.ownerToken,
                  completed.operationGeneration == snapshot.operationGeneration,
                  await transport.verifiedOwnerToken() == completed.ownerToken,
                  await transport.operationGeneration() == completed.operationGeneration else { continue }

            let completedSnapshot: LibraryListenNextRequestSnapshot
            if snapshot.status == .playing {
                guard let updated = await setListenNextStatus(snapshot, to: .completed), updated.status == .completed,
                      await transport.verifiedOwnerToken() == completed.ownerToken,
                      await transport.operationGeneration() == completed.operationGeneration else { return }
                completedSnapshot = updated
            } else {
                completedSnapshot = snapshot
            }

            await discardCompletedListenNextAudio(completedSnapshot)
            guard await transport.verifiedOwnerToken() == completed.ownerToken,
                  await transport.operationGeneration() == completed.operationGeneration,
                  canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch,
                                       allowHeld: true) else { return }
            guard let continuation = completed.continuation else { return }
            guard completed.holdEpoch == holdEpoch,
                  !preferences.bool(forKey: Self.listenNextPlaybackHeldKey),
                  canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return }
            guard continuation.shouldAutomaticallyContinue else { return }

            // Readiness can have been cached just before the process stopped,
            // before that path reached the playback ledger.
            for readySnapshot in snapshots where readySnapshot.requesterDeviceID == deviceID
                && readySnapshot.status == .ready
                && readySnapshot.ownerToken == completed.ownerToken
                && readySnapshot.operationGeneration == completed.operationGeneration {
                guard canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return }
                guard let url = await listenNextAudioURL(for: readySnapshot),
                      canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { continue }
                ledger.setReadyMedia(
                    requestID: readySnapshot.requestID, fileURL: url,
                    audioOfferIdentity: audioOfferIdentity(for: readySnapshot))
            }

            let boundaryID = "story-recovery:\(snapshot.requestID):\(transportCount)"
            ledger.recordNaturalBoundary(boundaryID: boundaryID, continuation: continuation, holdEpoch: holdEpoch)
            if let selected = ledger.selectAtNaturalBoundary(
                boundaryID: boundaryID, continuation: continuation, currentHoldEpoch: holdEpoch),
               selected.requestID != snapshot.requestID,
               let next = snapshots.first(where: { $0.requestID == selected.requestID }),
               next.status == .ready,
               let url = storyPlaybackAudioURL(for: next),
               await startRecoveredStory(
                    next, fileURL: url, selected: selected, ledger: ledger, store: store,
                    player: player, transportCount: transportCount, holdEpoch: holdEpoch) { return }

            try? store.save(ledger)
            await resumePhoneContinuationAfterRecovery(
                continuation, player: player, transportCount: transportCount, holdEpoch: holdEpoch)
            return
        }
    }

    private func startRecoveredStory(
        _ snapshot: LibraryListenNextRequestSnapshot, fileURL: URL,
        selected: ListenNextPlaybackLedger.Entry, ledger sourceLedger: ListenNextPlaybackLedger,
        store: ListenNextPlaybackLedgerStore, player: LibraryPlayer,
        transportCount: Int, holdEpoch: UInt64
    ) async -> Bool {
        guard canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch),
              selected.holdEpoch == holdEpoch, FileManager.default.fileExists(atPath: fileURL.path),
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return false }
        var ledger = sourceLedger
        ledger.markStarting(requestID: selected.requestID)
        do { try store.save(ledger) } catch { return false }
        guard let selectedSnapshot = await setListenNextStatus(snapshot, to: .selected),
              selectedSnapshot.status == .selected,
              canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch),
              let verifiedURL = await listenNextAudioURL(for: selectedSnapshot),
              verifiedURL.standardizedFileURL == fileURL.standardizedFileURL,
              canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return false }

        let item = LibraryPlayer.Item(
            entryID: storyID, title: snapshot.story.title, showTitle: snapshot.story.publisherName,
            fileURL: verifiedURL, storyRequestID: snapshot.requestID)
        guard player.start(item, autoplay: true, automatic: true) else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            _ = await setListenNextStatus(selectedSnapshot, to: .failed)
            return false
        }
        ledger.markPlaying(requestID: selected.requestID)
        do { try store.save(ledger) } catch { return false }
        _ = await setListenNextStatus(selectedSnapshot, to: .playing)
        return true
    }

    private func resumePhoneContinuationAfterRecovery(
        _ continuation: ListenNextContinuation, player: LibraryPlayer,
        transportCount: Int, holdEpoch: UInt64
    ) async {
        guard continuation.shouldAutomaticallyContinue,
              canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return }
        let cached = await mediaCache.cachedEntries()
        guard canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return }
        let queuedByID = Dictionary(uniqueKeysWithValues: logicalQueued.map { ($0.id, $0) })
        for id in continuation.remainingEntryIDs {
            guard canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch),
                  let row = queuedByID[id], automaticContinuationIsEligible(id),
                  cached[backingEntryID(for: id)] != nil else { continue }
            let outcome = await startCached(row, kind: .automatic) { current in
                self.canRecoverStoryQueue(current, transportCount: transportCount, holdEpoch: holdEpoch)
                    && self.automaticContinuationIsEligible(id)
            }
            if outcome == .started || outcome == .resumed {
                if continuation.kind == .phoneForwardSequence {
                    handoffState.forwardSequenceIDs = continuation.entryIDs
                }
                return
            }
            guard canRecoverStoryQueue(player, transportCount: transportCount, holdEpoch: holdEpoch) else { return }
        }
    }

    private func canRecoverStoryQueue(
        _ player: LibraryPlayer, transportCount: Int, holdEpoch: UInt64, allowHeld: Bool = false
    ) -> Bool {
        !accountQuarantined && player.item == nil && player.transportCount == transportCount
            && player.storyAutoStartEpoch == holdEpoch
            && (allowHeld || !preferences.bool(forKey: Self.listenNextPlaybackHeldKey))
    }

    private func authorizesRestoredStory(
        _ entry: ListenNextPlaybackLedger.Entry, snapshot: LibraryListenNextRequestSnapshot, url: URL
    ) async -> Bool {
        guard !accountQuarantined, entry.mediaFilePath == url.standardizedFileURL.path,
              await transport.verifiedOwnerToken() == entry.ownerToken,
              await transport.operationGeneration() == entry.operationGeneration else { return false }
        return snapshot.requesterDeviceID == deviceID
            && snapshot.ownerToken == entry.ownerToken
            && snapshot.operationGeneration == entry.operationGeneration
            && FileManager.default.fileExists(atPath: url.path)
    }

}
