import Foundation
import WiltedDomain

/// What a playing device should do after observing the other devices' records.
public enum HandoffDecision: Sendable, Equatable {
    case keepPlaying
    /// Another device holds a higher epoch; stop and hand over.
    case relinquish(to: String)
}

/// Pure handoff rules. Devices write only their own records; readers order them
/// by `(epoch, server modification date)`.
public enum HandoffResolver {
    /// A playing record not refreshed for longer than this (three publish cadences, see
    /// `SyncCadence`) is treated as paused at its recorded position: its device is presumed dead.
    public static let staleAfter: TimeInterval = SyncCadence.staleAfter

    /// Whether `incoming` outranks `current`: higher epoch, else later server date.
    /// A lower epoch is stale no matter how recent its server date is.
    public static func supersedes(_ incoming: ObservedPlayback, over current: ObservedPlayback) -> Bool {
        ordered(current, before: incoming)
    }

    /// The authoritative record, or nil for an empty set. Ties resolve by device ID.
    public static func winner(among observed: [ObservedPlayback]) -> ObservedPlayback? {
        observed.max { ordered($0, before: $1) }
    }

    /// True when `record` carries an epoch below the highest one seen.
    public static func isStale(_ record: DevicePlaybackPosition, seen: [DevicePlaybackPosition]) -> Bool {
        record.epoch < (seen.map(\.epoch).max() ?? 0)
    }

    /// Epoch for a device taking over: the maximum epoch seen plus one.
    public static func takeoverEpoch(seen: [DevicePlaybackPosition]) -> Int {
        (seen.map(\.epoch).max() ?? 0) + 1
    }

    /// Relinquish when another device holds a higher epoch, or the same epoch
    /// with a later `(server date, device ID)` (a simultaneous takeover race).
    /// Rewinds inside the local epoch never trigger this.
    public static func decision(localDeviceID: String, localEpoch: Int, observed: [ObservedPlayback]) -> HandoffDecision {
        let local = observed.first { $0.record.deviceID == localDeviceID }
        let others = observed.filter { other in
            guard other.record.deviceID != localDeviceID else { return false }
            if other.record.epoch > localEpoch { return true }
            guard other.record.epoch == localEpoch, let local else { return false }
            return ordered(local, before: other)
        }
        guard let winner = winner(among: others) else { return .keepPlaying }
        return .relinquish(to: winner.record.deviceID)
    }

    /// Position to resume at. While playing, advance by the elapsed time at the
    /// recorded rate; `clockOffset` is (server clock minus local clock) in seconds.
    public static func resumePosition(
        of observed: ObservedPlayback,
        now: Date,
        clockOffset: TimeInterval = 0,
        durationSeconds: Double? = nil
    ) -> Double {
        let record = observed.record
        var position = record.positionSeconds
        if effective(observed, now: now, clockOffset: clockOffset).record.isPlaying {
            let elapsed = max(0, now.addingTimeInterval(clockOffset).timeIntervalSince(observed.serverModifiedAt))
            position += elapsed * record.rate
        }
        if let durationSeconds { position = min(position, durationSeconds) }
        return max(0, position)
    }

    /// Server clock minus the publisher's clock, from one record's `publishedAt`. Nil when
    /// the record carries none. A device reading back its own record gets its own offset.
    public static func clockOffset(of observed: ObservedPlayback) -> TimeInterval? {
        observed.record.publishedAt.map { observed.serverModifiedAt.timeIntervalSince($0) }
    }

    /// `observed` with a playing record older than `staleAfter` downgraded to paused at its
    /// recorded position. `clockOffset` is (server clock minus local clock) in seconds.
    public static func effective(
        _ observed: ObservedPlayback, now: Date, clockOffset: TimeInterval = 0, staleAfter: TimeInterval = staleAfter
    ) -> ObservedPlayback {
        let record = observed.record
        let age = now.addingTimeInterval(clockOffset).timeIntervalSince(observed.serverModifiedAt)
        guard record.isPlaying, age > staleAfter,
              let paused = try? DevicePlaybackPosition(
                  deviceID: record.deviceID, entryID: record.entryID, revision: record.revision,
                  positionSeconds: record.positionSeconds, rate: record.rate, isPlaying: false,
                  epoch: record.epoch, publishedAt: record.publishedAt)
        else { return observed }
        return ObservedPlayback(record: paused, serverModifiedAt: observed.serverModifiedAt)
    }

    /// The other devices that are genuinely playing right now. A paused or presumed-dead
    /// device never forces the local device to relinquish. The local record is kept for
    /// same-epoch tie-breaking.
    public static func livePlayers(
        _ observed: [ObservedPlayback], localDeviceID: String, now: Date, clockOffset: TimeInterval = 0
    ) -> [ObservedPlayback] {
        observed.compactMap { item in
            if item.record.deviceID == localDeviceID { return item }
            let current = effective(item, now: now, clockOffset: clockOffset)
            return current.record.isPlaying ? current : nil
        }
    }

    /// What a device should do to continue what another device is playing. Resumes only
    /// when the local audio has exactly the revision the other device plays.
    public static func resumeTarget(
        observed: [ObservedPlayback],
        localDeviceID: String,
        localRevision: (ItemID) -> RevisionID?,
        now: Date,
        clockOffset: TimeInterval = 0,
        durationSeconds: (ItemID) -> Double? = { _ in nil }
    ) -> HandoffResumeTarget {
        let others = observed.filter { $0.record.deviceID != localDeviceID }
        guard let winner = winner(among: others) else { return .nothing }
        let record = winner.record
        guard localRevision(record.entryID) == record.revision else {
            return .needsMedia(entryID: record.entryID, revision: record.revision)
        }
        let current = effective(winner, now: now, clockOffset: clockOffset).record
        let position = resumePosition(
            of: winner, now: now, clockOffset: clockOffset, durationSeconds: durationSeconds(record.entryID))
        return .resume(HandoffResume(
            entryID: record.entryID, revision: record.revision, positionSeconds: position,
            rate: record.rate, wasPlaying: current.isPlaying, sourceDeviceID: record.deviceID))
    }

    private static func ordered(_ a: ObservedPlayback, before b: ObservedPlayback) -> Bool {
        if a.record.epoch != b.record.epoch { return a.record.epoch < b.record.epoch }
        if a.serverModifiedAt != b.serverModifiedAt { return a.serverModifiedAt < b.serverModifiedAt }
        return a.record.deviceID < b.record.deviceID
    }
}

/// Where to continue another device's playback.
public struct HandoffResume: Sendable, Equatable {
    public let entryID: ItemID
    public let revision: RevisionID
    /// Rate-aware position now, clamped to the duration when known.
    public let positionSeconds: Double
    public let rate: Double
    /// False when the other device is paused, or its record is stale and presumed dead.
    public let wasPlaying: Bool
    public let sourceDeviceID: String
}

/// Outcome of asking whether another device's playback can be resumed here.
public enum HandoffResumeTarget: Sendable, Equatable {
    /// No other device has a playback record.
    case nothing
    case resume(HandoffResume)
    /// The local audio is missing or a different revision; request the audio first.
    case needsMedia(entryID: ItemID, revision: RevisionID)
}
