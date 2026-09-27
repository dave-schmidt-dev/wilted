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
    func explicitPositionChange(intent: PlaybackIntent, position: Double) async {
        guard let itemID = selectedItemID, let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let current = playbackByItem[itemID],
              let playback else { return }
        await positionChange(item: item, asset: asset, playback: playback, current: current,
                             position: position, intent: intent, newSession: true)
        _ = revision
    }

    func positionChange(item: ListenerLibraryItem, asset: WiltedAsset,
                                playback: ListenerPlaybackController, current: PlaybackState,
                                position: Double, intent: PlaybackIntent, newSession: Bool) async {
        if playbackPhase == .paused {
            do {
                if let updated = try await playback.seek(
                    position: position,
                    intent: intent,
                    newSession: newSession
                ) {
                    try await recordPlayback(updated)
                    selectedPlayback = updated
                }
                playbackPhase = .paused
            } catch {
                playbackRetryOperation = .seek(position)
                playbackPhase = .failed("Playback command failed: \(error.localizedDescription)", retryable: true)
            }
            return
        }
        playbackPhase = .refreshing("Preparing offline audio")
        do {
            let updated = try await playback.play(asset: asset, title: item.title,
                                                  state: try nextPlayback(current, position: position,
                                                                           intent: intent, newSession: newSession))
            try await recordPlayback(updated)
            selectedPlayback = updated
            playbackPhase = .playing
        } catch {
            playbackRetryOperation = .seek(position)
            playbackPhase = .failed("Playback command failed: \(error.localizedDescription)", retryable: true)
        }
    }

    private func nextPlayback(_ current: PlaybackState, position: Double, intent: PlaybackIntent, newSession: Bool) throws -> PlaybackState {
        let resolvedIntent = newSession ? intent : (current.intent != .progress ? current.intent : intent)
        return try PlaybackState(itemID: current.itemID, revisionID: current.revisionID,
                                 sessionID: newSession ? UUID().uuidString : current.sessionID,
                                 sequence: newSession ? 1 : current.sequence + 1,
                                 positionSeconds: max(0, position), durationSeconds: current.durationSeconds,
                                 completed: false, intent: resolvedIntent, deviceID: current.deviceID,
                                 encodedCloudKitRecordSystemFields: current.encodedCloudKitRecordSystemFields,
                                 updatedAt: Timestamp(Date()))
    }

    func recordPlayback(_ state: PlaybackState) async throws {
        // Keep the local playback projection current even when a deliberately
        // account-free composition has no sync repository. Production still
        // enqueues the same durable change immediately below.
        playbackByItem[state.itemID] = state
        guard let repository else { return }
        let sidecar = WiltedOpaqueSidecar(
            changeTag: playbackChangeTagByItem[state.itemID],
            encodedSystemFields: state.encodedCloudKitRecordSystemFields
        )
        let envelope = try WiltedRecordCodec().encode(playback: state, sidecar: sidecar)
        let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
        try await repository.enqueue(change)
        try await metadataSaver?(ListenerMetadata(lastPlayedRecordID: envelope.id, lastPositionSeconds: state.positionSeconds))
    }

    func scheduleBackgroundCheckpoints(generation: UInt64) {
        let interval = backgroundCheckpointInterval
        let sleeper = backgroundSleeper
        backgroundCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleeper(interval) }
                catch { return }
                guard let self, self.isBackgrounded,
                      self.backgroundCheckpointGeneration == generation,
                      !Task.isCancelled else { return }
                guard await self.persistBoundedBackgroundCheckpoint(generation: generation) else {
                    if self.backgroundCheckpointGeneration == generation {
                        self.backgroundCheckpointTask = nil
                    }
                    return
                }
            }
        }
    }

    private func persistBoundedBackgroundCheckpoint(generation: UInt64) async -> Bool {
        guard isBackgrounded, backgroundCheckpointGeneration == generation,
              let playback else { return false }
        do {
            guard let updated = try await playback.liveCheckpoint() else { return false }
            guard isBackgrounded, backgroundCheckpointGeneration == generation,
                  !Task.isCancelled else { return false }
            try await recordPlayback(updated)
            if selectedItemID == updated.itemID { selectedPlayback = updated }
            return true
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
            return false
        }
    }

    func persistActivePlaybackCheckpoint() async {
        guard let playback else { return }
        do {
            if let readout = try await playback.liveReadout(),
               let persisted = playbackByItem[readout.itemID],
               persisted.revisionID == readout.revisionID,
               persisted.sessionID == readout.sessionID,
               persisted.positionSeconds == readout.positionSeconds,
               persisted.completed == readout.completed {
                return
            }
            guard let updated = try await playback.liveCheckpoint() else { return }
            try await recordPlayback(updated)
            if selectedItemID == updated.itemID { selectedPlayback = updated }
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
        }
    }

    func updateItemState(itemID: ItemID, state: ListenerItemState) {
        guard let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        let item = items[index]
        items[index] = ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                           revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                           asset: item.asset, state: state)
    }

}
