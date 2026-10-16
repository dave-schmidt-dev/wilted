import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// The version of the local producer schema.  CloudKit mirroring is deliberately
/// not configured here; this store is the producer's local source of truth.
public enum LocalLibrarySchemaVersion: Int, Codable, Sendable {
    case v1 = 1
    case v2 = 2
    case v3 = 3
    case v4 = 4
    case v5 = 5
    case v6 = 6
    case v7 = 7
    case v8 = 8
    case v9 = 9
    case v10 = 10
    case v11 = 11
    case v12 = 12
    case v13 = 13
    case v14 = 14
    case v15 = 15
    case v16 = 16
    case v17 = 17
    case v18 = 18
    case v19 = 19
    case v20 = 20

    public static let current: LocalLibrarySchemaVersion = .v20
}

/// Positive equivalence requires the owner's confirmation of these exact two
/// source IDs in this feed. This is a provenance assertion by an authorized
/// caller, never a constructor for guessed publisher/title/hash evidence.
public struct PodcastEpisodePairConfirmation: Codable, Equatable, Sendable {
    public let confirmationID: UUID
    public let feedID: ItemID
    public let first: ItemID
    public let second: ItemID
    public let confirmedAt: Timestamp

    public init(confirmationID: UUID, feedID: ItemID, first: ItemID, second: ItemID,
                confirmedAt: Timestamp) {
        self.confirmationID = confirmationID
        self.feedID = feedID
        self.first = first
        self.second = second
        self.confirmedAt = confirmedAt
    }
}

public enum PodcastEpisodeAssociationError: Error, Equatable, Sendable {
    case invalidPair
    case crossFeed
    case episodeUnavailable
    case overlappingAssociation
    case stalePreview
    case staleVersion
    case conflictingOwnerState
    case confirmationAlreadyUsed
    case corruptAssociation
}

/// The stable representative is a display identity, never a replacement media
/// or revision key. Reversed records remain available as association history.
public struct PodcastEpisodeAssociation: Codable, Equatable, Sendable {
    public let associationID: UUID
    public let feedID: ItemID
    public let representativeID: ItemID
    public let memberIDs: [ItemID]
    public let confirmation: PodcastEpisodePairConfirmation
    public let version: Int
    public let isActive: Bool
    public let createdAt: Timestamp
    public let reversedAt: Timestamp?
}

/// Side-effect-free evidence about one member of an unconfirmed candidate pair.
///
/// Comparison is discovery, never consent: the evidence carries identities,
/// content hashes and prepared revision identities so an owner can judge the
/// pair, and deliberately carries no media path.
public struct PodcastEpisodeAssociationComparisonMember: Equatable, Sendable {
    public let episodeID: ItemID
    public let feedID: ItemID
    public let rssGUID: String?
    public let title: String
    public let publishedAt: Timestamp?
    public let durationSeconds: Double?
    /// The completed original download's verified content hash, when one exists.
    public let originalMediaContentHash: String?
    /// The newest ready revision, when preparation produced one.
    public let preparedRevisionID: RevisionID?
    public let playbackPositionSeconds: Double?
    public let playbackCompleted: Bool
    public let listeningCompletedAt: Timestamp?
    public let decision: EpisodeDecision?
    public let decisionSource: EpisodeDecisionSource?
    public let decidedAt: Timestamp?
    /// The raw queue slot this member holds, if any; association never moves it.
    public let queuePosition: Int?
    public let isQueueCurrent: Bool
    public let isRemoved: Bool
}

/// One explicitly named same-feed pair's unconfirmed comparison evidence.
///
/// The store produces this read-only: it writes nothing, creates no
/// `PodcastEpisodePairConfirmation`, and refuses unavailable or cross-feed
/// IDs. Hints about other candidates and existing associations are for the
/// owner to see, never to apply: only an explicit pair and representative,
/// then the owner's confirmation, proceed.
public struct PodcastEpisodeAssociationComparison: Equatable, Sendable {
    public enum Ambiguity: String, Equatable, Hashable, Sendable {
        /// Title, publication date and duration do not all match.
        case metadataDiffers
        /// Other same-feed episodes share the pair's metadata.
        case otherMetadataCandidates
        /// Episodes in other feeds share a member's publisher GUID.
        case crossFeedGUIDCandidate
        /// A member already belongs to an active association.
        case existingAssociation
        /// Newest manual choices on the two IDs conflict.
        case conflictingManualChoices
    }

