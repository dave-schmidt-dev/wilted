import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)

private let handoffLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacHandoff")

/// The slice of the Mac player the handoff controller needs. The model adapter goes through
/// the model's own playback path; tests substitute a scripted player.
@MainActor
protocol WiltedMacHandoffPlayer: AnyObject {
    /// The podcast episode loaded in the player and where it is; nil when none is.
    func handoffSample() -> WiltedMacPlaybackSample?
    /// The audio revision loaded for `entryID`, or the newest ready one; nil when unknown.
    func handoffRevision(for entryID: ItemID) async -> RevisionID?
    /// Pauses playback and writes the durable playback checkpoint.
    func pauseAndCheckpoint() async
    /// Calls `onChange` once, on the next change to what is playing or paused.
    func trackPlayback(onChange: @escaping @MainActor () -> Void)
}

/// Drives `HandoffCoordinator` from the Mac player: takes over when the Mac starts playing,
/// republishes on a timer while it plays, records a pause, and stops the Mac when another device
/// holds a higher epoch (W-INV-005: it pauses through the player, never writes library state).
///
/// The coordinator is the only writer of the Mac's playback records. `reconcile()` is the whole
/// state machine and runs on every observed change and on each timer tick, so a failed publish
/// or a failed pause is retried by the next tick.
@MainActor
final class WiltedMacHandoffController {
    /// Gap between timer ticks; below the 5 s publish cadence so a tick cannot miss it.
    static let defaultTickInterval: Duration = .seconds(2)

    private let coordinator: HandoffCoordinator
    private let player: any WiltedMacHandoffPlayer
    private let deviceID: String
    private let latestRecords: (@Sendable () async -> LibraryDeviceRecords?)?
    private let tickInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    private var running = false
    private var again = false
    private var stopped = false

    /// True while a playing session is published as playing under an epoch.
    private var sessionPlaying = false
    private var sessionEntry: ItemID?
    private var lastPosition: Double = 0
    /// A higher epoch was seen and the pause has not yet succeeded.
    private var pendingRelinquish = false

    private(set) var takeoverCount = 0
    private(set) var relinquishCount = 0
    private(set) var lastFailure: String?

    /// - Parameters:
    ///   - latestRecords: the inbound poller's newest device records. When it shows no other
    ///     device at or above the local epoch, the tick skips its own fetch; nil always fetches.
    init(
        coordinator: HandoffCoordinator,
        player: any WiltedMacHandoffPlayer,
        deviceID: String,
        latestRecords: (@Sendable () async -> LibraryDeviceRecords?)? = nil,
        tickInterval: Duration = WiltedMacHandoffController.defaultTickInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.coordinator = coordinator
        self.player = player
        self.deviceID = deviceID
        self.latestRecords = latestRecords
        self.tickInterval = tickInterval
        self.sleep = sleep
    }

    /// Starts the timer and the observation of player changes. Calling it again does nothing.
    func start() {
        guard loop == nil, !stopped else { return }
        observePlayer()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcile()
                do { try await self.sleep(self.tickInterval) } catch { return }
            }
        }
    }

    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
    }

    isolated deinit { stop() }

    private func observePlayer() {
        guard !stopped else { return }
        player.trackPlayback { [weak self] in
            guard let self, !self.stopped else { return }
            Task { await self.reconcile() }
            self.observePlayer()
        }
    }

    /// One pass of the state machine. A call made during a pass runs one more pass afterwards.
    func reconcile() async {
        guard !stopped else { return }
        if running {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            await step()
        } while again && !stopped
        running = false
    }

    private func step() async {
        do {
            let sample = player.handoffSample()
            if let sample, sample.isPlaying {
                lastPosition = sample.positionSeconds
                if !sessionPlaying || sessionEntry != sample.episodeID {
                    try await takeOver(sample)
                } else if pendingRelinquish {
                    try await relinquish()
                } else {
                    try await coordinator.positionUpdate(sample.positionSeconds, rate: sample.rate)
                    if await shouldObserve() { try await applyDecision(await coordinator.observe()) }
                }
            } else if sessionPlaying {
                let position = sample?.positionSeconds ?? lastPosition
                try await coordinator.paused(at: position)
                sessionPlaying = false
                pendingRelinquish = false
            }
            lastFailure = nil
        } catch {
            lastFailure = String(describing: error)
            handoffLog.error("Handoff step failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func takeOver(_ sample: WiltedMacPlaybackSample) async throws {
        guard let revision = await player.handoffRevision(for: sample.episodeID) else {
            handoffLog.notice("Playing \(sample.episodeID.rawValue, privacy: .public) has no known revision; not published")
            return
        }
        let epoch = try await coordinator.takeover(
            entryID: sample.episodeID, revision: revision, positionSeconds: sample.positionSeconds, rate: sample.rate)
        sessionPlaying = true
        sessionEntry = sample.episodeID
        pendingRelinquish = false
        takeoverCount += 1
        handoffLog.notice("Took over playback at epoch \(epoch)")
        try await applyDecision(await coordinator.settleCheck())
    }

    /// Whether another device could outrank this one, judged from the poller's last records so
    /// an ordinary tick costs no fetch. A missing poller means "always check".
    private func shouldObserve() async -> Bool {
        guard let latestRecords, let epoch = await coordinator.epoch else { return true }
        guard let records = await latestRecords() else { return true }
        return records.nowPlaying.contains { $0.record.deviceID != deviceID && $0.record.epoch >= epoch }
    }

    private func applyDecision(_ decision: HandoffDecision) async throws {
        guard case let .relinquish(winner) = decision else { return }
        handoffLog.notice("Relinquishing playback to \(winner, privacy: .public)")
        pendingRelinquish = true
        try await relinquish()
    }

    /// Pauses with a checkpoint, then publishes the paused record the coordinator does not
    /// publish itself. If the player is still playing afterwards, the next tick retries.
    private func relinquish() async throws {
        await player.pauseAndCheckpoint()
        let after = player.handoffSample()
        if after?.isPlaying == true { return }
        try await coordinator.paused(at: after?.positionSeconds ?? lastPosition)
        pendingRelinquish = false
        sessionPlaying = false
        relinquishCount += 1
    }
}

#endif
