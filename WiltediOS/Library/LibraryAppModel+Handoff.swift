import Combine
import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let handoffLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryHandoff")

/// What "Continue from Mac" would do, decided from the device records and what the phone caches.
enum LibraryContinuation: Equatable, Sendable {
    /// The same revision is on the phone: play it at `positionSeconds`.
    case ready(entryID: ItemID, positionSeconds: Double, rate: Double, wasPlaying: Bool, sourceDeviceID: String)
    /// Nothing is cached for the entry: request the audio first, then continue.
    case needsAudio(entryID: ItemID, revision: RevisionID)
    /// The phone holds a different revision than the other device plays; continuing would resume the wrong audio.
    case refused(entryID: ItemID, reason: String)

    var entryID: ItemID {
        switch self {
        case let .ready(entryID, _, _, _, _), let .needsAudio(entryID, _), let .refused(entryID, _): entryID
        }
    }
}

/// Pure decision for the Continue banner. No I/O, so it is testable without a player.
enum LibraryContinuationPlanner {
    static let mismatchReason = "This phone has a different version of the episode than the Mac is playing. "
        + "Remove it from the phone, then get the Mac's version."

    /// Nil when no other device has playback, or this device's own record already outranks it
    /// (the phone was the last to play, so the Mac's older checkpoint is not something to continue).
    static func plan(
        records: LibraryDeviceRecords, deviceID: String, cachedRevisions: [ItemID: RevisionID],
        durations: [ItemID: Double], now: Date, clockOffset: TimeInterval
    ) -> LibraryContinuation? {
        let own = records.nowPlaying.first { $0.record.deviceID == deviceID }
        let others = records.nowPlaying.filter { $0.record.deviceID != deviceID }
        guard let winner = HandoffResolver.winner(among: others) else { return nil }
        if let own, !HandoffResolver.supersedes(winner, over: own) { return nil }
        let target = HandoffResolver.resumeTarget(
            observed: records.nowPlaying, localDeviceID: deviceID, localRevision: { cachedRevisions[$0] },
            now: now, clockOffset: clockOffset, durationSeconds: { durations[$0] })
        switch target {
        case .nothing:
            return nil
        case let .resume(resume):
            return .ready(
                entryID: resume.entryID, positionSeconds: resume.positionSeconds, rate: resume.rate,
                wasPlaying: resume.wasPlaying, sourceDeviceID: resume.sourceDeviceID)
        case let .needsMedia(entryID, revision):
            return cachedRevisions[entryID] == nil
                ? .needsAudio(entryID: entryID, revision: revision)
                : .refused(entryID: entryID, reason: mismatchReason)
        }
    }
}

/// Waits the phone's sync tick uses. Injected so tests drive the cadence without real time.
struct LibraryHandoffTiming: Sendable {
    /// The tick interval (`SyncCadence.phoneObserveInterval`, 30 s): the gap between rounds that look at
    /// the other devices and publish the playing checkpoint. Peers treat a device as dead after
    /// `SyncCadence.staleAfter`, so a Mac takeover pauses the phone within about 30 s.
    var observeInterval: TimeInterval = SyncCadence.phoneObserveInterval
    /// Waits `observeInterval` between rounds.
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// The coordinator's settle wait; the phone no longer makes a confirming fetch after a takeover, the next round decides.
    var settleSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

/// Mutable handoff bookkeeping. A class so the model's extension can keep state without stored
/// properties of its own; everything here is touched only on the main actor.
@MainActor
final class LibraryHandoffState {
    var player: LibraryPlayer?
    var subscriptions = Set<AnyCancellable>()
    /// The last queued player-change task; each new one waits for it, so coordinator calls stay in order.
    var chain: Task<Void, Never>?
    var syncQueued = false
    /// True between a successful takeover and the next pause, stop or relinquish.
    var reportedPlaying = false
    var reportedEntry: ItemID?
    /// The entry the coordinator's session belongs to; only a successful takeover sets it. Whether
    /// the session still exists is the coordinator's `epoch`, not this.
    var sessionEntry: ItemID?
    /// The entry the player held at the previous sync, so a change of item is not read as a seek.
    var lastItemEntry: ItemID?
    var lastPosition: Double = 0
    var lastPositionAt: Date?
    /// When a takeover last failed; nil after a success. Failed attempts repeat at the observe interval.
    var lastTakeoverFailure: Date?
    /// This phone's own last position per entry (progress records), so Play resumes where the phone
    /// left off when nothing newer came from another device. Refreshed from every device-record fetch.
    var ownPositions: [ItemID: ObservedPlayback] = [:] {
        didSet { persistOwnPositions() }
    }
    /// Persists `ownPositions` so a launch with no network still resumes where the phone left off.
    var ownPositionStore = LibraryOwnPositionStore(url: nil)
    /// The other devices' newest records as last fetched, persisted for a cold offline start.
    var savedCheckpoints: [ItemID: ObservedPlayback] = [:] {
        didSet { persistOwnPositions() }
    }

