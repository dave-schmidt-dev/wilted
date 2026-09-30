import Foundation
import WiltedDomain

/// A playback position another device reported for one exact audio revision, to be adopted as
/// this device's stored position. The Mac is the only writer of library state (W-INV-005), so a
/// phone's position reaches the store only through `PlaybackController.applyRemotePosition`.
public struct RemotePositionRequest: Sendable, Equatable {
    public let itemID: ItemID
    public let revisionID: RevisionID
    public let positionSeconds: Double
    /// Duration of the revision, used when nothing is stored for it yet.
    public let durationSeconds: Double
    /// When the other device saved the position, on this device's clock.
    public let observedAt: Date

    public init(itemID: ItemID, revisionID: RevisionID, positionSeconds: Double, durationSeconds: Double, observedAt: Date) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.observedAt = observedAt
    }
}

/// What `PlaybackController.applyRemotePosition` did with a request.
public enum RemotePositionOutcome: Sendable, Equatable {
    /// The stored (and, when loaded, the in-memory) position now matches the request.
    case applied
    /// The stored position is at least as recent as the request: nothing to do, and a repeat
    /// of the same request lands here.
    case notNewer
    /// The episode is playing on this device; the epoch and relinquish logic owns it.
    case playing
    /// The episode is finished here. A finished episode is never resurrected by a position.
    case completed
    /// The position is at or past the end, or not a usable position.
    case unusable
}

/// The decisions behind `applyRemotePosition`, pure so the rules are testable without a store.
enum RemotePositionRules {
    /// Within this many seconds of the end an episode counts as finished, not resumable.
    static let endMargin: Double = 1
    /// A move smaller than this is not a rewind.
    static let rewindTolerance: Double = 0.5

    /// Why the request must not be applied, or nil when it may be.
    static func refusal(
        persisted: PlaybackState?, positionSeconds: Double, durationSeconds: Double, observedAt: Date
    ) -> RemotePositionOutcome? {
        if persisted?.completed == true { return .completed }
        guard positionSeconds.isFinite, positionSeconds > 0, durationSeconds > 0,
              positionSeconds < durationSeconds - endMargin else { return .unusable }
        if let persisted, persisted.updatedAt.date >= observedAt { return .notNewer }
        return nil
    }

    /// The state to store. Moving forward keeps the session and its intent; moving backwards is
    /// an intentional rewind by the other device (W-INV-006), so it starts a new session with
    /// rewind intent. The state is stamped with the time the other device saved it, never
    /// later than now, so a repeat of the same request is `.notNewer`.
    static func state(
        persisted: PlaybackState?, request: RemotePositionRequest, deviceID: String, now: Date, newSessionID: () -> String
    ) throws -> PlaybackState {
        let stamp = Timestamp(min(request.observedAt, now))
        guard let persisted else {
            return try PlaybackState(
                itemID: request.itemID, revisionID: request.revisionID, sessionID: newSessionID(), sequence: 1,
                positionSeconds: request.positionSeconds, durationSeconds: request.durationSeconds, completed: false,
                intent: .progress, deviceID: deviceID, updatedAt: stamp)
        }
        let rewind = request.positionSeconds < persisted.positionSeconds - rewindTolerance
        return try PlaybackState(
            itemID: request.itemID, revisionID: request.revisionID,
            sessionID: rewind ? newSessionID() : persisted.sessionID,
            sequence: rewind ? 1 : max(1, persisted.sequence + 1),
            positionSeconds: request.positionSeconds, durationSeconds: persisted.durationSeconds, completed: false,
            intent: rewind ? .rewind : persisted.intent, deviceID: deviceID,
            encodedCloudKitRecordSystemFields: persisted.encodedCloudKitRecordSystemFields, updatedAt: stamp)
    }
}