    public let feedID: ItemID
    public let first: PodcastEpisodeAssociationComparisonMember
    public let second: PodcastEpisodeAssociationComparisonMember
    /// Whether the pair matches on title, publication date and duration.
    public let sharesMetadata: Bool
    /// Same-feed episodes besides the pair that match either member's metadata.
    public let otherCandidateIDs: [ItemID]
    /// Episodes in other feeds sharing a member's publisher GUID. Never a
    /// same-feed pair: only an exact same-feed pair can be confirmed.
    public let crossFeedSameGUIDCandidateIDs: [ItemID]
    /// Active associations already naming a member; preview and apply refuse these.
    public let existingAssociationIDs: [UUID]
    public let ambiguities: [Ambiguity]
    /// The pair's logical state as if associated; read-only evidence only.
    public let resolvedState: PodcastEpisodeLogicalState
}

/// What applying the captured preview means, derived from the same member
/// state `applyEpisodeAssociation` validates.
///
/// Preserved raw facts and the logical Larder projection are deliberately
/// separate: members keep their stored rows and queue slots, while the Larder
/// folds the members into one row under the representative and hides the
/// group entirely once it is terminal. The eligibility fields cover only the
/// association guards evaluated here, never every admission or download
/// prerequisite.
public struct PodcastEpisodeAssociationApprovalConsequences: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let episodeID: ItemID
        /// Raw fact: the stored row is still on the shelf (neither retired
        /// nor dismissed). It does not by itself decide the Larder row.
        public let retainsRawRow: Bool
        public let hasDownloadRecord: Bool
        /// Whether an untouched download claim would pass the group's
        /// terminal guard. An existing download record is reported separately
        /// and is not part of this evaluation.
        public let canClaimDownload: Bool
        /// The raw queue slot retained for this member, if any.
        public let queuePosition: Int?
        public let isQueueCurrent: Bool
    }

    public let representativeID: ItemID
    public let memberIDs: [ItemID]
    public let members: [Member]
    /// The newest manual choice the group would show, Keep winning equal ties.
    public let winningDecision: EpisodeDecision?
    public let manualDecidedAt: Timestamp?
    public let hasConflictingManualChoices: Bool
    public let isTerminal: Bool
    /// The logical Larder projection: one row under the representative while
    /// the group is not terminal and at least one stored member remains.
    /// Terminal groups are hidden from the Larder entirely.
    public let isLarderRowVisible: Bool
    /// Covers only the terminal-association admission guard; every other
    /// admission prerequisite stays authoritative and unevaluated here.
    public let isAdmissionEligible: Bool
    /// Covers only the terminal-association guard on an untouched claim.
    public let isDownloadEligible: Bool
    public let hasQueueSlot: Bool
}

/// What reversing the captured association means per member. Reversal never
/// copies a manual choice onto a member and never changes automation
/// semantics: a member without a manual choice of its own simply stops
/// inheriting the group's, and a member whose own choice is overridden by a
/// newer group choice keeps only its raw choice.
public struct PodcastEpisodeAssociationReversalConsequences: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let episodeID: ItemID
        /// This member's own raw manual choice, when it made one.
        public let ownManualDecision: EpisodeDecision?
        /// The captured group's newest manual choice, whoever made it: the
        /// value a member shows today when it has no own choice, or when the
        /// group's choice is newer than its own opposing one.
        public let resolvedManualDecision: EpisodeDecision?
        /// A newer (or equal-time, Keep-winning) group choice overrides this
        /// member's own opposing manual choice: reversal keeps the raw choice
        /// and drops the resolved override. The raw choice still protects the
        /// member from automatic decisions.
        public let losesNewerResolvedOverride: Bool
        /// A group Keep this member does not itself hold: reversal leaves it
        /// exposed to later feed automation, which may retire it and delete
        /// unprotected media.
        public let losesInheritedProtection: Bool
        /// A group Skip this member does not itself hold: reversal lifts the
        /// inherited suppression.
        public let losesInheritedSuppression: Bool
        public let hasDownloadRecord: Bool
        public let isRemoved: Bool
    }

    public let associationID: UUID
    public let memberIDs: [ItemID]
    public let members: [Member]
    /// True when any member loses inherited protection and the owner must be
    /// warned before confirming.
    public let warnsAutomationMayRetire: Bool
}

/// A store-produced preview cannot be manufactured by an external caller.
/// Captured state is checked again inside the actor immediately before save.
public struct PodcastEpisodeAssociationPreview: Sendable {
    public let confirmation: PodcastEpisodePairConfirmation
    public let representativeID: ItemID
    public let resolvedState: PodcastEpisodeLogicalState
    /// Derived from the same captured member state `applyEpisodeAssociation`
    /// validates, so the reviewed consequences cannot drift from what applies.
    public let approvalConsequences: PodcastEpisodeAssociationApprovalConsequences
    let capturedMembers: Data
    let capturedAssociations: Data
}

/// Fresh reversal leaves current raw state in place, including newer progress.
public struct PodcastEpisodeAssociationReversalPreview: Sendable {
    public let associationID: UUID
    public let expectedVersion: Int
    /// Per-member inherited-protection loss, derived from the same captured
    /// member state `reverseEpisodeAssociation` validates.
    public let consequences: PodcastEpisodeAssociationReversalConsequences
    let capturedMembers: Data
    let capturedAssociations: Data
}

