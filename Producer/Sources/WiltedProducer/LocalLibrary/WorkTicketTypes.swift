import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// What kind of background work a `WorkTicket` tracks.
public enum WorkTicketKind: String, Codable, Equatable, Sendable, CaseIterable {
    case podcastDownload
    case podcastPreparation
    case articlePreparation
}

/// A ticket's lifecycle. `isTerminal` covers the three states a ticket
/// cannot leave once reached. A subsequent request re-admits the same durable
/// row with a newer request sequence; it does not transition this attempt
/// backward.
public enum WorkTicketState: String, Codable, Equatable, Sendable {
    case pending
    case deferred
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .pending, .deferred, .running: return false
        }
    }

    /// This state's tier in the ticket's forward lifecycle: admitted (0),
    /// running (1), terminal (2). Two writers racing to record the same
    /// subject's transitions (e.g. `registerPreparationRequest`'s `.pending`
    /// and `consumePreparationRequest`'s `.running`, dispatched from separate
    /// `Task`s with no ordering guarantee between them) must not let
    /// whichever call happens to land second drag the ticket backward.
    private var tier: Int {
        switch self {
        case .pending, .deferred: return 0
        case .running: return 1
        case .succeeded, .failed, .cancelled: return 2
        }
    }

    /// Whether a ticket may move from `self` to `next`. Same-state writes are
    /// always a no-op-safe idempotent duplicate. Otherwise a transition is
    /// only legal if it does not move the ticket to an earlier tier than the
    /// one it already occupies -- a terminal ticket (tier 2) never leaves,
    /// and a `.running` ticket (tier 1) cannot be dragged back to `.pending`
    /// or `.deferred` (tier 0) by a late-arriving admission write.
    public func canTransition(to next: WorkTicketState) -> Bool {
        if next == self { return true }
        return next.tier >= tier
    }
}

/// One durable request for background work -- a podcast download, podcast
/// preparation, or article preparation -- keyed by kind and subject so a
/// retry or relaunch finds the existing ticket instead of issuing a
/// duplicate. `requestSequence` orders tickets across kinds by intake order
/// and identifies the current attempt in the one durable row for this kind
/// and subject.
public struct WorkTicket: Codable, Equatable, Sendable {
    public let kind: WorkTicketKind
    public let subjectID: String
    public var resolvedItemID: String?
    public var requestSequence: Int
    public var state: WorkTicketState
    public var attemptCount: Int
    public var failureKind: String?
    public var lastFailureMessage: String?
    public var nextEligibleAt: Timestamp?
    public var policySnapshot: Data?
    public var processingPolicy: Data?
    public var runID: String?
    public var requestedAt: Timestamp
    public var updatedAt: Timestamp

    /// `"<kind>|<subjectID>"`, matching the persisted record's unique key.
    public var id: String { "\(kind.rawValue)|\(subjectID)" }

    public init(kind: WorkTicketKind, subjectID: String, resolvedItemID: String? = nil,
                requestSequence: Int, state: WorkTicketState = .pending, attemptCount: Int = 0,
                failureKind: String? = nil, lastFailureMessage: String? = nil,
                nextEligibleAt: Timestamp? = nil, policySnapshot: Data? = nil,
                processingPolicy: Data? = nil, runID: String? = nil,
                requestedAt: Timestamp, updatedAt: Timestamp) {
        self.kind = kind; self.subjectID = subjectID; self.resolvedItemID = resolvedItemID
        self.requestSequence = requestSequence; self.state = state; self.attemptCount = attemptCount
        self.failureKind = failureKind; self.lastFailureMessage = lastFailureMessage
        self.nextEligibleAt = nextEligibleAt; self.policySnapshot = policySnapshot
        self.processingPolicy = processingPolicy; self.runID = runID
        self.requestedAt = requestedAt; self.updatedAt = updatedAt
    }
}

/// Named reasons `reconcileWorkTickets` can fail a ticket outright, distinct
/// from `PodcastDownloadFailureKind`: that vocabulary classifies why a
/// download's bytes stopped; this one names why reconciliation itself gave
/// up on a ticket rather than retrying it.
public enum WorkTicketFailure: String, Codable, Equatable, Sendable {
    case interrupted
}

/// One preferences-held deferred automatic preparation, translated into the
/// store's vocabulary by the caller before it crosses into the actor.
/// `policySnapshot`/`processingPolicy` are pre-encoded because their source
/// types (`WiltedAutomationProcessingPolicy`, and whatever the caller pairs
/// with `PodcastPreparationPolicySnapshot`) are not something this package
/// -- or, for the former, any package below the app target -- necessarily
/// knows how to decode; `WorkTicket` already carries both fields as opaque
/// `Data`, so reconciliation only needs to carry them the same way.
public struct WorkTicketImportedDeferral: Sendable {
    public let subjectID: String
    public let policySnapshot: Data?
    public let processingPolicy: Data?

    public init(subjectID: String, policySnapshot: Data? = nil, processingPolicy: Data? = nil) {
        self.subjectID = subjectID
        self.policySnapshot = policySnapshot
        self.processingPolicy = processingPolicy
    }
}

/// What one `reconcileWorkTickets` pass did, so a caller (and a test) can
/// see the counts without re-deriving them from a full `workTickets()` diff.
public struct WorkTicketReconciliation: Equatable, Sendable {
    public let importedDeferralCount: Int
    public let adoptedDownloadCount: Int
    public let closedRunCount: Int
    public let collapsedDuplicateCount: Int
    public let prunedCount: Int

    public init(
        importedDeferralCount: Int, adoptedDownloadCount: Int, closedRunCount: Int,
        collapsedDuplicateCount: Int = 0, prunedCount: Int
    ) {
        self.importedDeferralCount = importedDeferralCount
        self.adoptedDownloadCount = adoptedDownloadCount
        self.closedRunCount = closedRunCount
        self.collapsedDuplicateCount = collapsedDuplicateCount
        self.prunedCount = prunedCount
    }
}

/// What one `reconcileEpisodeRemovals` pass did, so a caller (and a test) can
/// tell a real migration from a no-op rerun.
public struct EpisodeRemovalReconciliation: Equatable, Sendable {
    /// Pre-V13 rows with `retiredAt` set now also carry `removalKind = .retired`.
    public let backfilledRetirementCount: Int
    /// Dismissal tombstones folded onto an episode row (existing or placeholder)
    /// and then deleted.
    public let convertedDismissalCount: Int
}
