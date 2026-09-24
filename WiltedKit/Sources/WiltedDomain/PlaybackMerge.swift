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

    // An explicit rewind or restart names the whole causal session, rather than
    // only the transition that created it. Older peers can still send ordinary
    // progress for that session, but a different explicit intent must establish
    // its own session.
    let incomingContinuesSession = incoming.intent == .progress
        || (current.intent != .progress && incoming.intent == current.intent)
    guard incomingContinuesSession else { return reject(.explicitIntentRequiresNewSession) }
    guard changeTagMatches else { return reject(.staleChangeTag) }
    guard incoming.sequence > current.sequence else { return reject(.staleSequence) }
    guard incoming.positionSeconds >= current.positionSeconds else { return reject(.backwardProgress) }
    guard !current.completed || incoming.completed else { return reject(.completionCannotBeReversed) }
    return accept(.forwardProgress)
}
