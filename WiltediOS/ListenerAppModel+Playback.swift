import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

extension WiltedListenerAppModel {
    public func download(itemID: ItemID) async {
        syncRetryOperation = nil
        guard !accountQuarantined else { return }
        guard let cache,
              let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID] else { return }
        guard item.state == .metadataOnly else { return }
        guard let operation = beginOperation() else {
            if downloadingItemID == itemID {
                downloadRequestFeedback = "Download already in progress."
            }
            return
        }
        downloadingItemID = itemID
        downloadRequestFeedback = nil
        defer {
            if downloadingItemID == itemID {
                downloadingItemID = nil
                downloadRequestFeedback = nil
            }
            finishOperation(operation)
        }
        syncPhase = .refreshing("Downloading \(item.title)…")
        do {
            if let manifest = manifestByItem[itemID] {
                guard let audioChunkLoader else {
                    throw ListenerError.cacheUnavailable(asset.assetID)
                }
                let data = try await audioChunkLoader(itemID, revision.revisionID, manifest)
                guard isCurrent(operation) else { return }
                _ = try await cache.store(data: data, asset: asset)
            } else {
                guard let assetLoader else {
                    throw ListenerError.cacheUnavailable(asset.assetID)
                }
                let recordID = try WiltedRecordID.revision(itemID, revision.revisionID)
                let sourceURL = try await assetLoader(recordID, asset)
                guard isCurrent(operation) else { return }
                _ = try await cache.store(fileURL: sourceURL, asset: asset)
            }
            guard isCurrent(operation) else { return }
            updateItemState(itemID: itemID, state: .downloaded)
            await refreshDownloadStatistics()
            syncPhase = .ready
        } catch {
            guard isCurrent(operation) else { return }
            syncRetryOperation = .download(itemID)
            syncPhase = .failed("Download failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func removeDownload(itemID: ItemID) async {
        guard !accountQuarantined,
              let cache, assetByItem[itemID] != nil,
              items.contains(where: { $0.itemID == itemID }) else { return }
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        if selectedItemID == itemID { await pause() }
        guard isCurrent(operation), !accountQuarantined else { return }
        let retainedAssets = assetByItem.compactMap { $0.key == itemID ? nil : $0.value }
        await cache.reconcile(retaining: retainedAssets)
        guard isCurrent(operation), !accountQuarantined else { return }
        await updateDownloadedStates()
        guard isCurrent(operation), !accountQuarantined else { return }
        syncPhase = .ready
    }

    public func play(itemID: ItemID) async {
        playbackRetryOperation = nil
        guard let item = items.first(where: { $0.itemID == itemID }) else { return }
        guard item.state == .downloaded, let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let playback else {
            playbackPhase = item.state == .incompatibleRevision
                ? .incompatible("This item cannot play with its current revision")
                : .offline("Audio is not cached for offline playback")
            return
        }
        let state: PlaybackState
        if let existing = playbackByItem[itemID], existing.revisionID == revision.revisionID {
            state = existing
        } else if let initial = makeInitialPlayback(for: item, revision: revision) {
            state = initial
        } else {
            playbackPhase = .failed("Playback state could not be created", retryable: false)
            return
        }
        playbackPhase = .refreshing("Preparing offline audio")
        do {
            if selectedItemID != nil, selectedItemID != itemID,
               let outgoing = try await playback.liveCheckpoint() {
                try await recordPlayback(outgoing)
                selectedPlayback = outgoing
            }
            let updated = try await playback.play(asset: asset, title: item.title, state: state)
            try await recordPlayback(updated)
            selectedItemID = itemID
            selectedPlayback = updated
            playbackPhase = .playing
        } catch {
            playbackRetryOperation = .play(itemID)
            playbackPhase = .failed("Playback failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func pause() async {
        playbackRetryOperation = nil
        guard let playback else { return }
        do {
            if let updated = try await playback.pause() {
                try await recordPlayback(updated)
                selectedPlayback = updated
            }
            playbackPhase = .paused
        } catch {
            playbackRetryOperation = .pause
            playbackPhase = .failed("Pause failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func seek(to position: Double) async {
        playbackRetryOperation = nil
        guard let itemID = selectedItemID, let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let current = playbackByItem[itemID],
              let playback else { return }
        let bounded = max(0, min(position, revision.durationSeconds))
        await positionChange(item: item, asset: asset, playback: playback, current: current,
                             position: bounded, intent: bounded < current.positionSeconds ? .rewind : .progress,
                             newSession: bounded < current.positionSeconds)
    }

    public func seekForward(by seconds: Double = 30) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        await seek(to: (selectedPlayback?.positionSeconds ?? 0) + seconds)
    }

    public func seekBackward(by seconds: Double = 15) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        await seek(to: max(0, (selectedPlayback?.positionSeconds ?? 0) - seconds))
    }

    public func rewind() async {
        await explicitPositionChange(intent: .rewind, position: max(0, (selectedPlayback?.positionSeconds ?? 0) - 15))
    }

    public func restart() async {
        await explicitPositionChange(intent: .restart, position: 0)
    }

    public func enterBackground() async {
        isBackgrounded = true
        backgroundCheckpointGeneration &+= 1
        let generation = backgroundCheckpointGeneration
        backgroundCheckpointTask?.cancel()
        guard let playback else {
            return
        }
        do {
            if let updated = try await playback.enterBackground() {
                guard isBackgrounded, backgroundCheckpointGeneration == generation else { return }
                try await recordPlayback(updated)
                guard isBackgrounded, backgroundCheckpointGeneration == generation else { return }
                selectedPlayback = updated
                scheduleBackgroundCheckpoints(generation: generation)
            }
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
        }
    }

    /// Refreshes the displayed position from the active engine without queuing a sync write.
    public func refreshNowPlayingReadout() async {
        guard case .playing = playbackPhase, let playback else { return }
        do {
            guard let readout = try await playback.liveReadout() else { return }
            playbackByItem[readout.itemID] = readout
            selectedPlayback = readout
        } catch {
            playbackPhase = .failed("Playback readout failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func resumeForeground() async {
        let shouldPersistActivePosition = isBackgrounded
        isBackgrounded = false
        backgroundCheckpointGeneration &+= 1
        let cancelledCheckpointTask = backgroundCheckpointTask
        cancelledCheckpointTask?.cancel()
        backgroundCheckpointTask = nil
        await cancelledCheckpointTask?.value
        if shouldPersistActivePosition { await persistActivePlaybackCheckpoint() }
        // Scene activation can race the view's initial task. Treat the first
        // foreground as launch so that pair produces one catalog fetch.
        if !didStart { await start() } else { await refresh() }
    }

    public func cancel() {
        invalidateCurrentOperation()
        syncRetryOperation = nil
        playbackRetryOperation = nil
        syncPhase = .idle
        Task { await session?.cancel() }
    }

    /// Repeats the sync operation that produced the visible retryable failure.
    /// A failed download or send must not turn into a catalog refresh.
    public func retrySyncOperation() async {
        guard case .failed(_, retryable: true) = syncPhase, let operation = syncRetryOperation else { return }
        switch operation {
        case .refresh: await refresh()
        case .send: await sendPending()
        case let .download(itemID): await download(itemID: itemID)
        }
    }

    /// Repeats the playback command that produced the visible retryable failure.
    public func retryPlaybackOperation() async {
        guard case .failed(_, retryable: true) = playbackPhase, let operation = playbackRetryOperation else { return }
        switch operation {
        case let .play(itemID): await play(itemID: itemID)
        case .pause: await pause()
        case let .seek(position): await seek(to: position)
        }
    }

}