    func persistOwnPositions() {
        ownPositionStore.save(.init(positions: ownPositions, unpublished: unpublished, checkpoints: savedCheckpoints))
    }
    /// Positions this phone saved but could not publish (offline, a failed write), by entry. The
    /// Mac adopts the phone's position only from a published record, so each is republished on the
    /// next sync, and meanwhile stays this phone's own position for Play.
    var unpublished: [ItemID: (position: Double, savedAt: Date)] = [:] {
        didSet { persistOwnPositions() }
    }
    /// Server clock minus this phone's clock, learned from this device's own record.
    var clockOffset: TimeInterval = 0
    /// The playing position last written to the phone's own store, so the next write waits for
    /// `LibraryAppModel.localSaveInterval` of listening.
    /// nil after the loaded item changes: the first position of an episode is the baseline, not a save.
    var lastLocalSave: Double?
    /// A newer save supersedes only an older save for the same episode.
    var localSaveTokens: [ItemID: UInt64] = [:]
    var refusedRevisions: [ItemID: RevisionID] = [:]
    var continueInFlight = false
    /// Completed observations; lets tests wait for a cycle.
    var observeCycles = 0
    /// Stable forward sequence captured at manual start to prevent autoContinue from wrapping backwards.
    var forwardSequenceIDs: [ItemID] = []
}

/// Lets the transport gate, built before the model exists, report to it afterwards.
@MainActor
final class LibraryThrottleRelay {
    weak var model: LibraryAppModel?
}

extension LibraryAppModel {
    /// A position change larger than this from what elapsed time predicts counts as a seek.
    static let seekThreshold: Double = 2
    /// Seconds of listening between writes of the playing position to the phone's own store.
    static let localSaveInterval: Double = 10

    // MARK: - Player wiring

    /// Starts driving the coordinator from `player`. Lock-screen and headset commands go to the
    /// player directly, so its published state is the source of truth, not the buttons.
    func attachPlayer(_ player: LibraryPlayer) {
        guard handoffState.player !== player else { return }
        player.onListened = { [phoneStats] wall, rate in phoneStats.recordListening(wall: wall, rate: rate) }
        player.onFinished = { [weak self] ended, autoPlayNext in
            Task { @MainActor [weak self] in await self?.episodeFinished(ended, autoPlayNext: autoPlayNext) }
        }
        handoffState.subscriptions.removeAll()
        handoffState.player = player
        // `@Published` emits on the thread that mutates it, which is always the main actor here.
        player.$status.removeDuplicates().sink { [weak self] status in
            // The status is already visible on the player when its own subscribers run on the next turn.
            MainActor.assumeIsolated {
                // Before anything queues behind the network: a pause is when the car drops the phone.
                if status == .paused { self?.saveLoadedPositionLocally() }
                self?.enqueueHandoffSync()
                Task { @MainActor [weak self] in self?.refreshProgress() }
            }
        }.store(in: &handoffState.subscriptions)
        player.$position.sink { [weak self] position in
            MainActor.assumeIsolated {
                if let state = self?.handoffState {
                    if let last = state.lastLocalSave {
                        if player.status == .playing, abs(position - last) >= Self.localSaveInterval {
                            self?.saveLoadedPositionLocally(position)
                        }
                    } else {
                        state.lastLocalSave = position
                    }
                }
                self?.enqueueHandoffSync()
            }
        }.store(in: &handoffState.subscriptions)
        // Any transport command given meanwhile (lock screen, headset, a seek) replaces a pending start.
        player.onCommand = { [weak self] in self?.playerCommandArrived() }
        player.$item.sink { [weak self] item in
            // `@Published` emits before the value changes, so hand the new item over rather than re-reading it.
            MainActor.assumeIsolated {
                self?.handoffState.lastLocalSave = nil
                self?.refreshProgress(playingEntry: item?.entryID)
                self?.enqueueHandoffSync()
            }
        }.store(in: &handoffState.subscriptions)
    }

