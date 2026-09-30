import Foundation
import WiltedDomain

/// Owns one device's side of playback handoff and is that device's only writer of playback
/// records: takeover, cadence publishing, relinquish and resume. Platform-neutral; the app
/// reports player events and calls `observe()` on its own poll.
///
/// A takeover reads every device's records right before choosing its epoch (max seen plus
/// one). Both devices can still publish the same epoch inside the propagation window, so
/// exactly one winner is guaranteed only once each has observed the other; the brief
/// overlap where both play is a documented residual, narrowed by `settleCheck()`.
public actor HandoffCoordinator {
    public struct Configuration: Sendable, Equatable {
        /// Minimum gap between cadence publishes while playing.
        public var publishInterval: TimeInterval
        /// Pause before the one confirming fetch after a takeover.
        public var settleDelay: TimeInterval

        public init(
            publishInterval: TimeInterval = SyncCadence.playingPublishInterval,
            settleDelay: TimeInterval = SyncCadence.takeoverSettleDelay
        ) {
            self.publishInterval = publishInterval
            self.settleDelay = settleDelay
        }
    }

    private struct Session {
        let entryID: ItemID
        let revision: RevisionID
        let epoch: Int
        var rate: Double
        var position: Double
        var isPlaying: Bool
        var lastPublishedAt: Date?
        var relinquishedTo: String?
        var relinquished: Bool { relinquishedTo != nil }
    }

    private let transport: any LibraryTransport
    private let deviceID: String
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let configuration: Configuration
    private var session: Session?
    private var clockOffset: TimeInterval = 0
    /// True when the last `publishStoredPositions` skipped an entry only because a device was
    /// playing it, so the same list is worth offering again once that device pauses.
    public private(set) var deferredStoredPositions = false

    /// - Parameters:
    ///   - clock: local wall clock; injectable for tests.
    ///   - sleep: waits `settleDelay` in `settleCheck()`; injectable for tests.
    public init(
        transport: any LibraryTransport,
        deviceID: String,
        configuration: Configuration = Configuration(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.deviceID = deviceID
        self.configuration = configuration
        self.clock = clock
        self.sleep = sleep
    }

    /// Epoch of the active playback session, if any.
    public var epoch: Int? { session?.epoch }

    /// True once `observe()` decided another device holds playback.
    public var hasRelinquished: Bool { session?.relinquished ?? false }

    /// Starts playing `entryID` here. Fetches every device's records first, takes epoch
    /// max seen plus one, and publishes NowPlaying and Progress immediately.
    @discardableResult
    public func takeover(entryID: ItemID, revision: RevisionID, positionSeconds: Double, rate: Double = 1) async throws -> Int {
        let records = try await transport.fetchDeviceRecords()
        learnClockOffset(from: records)
        let seen = (records.nowPlaying + records.progress).map(\.record)
        let epoch = HandoffResolver.takeoverEpoch(seen: seen)
        session = Session(entryID: entryID, revision: revision, epoch: epoch, rate: rate,
                          position: positionSeconds, isPlaying: true, lastPublishedAt: nil)
        try await publishCurrent()
        return epoch
    }

    /// Periodic player tick; publishes only when `publishInterval` has elapsed since the
    /// last publish. No-op while paused, stopped or relinquished.
    public func positionUpdate(_ positionSeconds: Double, rate: Double? = nil) async throws {
        guard var current = session, current.isPlaying, !current.relinquished else { return }
        current.position = positionSeconds
        if let rate { current.rate = rate }
        session = current
        if let last = current.lastPublishedAt, clock().timeIntervalSince(last) < configuration.publishInterval { return }
        try await publishCurrent()
    }

    /// Publishes immediately as paused at `positionSeconds`.
    public func paused(at positionSeconds: Double) async throws {
        guard var current = session else { return }
        current.position = positionSeconds
        current.isPlaying = false
        session = current
        try await publishCurrent()
    }

    /// Publishes the new position immediately, keeping the play state. No-op once relinquished.
    public func seeked(to positionSeconds: Double) async throws {
        guard var current = session, !current.relinquished else { return }
        current.position = positionSeconds
        session = current
        try await publishCurrent()
    }

    /// Publishes a final paused record and ends the session.
    public func stopped(at positionSeconds: Double) async throws {
        try await paused(at: positionSeconds)
        session = nil
    }

    /// A durable position the device holds for an entry it is not playing right now.
    public struct StoredPosition: Sendable, Equatable {
        public let entryID: ItemID
        public let revision: RevisionID
        public let positionSeconds: Double
        /// When the device last saved this position, on its own clock; nil when unknown.
        public let updatedAt: Date?

        public init(entryID: ItemID, revision: RevisionID, positionSeconds: Double, updatedAt: Date? = nil) {
            self.entryID = entryID
            self.revision = revision
            self.positionSeconds = positionSeconds
            self.updatedAt = updatedAt
        }
    }

    /// Publishes each stored position as a paused record on the Progress channel only, so
    /// another device can resume an episode this device paused earlier (or in a run that was
    /// not syncing). It never touches the session, the NowPlaying record or the takeover
    /// epoch: a playing device is not asked to relinquish, because `observe()` reads only
    /// NowPlaying. A record carries the highest epoch already seen for its entry, so the
    /// later server date decides among devices at that epoch.
    ///
    /// Skipped: the entry being played here, an entry another device is playing, an entry
    /// another device saved more recently than `updatedAt`, and one whose own paused record
    /// already holds this revision and position. Returns the entries written; see
    /// `deferredStoredPositions` for a list that was held back while a device played.
    @discardableResult
    public func publishStoredPositions(_ positions: [StoredPosition]) async throws -> [ItemID] {
        deferredStoredPositions = false
        guard !positions.isEmpty else { return [] }
        let records = try await transport.fetchDeviceRecords()
        learnClockOffset(from: records)
        let now = clock()
        var written: [ItemID] = []
        for position in positions {
            if let session = session, session.entryID == position.entryID, session.isPlaying, !session.relinquished {
                deferredStoredPositions = true
                continue
            }
            let seen = (records.nowPlaying + records.progress).filter { $0.record.entryID == position.entryID }
            let others = seen.filter { $0.record.deviceID != deviceID }
            if HandoffResolver.livePlayers(others, localDeviceID: deviceID, now: now, clockOffset: clockOffset)
                .contains(where: { $0.record.deviceID != deviceID }) {
                deferredStoredPositions = true
                continue
            }
            if let saved = position.updatedAt,
               others.contains(where: { $0.serverModifiedAt.addingTimeInterval(-clockOffset) > saved }) { continue }
            let own = records.progress.first { $0.record.deviceID == deviceID && $0.record.entryID == position.entryID }
            if let own, !own.record.isPlaying, own.record.revision == position.revision,
               abs(own.record.positionSeconds - position.positionSeconds) < 0.5 { continue }
            let record = try DevicePlaybackPosition(
                deviceID: deviceID, entryID: position.entryID, revision: position.revision,
                positionSeconds: max(0, position.positionSeconds), rate: 1, isPlaying: false,
                epoch: seen.map(\.record.epoch).max() ?? 0, publishedAt: now)
            try await transport.publish(record, as: .progress)
            written.append(position.entryID)
        }
        return written
    }

    /// Waits about `settleDelay`, then observes once, catching a takeover that raced ours.
    public func settleCheck() async throws -> HandoffDecision {
        try await sleep(configuration.settleDelay)
        return try await observe()
    }

    /// Fetches device records and returns `.relinquish(to:)` when another device that is
    /// playing outranks this one. Once relinquished it keeps returning that decision, so a
    /// poller never restarts the loser. Paused and presumed-dead devices never force a handoff.
    public func observe() async throws -> HandoffDecision {
        decision(from: try await transport.fetchDeviceRecords())
    }

    /// The same decision as `observe()`, from records the caller already holds, so a device that
    /// polls anyway (the Mac's inbound poller) decides without a second fetch.
    public func decision(from records: LibraryDeviceRecords) -> HandoffDecision {
        learnClockOffset(from: records)
        guard var current = session else { return .keepPlaying }
        if let winner = current.relinquishedTo { return .relinquish(to: winner) }
        let live = HandoffResolver.livePlayers(
            records.nowPlaying, localDeviceID: deviceID, now: clock(), clockOffset: clockOffset)
        let decision = HandoffResolver.decision(localDeviceID: deviceID, localEpoch: current.epoch, observed: live)
        if case .relinquish(let winner) = decision {
            current.relinquishedTo = winner
            session = current
        }
        return decision
    }

    /// What continuing another device's playback would take, given the audio revisions
    /// held locally. `.needsMedia` unless the revision matches exactly.
    public func resumeTarget(
        localRevision: @Sendable (ItemID) -> RevisionID?,
        durationSeconds: @Sendable (ItemID) -> Double? = { _ in nil }
    ) async throws -> HandoffResumeTarget {
        let records = try await transport.fetchDeviceRecords()
        learnClockOffset(from: records)
        return HandoffResolver.resumeTarget(
            observed: records.nowPlaying, localDeviceID: deviceID, localRevision: localRevision,
            now: clock(), clockOffset: clockOffset, durationSeconds: durationSeconds)
    }

    private func learnClockOffset(from records: LibraryDeviceRecords) {
        guard let own = records.nowPlaying.first(where: { $0.record.deviceID == deviceID }),
              let offset = HandoffResolver.clockOffset(of: own) else { return }
        clockOffset = offset
    }

    private func publishCurrent() async throws {
        guard let current = session else { return }
        let now = clock()
        let record = try DevicePlaybackPosition(
            deviceID: deviceID, entryID: current.entryID, revision: current.revision,
            positionSeconds: max(0, current.position), rate: current.rate, isPlaying: current.isPlaying,
            epoch: current.epoch, publishedAt: now)
        try await transport.publish(record, as: .nowPlaying)
        try await transport.publish(record, as: .progress)
        guard var after = session else { return }
        after.lastPublishedAt = now
        session = after
    }
}
