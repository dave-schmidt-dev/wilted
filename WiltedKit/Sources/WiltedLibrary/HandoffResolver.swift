import Foundation

/// What a playing device should do after observing the other devices' records.
public enum HandoffDecision: Sendable, Equatable {
    case keepPlaying
    /// Another device holds a higher epoch; stop and hand over.
    case relinquish(to: String)
}

/// Pure handoff rules. Devices write only their own records; readers order them
/// by `(epoch, server modification date)`.
public enum HandoffResolver {
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
        if record.isPlaying {
            let elapsed = max(0, now.addingTimeInterval(clockOffset).timeIntervalSince(observed.serverModifiedAt))
            position += elapsed * record.rate
        }
        if let durationSeconds { position = min(position, durationSeconds) }
        return max(0, position)
    }

    private static func ordered(_ a: ObservedPlayback, before b: ObservedPlayback) -> Bool {
        if a.record.epoch != b.record.epoch { return a.record.epoch < b.record.epoch }
        if a.serverModifiedAt != b.serverModifiedAt { return a.serverModifiedAt < b.serverModifiedAt }
        return a.record.deviceID < b.record.deviceID
    }
}
