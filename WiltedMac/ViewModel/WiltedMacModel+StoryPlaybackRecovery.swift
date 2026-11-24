import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

extension WiltedMacModel {
    /// Restores a still-authorized active story paused at its durable position before the podcast queue is loaded.
    func restoreStoryPlaybackAfterRelaunch() async -> Bool {
        guard let playback,
              let data = preferences.data(forKey: Self.listenNextPlaybackLedgerKey),
              let stored = try? JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data),
              stored.requesterDeviceID == libraryDeviceID() else { return false }
        let snapshots = await listenNextSnapshots()
        guard let entry = stored.activeEntry else {
            guard !preferences.bool(forKey: Self.listenNextPlaybackHeldKey) else { return false }
            guard let completedSnapshot = snapshots.first(where: { candidate in
                guard let completed = stored.completedEntryForRecovery(
                    requestID: candidate.requestID, remotePhase: queuePhase(for: candidate.status)) else { return false }
                return candidate.requesterDeviceID == completed.requesterDeviceID
                    && candidate.ownerToken == completed.ownerToken
                    && candidate.operationGeneration == completed.operationGeneration
            }),
            let completed = stored.completedEntryForRecovery(
                requestID: completedSnapshot.requestID, remotePhase: queuePhase(for: completedSnapshot.status)),
            let localStore = store,
            let queueState = try? await localStore.podcastQueueState(), queueState.currentEpisodeID == nil,
            let continuation = completed.continuation else { return false }
            if completedSnapshot.status == .playing {
                guard let reconciled = await setListenNextStatus(completedSnapshot, to: .completed),
                      reconciled.status == .completed else { return false }
            }
            guard continuation.shouldAutomaticallyContinue else { return false }
            await resumeMacContinuation(continuation, playback: playback)
            return playback.itemID != nil
        }
        guard entry.phase == .selected || entry.phase == .starting || entry.phase == .playing else { return false }
        if entry.phase != .playing,
           (preferences.bool(forKey: Self.listenNextPlaybackHeldKey)
                || entry.holdEpoch != playback.listenNextHoldEpoch) { return false }
        guard let snapshot = snapshots.first(where: { $0.requestID == entry.requestID }),
              snapshot.requesterDeviceID == entry.requesterDeviceID,
              snapshot.ownerToken == entry.ownerToken,
              snapshot.operationGeneration == entry.operationGeneration,
              snapshot.status == .selected || snapshot.status == .playing,
              let url = await verifiedStoryURL(snapshot),
              entry.mediaFilePath == url.standardizedFileURL.path,
              let storyID = try? ItemID(rawValue: snapshot.storyID),
              let revision = audioRevision(for: snapshot) else { return false }
        var ledger = storyPlaybackLedgerStore(for: snapshot)?.load() ?? stored
        ledger.markStarting(requestID: snapshot.requestID)
        ledger.markPlaying(requestID: snapshot.requestID, positionSeconds: entry.positionSeconds)
        try? storyPlaybackLedgerStore(for: snapshot)?.save(ledger)
        do {
            try await playback.loadListenNextStory(
                requestID: snapshot.requestID, revision: revision, mediaURL: url,
                positionSeconds: entry.positionSeconds)
        } catch { return false }
        currentListenNextStory = WiltedMacListenNextNowPlaying(
            requestID: snapshot.requestID, storyID: snapshot.storyID,
            title: snapshot.story.title, publisherName: snapshot.story.publisherName)
        currentPodcastEpisodeID = nil
        selectedArticleID = nil
        isPodcastPlayback = false
        isLarderQueuePlayback = false
        isNowPlaying = true
        isPlaying = false
        if snapshot.status == .selected { _ = await setListenNextStatus(snapshot, to: .playing) }
        refreshPlaybackReadout()
        return true
    }

    func startStoryAtSavedBoundaryIfEligible(snapshot readySnapshot: LibraryListenNextRequestSnapshot) async {
        guard let playback, playback.completed,
              let anchorID = playback.itemID,
              let store = storyPlaybackLedgerStore(for: readySnapshot) else { return }
        var ledger = store.load()
        guard let boundaryID = ledger.latestBoundaryID,
              let continuation = ledger.latestContinuation,
              ledger.latestContinuation?.anchorID == anchorID,
              ledger.latestHoldEpoch == playback.listenNextHoldEpoch,
              let selected = ledger.selectAtNaturalBoundary(
                boundaryID: boundaryID, continuation: continuation,
                currentHoldEpoch: playback.listenNextHoldEpoch),
              let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready,
              let url = await verifiedStoryURL(snapshot) else {
            try? store.save(ledger)
            return
        }
        _ = await startSelectedMacStory(
            snapshot: snapshot, fileURL: url, selected: selected, ledger: ledger,
            continuation: continuation, holdEpoch: playback.listenNextHoldEpoch,
            canStart: { [weak self, weak playback] in
                guard let self, let playback else { return false }
                return playback.completed && playback.listenNextHoldEpoch == ledger.latestHoldEpoch
            }, store: store)
    }

    func resumeMacContinuation(
        _ continuation: ListenNextContinuation, playback: PlaybackController,
        expectedHoldEpoch: UInt64? = nil
    ) async {
        guard expectedHoldEpoch.map({ $0 == playback.listenNextHoldEpoch }) ?? true,
              !preferences.bool(forKey: Self.listenNextPlaybackHeldKey) else { return }
        if continuation.kind == .macPlaylist {
            resumePlaylistContinuation(continuation)
            return
        }
        for rawID in continuation.remainingEntryIDs {
            guard expectedHoldEpoch.map({ $0 == playback.listenNextHoldEpoch }) ?? true,
                  !preferences.bool(forKey: Self.listenNextPlaybackHeldKey) else { return }
            guard let id = try? ItemID(rawValue: rawID.rawValue),
                  (try? await playback.isEpisodeEligible(id)) == true else { continue }
            do {
                try await playback.playPodcastQueueEpisodeNow(id, startsIf: {
                    expectedHoldEpoch.map({ $0 == playback.listenNextHoldEpoch }) ?? true
                })
                guard playback.itemID == id, playback.liveIsPlaying else { return }
                currentListenNextStory = nil
                currentPodcastEpisodeID = id.rawValue
                selectedArticleID = nil
                isPodcastPlayback = true
                isLarderQueuePlayback = continuation.kind == .macReadyLarder
                isNowPlaying = true
                isPlaying = playback.isPlaying
                refreshPlaybackReadout()
                return
            } catch { continue }
        }
        isNowPlaying = false
        isPodcastPlayback = false
        isLarderQueuePlayback = false
    }

    private func resumePlaylistContinuation(_ continuation: ListenNextContinuation) {
        guard let playlistID = continuation.playlistID,
              playlists.playlists.contains(where: { $0.id == playlistID }) else { return }
        for (offset, rawID) in continuation.remainingEntryIDs.enumerated() {
            guard canPlayPlaylistItemByID(rawID) else { continue }
            let savedIndex = continuation.nextIndex + offset
            playlists.session = WiltedMacPlaylistSession(
                playlistID: playlistID,
                entryIDs: continuation.entryIDs.map(\.rawValue), index: savedIndex)
            startPlaylistEntry(at: savedIndex)
            return
        }
    }

    private func canPlayPlaylistItemByID(_ itemID: ItemID) -> Bool {
        guard let item = (episodes.map(WiltedMacLibraryItem.init(episode:)) + articles.map(WiltedMacLibraryItem.article))
            .first(where: { $0.id == itemID.rawValue }) else { return false }
        return canPlayPlaylistItem(item)
    }

    func startSelectedMacStory(
        snapshot: LibraryListenNextRequestSnapshot, fileURL: URL,
        selected: ListenNextPlaybackLedger.Entry, ledger source: ListenNextPlaybackLedger,
        continuation: ListenNextContinuation, holdEpoch: UInt64,
        canStart: @escaping @MainActor () -> Bool,
        store: ListenNextPlaybackLedgerStore
    ) async -> Bool {
        guard let playback, canStart(),
              let revision = audioRevision(for: snapshot),
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return false }
        var ledger = source
        ledger.markStarting(requestID: selected.requestID)
        do { try store.save(ledger) } catch { return false }
        guard let selectedSnapshot = await setListenNextStatus(snapshot, to: .selected) else {
            await returnAbandonedMacStoryStartToQueue(
                snapshot: nil, requestID: selected.requestID, store: store, restorePodcast: false)
            return false
        }
        guard canStart(), playback.listenNextHoldEpoch == holdEpoch else {
            await returnAbandonedMacStoryStartToQueue(
                snapshot: selectedSnapshot, requestID: selected.requestID, store: store, restorePodcast: false)
            return false
        }
        guard let verifiedURL = await verifiedStoryURL(selectedSnapshot),
              verifiedURL.standardizedFileURL == fileURL.standardizedFileURL else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            _ = await setListenNextStatus(selectedSnapshot, to: .failed)
            return false
        }
        guard canStart(), playback.listenNextHoldEpoch == holdEpoch else {
            await returnAbandonedMacStoryStartToQueue(
                snapshot: selectedSnapshot, requestID: selected.requestID, store: store, restorePodcast: false)
            return false
        }
        do {
            try await playback.loadListenNextStory(
                requestID: selected.requestID, revision: revision, mediaURL: verifiedURL,
                positionSeconds: selected.positionSeconds)
        } catch {
            if !canStart() || playback.listenNextHoldEpoch != holdEpoch {
                await returnAbandonedMacStoryStartToQueue(
                    snapshot: selectedSnapshot, requestID: selected.requestID, store: store, restorePodcast: true)
                return false
            }
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            _ = await setListenNextStatus(selectedSnapshot, to: .failed)
            return false
        }
        guard canStart(), playback.listenNextHoldEpoch == holdEpoch else {
            await returnAbandonedMacStoryStartToQueue(
                snapshot: selectedSnapshot, requestID: selected.requestID, store: store, restorePodcast: true)
            return false
        }
        currentListenNextStory = WiltedMacListenNextNowPlaying(
            requestID: snapshot.requestID, storyID: snapshot.storyID,
            title: snapshot.story.title, publisherName: snapshot.story.publisherName)
        currentPodcastEpisodeID = nil
        selectedArticleID = nil
        isPodcastPlayback = false
        isLarderQueuePlayback = false
        isNowPlaying = true
        refreshPlaybackReadout(shouldPublishNowPlaying: false)
        do { _ = try playback.startListenNextStory() }
        catch {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            _ = await setListenNextStatus(selectedSnapshot, to: .failed)
            currentListenNextStory = nil
            await playback.restorePodcastQueue(afterListenNextRequest: selected.requestID)
            return false
        }
        ledger.markPlaying(requestID: selected.requestID, positionSeconds: selected.positionSeconds)
        do { try store.save(ledger) } catch { return false }
        _ = await setListenNextStatus(selectedSnapshot, to: .playing)
        isPlaying = playback.isPlaying
        refreshPlaybackReadout()
        publishNowPlaying(force: true)
        return true
    }

    private func returnAbandonedMacStoryStartToQueue(
        snapshot suppliedSnapshot: LibraryListenNextRequestSnapshot?, requestID: String,
        store: ListenNextPlaybackLedgerStore, restorePodcast: Bool
    ) async {
        let currentSnapshot: LibraryListenNextRequestSnapshot?
        if let suppliedSnapshot {
            currentSnapshot = suppliedSnapshot
        } else {
            currentSnapshot = (await listenNextSnapshots()).first(where: { $0.requestID == requestID })
        }
        guard let currentSnapshot else { return }
        let readySnapshot: LibraryListenNextRequestSnapshot?
        if currentSnapshot.status == .selected {
            readySnapshot = await setListenNextStatus(currentSnapshot, to: .ready)
        } else {
            readySnapshot = currentSnapshot.status == .ready ? currentSnapshot : nil
        }
        guard readySnapshot?.status == .ready else { return }
        var ledger = store.load()
        ledger.returnAbandonedStartToReady(requestID: requestID)
        try? store.save(ledger)
        if restorePodcast, let playback {
            await playback.restorePodcastQueue(afterListenNextRequest: requestID)
        }
    }

}