/// Raw backing members remain independently addressable. Equal-time conflicting
/// choices preserve Keep and expose the ambiguity for a caller to display.
public struct PodcastEpisodeLogicalState: Equatable, Sendable {
    public let representativeID: ItemID
    public let memberIDs: [ItemID]
    public let manualDecision: EpisodeDecision?
    public let manualDecidedAt: Timestamp?
    public let isTerminal: Bool
    public let hasConflictingManualChoices: Bool
}

/// Callers can refuse stale intent effects before changing lifecycle or media.
public enum PodcastEpisodeDecisionWriteResult: Equatable, Sendable {
    case applied
    case superseded
}

/// The local ownership state used by generation-based remote reconciliation.
public enum LocalLibrarySyncStatus: String, Codable, Sendable {
    case remoteAcknowledged
    case localOnly
    case pendingUpload
    case conflicted
    case failedUpload
}

/// Opaque CKSyncEngine state and the timestamps of the last successful operations.
public struct LocalLibrarySyncState: Codable, Equatable, Sendable {
    public let key: String
    public let engineState: Data
    public let lastFetchAt: Timestamp?
    public let lastSendAt: Timestamp?

    public init(key: String, engineState: Data = Data(), lastFetchAt: Timestamp? = nil, lastSendAt: Timestamp? = nil) {
        self.key = key
        self.engineState = engineState
        self.lastFetchAt = lastFetchAt
        self.lastSendAt = lastSendAt
    }
}

/// A durable local deletion request. It remains until the remote deletion is acknowledged.
public struct LocalLibraryTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: ItemID
    public let generationID: String?
    public let requestedAt: Timestamp
    public let remoteAcknowledged: Bool

    public init(id: String, itemID: ItemID, generationID: String? = nil, requestedAt: Timestamp,
                remoteAcknowledged: Bool = false) {
        self.id = id
        self.itemID = itemID
        self.generationID = generationID
        self.requestedAt = requestedAt
        self.remoteAcknowledged = remoteAcknowledged
    }
}

/// Opaque system fields and change tag needed for an optimistic playback save/delete.
public struct PlaybackSystemFieldsSidecar: Codable, Equatable, Sendable {
    public let encodedSystemFields: Data?
    public let changeTag: String?

    public init(encodedSystemFields: Data? = nil, changeTag: String? = nil) {
        self.encodedSystemFields = encodedSystemFields
        self.changeTag = changeTag
    }
}

/// The deterministic result of finalizing one full-zone fetch generation.
public struct LocalLibrarySnapshotResult: Equatable, Sendable {
    public let generationID: String
    public let deletedItemIDs: [ItemID]
    public let retainedItemIDs: [ItemID]
    public let mutated: Bool

    public init(generationID: String, deletedItemIDs: [ItemID], retainedItemIDs: [ItemID], mutated: Bool) {
        self.generationID = generationID
        self.deletedItemIDs = deletedItemIDs
        self.retainedItemIDs = retainedItemIDs
        self.mutated = mutated
    }
}

/// One validated sync transaction applied to the local SwiftData source of truth.
public struct LocalLibrarySyncCommit: Sendable {
    /// A decoded item and its ownership status to apply in the transaction.
    public struct ArticleApply: Sendable {
        public let article: Article
        public let status: LocalLibrarySyncStatus

        public init(article: Article, status: LocalLibrarySyncStatus) {
            self.article = article; self.status = status
        }
    }

    /// A decoded revision backed by already validated local media.
    public struct RevisionApply: Sendable {
        public let revision: AudioRevision
        public let mediaURL: URL

        public init(revision: AudioRevision, mediaURL: URL) {
            self.revision = revision; self.mediaURL = mediaURL
        }
    }

    /// A decoded playback state and its opaque CloudKit sidecar.
    public struct PlaybackApply: Sendable {
        public let state: PlaybackState
        public let sidecar: PlaybackSystemFieldsSidecar

        public init(state: PlaybackState, sidecar: PlaybackSystemFieldsSidecar) {
            self.state = state; self.sidecar = sidecar
        }
    }

    /// A decoded transcript bound to an existing immutable revision identity.
    public struct TranscriptApply: Sendable {
        public let transcript: Transcript

        public init(transcript: Transcript) {
            self.transcript = transcript
        }
    }

    /// A status-only update for an existing item, used by send outcomes.
    public struct StatusApply: Sendable {
        public let recordID: WiltedRecordID
        public let status: LocalLibrarySyncStatus

        public init(recordID: WiltedRecordID, status: LocalLibrarySyncStatus) {
            self.recordID = recordID; self.status = status
        }
    }

