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
    func freshenStartRecords(for rawID: ItemID) async {
        let entries = Set(episodeGroup(rawID)?.memberIDs ?? [rawID])
        let transport = transport, limit = handoffTiming.startRecordsWait
        await tellTransportKnownPeers(writer: lastObservedPublication?.writerDeviceID)
        let generation = await transport.operationGeneration()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = StartRecordsWait(continuation)
            Task { @MainActor [weak self] in
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
