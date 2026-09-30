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

/// Waits the handoff timers use. Injected so tests drive the 5 s observe cadence without real time.
struct LibraryHandoffTiming: Sendable {
    /// Gap between observations of the other devices while the phone plays. Peers treat a
    /// device as dead after 15 s and the goal is a pause within 10 s of a Mac takeover.
    var observeInterval: TimeInterval = 5
    /// Waits `observeInterval` between observations.
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// The pause before the single confirming fetch after a takeover.
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
    var observeTask: Task<Void, Never>?
    var settleTask: Task<Void, Never>?
    /// True between a successful takeover and the next pause, stop or relinquish.
    var reportedPlaying = false
    var reportedEntry: ItemID?
    var lastPosition: Double = 0
    var lastPositionAt: Date?
    /// When a takeover last failed; nil after a success. Failed attempts repeat at the observe interval.
    var lastTakeoverFailure: Date?
    /// Server clock minus this phone's clock, learned from this device's own record.
    var clockOffset: TimeInterval = 0
    var refusedRevisions: [ItemID: RevisionID] = [:]
    var continueInFlight = false
    /// Completed observations; lets tests wait for a cycle.
    var observeCycles = 0
}

extension LibraryAppModel {
    /// A position change larger than this from what elapsed time predicts counts as a seek.
    static let seekThreshold: Double = 2

    // MARK: - Player wiring

    /// Starts driving the coordinator from `player`. Lock-screen and headset commands go to the
    /// player directly, so its published state is the source of truth, not the buttons.
    func attachPlayer(_ player: LibraryPlayer) {
        guard handoffState.player !== player else { return }
        handoffState.subscriptions.removeAll()
        handoffState.player = player
        // `@Published` emits on the thread that mutates it, which is always the main actor here.
        player.$status.removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueueHandoffSync() }
        }.store(in: &handoffState.subscriptions)
        player.$position.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueueHandoffSync() }
        }.store(in: &handoffState.subscriptions)
        player.$item.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueueHandoffSync() }
        }.store(in: &handoffState.subscriptions)
    }

    /// Waits until every queued coordinator call has finished. For tests.
    func waitForHandoff() async { await handoffState.chain?.value }

    /// Plays the cached file for `row` from the Mac's last observed position (else the start), or
    /// toggles it when it is already loaded. Starting playback takes over through the player's
    /// status change.
    func playCached(_ row: LibraryRow) async {
        guard let player = handoffState.player, let cached = await mediaCache.cachedEntries()[row.id] else { return }
        let item = LibraryPlayer.Item(entryID: row.id, title: row.title, showTitle: row.showTitle, fileURL: cached.url)
        guard player.item != item else { return player.togglePlayPause() }
        // The Mac's position belongs to the revision it played; a different cached revision starts over.
        let sameAudio = checkpoints[row.id]?.record.revision == cached.revisionID
        player.start(item, at: sameAudio ? row.resumeSeconds ?? 0 : 0)
    }

    /// The app moved to the background: publish the current position now, since the next
    /// cadence tick may be a long way off.
    func sceneEnteredBackground() async {
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
        defer { state.lastPosition = position; state.lastPositionAt = clock }
        if status == .playing, let item {
            if !state.reportedPlaying || state.reportedEntry != item.entryID {
                await beginPlayback(item, position: position, rate: player.rate, at: clock)
            } else if hasJumped(to: position, rate: player.rate, at: clock) {
                try? await coordinator.seeked(to: position)
            } else {
                try? await coordinator.positionUpdate(position, rate: player.rate)
            }
        } else if state.reportedPlaying {
            state.reportedPlaying = false
            state.observeTask?.cancel()
            state.settleTask?.cancel()
            do {
                if item == nil { try await coordinator.stopped(at: state.lastPosition) } else { try await coordinator.paused(at: position) }
            } catch {
                handoffLog.error("Could not publish the pause: \(String(describing: error), privacy: .public)")
            }
        } else if item != nil, abs(position - state.lastPosition) > 0.01 {
            try? await coordinator.seeked(to: position)
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
            handoffMessage = nil
            handoffLog.info("Took over playback at epoch \(epoch, privacy: .public)")
            startObserving()
            scheduleSettleCheck()
        } catch {
            state.lastTakeoverFailure = clock
            handoffMessage = "Handoff is unavailable: \(Self.text(for: error))"
            handoffLog.error("Takeover failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Observing the other devices

    /// While the phone plays, look at the other devices every `observeInterval`. Runs on the
    /// audio background mode too, since the audio session keeps the app alive.
    private func startObserving() {
        handoffState.observeTask?.cancel()
        handoffState.observeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let timing = self?.handoffTiming else { return }
                do { try await timing.sleep(timing.observeInterval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.observeHandoffOnce()
            }
        }
    }

    /// One observation. A higher epoch elsewhere pauses the phone.
    func observeHandoffOnce() async {
        defer { handoffState.observeCycles += 1 }
        do {
            if case let .relinquish(winner) = try await coordinator.observe() {
                await relinquish(to: winner)
            }
        } catch {
            handoffLog.error("Observe failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleSettleCheck() {
        handoffState.settleTask?.cancel()
        handoffState.settleTask = Task { [weak self] in
            guard let self, let decision = try? await self.coordinator.settleCheck(),
                  case let .relinquish(winner) = decision, !Task.isCancelled else { return }
            await self.relinquish(to: winner)
        }
    }

    private func relinquish(to winner: String) async {
        await runOnHandoffChain { [weak self] in
            guard let self, let player = self.handoffState.player, self.handoffState.reportedPlaying else { return }
            let state = self.handoffState
            state.reportedPlaying = false
            state.observeTask?.cancel()
            state.settleTask?.cancel()
            player.pause()
            state.lastPosition = player.position
            // The coordinator does not publish a paused record on its own after a loss.
            try? await self.coordinator.paused(at: player.position)
            self.handoffMessage = "Paused because \(winner) started playing."
            handoffLog.info("Relinquished to \(winner, privacy: .public)")
            if let records = try? await self.transport.fetchDeviceRecords() { await self.updateContinuation(from: records) }
        }
    }

    // MARK: - Continue from Mac

    /// Recomputes the banner from fresh device records. Runs on every sync, so it covers app
    /// activation, pull to refresh and silent pushes.
    func updateContinuation(from records: LibraryDeviceRecords) async {
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
                showTitle: entry.flatMap { decisionContent.sources[$0.sourceID]?.title } ?? "", fileURL: cached.url)
            player.setRate(rate)
            continuation = nil
            player.start(item, at: position)
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