    /// Waits until every queued coordinator call has finished. For tests.
    func waitForHandoff() async { await handoffState.chain?.value }

    /// Where `entryID` should start: the newest same-revision position, else the start.
    func resumeStart(for entryID: ItemID, cachedRevision: RevisionID) -> Double {
        let candidates = [checkpoints[entryID], handoffState.ownPositions[entryID]]
            .compactMap { $0 }.filter { $0.record.revision == cachedRevision }
        return LibraryRowBuilder.resumeSeconds(
            HandoffResolver.winner(among: candidates), duration: entryDurations[entryID]) ?? 0
    }

    /// The app moved to the background: publish the current position now, since the next
    /// cadence tick may be a long way off.
    func sceneEnteredBackground() async {
        saveLoadedPositionLocally()
        await sceneBecameBackground()
        await republishUnpublishedPositions()
        guard handoffState.reportedPlaying, let player = handoffState.player else { return }
        await runOnHandoffChain { [weak self] in
            guard let self, self.handoffState.reportedPlaying else { return }
            self.handoffState.lastPosition = player.position
            self.handoffState.lastPositionAt = self.now()
            try? await self.coordinator.seeked(to: player.position)
        }
    }

    // MARK: - Event chain

    private func enqueueHandoffSync() {
        guard !handoffState.syncQueued else { return }
        handoffState.syncQueued = true
        let previous = handoffState.chain
        handoffState.chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.handoffState.syncQueued = false
            await self.syncHandoff()
        }
    }

    /// Runs `work` after everything already queued and returns when it is done.
    private func runOnHandoffChain(_ work: @escaping @MainActor () async -> Void) async {
        let previous = handoffState.chain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        handoffState.chain = task
        await task.value
    }

    /// Reads the settled player state and tells the coordinator what changed since last time.
    private func syncHandoff() async {
        guard let player = handoffState.player else { return }
        let state = handoffState
        let (status, position, item) = (player.status, player.position, player.item)
        let clock = now()
        defer { state.lastPosition = position; state.lastPositionAt = clock; state.lastItemEntry = item?.entryID }
        if status == .playing, let item {
            if !state.reportedPlaying || state.reportedEntry != item.entryID {
                await beginPlayback(item, position: position, rate: player.rate, at: clock)
                // A listen with no session (offline, a failed takeover) is published on the next sync.
                if !state.reportedPlaying {
                    state.unpublished[item.entryID] = (position, clock)
                    await rememberOwnPosition(item.entryID, position: position)
                }
            } else if hasJumped(to: position, rate: player.rate, at: clock) {
                try? await coordinator.seeked(to: position)
                refreshProgress()
            }
            // Otherwise the position is only noted locally: the sync round publishes the checkpoint.
        } else if state.reportedPlaying {
            state.reportedPlaying = false
            let entryID = item?.entryID ?? state.reportedEntry
            let paused = item == nil ? state.lastPosition : position
            var published = true
            do {
                if item == nil { try await coordinator.stopped(at: paused) } else { try await coordinator.paused(at: paused) }
            } catch {
                published = false
                handoffLog.error("Could not publish the pause: \(String(describing: error), privacy: .public)")
            }
            if let entryID {
                await rememberOwnPosition(entryID, position: paused)
                if !published { state.unpublished[entryID] = (paused, clock) } else { state.unpublished[entryID] = nil }
            }
            await updateSyncTick()
        } else if let item, state.lastItemEntry == item.entryID, abs(position - state.lastPosition) > 0.01 {
            // The coordinator's session speaks for a seek only while it is this entry's, still exists
            // and has not been outranked by another device's epoch since (a Mac takeover): its
            // records publish at its own epoch. Anything else is a stored position, which takes
            // the entry's highest epoch and needs no session.
            var published = false
            if state.sessionEntry == item.entryID, let epoch = await coordinator.epoch,
               epoch >= (checkpoints[item.entryID]?.record.epoch ?? 0) {
                do { try await coordinator.seeked(to: position); published = true } catch {}
            }
            if !published {
                state.unpublished[item.entryID] = (position, clock)
                await rememberOwnPosition(item.entryID, position: position)
                await republishUnpublishedPositions()
            }
            refreshProgress()
        }
    }

