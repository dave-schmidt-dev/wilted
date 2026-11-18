import Foundation
import WiltedDomain
import WiltedLibrary

/// One wait that the first of several finishers ends.
@MainActor
private final class StartRecordsWait {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func end() {
        continuation?.resume()
        continuation = nil
    }
}

extension LibraryAppModel {
    /// Where the loaded, paused episode should resume because another device played it on after the
    /// phone paused: that device's position, or nil to resume in place. Without this a play on the
    /// phone resumed at the phone's old pause, and its takeover then handed that older place back to
    /// the Mac (2026-11-18).
    ///
    /// The phone moves only when all of this holds, so a pause it made itself is never rewound by an
    /// older record: the other device's record is for the same audio revision and carries a higher
    /// epoch than the phone's own (that device took the episode over; a stored position it merely
    /// offers again carries the epoch already in use, and can postdate a pause the phone could not
    /// publish), it was written after the phone last set its paused position (the pause, or a seek
    /// made while paused), and it is more than `seekThreshold` away. A paused position younger than
    /// `handoffTiming.resumeReadAfterPause` is resumed at once, with no read. Otherwise the read
    /// waits `handoffTiming.resumeRecordsWait` at most, and a failed or slow read resumes in place.
    func resumePositionFromOtherDevice(_ rawID: ItemID) async -> Double? {
        guard let player = handoffState.player, player.item?.entryID == rawID, player.status == .paused,
              let setAt = player.pausedPositionSetAt,
              now().timeIntervalSince(setAt) >= handoffTiming.resumeReadAfterPause else { return nil }
        await freshenStartRecords(for: rawID, limit: handoffTiming.resumeRecordsWait)
        // Re-read after the wait: a pause, a seek or another item since then is the listener's newer word.
        guard player.item?.entryID == rawID, player.status == .paused, player.pausedPositionSetAt == setAt,
              let other = checkpoints[rawID], let own = handoffState.ownPositions[rawID],
              other.record.revision == own.record.revision, other.record.epoch > own.record.epoch,
              other.serverModifiedAt.addingTimeInterval(-handoffState.clockOffset) > setAt,
              let target = LibraryRowBuilder.resumeSeconds(other, duration: entryDurations[rawID]),
              abs(target - player.position) > Self.seekThreshold else { return nil }
        return target
    }

    /// Tells the transport which other devices exist and which episodes this phone holds their
    /// positions for, from what is saved on the phone: the Mac named by the library's publication and
    /// the saved checkpoints. The transport learns devices only from records it fetches, so a phone
    /// opened in a new process while the Mac was idle read nothing from it, and the round then
    /// replaced the saved positions with that nothing (2026-11-18). Local bookkeeping, no request.
    ///
    /// Only queued episodes are named: they are the ones the phone can play, and a new process
    /// reads every named pair once. A start reads its own episode whether named here or not.
    func tellTransportKnownPeers(writer: String?) async {
        let saved = handoffState.savedCheckpoints
        let devices = Set(saved.values.map(\.record.deviceID)).union([writer].compactMap { $0 }).subtracting([deviceID])
        guard !devices.isEmpty else { return }
        let queued = Set(decisionContent.queue.map(\.entryID).flatMap { episodeGroup($0)?.memberIDs ?? [$0] })
        let entries = saved.keys.filter(queued.contains).sorted { $0.rawValue < $1.rawValue }
        await transport.track(devices: devices.sorted(), entries: entries)
    }

    /// Reads the playback records of the episode about to start and lays them over what the phone
    /// last synced, so the start is where every device holds the episode now. An idle phone syncs
    /// every `SyncCadence.phoneIdleInterval`, and a row pressed right after the app opens is ahead of
    /// the first round: such a start used the older records, or none, and an episode paused on the
    /// Mac began from the start (2026-11-18). The takeover that follows then publishes from the
    /// right place, so the Mac is not handed a position near zero either.
    ///
    /// Returns after `handoffTiming.startRecordsWait` at the latest, and at once when the read fails
    /// (no signal, a throttled request): the start then goes ahead on what the phone knows. An answer
    /// that comes later is still kept. One request for the episode's own records, not a sync round.
    /// Every call on the transport runs inside the timed wait, so none can hold a start past it.
    func freshenStartRecords(for rawID: ItemID, limit: Duration? = nil) async {
        let entries = Set(episodeGroup(rawID)?.memberIDs ?? [rawID])
        let transport = transport, limit = limit ?? handoffTiming.startRecordsWait
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = StartRecordsWait(continuation)
            Task { @MainActor [weak self] in
                await self?.tellTransportKnownPeers(writer: self?.lastObservedPublication?.writerDeviceID)
                let generation = await transport.operationGeneration()
                if let records = try? await transport.fetchDeviceRecords(entries: entries), let self,
                   await transport.operationGeneration() == generation, !self.accountQuarantined {
                    self.adoptFresherCheckpoints(from: records, for: entries)
                }
                wait.end()
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                wait.end()
            }
        }
    }
}
