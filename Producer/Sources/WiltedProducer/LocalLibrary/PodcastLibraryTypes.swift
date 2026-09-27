import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

public enum PodcastDownloadStatus: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
}

public struct PodcastSubscription: Codable, Equatable, Sendable {
    public let feedID: ItemID
    public let subscribedAt: Timestamp
    public let enabled: Bool

    public init(feedID: ItemID, subscribedAt: Timestamp, enabled: Bool = true) {
        self.feedID = feedID; self.subscribedAt = subscribedAt; self.enabled = enabled
    }
}

/// How a terminal download failure should be treated by automatic retry.
/// Classification itself is Phase 3's job; Phase 2 only carries the column.
public enum PodcastDownloadFailureKind: String, Codable, Equatable, Sendable {
    case retryable
    case terminal
}

public struct PodcastDownload: Codable, Equatable, Sendable {
    public let episodeID: ItemID
    public let status: PodcastDownloadStatus
    public let bytesReceived: Int64
    public let expectedByteCount: Int64?
    public let localURL: URL?
    public let contentHash: String?
    public let updatedAt: Timestamp
    public let failureKind: PodcastDownloadFailureKind?

    public var itemID: ItemID { episodeID }

    public init(episodeID: ItemID, status: PodcastDownloadStatus = .queued,
                bytesReceived: Int64 = 0, expectedByteCount: Int64? = nil,
                localURL: URL? = nil, contentHash: String? = nil, updatedAt: Timestamp,
                failureKind: PodcastDownloadFailureKind? = nil) throws {
        guard bytesReceived >= 0, expectedByteCount == nil || expectedByteCount! > 0 else {
            throw LocalLibraryStoreError.invalidPodcastState("download byte counts")
        }
        if let expectedByteCount, bytesReceived > expectedByteCount {
            throw LocalLibraryStoreError.invalidPodcastState("download exceeds expected byte count")
        }
        if let contentHash, contentHash.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            throw LocalLibraryStoreError.invalidPodcastState("download content hash")
        }
        if status == .completed && (localURL == nil || contentHash == nil) {
            throw LocalLibraryStoreError.invalidPodcastState("completed download requires local media and content hash")
        }
        self.episodeID = episodeID; self.status = status; self.bytesReceived = bytesReceived
        self.expectedByteCount = expectedByteCount; self.localURL = localURL
        self.contentHash = contentHash; self.updatedAt = updatedAt; self.failureKind = failureKind
    }
}

/// Whether a preparation outcome's artifact still matches what the current
/// pipeline would produce. Phase 2 only carries this column: every backfilled
/// and newly-written row defaults to `.current` unless an explicit
/// invalidation rule (Phase 7) says otherwise.
public enum PodcastPreparationEligibility: String, Codable, Equatable, Sendable {
    case current
    case eligible
    case invalid
}

/// What an episode's prior preparation is compared against when deciding
/// whether a `PodcastPreparationInvalidationRule` condemns it.
public struct PodcastPreparationInvalidationSubject: Sendable {
    public let episodeID: ItemID
    public let semanticVersion: String?
    public let pipelineFingerprint: String?

    public init(episodeID: ItemID, semanticVersion: String?, pipelineFingerprint: String?) {
        self.episodeID = episodeID; self.semanticVersion = semanticVersion
        self.pipelineFingerprint = pipelineFingerprint
    }
}

/// What happens to an episode whose preparation a rule condemns.
public enum PodcastPreparationInvalidationConsequence: Sendable {
    /// Re-run preparation against the existing source; still escalates to a
    /// forced redownload on its own if the source bytes no longer match what
    /// preparation used, or if preparation replaced the source outright.
    case resetPreparation
    /// Re-fetch the source before preparing again, regardless of whether the
    /// local bytes still check out.
    case forceRedownload
}

/// One named, injectable reason a prior preparation should no longer be
/// trusted. The production table starts empty (`PodcastPreparationPipeline
/// .invalidationRules`) so that a bare fingerprint drift -- the pipeline's
/// hash changing for a reason that does not affect existing output, such as
/// a comment or log-message edit -- invalidates nothing until a rule says it
/// actually matters.
public struct PodcastPreparationInvalidationRule: Sendable {
    public let id: String
    public let consequence: PodcastPreparationInvalidationConsequence
    public let applies: @Sendable (PodcastPreparationInvalidationSubject) -> Bool

