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
    /// Durable positions of started, unfinished queued episodes, each at the revision the Mac
    /// offers as audio. Empty when none or when the read failed.
    func storedPositions() async -> [HandoffCoordinator.StoredPosition]
}

extension WiltedMacHandoffPlayer {
    func storedPositions() async -> [HandoffCoordinator.StoredPosition] { [] }
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
    /// Gap between timer ticks. A tick sends nothing by itself: publishes are paced by the
    /// coordinator's `SyncCadence.playingPublishInterval` and the other devices are read from the
    /// poller's records, so this only bounds how soon an edge (a pause, a seek) is noticed.
    static let defaultTickInterval: Duration = .seconds(SyncCadence.macTickInterval)
    /// Ticks between rereads of the stored positions while nothing plays
    /// (`SyncCadence.storedPositionRefreshInterval`), which catches a seek made while paused.
    static let storedPositionRefreshTicks = Int(SyncCadence.storedPositionRefreshInterval / SyncCadence.macTickInterval)

    private let coordinator: HandoffCoordinator
    private let player: any WiltedMacHandoffPlayer
    private let deviceID: String
    private let latestRecords: (@Sendable () async -> LibraryDeviceRecords?)?
    private let now: @Sendable () -> Date
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
    private var lastSampleAt: Date?
    /// A higher epoch was seen and the pause has not yet succeeded.
    private var pendingRelinquish = false
    /// Stored positions are due for publishing: at start, after a pause, and on the refresh tick.
    private var storedPositionsDue = true
    private var lastStoredPositions: [HandoffCoordinator.StoredPosition] = []
    private var tickCount = 0
    /// When the tick last fetched the other devices itself (only without a poller to read from).
    private var lastOwnObserveAt: Date?
    /// The last failure that was logged, so a repeat of it (every tick while offline or throttled)
    /// is not.
    private var lastLoggedFailure: String?

    private(set) var takeoverCount = 0
    private(set) var relinquishCount = 0
    private(set) var lastFailure: String?

    /// - Parameters:
    ///   - latestRecords: the inbound poller's newest device records. The tick decides from them
    ///     and sends nothing; without them it fetches, at most once per `SyncCadence.pollInterval`.
    init(
        coordinator: HandoffCoordinator,
        player: any WiltedMacHandoffPlayer,
        deviceID: String,
        latestRecords: (@Sendable () async -> LibraryDeviceRecords?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        tickInterval: Duration = WiltedMacHandoffController.defaultTickInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.coordinator = coordinator
        self.player = player
        self.deviceID = deviceID
        self.latestRecords = latestRecords
        self.now = now
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
                self.tickCount += 1
                if self.tickCount % Self.storedPositionRefreshTicks == 0 { self.storedPositionsDue = true }
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
                let jumped = hasJumped(to: sample)
                lastPosition = sample.positionSeconds
                lastSampleAt = now()
                if !sessionPlaying || sessionEntry != sample.episodeID {
                    try await takeOver(sample)
                } else if pendingRelinquish {
                    try await relinquish()
                } else {
                    // A seek is an edge: published now, not at the next 30 s publish.
                    if jumped {
                        try await coordinator.seeked(to: sample.positionSeconds)
                    } else {
                        try await coordinator.positionUpdate(sample.positionSeconds, rate: sample.rate)
                    }
                    try await applyDecision(await observeDecision())
                }
            } else if sessionPlaying {
                let position = sample?.positionSeconds ?? lastPosition
                try await coordinator.paused(at: position)
                sessionPlaying = false
                pendingRelinquish = false
                storedPositionsDue = true
            }
            if storedPositionsDue, !sessionPlaying { try await publishStoredPositions() }
            lastFailure = nil
            lastLoggedFailure = nil
        } catch {
            lastFailure = String(describing: error)
            // A gate that is closed says so through its own status; a step that fails the same way
            // on every tick is logged once.
            if !(error is TransportThrottled), lastLoggedFailure != lastFailure {
                handoffLog.error("Handoff step failed: \(String(describing: error), privacy: .public)")
            }
            lastLoggedFailure = lastFailure
        }
    }

    /// A position further from where playing since the last sample would have put it than
    /// `seekThreshold` is a seek (the listener scrubbed), not the audio advancing.
    private func hasJumped(to sample: WiltedMacPlaybackSample) -> Bool {
        guard sessionPlaying, sessionEntry == sample.episodeID, let last = lastSampleAt else { return false }
        let expected = lastPosition + max(0, now().timeIntervalSince(last)) * sample.rate
        return abs(sample.positionSeconds - expected) > Self.seekThreshold
    }

    /// Seconds a position may differ from the elapsed-time prediction before it counts as a seek.
    static let seekThreshold: Double = 2

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

    /// Whether another device outranks this one, judged from the poller's last records so a tick
    /// costs no request. With no poller records to read, one fetch per `SyncCadence.pollInterval`.
    private func observeDecision() async throws -> HandoffDecision {
        if let latestRecords, let records = await latestRecords() {
            return await coordinator.decision(from: records)
        }
        let current = now()
        if let last = lastOwnObserveAt, current.timeIntervalSince(last) < SyncCadence.pollInterval { return .keepPlaying }
        lastOwnObserveAt = current
        return try await coordinator.observe()
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
        storedPositionsDue = true
        relinquishCount += 1
    }

    /// Publishes the Mac's durable positions for paused episodes so another device can resume
    /// them, including an episode that was paused before this launch or in a run without sync.
    /// The coordinator writes them as paused Progress records under the epoch already in use, so
    /// no device is asked to relinquish. A list equal to the last one published is not sent again.
    private func publishStoredPositions() async throws {
        let positions = await player.storedPositions()
        guard positions != lastStoredPositions else {
            storedPositionsDue = false
            return
        }
        let written = try await coordinator.publishStoredPositions(positions)
        // A list held back while a device was playing is offered again on the next refresh.
        lastStoredPositions = await coordinator.deferredStoredPositions ? [] : positions
        storedPositionsDue = false
        if !written.isEmpty { handoffLog.notice("Published \(written.count) stored playback position(s)") }
    }
}

#endif