    /// Writes the loaded episode's position to the phone's own store now, outside the handoff event
    /// chain. The chain waits on the network (a pause publish, or an earlier call that is still
    /// hanging in a car park), and a locked, backgrounded phone is suspended before it gets there:
    /// the next launch then resumed from the last record the server held, usually the start. The
    /// position is also marked unpublished, so a fetch cannot replace it with an older server copy
    /// and the next sync publishes it.
    /// Returns the queued save so callers can wait for local persistence.
    @discardableResult
    func saveLoadedPositionLocally(_ position: Double? = nil) -> Task<Void, Never>? {
        guard let player = handoffState.player, let entryID = player.item?.entryID else { return nil }
        let position = position ?? player.position
        let token = (handoffState.localSaveTokens[entryID] ?? 0) &+ 1
        handoffState.localSaveTokens[entryID] = token
        handoffState.lastLocalSave = position
        return Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rememberOwnPosition(entryID, position: position, unless: { self.handoffState.localSaveTokens[entryID] != token })
            guard self.handoffState.localSaveTokens[entryID] == token, self.handoffState.ownPositions[entryID] != nil else { return }
            self.handoffState.unpublished[entryID] = (position, self.now())
        }
    }

    /// Keeps this phone's own last position current between device-record fetches, so returning to
    /// an episode after playing another one resumes here rather than at an older record. `stale`
    /// is asked again after the lookups, so a write that a newer one overtook is dropped.
    func rememberOwnPosition(_ entryID: ItemID, position: Double, unless stale: () -> Bool = { false }) async {
        // The highest epoch this phone knows for the entry, so its own position outranks an older
        // Mac record when the phone resumes offline.
        let epoch = max(await coordinator.epoch ?? 0, checkpoints[entryID]?.record.epoch ?? 0)
        guard let revision = await mediaCache.cachedEntries()[entryID]?.revisionID, !stale(),
              let record = try? DevicePlaybackPosition(
                  deviceID: deviceID, entryID: entryID, revision: revision, positionSeconds: max(0, position),
                  isPlaying: false, epoch: epoch, publishedAt: now()) else { return }
        handoffState.ownPositions[entryID] = ObservedPlayback(
            record: record, serverModifiedAt: now().addingTimeInterval(handoffState.clockOffset))
        refreshProgress()
    }

    /// Publishes positions saved while a write failed, as paused Progress records. Anything the
    /// coordinator declines (another device is playing the entry or saved it later) is settled
    /// too; a failed write keeps them for the next sync.
    func republishUnpublishedPositions() async {
        let state = handoffState
        guard !state.unpublished.isEmpty else { return }
        let cached = await mediaCache.cachedEntries()
        let pending = state.unpublished
        do {
            // Stored positions, not the session: they publish at the entry's highest epoch (a Mac
            // takeover since the session began has outranked the session's own) and need no session.
            var stored: [HandoffCoordinator.StoredPosition] = []
            for (entryID, saved) in pending {
                // An entry playing right now is left to its takeover, which clears the record.
                if state.player?.isPlaying == true, state.player?.item?.entryID == entryID { continue }
                if let revision = cached[entryID]?.revisionID {
                    stored.append(.init(entryID: entryID, revision: revision, positionSeconds: saved.position, updatedAt: saved.savedAt))
                }
            }
            _ = try await coordinator.publishStoredPositions(stored)
            for (entryID, saved) in pending where state.unpublished[entryID]?.savedAt == saved.savedAt {
                state.unpublished[entryID] = nil
            }
        } catch {
            handoffLog.error("Could not republish positions: \(String(describing: error), privacy: .public)")
        }
    }

    private func hasJumped(to position: Double, rate: Double, at clock: Date) -> Bool {
        guard let last = handoffState.lastPositionAt else { return false }
        let expected = handoffState.lastPosition + max(0, clock.timeIntervalSince(last)) * rate
        return abs(position - expected) > Self.seekThreshold
    }

    /// Takes over playback for the entry that just started. Failing to publish never stops the
    /// audio; the attempt repeats no more often than the observe interval.
    private func beginPlayback(_ item: LibraryPlayer.Item, position: Double, rate: Double, at clock: Date) async {
        let state = handoffState
        if let failed = state.lastTakeoverFailure, clock.timeIntervalSince(failed) < handoffTiming.observeInterval,
           state.reportedEntry == item.entryID { return }
        state.reportedEntry = item.entryID
        guard let revision = await mediaCache.cachedEntries()[item.entryID]?.revisionID else {
            state.lastTakeoverFailure = clock
            handoffLog.error("Playing an entry with no cached revision; handoff not published")
            return
        }
        do {
            let epoch = try await coordinator.takeover(
                entryID: item.entryID, revision: revision, positionSeconds: position, rate: rate)
            state.reportedPlaying = true
            state.lastTakeoverFailure = nil
            state.sessionEntry = item.entryID
            state.unpublished[item.entryID] = nil
            handoffMessage = nil
            handoffLog.info("Took over playback at epoch \(epoch, privacy: .public)")
            await updateSyncTick()
        } catch {
            state.lastTakeoverFailure = clock
            handoffMessage = "Handoff is unavailable: \(Self.text(for: error))"
            handoffLog.error("Takeover failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Relinquishing

    /// Pauses for `winner`, the device that outranks this one, from the round's own `records`.
    func relinquish(to winner: String, records: LibraryDeviceRecords) async {
        await runOnHandoffChain { [weak self] in
            guard let self, let player = self.handoffState.player, self.handoffState.reportedPlaying else { return }
            let state = self.handoffState
            state.reportedPlaying = false
            player.pause()
            state.lastPosition = player.position
            // The coordinator does not publish a paused record on its own after a loss.
            try? await self.coordinator.paused(at: player.position)
            self.handoffMessage = "Paused because \(winner) started playing."
            handoffLog.info("Relinquished to \(winner, privacy: .public)")
            await self.updateSyncTick()
            await self.updateContinuation(from: records)
        }
    }

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
        let cached = await mediaCache.cachedEntries().mapValues(\.revisionID)
        var plan = LibraryContinuationPlanner.plan(
            records: records, deviceID: deviceID, cachedRevisions: cached, durations: entryDurations,
            now: now(), clockOffset: handoffState.clockOffset)
        if case let .needsAudio(entryID, revision) = plan, handoffState.refusedRevisions[entryID] == revision {
            plan = .refused(entryID: entryID, reason: Self.offerMismatchReason)
        }
        if plan != continuation { continuation = plan }
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
        guard var plan = await freshPlan() else { continuation = nil; return }
        if case let .needsAudio(entryID, revision) = plan {
            guard await fetchAudio(entryID, revision: revision) else { return }
            guard let replanned = await freshPlan() else { continuation = nil; return }
            plan = replanned
        }
        switch plan {
        case let .ready(entryID, position, rate, _, _):
            guard let cached = await mediaCache.cachedEntries()[entryID] else { return }
            let entry = decisionContent.entries[entryID]
            let item = LibraryPlayer.Item(
                entryID: entryID, title: entry?.title ?? "Episode",
                showTitle: entry.flatMap { decisionContent.sources[$0.sourceID]?.title } ?? "", fileURL: cached.url,
                artworkURL: LibraryRowBuilder.artworkURL(entry?.artworkRef))
            let forwardSequence = manualForwardSuffix(from: entryID)
            guard commandState.token == token else { return }
            player.setRate(rate)
            continuation = nil
            let started = player.start(item, at: position)
            if started {
                handoffState.forwardSequenceIDs = forwardSequence
            }
        case let .refused(_, reason):
            handoffMessage = reason
            continuation = plan
        case .needsAudio:
            break
        }
    }

    private func freshPlan() async -> LibraryContinuation? {
        guard let records = try? await transport.fetchDeviceRecords() else {
            handoffMessage = "Could not read the Mac's playback. Check your connection."
            return nil
        }
        let cached = await mediaCache.cachedEntries().mapValues(\.revisionID)
        return LibraryContinuationPlanner.plan(
            records: records, deviceID: deviceID, cachedRevisions: cached, durations: entryDurations,
            now: now(), clockOffset: handoffState.clockOffset)
    }

    /// Requests the audio and waits for it. Returns false when it did not arrive on the phone or
    /// the Mac offers a different revision than the one being continued.
    private func fetchAudio(_ entryID: ItemID, revision: RevisionID) async -> Bool {
        if let offers = try? await transport.mediaOffers(),
           let offer = offers.first(where: { $0.entryID == entryID }), offer.isPrepared,
           let offered = offer.revisionID, offered != revision {
            handoffState.refusedRevisions[entryID] = revision
            continuation = .refused(entryID: entryID, reason: Self.offerMismatchReason)
            handoffMessage = Self.offerMismatchReason
            return false
        }
        startMediaRequest(entryID: entryID)
        await waitForMedia(entryID: entryID)
        guard mediaState(for: entryID) == .onPhone else { return false }
        return true
    }
}