    public init(id: String, consequence: PodcastPreparationInvalidationConsequence,
                applies: @escaping @Sendable (PodcastPreparationInvalidationSubject) -> Bool) {
        self.id = id; self.consequence = consequence; self.applies = applies
    }
}

/// One durable proof that preparation produced a playable artifact for one
/// revision. Keyed by `(episodeID, revisionID)` rather than by episode alone:
/// preparation replaces the revision, and a superseded revision's outcome is
/// retained as history rather than overwritten.
public struct PodcastPreparationOutcome: Codable, Equatable, Sendable {
    public let episodeID: ItemID
    public let revisionID: RevisionID
    public let policyDigest: String
    public let pipelineFingerprint: String?
    public let semanticVersion: String
    public let producedAt: Timestamp
    public let eligibility: PodcastPreparationEligibility
    public let invalidationRuleID: String?

    public init(episodeID: ItemID, revisionID: RevisionID, policyDigest: String,
                pipelineFingerprint: String?, semanticVersion: String, producedAt: Timestamp,
                eligibility: PodcastPreparationEligibility = .current, invalidationRuleID: String? = nil) {
        self.episodeID = episodeID; self.revisionID = revisionID; self.policyDigest = policyDigest
        self.pipelineFingerprint = pipelineFingerprint; self.semanticVersion = semanticVersion
        self.producedAt = producedAt; self.eligibility = eligibility; self.invalidationRuleID = invalidationRuleID
    }

    public var id: String { "\(episodeID.rawValue)|\(revisionID.rawValue)" }
}

/// One durable "the listener reached the end" fact. Item-scoped rather than
/// revision-scoped, because both `replaceReadyRevision` and
/// `dismissPodcastEpisode` delete revision-scoped rows and completion must
/// outlive both. Named `PodcastListeningState`, not `PodcastListeningRecord`
/// -- that name is reserved for the `@Model` SwiftData class describing the
/// same dimension, exactly as `PodcastDownload`/`PodcastDownloadRecord` are
/// already two names for one dimension elsewhere in this file.
public struct PodcastListeningState: Codable, Equatable, Sendable {
    public let episodeID: ItemID
    public let completedAt: Timestamp?
    public let lastRevisionID: RevisionID?
    public let updatedAt: Timestamp

    public init(episodeID: ItemID, completedAt: Timestamp?, lastRevisionID: RevisionID?, updatedAt: Timestamp) {
        self.episodeID = episodeID; self.completedAt = completedAt
        self.lastRevisionID = lastRevisionID; self.updatedAt = updatedAt
    }
}

public struct PodcastArtwork: Codable, Equatable, Sendable {
    public let id: String
    public let ownerID: ItemID
    public let remoteURL: URL?
    public let localURL: URL?
    public let contentHash: String?
    public let byteCount: Int64?
    public let updatedAt: Timestamp

    public var itemID: ItemID { ownerID }

    public init(id: String, ownerID: ItemID, remoteURL: URL? = nil, localURL: URL? = nil,
                contentHash: String? = nil, byteCount: Int64? = nil, updatedAt: Timestamp) throws {
        guard !id.isEmpty, id.utf8.count <= 256, byteCount == nil || byteCount! > 0 else {
            throw LocalLibraryStoreError.invalidPodcastState("artwork metadata")
        }
        if let contentHash, contentHash.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            throw LocalLibraryStoreError.invalidPodcastState("artwork content hash")
        }
        self.id = id; self.ownerID = ownerID; self.remoteURL = remoteURL; self.localURL = localURL
        self.contentHash = contentHash; self.byteCount = byteCount; self.updatedAt = updatedAt
    }
}

public struct PodcastQueueEntry: Codable, Equatable, Sendable {
    public let episodeID: ItemID
    public let position: Int
    public let addedAt: Timestamp

    public var itemID: ItemID { episodeID }

    public init(episodeID: ItemID, position: Int, addedAt: Timestamp) throws {
        guard position >= 0 else { throw LocalLibraryStoreError.invalidPodcastState("queue position") }
        self.episodeID = episodeID; self.position = position; self.addedAt = addedAt
    }
}

public struct PodcastPlaybackSpeed: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let speed: Double
    public let updatedAt: Timestamp

    public init(itemID: ItemID, speed: Double, updatedAt: Timestamp) throws {
        guard speed.isFinite, speed >= 0.5, speed <= 2.0 else {
            throw LocalLibraryStoreError.invalidPodcastState("playback speed")
        }
        self.itemID = itemID; self.speed = speed; self.updatedAt = updatedAt
    }
}