    public let state: SyncRepositoryState
    public let articles: [ArticleApply]
    public let revisions: [RevisionApply]
    public let transcripts: [TranscriptApply]
    public let playbacks: [PlaybackApply]
    public let statusUpdates: [StatusApply]
    public let deletions: [WiltedRecordID]
    public let lastFetchAt: Timestamp?
    public let lastSendAt: Timestamp?

    public init(state: SyncRepositoryState, articles: [ArticleApply] = [], revisions: [RevisionApply] = [],
                transcripts: [TranscriptApply] = [],
                playbacks: [PlaybackApply] = [], statusUpdates: [StatusApply] = [], deletions: [WiltedRecordID] = [],
                lastFetchAt: Timestamp? = nil, lastSendAt: Timestamp? = nil) {
        self.state = state; self.articles = articles; self.revisions = revisions; self.transcripts = transcripts
        self.playbacks = playbacks; self.statusUpdates = statusUpdates; self.deletions = deletions
        self.lastFetchAt = lastFetchAt; self.lastSendAt = lastSendAt
    }
}

/// Where an immutable-revision violation was detected.
///
/// Seven call sites raise the same invariant failure, and without this a
/// reproduction can only say "some identity mismatch", never which write was
/// refused. The raw values are stable names for diagnostics; nothing persists
/// them.
public enum ImmutableRevisionSite: String, CaseIterable, Equatable, Sendable {
    /// `saveReadyRevision(_:mediaURL:)` found an existing record that differs.
    case readyRevision
    /// `saveReadyRevision(_:mediaURL:transcript:)` found an existing record that differs.
    case readyRevisionWithTranscript
    /// `saveReadyRevision(_:mediaURL:transcript:outcome:)` found an existing record that differs.
    case readyRevisionWithOutcome
    /// `applySyncCommit(_:)` tried to write a revision identity the store holds differently.
    case syncCommit
    /// `finalizePodcastDownload(revision:mediaURL:download:)` found an existing record that differs.
    case finalizedDownload
    /// `replaceReadyRevision` was asked to supersede the revision it is writing.
    case replacementSupersedesItself
    /// `replaceReadyRevision` found an existing record for the new revision that differs.
    case replacement
}

public enum LocalLibraryStoreError: Error, Equatable, Sendable {
    case immutableRevision(RevisionID, site: ImmutableRevisionSite)
    case revisionBelongsToDifferentItem
    case invalidPreparationStatus(String)
    case invalidPodcastState(String)
    case migrationPreflightFailed(String)
    case invalidWorkTicketTransition(from: String, to: String)
    case invalidFeedAutomationPolicy(String)
    /// The on-disk store matches no schema this build knows -- typically a
    /// newer build's store. Nothing was written, checkpointed or copied.
    case incompatibleStoreVersion(String)
    /// `migrate: false` was asked to open a store that needs a migration.
    /// Nothing was written.
    case migrationRequired(fromVersion: Int)
    /// A forward migration failed after the backup was taken; the original
    /// files were restored from `backupURL`, which is retained.
    case migrationFailedRestored(backupURL: URL, reason: String)
    /// A forward migration failed and restoring the original also failed.
    /// The retained backup at `backupURL` is intact; see
    /// docs/statistics-migration-recovery.md for the manual restore.
    case migrationRestoreFailed(backupURL: URL, reason: String)
    /// Only one summary rebuild runs at a time.
    case statisticsRebuildInProgress
}

/// One progress report from `rebuildLifetimeStatisticsSummary`.
public struct LifetimeStatisticsRebuildProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case measuredLedger
        case legacyLedger
        case published
    }

    public let phase: Phase
    /// Ledger rows read so far, across both ledgers.
    public let processedEvents: Int
    /// Ledger rows counted when the rebuild started. Rows appended during the
    /// rebuild can make `processedEvents` exceed it.
    public let totalEvents: Int

    public init(phase: Phase, processedEvents: Int, totalEvents: Int) {
        self.phase = phase; self.processedEvents = processedEvents; self.totalEvents = totalEvents
    }
}

/// The media files writers own before any record names them.
///
/// A download's staging file, a synthesis candidate, and an assembler's
/// temporary file all exist on disk while the store still has no revision for
/// them. The reclaim audit consults this registry, so a sweep can only delete
/// files that no writer holds and no record names.
public final class MediaInFlightRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    public init() {}

    public func begin(_ url: URL) { lock.withLock { _ = paths.insert(url.standardizedFileURL.path) } }
    public func end(_ url: URL) { lock.withLock { _ = paths.remove(url.standardizedFileURL.path) } }
    public func isInFlight(_ url: URL) -> Bool { lock.withLock { paths.contains(url.standardizedFileURL.path) } }
    public var inFlightPaths: Set<String> { lock.withLock { paths } }
}
