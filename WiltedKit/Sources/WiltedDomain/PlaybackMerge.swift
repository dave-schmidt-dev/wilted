import Foundation

public enum PlaybackMergeReason: String, Codable, Sendable {
    case forwardProgress
    case explicitIntentNewSession
    case staleOrdinaryProgressAcrossSessions
    case staleSequence
    case incompatibleItem
    case incompatibleRevision
    case explicitIntentRequiresNewSession
    case staleChangeTag
    case backwardProgress
    case completionCannotBeReversed
}

public struct PlaybackMergeResult: Equatable, Sendable {
    public enum Decision: String, Sendable { case accept, reject }
    public enum Winner: String, Sendable { case current, incoming }

    public let decision: Decision
    public let winner: Winner
    public let reason: PlaybackMergeReason
    public var acceptedStateIsIncoming: Bool { winner == .incoming }
}

/// Resolves playback causally. Timestamps never outrank session or sequence.
public func mergePlayback(
    current: PlaybackState,
    incoming: PlaybackState,
    changeTagMatches: Bool
) -> PlaybackMergeResult {
    func reject(_ reason: PlaybackMergeReason) -> PlaybackMergeResult {
        PlaybackMergeResult(decision: .reject, winner: .current, reason: reason)
    }
    func accept(_ reason: PlaybackMergeReason) -> PlaybackMergeResult {
        PlaybackMergeResult(decision: .accept, winner: .incoming, reason: reason)
    }

    guard current.itemID == incoming.itemID else { return reject(.incompatibleItem) }
    guard current.revisionID == incoming.revisionID else { return reject(.incompatibleRevision) }

    if current.sessionID != incoming.sessionID {
        guard incoming.intent == .rewind || incoming.intent == .restart else {
            return reject(.staleOrdinaryProgressAcrossSessions)
        }
        guard changeTagMatches else { return reject(.staleChangeTag) }
        return accept(.explicitIntentNewSession)
    }

    guard incoming.intent == .progress else { return reject(.explicitIntentRequiresNewSession) }
    guard changeTagMatches else { return reject(.staleChangeTag) }
    guard incoming.sequence > current.sequence else { return reject(.staleSequence) }
    guard incoming.positionSeconds >= current.positionSeconds else { return reject(.backwardProgress) }
    guard !current.completed || incoming.completed else { return reject(.completionCannotBeReversed) }
    return accept(.forwardProgress)
}
