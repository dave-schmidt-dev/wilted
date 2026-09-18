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

    public static let current: LocalLibrarySchemaVersion = .v12
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

/// What kind of background work a `WorkTicket` tracks.
public enum WorkTicketKind: String, Codable, Equatable, Sendable {
    case podcastDownload
    case podcastPreparation
    case articlePreparation
}

/// A ticket's lifecycle. `isTerminal` covers the three states a ticket
/// cannot leave once reached -- a fresh issue or retry always starts a new
/// ticket rather than reopening one of these.
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
}

/// One durable request for background work -- a podcast download, podcast
/// preparation, or article preparation -- keyed by kind and subject so a
/// retry or relaunch finds the existing ticket instead of issuing a
/// duplicate. `requestSequence` orders tickets across kinds by intake order
/// and is allocated by the store, never by the caller.
public struct WorkTicket: Codable, Equatable, Sendable {
    public let kind: WorkTicketKind
    public let subjectID: String
    public var resolvedItemID: String?
    public let requestSequence: Int
    public var state: WorkTicketState
    public var attemptCount: Int
    public var failureKind: String?
    public var lastFailureMessage: String?
    public var nextEligibleAt: Timestamp?
    public var policySnapshot: Data?
    public var processingPolicy: Data?
    public var runID: String?
    public let requestedAt: Timestamp
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

public struct LocalLibraryMigrationPreflight: Equatable, Sendable {
    public let sourceURL: URL
    public let retainedURL: URL
    public let retainedFiles: [URL]

    public init(sourceURL: URL, retainedURL: URL, retainedFiles: [URL]) {
        self.sourceURL = sourceURL; self.retainedURL = retainedURL; self.retainedFiles = retainedFiles
    }
}

public typealias PodcastFeedSubscription = PodcastSubscription
public typealias PodcastDownloadState = PodcastDownload
public typealias PodcastArtworkAsset = PodcastArtwork
public typealias UpNextEntry = PodcastQueueEntry
public typealias PodcastPlaybackRate = PodcastPlaybackSpeed

public struct StoredAudioRevision: Codable, Equatable, Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL

    public var itemID: ItemID { revision.itemID }
    public var revisionID: RevisionID { revision.revisionID }

    public init(revision: AudioRevision, mediaURL: URL) {
        self.revision = revision
        self.mediaURL = mediaURL
    }
}

/// A durable preparation status associated with one producer request.
public struct PreparationJournalEntry: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: ItemID
    public let requestID: String
    public let status: PreparationStatus

    public init(id: String, itemID: ItemID, requestID: String, status: PreparationStatus) {
        self.id = id
        self.itemID = itemID
        self.requestID = requestID
        self.status = status
    }
}

/// The result of reconciling podcast preparation attempts against the current
/// semantic pipeline. The store returns IDs rather than starting work so the
/// app can admit redownloads only after its library rows are loaded.
public struct PodcastPreparationInvalidationResult: Equatable, Sendable {
    public let resetEpisodeIDs: [ItemID]
    public let forcedRedownloadEpisodeIDs: [ItemID]

    public init(resetEpisodeIDs: [ItemID] = [], forcedRedownloadEpisodeIDs: [ItemID] = []) {
        self.resetEpisodeIDs = resetEpisodeIDs
        self.forcedRedownloadEpisodeIDs = forcedRedownloadEpisodeIDs
    }
}

/// Orders journal events without relying on SwiftData's undefined ordering for
/// rows emitted at the same instant. Event IDs carry a numeric ordinal when
/// they were written by the pipeline; legacy or externally-created IDs fall
/// back to their complete ID so their order is still stable.
private func preparationEntryPrecedes(_ lhs: PreparationJournalEntry, _ rhs: PreparationJournalEntry) -> Bool {
    if lhs.status.emittedAt.date != rhs.status.emittedAt.date {
        return lhs.status.emittedAt.date < rhs.status.emittedAt.date
    }

    let lhsOrdinal = preparationOrdinal(in: lhs.id)
    let rhsOrdinal = preparationOrdinal(in: rhs.id)
    switch (lhsOrdinal, rhsOrdinal) {
    case let (left?, right?) where left != right:
        return left < right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id < rhs.id
    }
}

private func preparationOrdinal(in id: String) -> Int? {
    guard let marker = id.lastIndex(of: "#") else { return nil }
    let suffix = id[id.index(after: marker)...]
    guard !suffix.isEmpty, let ordinal = Int(suffix), ordinal >= 1 else { return nil }
    return ordinal
}

/// One preparation attempt, summarised from its journal entries.
///
/// The journal records every status a run emitted, which is the right shape
/// for diagnosis and the wrong shape for a list: a single article produces a
/// dozen rows. This collapses a run to what a reader needs — what it was
/// working on, where it got to, and whether it finished.
public struct PreparationRunSummary: Equatable, Sendable, Identifiable {
    public let requestID: String
    public let itemID: ItemID
    public let startedAt: Timestamp
    public let updatedAt: Timestamp
    public let stage: PreparationStage
    public let detail: String
    public let fraction: Double?
    public let isTerminal: Bool
    public let outcome: PreparationOutcome?
    public let failure: ProducerError?
    /// Every status the run journalled, oldest first. The summary fields
    /// above describe where the run is; this is how it got there.
    public let entries: [PreparationJournalEntry]

    public var id: String { requestID }

    public init(
        requestID: String,
        itemID: ItemID,
        startedAt: Timestamp,
        updatedAt: Timestamp,
        stage: PreparationStage,
        detail: String,
        fraction: Double?,
        isTerminal: Bool,
        outcome: PreparationOutcome?,
        failure: ProducerError?,
        entries: [PreparationJournalEntry] = []
    ) {
        self.requestID = requestID
        self.itemID = itemID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.isTerminal = isTerminal
        self.outcome = outcome
        self.failure = failure
        self.entries = entries
    }
}

public struct LocalLibraryInspection: Equatable, Sendable {
    public let schemaVersion: LocalLibrarySchemaVersion
    public let articleCount: Int
    public let revisionCount: Int
    public let preparationCount: Int
    public let playbackCount: Int
    public let transcriptCount: Int
}

// Keep model names and property names stable: SwiftData's lightweight migration
// uses them as the persistent identity across schema versions.
//
// V1-V3 keep `isDeleted` because that is the column name those stores were
// written with. V5 renames it; see the note there for why.
private enum LocalLibrarySchemaV1Models {
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var source: String
        var author: String?
        var publishedTime: Date?
        var createdAt: Date
        var isDeleted: Bool
        var schemaVersion: Int

        init(_ article: Article, schemaVersion: Int = 1) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isDeleted = article.isDeleted; self.schemaVersion = schemaVersion
        }
    }

    @Model final class RevisionRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var durationSeconds: Double
        var byteCount: Int64
        var contentHash: String
        var mediaType: String
        var createdAt: Date
        var schemaVersion: Int

        init(_ revision: AudioRevision, schemaVersion: Int = 1) {
            id = revision.revisionID.rawValue; itemID = revision.itemID.rawValue
            durationSeconds = revision.durationSeconds; byteCount = revision.byteCount
            contentHash = revision.contentHash; mediaType = revision.mediaType
            createdAt = revision.createdAt.date; self.schemaVersion = schemaVersion
        }
    }

    @Model final class PreparationRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var requestID: String
        var statusData: Data
        var emittedAt: Date
        var schemaVersion: Int

        init(_ entry: PreparationJournalEntry, schemaVersion: Int = 1) throws {
            id = entry.id; itemID = entry.itemID.rawValue; requestID = entry.requestID
            statusData = try JSONEncoder().encode(entry.status); emittedAt = entry.status.emittedAt.date
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class PlaybackRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var revisionID: String
        var sessionID: String
        var sequence: Int64
        var positionSeconds: Double
        var durationSeconds: Double
        var completed: Bool
        var intent: String
        var deviceID: String
        var encodedCloudKitRecordSystemFields: Data?
        var updatedAt: Date
        var schemaVersion: Int

        init(_ state: PlaybackState, schemaVersion: Int = 1) {
            id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
            itemID = state.itemID.rawValue; revisionID = state.revisionID.rawValue
            sessionID = state.sessionID; sequence = state.sequence
            positionSeconds = state.positionSeconds; durationSeconds = state.durationSeconds
            completed = state.completed; intent = state.intent.rawValue; deviceID = state.deviceID
            encodedCloudKitRecordSystemFields = state.encodedCloudKitRecordSystemFields
            updatedAt = state.updatedAt.date; self.schemaVersion = schemaVersion
        }
    }
}

private enum LocalLibrarySchemaV2Models {
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var source: String
        var author: String?
        var publishedTime: Date?
        var createdAt: Date
        var isDeleted: Bool
        var schemaVersion: Int

        init(_ article: Article, schemaVersion: Int = 2) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isDeleted = article.isDeleted; self.schemaVersion = schemaVersion
        }
    }

    @Model final class RevisionRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var durationSeconds: Double
        var byteCount: Int64
        var contentHash: String
        var mediaType: String
        var mediaURL: String?
        var createdAt: Date
        var schemaVersion: Int

        init(_ revision: AudioRevision, mediaURL: URL, schemaVersion: Int = 2) {
            id = revision.revisionID.rawValue; itemID = revision.itemID.rawValue
            durationSeconds = revision.durationSeconds; byteCount = revision.byteCount
            contentHash = revision.contentHash; mediaType = revision.mediaType
            self.mediaURL = mediaURL.absoluteString; createdAt = revision.createdAt.date
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class PreparationRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var requestID: String
        var statusData: Data
        var emittedAt: Date
        var schemaVersion: Int

        init(_ entry: PreparationJournalEntry, schemaVersion: Int = 2) throws {
            id = entry.id; itemID = entry.itemID.rawValue; requestID = entry.requestID
            statusData = try JSONEncoder().encode(entry.status); emittedAt = entry.status.emittedAt.date
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class PlaybackRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var revisionID: String
        var sessionID: String
        var sequence: Int64
        var positionSeconds: Double
        var durationSeconds: Double
        var completed: Bool
        var intent: String
        var deviceID: String
        var encodedCloudKitRecordSystemFields: Data?
        var updatedAt: Date
        var schemaVersion: Int

        init(_ state: PlaybackState, schemaVersion: Int = 2) {
            id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
            itemID = state.itemID.rawValue; revisionID = state.revisionID.rawValue
            sessionID = state.sessionID; sequence = state.sequence
            positionSeconds = state.positionSeconds; durationSeconds = state.durationSeconds
            completed = state.completed; intent = state.intent.rawValue; deviceID = state.deviceID
            encodedCloudKitRecordSystemFields = state.encodedCloudKitRecordSystemFields
            updatedAt = state.updatedAt.date; self.schemaVersion = schemaVersion
        }
    }
}

internal enum LocalLibrarySchemaV3Models {
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var source: String
        var author: String?
        var publishedTime: Date?
        var createdAt: Date
        var isDeleted: Bool
        var syncStatus: String = LocalLibrarySyncStatus.localOnly.rawValue
        var schemaVersion: Int

        init(_ article: Article, schemaVersion: Int = 3) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isDeleted = article.isDeleted; syncStatus = LocalLibrarySyncStatus.localOnly.rawValue
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class RevisionRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var durationSeconds: Double
        var byteCount: Int64
        var contentHash: String
        var mediaType: String
        var mediaURL: String?
        var createdAt: Date
        var schemaVersion: Int

        init(_ revision: AudioRevision, mediaURL: URL, schemaVersion: Int = 3) {
            id = revision.revisionID.rawValue; itemID = revision.itemID.rawValue
            durationSeconds = revision.durationSeconds; byteCount = revision.byteCount
            contentHash = revision.contentHash; mediaType = revision.mediaType
            self.mediaURL = mediaURL.absoluteString; createdAt = revision.createdAt.date
            self.schemaVersion = schemaVersion
        }

        init(
            id: String,
            itemID: String,
            durationSeconds: Double = 42,
            byteCount: Int64 = 128,
            contentHash: String = "sha256:" + String(repeating: "a", count: 64),
            mediaType: String = "audio/mp4",
            mediaURL: String? = "file:///tmp/media.mp4",
            createdAt: Date = Date(),
            schemaVersion: Int = 3
        ) {
            self.id = id
            self.itemID = itemID
            self.durationSeconds = durationSeconds
            self.byteCount = byteCount
            self.contentHash = contentHash
            self.mediaType = mediaType
            self.mediaURL = mediaURL
            self.createdAt = createdAt
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class PreparationRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var requestID: String
        var statusData: Data
        var emittedAt: Date
        var schemaVersion: Int

        init(_ entry: PreparationJournalEntry, schemaVersion: Int = 3) throws {
            id = entry.id; itemID = entry.itemID.rawValue; requestID = entry.requestID
            statusData = try JSONEncoder().encode(entry.status); emittedAt = entry.status.emittedAt.date
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class PlaybackRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var revisionID: String
        var sessionID: String
        var sequence: Int64
        var positionSeconds: Double
        var durationSeconds: Double
        var completed: Bool
        var intent: String
        var deviceID: String
        var encodedCloudKitRecordSystemFields: Data?
        var encodedCloudKitRecordChangeTag: String?
        var updatedAt: Date
        var schemaVersion: Int

        init(_ state: PlaybackState, schemaVersion: Int = 3) {
            id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
            itemID = state.itemID.rawValue; revisionID = state.revisionID.rawValue
            sessionID = state.sessionID; sequence = state.sequence
            positionSeconds = state.positionSeconds; durationSeconds = state.durationSeconds
            completed = state.completed; intent = state.intent.rawValue; deviceID = state.deviceID
            encodedCloudKitRecordSystemFields = state.encodedCloudKitRecordSystemFields
            encodedCloudKitRecordChangeTag = nil
            updatedAt = state.updatedAt.date; self.schemaVersion = schemaVersion
        }
    }

    @Model final class SyncStateRecord {
        @Attribute(.unique) var key: String
        var engineState: Data = Data()
        var lastFetchAt: Date?
        var lastSendAt: Date?
        var schemaVersion: Int

        init(_ state: LocalLibrarySyncState, schemaVersion: Int = 3) {
            key = state.key; engineState = state.engineState
            lastFetchAt = state.lastFetchAt?.date; lastSendAt = state.lastSendAt?.date
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class TombstoneRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var generationID: String?
        var requestedAt: Date
        var remoteAcknowledged: Bool
        var schemaVersion: Int

        init(_ tombstone: LocalLibraryTombstone, schemaVersion: Int = 3) {
            id = tombstone.id; itemID = tombstone.itemID.rawValue; generationID = tombstone.generationID
            requestedAt = tombstone.requestedAt.date; remoteAcknowledged = tombstone.remoteAcknowledged
            self.schemaVersion = schemaVersion
        }
    }

    @Model final class RepositoryStateRecord {
        @Attribute(.unique) var key: String
        var stateData: Data
        var schemaVersion: Int

        init(stateData: Data, schemaVersion: Int = 3) {
            key = "private-zone"; self.stateData = stateData; self.schemaVersion = schemaVersion
        }
    }
}

private enum LocalLibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV1Models.ArticleRecord.self, LocalLibrarySchemaV1Models.RevisionRecord.self,
         LocalLibrarySchemaV1Models.PreparationRecord.self, LocalLibrarySchemaV1Models.PlaybackRecord.self]
    }
}

private enum LocalLibrarySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV2Models.ArticleRecord.self, LocalLibrarySchemaV2Models.RevisionRecord.self,
         LocalLibrarySchemaV2Models.PreparationRecord.self, LocalLibrarySchemaV2Models.PlaybackRecord.self]
    }
}

private enum LocalLibrarySchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV3Models.ArticleRecord.self, LocalLibrarySchemaV3Models.RevisionRecord.self,
         LocalLibrarySchemaV3Models.PreparationRecord.self, LocalLibrarySchemaV3Models.PlaybackRecord.self,
         LocalLibrarySchemaV3Models.SyncStateRecord.self, LocalLibrarySchemaV3Models.TombstoneRecord.self,
         LocalLibrarySchemaV3Models.RepositoryStateRecord.self]
    }
}

private enum LocalLibrarySchemaV4Models {
    @Model final class TranscriptRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var revisionID: String
        var availability: String
        var text: String?
        var format: String
        var languageCode: String?
        var updatedAt: Date
        var schemaVersion: Int

        init(_ transcript: Transcript) {
            id = "\(transcript.itemID.rawValue)|\(transcript.revisionID.rawValue)"
            itemID = transcript.itemID.rawValue
            revisionID = transcript.revisionID.rawValue
            availability = transcript.availability.rawValue
            text = transcript.text
            format = transcript.format.rawValue
            languageCode = transcript.languageCode
            updatedAt = transcript.updatedAt.date
            schemaVersion = transcript.schemaVersion
        }
    }
}

private enum LocalLibrarySchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV3.models + [LocalLibrarySchemaV4Models.TranscriptRecord.self]
    }
}

private enum LocalLibrarySchemaV5Models {
    /// V4's article with its deletion flag renamed, and nothing else changed.
    ///
    /// The flag may not be called `isDeleted` OR `deleted`: SwiftData reserves
    /// both, and a `@Model` stored property using either name writes its column
    /// and then reads back `false` forever. The setter is unambiguous, so the
    /// value lands on disk correctly and only the Swift getter lies — which is
    /// what kept this quiet enough to ship. `ZISDELETED` read 1 while every
    /// article still looked alive, so Remove appeared to do nothing and a
    /// remotely deleted item never disappeared. Both broken names and this
    /// working one were confirmed against a standalone SwiftData program; do
    /// not "tidy" it back to something shorter.
    ///
    /// `originalName` carries the existing `ZISDELETED` column across, so the
    /// V4 -> V5 stage renames it in place rather than dropping the values.
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var source: String
        var author: String?
        var publishedTime: Date?
        var createdAt: Date
        @Attribute(originalName: "isDeleted") var isRemoved: Bool
        var syncStatus: String = LocalLibrarySyncStatus.localOnly.rawValue
        var schemaVersion: Int

        init(_ article: Article, schemaVersion: Int = 5) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isRemoved = article.isDeleted; syncStatus = LocalLibrarySyncStatus.localOnly.rawValue
            self.schemaVersion = schemaVersion
        }
    }
}

private enum LocalLibrarySchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV5Models.ArticleRecord.self, LocalLibrarySchemaV3Models.RevisionRecord.self,
         LocalLibrarySchemaV3Models.PreparationRecord.self, LocalLibrarySchemaV3Models.PlaybackRecord.self,
         LocalLibrarySchemaV3Models.SyncStateRecord.self, LocalLibrarySchemaV3Models.TombstoneRecord.self,
         LocalLibrarySchemaV3Models.RepositoryStateRecord.self, LocalLibrarySchemaV4Models.TranscriptRecord.self]
    }
}

private enum LocalLibrarySchemaV6Models {
    @Model final class PodcastFeedRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var author: String?
        var artworkURL: String?
        var createdAt: Date

        init(_ value: PodcastFeed) {
            id = value.itemID.rawValue; canonicalURL = value.canonicalURL.absoluteString
            title = value.title; author = value.author; artworkURL = value.artworkURL?.absoluteString
            createdAt = value.createdAt.date
        }
    }

    @Model final class PodcastEpisodeRecord {
        @Attribute(.unique) var id: String
        var feedID: String
        var feedURL: String
        var rssGUID: String?
        var title: String
        var author: String?
        var publishedTime: Date?
        var enclosureURL: String
        var enclosureMediaType: String
        var enclosureByteCount: Int64?
        var durationSeconds: Double?
        var artworkURL: String?
        var createdAt: Date

        init(_ value: PodcastEpisode) {
            id = value.itemID.rawValue; feedID = value.feedID.rawValue; feedURL = value.feedURL.absoluteString
            rssGUID = value.rssGUID; title = value.title; author = value.author
            publishedTime = value.publishedTime?.date; enclosureURL = value.enclosureURL.absoluteString
            enclosureMediaType = value.enclosureMediaType; enclosureByteCount = value.enclosureByteCount
            durationSeconds = value.durationSeconds; artworkURL = value.artworkURL?.absoluteString
            createdAt = value.createdAt.date
        }
    }

    @Model final class PodcastSubscriptionRecord {
        @Attribute(.unique) var feedID: String
        var subscribedAt: Date
        var enabled: Bool

        init(_ value: PodcastSubscription) {
            feedID = value.feedID.rawValue; subscribedAt = value.subscribedAt.date; enabled = value.enabled
        }
    }

    @Model final class PodcastDownloadRecord {
        @Attribute(.unique) var episodeID: String
        var status: String
        var bytesReceived: Int64
        var expectedByteCount: Int64?
        var localURL: String?
        var contentHash: String?
        var updatedAt: Date

        init(_ value: PodcastDownload) {
            episodeID = value.episodeID.rawValue; status = value.status.rawValue
            bytesReceived = value.bytesReceived; expectedByteCount = value.expectedByteCount
            localURL = value.localURL?.absoluteString; contentHash = value.contentHash; updatedAt = value.updatedAt.date
        }
    }

    @Model final class PodcastArtworkRecord {
        @Attribute(.unique) var id: String
        var ownerID: String
        var remoteURL: String?
        var localURL: String?
        var contentHash: String?
        var byteCount: Int64?
        var updatedAt: Date

        init(_ value: PodcastArtwork) {
            id = value.id; ownerID = value.ownerID.rawValue; remoteURL = value.remoteURL?.absoluteString
            localURL = value.localURL?.absoluteString; contentHash = value.contentHash
            byteCount = value.byteCount; updatedAt = value.updatedAt.date
        }
    }

    @Model final class PodcastQueueRecord {
        @Attribute(.unique) var episodeID: String
        var position: Int
        var addedAt: Date

        init(_ value: PodcastQueueEntry) {
            episodeID = value.episodeID.rawValue; position = value.position; addedAt = value.addedAt.date
        }
    }

    @Model final class PodcastPlaybackSpeedRecord {
        @Attribute(.unique) var itemID: String
        var speed: Double
        var updatedAt: Date

        init(_ value: PodcastPlaybackSpeed) {
            itemID = value.itemID.rawValue; speed = value.speed; updatedAt = value.updatedAt.date
        }
    }
}

private enum LocalLibrarySchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV5.models + [
            LocalLibrarySchemaV6Models.PodcastFeedRecord.self,
            LocalLibrarySchemaV6Models.PodcastEpisodeRecord.self,
            LocalLibrarySchemaV6Models.PodcastSubscriptionRecord.self,
            LocalLibrarySchemaV6Models.PodcastDownloadRecord.self,
            LocalLibrarySchemaV6Models.PodcastArtworkRecord.self,
            LocalLibrarySchemaV6Models.PodcastQueueRecord.self,
            LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord.self,
        ]
    }
}

private enum LocalLibrarySchemaV7Models {
    /// The transcript entity as of store version 7: version four's columns plus
    /// cue timing.
    ///
    /// This is a separate class from `LocalLibrarySchemaV4Models.TranscriptRecord`
    /// rather than two more properties on it. Adding attributes to the shared
    /// class would silently change what versions four, five, and six mean, and
    /// SwiftData refuses the result -- two schema versions describing the same
    /// entity shape are duplicate version checksums, and the container fails to
    /// open at all. Keeping the old class frozen is what makes the stage a real
    /// migration instead of a rename of history.
    @Model final class TranscriptRecord {
        @Attribute(.unique) var id: String
        var itemID: String
        var revisionID: String
        var availability: String
        var text: String?
        var format: String
        var languageCode: String?
        var updatedAt: Date
        var schemaVersion: Int
        /// Both nullable, so a version-six store migrates by gaining two empty
        /// columns rather than rewriting a row of transcript text. A nil
        /// `timing` reads back as `TranscriptTiming.none`, which is precisely
        /// what a record written before timing existed was claiming.
        var timing: String?
        var cues: Data?

        init(_ transcript: Transcript) throws {
            id = "\(transcript.itemID.rawValue)|\(transcript.revisionID.rawValue)"
            itemID = transcript.itemID.rawValue
            revisionID = transcript.revisionID.rawValue
            availability = transcript.availability.rawValue
            text = transcript.text
            format = transcript.format.rawValue
            languageCode = transcript.languageCode
            updatedAt = transcript.updatedAt.date
            schemaVersion = transcript.schemaVersion
            timing = transcript.timing.rawValue
            cues = try transcript.cues.map(TranscriptCueCodec.encode)
        }
    }
}

private extension LocalLibrarySchemaV7Models {
    /// The episode entity as of store version 7: version six's columns plus the
    /// transcripts the feed publishes for the episode.
    ///
    /// Separate class for the same reason the transcript entity is: adding a
    /// column to version six's class would change what version six means, and
    /// two schema versions describing one entity shape is a duplicate checksum
    /// SwiftData refuses to open.
    @Model final class PodcastEpisodeRecord {
        @Attribute(.unique) var id: String
        var feedID: String
        var feedURL: String
        var rssGUID: String?
        var title: String
        var author: String?
        var publishedTime: Date?
        var enclosureURL: String
        var enclosureMediaType: String
        var enclosureByteCount: Int64?
        var durationSeconds: Double?
        var artworkURL: String?
        /// JSON, nullable. A version-six row migrates by gaining an empty
        /// column, which reads back as "this feed publishes no transcript" --
        /// exactly what was true before the column existed.
        var transcriptSources: Data?
        var createdAt: Date

        init(_ value: PodcastEpisode) throws {
            id = value.itemID.rawValue; feedID = value.feedID.rawValue; feedURL = value.feedURL.absoluteString
            rssGUID = value.rssGUID; title = value.title; author = value.author
            publishedTime = value.publishedTime?.date; enclosureURL = value.enclosureURL.absoluteString
            enclosureMediaType = value.enclosureMediaType; enclosureByteCount = value.enclosureByteCount
            durationSeconds = value.durationSeconds; artworkURL = value.artworkURL?.absoluteString
            transcriptSources = try Self.encode(value.transcriptSources)
            createdAt = value.createdAt.date
        }

        static func encode(_ sources: [PodcastTranscriptSource]) throws -> Data? {
            sources.isEmpty ? nil : try JSONEncoder().encode(sources)
        }

        static func decode(_ payload: Data?) throws -> [PodcastTranscriptSource] {
            guard let payload else { return [] }
            return try JSONDecoder().decode([PodcastTranscriptSource].self, from: payload)
        }
    }
}

/// Version 7 replaces the transcript entity with one that carries cue timing
/// and its provenance, and the episode entity with one that carries the
/// transcripts its feed publishes. Lightweight: every new column is nullable
/// and no existing column changes, so no row is rewritten.
private enum LocalLibrarySchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV6.models.filter {
            $0 != LocalLibrarySchemaV4Models.TranscriptRecord.self
                && $0 != LocalLibrarySchemaV6Models.PodcastEpisodeRecord.self
        } + [LocalLibrarySchemaV7Models.TranscriptRecord.self,
             LocalLibrarySchemaV7Models.PodcastEpisodeRecord.self]
    }
}

private enum LocalLibrarySchemaV8Models {
    /// One episode the listener removed from the Larder on purpose.
    ///
    /// Removal has to outlive both the launch and the next refresh, and neither
    /// is achievable by deleting the episode row alone: the feed still lists the
    /// episode, so the next refresh parses it and `savePodcastEpisodes` inserts
    /// it again. The record is the memory that says not to. It is deliberately a
    /// standalone entity rather than a column on the episode, so the episode row
    /// can be deleted outright -- every read path is then clean without a
    /// dismissed-filter threaded through queue joins and playback lookups.
    ///
    /// `feedID` and `title` are nil only when the episode row was already gone
    /// when the dismissal was written -- a second removal of something removed.
    /// They exist so the log is legible and so unsubscribing can forget a feed's
    /// dismissals along with the rest of its records.
    @Model final class PodcastEpisodeDismissalRecord {
        @Attribute(.unique) var id: String
        var feedID: String?
        var title: String?
        var dismissedAt: Date

        init(episodeID: String, feedID: String?, title: String?, dismissedAt: Date) {
            self.id = episodeID
            self.feedID = feedID
            self.title = title
            self.dismissedAt = dismissedAt
        }
    }
}

/// Version 8 adds the episode-dismissal entity. Lightweight: a new standalone
/// table, exactly as version six added the podcast tables, and no existing
/// entity changes shape.
private enum LocalLibrarySchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV7.models + [LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord.self]
    }
}

private enum LocalLibrarySchemaV9Models {
    /// The episode entity as of store version 9: version seven's columns plus
    /// the show notes the feed publishes. A separate class, as version seven
    /// was over six, because two versions may not describe one entity shape.
    @Model final class PodcastEpisodeRecord {
        @Attribute(.unique) var id: String
        var feedID: String
        var feedURL: String
        var rssGUID: String?
        var title: String
        var author: String?
        var publishedTime: Date?
        var enclosureURL: String
        var enclosureMediaType: String
        var enclosureByteCount: Int64?
        var durationSeconds: Double?
        var artworkURL: String?
        var transcriptSources: Data?
        /// Nullable: a version-eight row migrates to "no notes", which is what
        /// was true of it, and the next feed refresh fills it in.
        var notes: String?
        var createdAt: Date

        init(_ value: PodcastEpisode) throws {
            id = value.itemID.rawValue; feedID = value.feedID.rawValue; feedURL = value.feedURL.absoluteString
            rssGUID = value.rssGUID; title = value.title; author = value.author
            publishedTime = value.publishedTime?.date; enclosureURL = value.enclosureURL.absoluteString
            enclosureMediaType = value.enclosureMediaType; enclosureByteCount = value.enclosureByteCount
            durationSeconds = value.durationSeconds; artworkURL = value.artworkURL?.absoluteString
            transcriptSources = try Self.encode(value.transcriptSources)
            notes = value.notes
            createdAt = value.createdAt.date
        }

        static func encode(_ sources: [PodcastTranscriptSource]) throws -> Data? {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.encode(sources)
        }

        static func decode(_ payload: Data?) throws -> [PodcastTranscriptSource] {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.decode(payload)
        }
    }
}

/// Version 9 replaces the episode entity with one that carries the feed's show
/// notes. Lightweight: one nullable column, no existing column changes.
private enum LocalLibrarySchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV8.models.filter { $0 != LocalLibrarySchemaV7Models.PodcastEpisodeRecord.self }
            + [LocalLibrarySchemaV9Models.PodcastEpisodeRecord.self]
    }
}

private enum LocalLibrarySchemaV10Models {
    /// The episode entity as of store version 10: version nine's columns plus
    /// `retiredAt`. A separate class, as every prior version bump was, because
    /// two schema versions may not describe one entity shape.
    @Model final class PodcastEpisodeRecord {
        @Attribute(.unique) var id: String
        var feedID: String
        var feedURL: String
        var rssGUID: String?
        var title: String
        var author: String?
        var publishedTime: Date?
        var enclosureURL: String
        var enclosureMediaType: String
        var enclosureByteCount: Int64?
        var durationSeconds: Double?
        var artworkURL: String?
        var transcriptSources: Data?
        var notes: String?
        var createdAt: Date
        /// Nullable: a version-nine row migrates to "active", which is what was
        /// true of it before retirement existed as a dimension. Lifecycle-owned
        /// -- `apply(_:to:)` must never write this column from feed data.
        var retiredAt: Date?

        init(_ value: PodcastEpisode) throws {
            id = value.itemID.rawValue; feedID = value.feedID.rawValue; feedURL = value.feedURL.absoluteString
            rssGUID = value.rssGUID; title = value.title; author = value.author
            publishedTime = value.publishedTime?.date; enclosureURL = value.enclosureURL.absoluteString
            enclosureMediaType = value.enclosureMediaType; enclosureByteCount = value.enclosureByteCount
            durationSeconds = value.durationSeconds; artworkURL = value.artworkURL?.absoluteString
            transcriptSources = try Self.encode(value.transcriptSources)
            notes = value.notes
            createdAt = value.createdAt.date
            retiredAt = nil
        }

        static func encode(_ sources: [PodcastTranscriptSource]) throws -> Data? {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.encode(sources)
        }

        static func decode(_ payload: Data?) throws -> [PodcastTranscriptSource] {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.decode(payload)
        }
    }

    /// The download entity as of store version 10: version six's columns plus
    /// `failureKind`. Nothing before Phase 3 classifies or reads it.
    @Model final class PodcastDownloadRecord {
        @Attribute(.unique) var episodeID: String
        var status: String
        var bytesReceived: Int64
        var expectedByteCount: Int64?
        var localURL: String?
        var contentHash: String?
        var updatedAt: Date
        var failureKind: String?

        init(_ value: PodcastDownload) {
            episodeID = value.episodeID.rawValue; status = value.status.rawValue
            bytesReceived = value.bytesReceived; expectedByteCount = value.expectedByteCount
            localURL = value.localURL?.absoluteString; contentHash = value.contentHash; updatedAt = value.updatedAt.date
            failureKind = value.failureKind?.rawValue
        }
    }

    /// One durable proof that preparation produced a playable artifact for one
    /// revision. Keyed by `episodeID + revisionID` rather than by episode alone,
    /// because preparation replaces the revision and history for a superseded
    /// revision is retained, not overwritten.
    @Model final class PodcastPreparationOutcomeRecord {
        @Attribute(.unique) var id: String
        var episodeID: String
        var revisionID: String
        var policyDigest: String
        var pipelineFingerprint: String?
        var semanticVersion: String
        var producedAt: Date
        var eligibility: String
        var invalidationRuleID: String?

        init(_ value: PodcastPreparationOutcome) {
            id = value.id
            episodeID = value.episodeID.rawValue
            revisionID = value.revisionID.rawValue
            policyDigest = value.policyDigest
            pipelineFingerprint = value.pipelineFingerprint
            semanticVersion = value.semanticVersion
            producedAt = value.producedAt.date
            eligibility = value.eligibility.rawValue
            invalidationRuleID = value.invalidationRuleID
        }
    }

    /// One durable "the listener reached the end" fact, item-scoped rather than
    /// revision-scoped because both `replaceReadyRevision` and
    /// `dismissPodcastEpisode` delete revision-scoped rows and completion must
    /// outlive both.
    @Model final class PodcastListeningRecord {
        @Attribute(.unique) var id: String
        var completedAt: Date?
        var lastRevisionID: String?
        var updatedAt: Date

        init(_ value: PodcastListeningState) {
            id = value.episodeID.rawValue
            completedAt = value.completedAt?.date
            lastRevisionID = value.lastRevisionID?.rawValue
            updatedAt = value.updatedAt.date
        }
    }
}

/// Version 10 adds `retiredAt` to the episode entity, `failureKind` to the
/// download entity, and two new standalone entities for preparation outcome
/// and listening completion. Lightweight: every addition is nullable or a new
/// table, and no existing column changes shape.
private enum LocalLibrarySchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV9.models.filter {
            $0 != LocalLibrarySchemaV9Models.PodcastEpisodeRecord.self
                && $0 != LocalLibrarySchemaV6Models.PodcastDownloadRecord.self
        } + [
            LocalLibrarySchemaV10Models.PodcastEpisodeRecord.self,
            LocalLibrarySchemaV10Models.PodcastDownloadRecord.self,
            LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord.self,
            LocalLibrarySchemaV10Models.PodcastListeningRecord.self,
        ]
    }
}

private enum LocalLibrarySchemaV11Models {
    /// One immutable contribution to a device-local lifetime total. Duplicate
    /// IDs are ignored, and existing rows are never updated or removed.
    @Model final class LifetimeStatisticEventRecord {
        @Attribute(.unique) var id: String
        var kind: String
        var seconds: Double

        init(id: String, kind: LifetimeStatisticKind, seconds: Double) {
            self.id = id
            self.kind = kind.rawValue
            self.seconds = seconds
        }
    }

    /// The greatest program position already considered for speed savings.
    /// It is deliberately separate from the append-only event ledger.
    @Model final class PlaybackStatisticHighWaterRecord {
        @Attribute(.unique) var revisionID: String
        var positionSeconds: Double

        init(revisionID: RevisionID, positionSeconds: Double) {
            self.revisionID = revisionID.rawValue
            self.positionSeconds = positionSeconds
        }
    }
}

/// Version 11 adds device-local statistics only. Neither entity participates
/// in CloudKit, because this store's configuration remains `.none`.
private enum LocalLibrarySchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV10.models + [
            LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord.self,
            LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord.self,
        ]
    }
}

private enum LocalLibrarySchemaV12Models {
    /// One durable request for background work -- a podcast download,
    /// podcast preparation, or article preparation. A wholly new table; no
    /// existing V11 entity changes shape.
    @Model final class WorkTicketRecord {
        @Attribute(.unique) var id: String
        var kind: String
        var subjectID: String
        var resolvedItemID: String?
        var requestSequence: Int
        var state: String
        var attemptCount: Int
        var failureKind: String?
        var lastFailureMessage: String?
        var nextEligibleAt: Date?
        var policySnapshot: Data?
        var processingPolicy: Data?
        var runID: String?
        var requestedAt: Date
        var updatedAt: Date

        init(_ value: WorkTicket) {
            id = value.id
            kind = value.kind.rawValue
            subjectID = value.subjectID
            resolvedItemID = value.resolvedItemID
            requestSequence = value.requestSequence
            state = value.state.rawValue
            attemptCount = value.attemptCount
            failureKind = value.failureKind
            lastFailureMessage = value.lastFailureMessage
            nextEligibleAt = value.nextEligibleAt?.date
            policySnapshot = value.policySnapshot
            processingPolicy = value.processingPolicy
            runID = value.runID
            requestedAt = value.requestedAt.date
            updatedAt = value.updatedAt.date
        }

        /// Overwrites every field but `id`/`kind`/`subjectID`/`requestedAt` --
        /// the identity and intake time of a ticket never change underneath it.
        func apply(_ value: WorkTicket) {
            resolvedItemID = value.resolvedItemID
            requestSequence = value.requestSequence
            state = value.state.rawValue
            attemptCount = value.attemptCount
            failureKind = value.failureKind
            lastFailureMessage = value.lastFailureMessage
            nextEligibleAt = value.nextEligibleAt?.date
            policySnapshot = value.policySnapshot
            processingPolicy = value.processingPolicy
            runID = value.runID
            updatedAt = value.updatedAt.date
        }
    }
}

/// Version 12 adds the work-ticket queue only. Lightweight: the addition is
/// a wholly new table and no existing column changes shape -- same
/// justification V10 and V11 already carry.
private enum LocalLibrarySchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV11.models + [
            LocalLibrarySchemaV12Models.WorkTicketRecord.self,
        ]
    }
}

private enum LocalLibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalLibrarySchemaV1.self, LocalLibrarySchemaV2.self, LocalLibrarySchemaV3.self,
         LocalLibrarySchemaV4.self, LocalLibrarySchemaV5.self, LocalLibrarySchemaV6.self,
         LocalLibrarySchemaV7.self, LocalLibrarySchemaV8.self, LocalLibrarySchemaV9.self,
         LocalLibrarySchemaV10.self, LocalLibrarySchemaV11.self, LocalLibrarySchemaV12.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LocalLibrarySchemaV1.self, toVersion: LocalLibrarySchemaV2.self),
         .lightweight(fromVersion: LocalLibrarySchemaV2.self, toVersion: LocalLibrarySchemaV3.self),
         .lightweight(fromVersion: LocalLibrarySchemaV3.self, toVersion: LocalLibrarySchemaV4.self),
         .lightweight(fromVersion: LocalLibrarySchemaV4.self, toVersion: LocalLibrarySchemaV5.self),
         .lightweight(fromVersion: LocalLibrarySchemaV5.self, toVersion: LocalLibrarySchemaV6.self),
         .lightweight(fromVersion: LocalLibrarySchemaV6.self, toVersion: LocalLibrarySchemaV7.self),
         .lightweight(fromVersion: LocalLibrarySchemaV7.self, toVersion: LocalLibrarySchemaV8.self),
         .lightweight(fromVersion: LocalLibrarySchemaV8.self, toVersion: LocalLibrarySchemaV9.self),
         .lightweight(fromVersion: LocalLibrarySchemaV9.self, toVersion: LocalLibrarySchemaV10.self),
         .lightweight(fromVersion: LocalLibrarySchemaV10.self, toVersion: LocalLibrarySchemaV11.self),
         .lightweight(fromVersion: LocalLibrarySchemaV11.self, toVersion: LocalLibrarySchemaV12.self)]
    }
}

private enum LocalLibraryV5MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalLibrarySchemaV1.self, LocalLibrarySchemaV2.self, LocalLibrarySchemaV3.self,
         LocalLibrarySchemaV4.self, LocalLibrarySchemaV5.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LocalLibrarySchemaV1.self, toVersion: LocalLibrarySchemaV2.self),
         .lightweight(fromVersion: LocalLibrarySchemaV2.self, toVersion: LocalLibrarySchemaV3.self),
         .lightweight(fromVersion: LocalLibrarySchemaV3.self, toVersion: LocalLibrarySchemaV4.self),
         .lightweight(fromVersion: LocalLibrarySchemaV4.self, toVersion: LocalLibrarySchemaV5.self)]
    }
}

/// Actor-isolated SwiftData adapter for the producer's local library.
public actor LocalLibraryStore {
    public static let pipelineProvenanceEvidenceKind = "podcast-pipeline-provenance"
    public static let forcedRedownloadRequestPrefix = "podcast-invalidation|"
    public static let resetPreparationRequestPrefix = "podcast-reset-preparation|"
    /// Current-item identity is encoded inside the existing V6 queue record
    /// shape so Task 2.3 does not silently mutate a released SwiftData schema.
    private static let podcastCurrentPositionOffset = 1_000_000_000
    public let url: URL
    public let schemaVersion: LocalLibrarySchemaVersion = .current
    public let cloudKitDatabase: String? = nil
    public let migrationBackupURL: URL?

    nonisolated internal let container: ModelContainer

    /// Number of `context.fetch` calls made by `podcastLibrarySnapshot()` since
    /// this store opened. Test-only: proves the snapshot's read cost stays
    /// flat as the library grows instead of scaling with episode count.
    private(set) var podcastLibrarySnapshotFetchCount = 0

    public init(url: URL, migrate: Bool = true) throws {
        try self.init(url: url, migrate: migrate, migrationFailure: nil, retainingAt: nil)
    }

    #if DEBUG
    /// Test-only seam used to prove that the retained copy is complete when a
    /// forward migration fails after preflight and before the live container opens.
    internal init(url: URL, migrate: Bool = true,
                  migrationFailure: (@Sendable () throws -> Void)?, retainingAt: URL? = nil) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retainedURL: URL?
        if migrate, FileManager.default.fileExists(atPath: url.path), !Self.hasV6PodcastTables(at: url) {
            // This runs before ModelContainer sees the source URL. The retained
            // copy is the rollback artifact if a forward migration fails.
            retainedURL = try Self.migrationPreflight(at: url, retainingAt: retainingAt).retainedURL
            try migrationFailure?()
        }
        migrationBackupURL = retainedURL
        let schema = Schema(versionedSchema: LocalLibrarySchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    #else
    private init(url: URL, migrate: Bool, migrationFailure: (@Sendable () throws -> Void)?, retainingAt: URL?) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retainedURL: URL?
        if migrate, FileManager.default.fileExists(atPath: url.path), !Self.hasV6PodcastTables(at: url) {
            // This runs before ModelContainer sees the source URL. The retained
            // copy is the rollback artifact if a forward migration fails.
            retainedURL = try Self.migrationPreflight(at: url).retainedURL
        }
        migrationBackupURL = retainedURL
        let schema = Schema(versionedSchema: LocalLibrarySchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }
    #endif

    /// Appends one validated lifetime contribution. An existing deterministic
    /// ID wins unchanged, making retries and relaunches idempotent.
    @discardableResult
    public func recordLifetimeStatistic(
        id: String,
        kind: LifetimeStatisticKind,
        seconds: Double
    ) throws -> Bool {
        guard !id.isEmpty, seconds.isFinite, seconds >= 0 else { return false }
        let context = ModelContext(container)
        let inserted = try appendLifetimeStatistics([
            LifetimeStatisticContribution(id: id, kind: kind, seconds: seconds)
        ], in: context)
        guard inserted else { return false }
        try context.save()
        return true
    }

    /// Inserts new deterministic event IDs into an existing transaction.
    @discardableResult
    private func appendLifetimeStatistics(
        _ contributions: [LifetimeStatisticContribution],
        in context: ModelContext
    ) throws -> Bool {
        let existingIDs = Set(try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
        ).map(\.id))
        var admittedIDs = existingIDs
        var inserted = false
        for contribution in contributions
        where !contribution.id.isEmpty && contribution.seconds.isFinite && contribution.seconds >= 0
            && admittedIDs.insert(contribution.id).inserted {
            context.insert(LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord(
                id: contribution.id, kind: contribution.kind, seconds: contribution.seconds
            ))
            inserted = true
        }
        return inserted
    }

    /// Totals the immutable ledger and ignores any corrupt legacy value rather
    /// than allowing NaN, infinity, or a negative value to poison a total.
    public func lifetimeStatistics() throws -> LifetimeStatistics {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
        )
        var totals = LifetimeStatistics()
        for record in records where record.seconds.isFinite && record.seconds >= 0 {
            guard let kind = LifetimeStatisticKind(rawValue: record.kind) else { continue }
            switch kind {
            case .audioProcessed:
                let value = totals.audioProcessedSeconds + record.seconds
                if value.isFinite { totals.audioProcessedSeconds = value }
            case .speechGenerated:
                let value = totals.speechGeneratedSeconds + record.seconds
                if value.isFinite { totals.speechGeneratedSeconds = value }
            case .confirmedAdTimeRemoved:
                let value = totals.confirmedAdTimeRemovedSeconds + record.seconds
                if value.isFinite { totals.confirmedAdTimeRemovedSeconds = value }
            case .fasterPlaybackTimeSaved:
                let value = totals.fasterPlaybackTimeSavedSeconds + record.seconds
                if value.isFinite { totals.fasterPlaybackTimeSavedSeconds = value }
            }
        }
        return totals
    }

    /// Advances one revision's durable high-water mark on every checkpoint.
    /// Only the newly crossed program interval can contribute savings, and a
    /// rate at or below 1x still advances the mark so it cannot be counted by
    /// a later faster checkpoint.
    @discardableResult
    public func recordPlaybackSpeedCheckpoint(
        revisionID: RevisionID,
        from startSeconds: Double,
        to endSeconds: Double,
        rate: Double
    ) throws -> Double {
        guard startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds >= 0 else { return 0 }
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord>()
        )
        let existing = records.first { $0.revisionID == revisionID.rawValue }
        let lowerBound = max(existing?.positionSeconds ?? startSeconds, startSeconds)
        let upperBound = max(lowerBound, endSeconds)
        guard upperBound > lowerBound else { return 0 }

        if let existing {
            existing.positionSeconds = upperBound
        } else {
            context.insert(LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord(
                revisionID: revisionID, positionSeconds: upperBound
            ))
        }

        var savedSeconds = 0.0
        if rate.isFinite, rate > 1 {
            let programSeconds = upperBound - lowerBound
            savedSeconds = programSeconds - programSeconds / rate
            if savedSeconds.isFinite, savedSeconds > 0 {
                let eventID = "playback-speed|\(revisionID.rawValue)|\(lowerBound.bitPattern)|\(upperBound.bitPattern)"
                let events = try context.fetch(
                    FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
                )
                if !events.contains(where: { $0.id == eventID }) {
                    context.insert(LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord(
                        id: eventID, kind: .fasterPlaybackTimeSaved, seconds: savedSeconds
                    ))
                } else {
                    savedSeconds = 0
                }
            } else {
                savedSeconds = 0
            }
        }
        try context.save()
        return savedSeconds
    }

    /// Decodes a persisted work-ticket row, dropping it if its `kind` or
    /// `state` raw value is not one this store recognizes.
    private static func decodeWorkTicket(_ record: LocalLibrarySchemaV12Models.WorkTicketRecord) -> WorkTicket? {
        guard let kind = WorkTicketKind(rawValue: record.kind),
              let state = WorkTicketState(rawValue: record.state) else { return nil }
        return WorkTicket(
            kind: kind, subjectID: record.subjectID, resolvedItemID: record.resolvedItemID,
            requestSequence: record.requestSequence, state: state, attemptCount: record.attemptCount,
            failureKind: record.failureKind, lastFailureMessage: record.lastFailureMessage,
            nextEligibleAt: record.nextEligibleAt.map(Timestamp.init),
            policySnapshot: record.policySnapshot, processingPolicy: record.processingPolicy,
            runID: record.runID, requestedAt: Timestamp(record.requestedAt), updatedAt: Timestamp(record.updatedAt)
        )
    }

    /// All persisted work tickets, in no particular order.
    public func workTickets() throws -> [WorkTicket] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
            .compactMap(Self.decodeWorkTicket)
    }

    /// Overwrites the ticket matching `ticket.id`, or inserts it if absent.
    /// Unlike `issueWorkTicket`, the caller supplies `requestSequence`
    /// directly -- this is the path state transitions (running, succeeded,
    /// a retry's incremented `attemptCount`) use, not the path that assigns
    /// a ticket its place in the queue.
    @discardableResult
    public func upsertWorkTicket(_ ticket: WorkTicket) throws -> WorkTicket {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        if let existing = records.first(where: { $0.id == ticket.id }) {
            existing.apply(ticket)
        } else {
            context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        }
        try context.save()
        return ticket
    }

    /// Finds or creates the ticket for one `(kind, subjectID)`. An existing
    /// ticket -- pending, in flight, or already terminal -- is returned
    /// unchanged; this is a find-or-insert, not a reset. A new ticket's
    /// `requestSequence` is `max(requestSequence) + 1` computed inside the
    /// same fetch-then-save as the insert, so sequence numbers are
    /// monotonic by construction and never assigned by a separate counter
    /// row.
    @discardableResult
    public func issueWorkTicket(
        kind: WorkTicketKind, subjectID: String, resolvedItemID: String? = nil,
        policySnapshot: Data? = nil, processingPolicy: Data? = nil, requestedAt: Timestamp
    ) throws -> WorkTicket {
        let context = ModelContext(container)
        let id = "\(kind.rawValue)|\(subjectID)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        if let existing = records.first(where: { $0.id == id }) {
            guard let decoded = Self.decodeWorkTicket(existing) else {
                throw LocalLibraryStoreError.invalidPodcastState("corrupt work ticket row")
            }
            return decoded
        }
        let nextSequence = (records.map(\.requestSequence).max() ?? 0) + 1
        let ticket = WorkTicket(
            kind: kind, subjectID: subjectID, resolvedItemID: resolvedItemID,
            requestSequence: nextSequence, state: .pending, attemptCount: 0,
            policySnapshot: policySnapshot, processingPolicy: processingPolicy,
            requestedAt: requestedAt, updatedAt: requestedAt
        )
        context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        try context.save()
        return ticket
    }

    /// Checkpoints the source WAL and verifies a complete V5 rollback copy before
    /// the live V6 migration is allowed to open the source database.
    public nonisolated static func migrationPreflight(at sourceURL: URL, retainingAt destinationURL: URL? = nil) throws -> LocalLibraryMigrationPreflight {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("source store does not exist")
        }
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let sourceName = sourceURL.lastPathComponent
        if let destinationURL,
           destinationURL.deletingLastPathComponent().standardizedFileURL == sourceDirectory.standardizedFileURL {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained destination must not share the source directory")
        }
        try checkpointSQLite(at: sourceURL)
        let retainedDirectory = destinationURL?.deletingLastPathComponent()
            ?? sourceDirectory.appendingPathComponent("\(sourceName).v5-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        let retainedURL = destinationURL ?? retainedDirectory.appendingPathComponent(sourceName)
        let retainedName = retainedURL.lastPathComponent
        let files = try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == sourceName || $0.lastPathComponent.hasPrefix("\(sourceName)-") }
        guard files.contains(where: { $0.standardizedFileURL == sourceURL.standardizedFileURL }) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("source store disappeared")
        }
        let checkpointedFiles = try files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { file in
            (url: file, bytes: try Data(contentsOf: file))
        }
        // Validate a disposable clone. SwiftData may checkpoint or remove WAL
        // sidecars as it opens a store, so opening retainedURL itself would make
        // the rollback artifact differ from the post-checkpoint source.
        let validationDirectory = manager.temporaryDirectory.appendingPathComponent("wilted-v5-validation-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: validationDirectory, withIntermediateDirectories: true)
        let validationURL = validationDirectory.appendingPathComponent(sourceName)
        // The checkpointed main file is self-contained. Keep sidecars out of the
        // disposable validation clone because SQLite may delete them on open.
        try manager.copyItem(at: sourceURL, to: validationURL)
        do {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV5.self)
            let configuration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
            _ = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Legacy V1-V4 stores are still supported. Upgrade only the disposable
            // validation clone to V5; the retained copy and source remain untouched.
            do {
                let schema = Schema(versionedSchema: LocalLibrarySchemaV5.self)
                let configuration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                _ = try ModelContainer(for: schema, migrationPlan: LocalLibraryV5MigrationPlan.self,
                                        configurations: [configuration])
                let reopenedConfiguration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                _ = try ModelContainer(for: schema, configurations: [reopenedConfiguration])
            } catch {
                try? manager.removeItem(at: validationDirectory)
                throw LocalLibraryStoreError.migrationPreflightFailed("retained V5 copy could not be opened: \(error)")
            }
        }
        try? manager.removeItem(at: validationDirectory)
        // Copy only after validation has closed so SQLite cannot clean up the
        // rollback artifact's sidecars. This preserves every post-checkpoint
        // source file, including zero-length WAL/SHM files.
        var retainedFiles: [URL] = []
        for file in checkpointedFiles {
            let suffix = file.url.lastPathComponent == sourceName
                ? ""
                : String(file.url.lastPathComponent.dropFirst(sourceName.count))
            let copy = retainedDirectory.appendingPathComponent(retainedName + suffix)
            try file.bytes.write(to: copy, options: .atomic)
            retainedFiles.append(copy)
        }
        guard manager.fileExists(atPath: retainedURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained V5 store was not written")
        }
        return LocalLibraryMigrationPreflight(sourceURL: sourceURL, retainedURL: retainedURL, retainedFiles: retainedFiles)
    }

    private nonisolated static func hasV6PodcastTables(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let result = runSQLite(url: url, sql: "SELECT name FROM sqlite_master WHERE lower(name) LIKE '%podcastfeed%' LIMIT 1;")
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func checkpointSQLite(at url: URL) throws {
        let result = runSQLite(url: url, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        guard result.status == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("SQLite WAL checkpoint failed: \(result.output)")
        }
        let walURL = URL(fileURLWithPath: "\(url.path)-wal")
        let walByteCount = FileManager.default.fileExists(atPath: walURL.path)
            ? (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value
            : nil
        try validateWALCheckpointOutput(result.output, walByteCount: walByteCount)
    }

    private nonisolated static func validateWALCheckpointOutput(_ output: String, walByteCount: Int64?) throws {
        let fields = output.split { character in
            character == "|" || character == " " || character == "\t" || character == "\r" || character == "\n"
        }
        guard fields.count == 3, let busy = Int(fields[0]), let log = Int(fields[1]), let checkpointed = Int(fields[2]),
              busy == 0, log == checkpointed, walByteCount == nil || walByteCount == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("SQLite WAL checkpoint was busy or incomplete: \(output)")
        }
    }

    #if DEBUG
    /// Deterministic parser seam for WAL checkpoint failure cases.
    internal nonisolated static func validateWALCheckpointOutputForTesting(_ output: String, walByteCount: Int64? = nil) throws {
        try validateWALCheckpointOutput(output, walByteCount: walByteCount)
    }
    #endif

    private nonisolated static func runSQLite(url: URL, sql: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run(); process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, String(describing: error))
        }
    }

    #if DEBUG
    /// Builds a frozen v2 store for migration tests without exposing schema internals to callers.
    nonisolated internal static func createV2MigrationFixture(at url: URL, article: Article, playback: PlaybackState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalLibrarySchemaV2Models.ArticleRecord(article))
        context.insert(LocalLibrarySchemaV2Models.PlaybackRecord(playback))
        try context.save()
    }

    /// Builds a frozen V5 store for the forward-migration and rollback-copy tests.
    nonisolated internal static func createV5MigrationFixture(at url: URL, article: Article, playback: PlaybackState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalLibrarySchemaV5Models.ArticleRecord(article))
        context.insert(LocalLibrarySchemaV3Models.RevisionRecord(playbackRevision(playback), mediaURL: URL(fileURLWithPath: "/tmp/v5.m4a")))
        context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback))
        // Written through version four's untimed entity on purpose: a fixture
        // that already carried timing columns would skip the very migration
        // these tests exist to exercise. It also has to declare schema version
        // one, because version two is the shape that introduced timing.
        let transcript = try Transcript(itemID: playback.itemID, revisionID: playback.revisionID,
                                        availability: .available, text: "V5 transcript",
                                        updatedAt: playback.updatedAt, schemaVersion: 1)
        context.insert(LocalLibrarySchemaV4Models.TranscriptRecord(transcript))
        let status = try PreparationStatus(stage: .completed, detail: "V5 ready", fraction: 1, cancellable: false,
                                            terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: playback.revisionID),
                                            emittedAt: playback.updatedAt)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(
            PreparationJournalEntry(id: "v5-prep", itemID: playback.itemID, requestID: "v5-request", status: status)))
        context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(
            LocalLibrarySyncState(key: "private-zone", engineState: Data([5]), lastFetchAt: playback.updatedAt, lastSendAt: playback.updatedAt)))
        context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(
            LocalLibraryTombstone(id: "v5-tombstone", itemID: playback.itemID, generationID: "v5-generation", requestedAt: playback.updatedAt)))
        context.insert(LocalLibrarySchemaV3Models.RepositoryStateRecord(
            stateData: try JSONEncoder().encode(SyncRepositoryState(engineState: Data([5])))))
        try context.save()
    }

    private nonisolated static func playbackRevision(_ playback: PlaybackState) -> AudioRevision {
        // The V5 fixture only needs a valid immutable revision envelope. Its
        // media URL is intentionally local and is not read during migration.
        return try! AudioRevision(itemID: playback.itemID, revisionID: playback.revisionID,
                                  durationSeconds: playback.durationSeconds, byteCount: 1,
                                  contentHash: "sha256:" + String(repeating: "5", count: 64), mediaType: "audio/mp4",
                                  createdAt: playback.updatedAt, schemaVersion: 3)
    }

    /// One episode's inputs for `createV9MigrationFixture`, bundling only what
    /// a V9 fixture needs: episode metadata, an optional completed download
    /// plus ready revision (nil skips both -- the episode carries no proof to
    /// backfill), an optional completed-playback state, and any preparation
    /// journal entries to seed (terminal successes, forced-redownload/reset
    /// markers, or both).
    internal struct PodcastEpisodeMigrationFixture {
        let episode: PodcastEpisode
        let download: PodcastDownload?
        let revision: AudioRevision?
        let mediaURL: URL?
        let playback: PlaybackState?
        let journalEntries: [PreparationJournalEntry]

        internal init(episode: PodcastEpisode, download: PodcastDownload? = nil, revision: AudioRevision? = nil,
                      mediaURL: URL? = nil, playback: PlaybackState? = nil, journalEntries: [PreparationJournalEntry] = []) {
            self.episode = episode; self.download = download; self.revision = revision
            self.mediaURL = mediaURL; self.playback = playback; self.journalEntries = journalEntries
        }
    }

    /// Builds a frozen V9 store exercising every `reconcilePodcastStateV10()`
    /// backfill path: a journal-proved preparation outcome, a
    /// completed-listening backfill, and legacy forced-redownload/reset
    /// markers to translate onto an outcome row or drop outright.
    nonisolated internal static func createV9MigrationFixture(
        at url: URL, feed: PodcastFeed, subscription: PodcastSubscription,
        episodes: [PodcastEpisodeMigrationFixture]
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalLibrarySchemaV6Models.PodcastFeedRecord(feed))
        context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription))
        for fixture in episodes {
            context.insert(try LocalLibrarySchemaV9Models.PodcastEpisodeRecord(fixture.episode))
            if let download = fixture.download {
                context.insert(LocalLibrarySchemaV6Models.PodcastDownloadRecord(download))
            }
            if let revision = fixture.revision, let mediaURL = fixture.mediaURL {
                context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
            }
            if let playback = fixture.playback {
                context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback))
            }
            for entry in fixture.journalEntries {
                context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry))
            }
        }
        try context.save()
    }

    /// Builds a frozen V11 store for the V12 work-ticket migration test: a
    /// handful of pre-existing download and preparation-journal rows that
    /// must still read back correctly once the work-ticket table is layered
    /// on top by a lightweight migration.
    nonisolated internal static func createV11MigrationFixture(
        at url: URL, downloads: [PodcastDownload], preparationEntries: [PreparationJournalEntry]
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV11.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for download in downloads {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download))
        }
        for entry in preparationEntries {
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry))
        }
        try context.save()
    }

    /// Corrupts repository metadata for deterministic decoder-failure tests.
    nonisolated internal static func corruptRepositoryStateFixture(at url: URL, data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(LocalLibrarySchemaV3Models.RepositoryStateRecord(stateData: data))
        try context.save()
    }

    /// Seeds a raw revision record directly into the store without domain validation,
    /// enabling regression tests for malformed persisted rows.
    nonisolated internal func seedRevisionRecord(
        in context: ModelContext? = nil,
        id: String,
        itemID: String,
        durationSeconds: Double = 42,
        byteCount: Int64 = 128,
        contentHash: String = "sha256:" + String(repeating: "a", count: 64),
        mediaType: String = "audio/mp4",
        mediaURL: String? = "file:///tmp/media.mp4",
        createdAt: Date = Date(),
        schemaVersion: Int = 3
    ) throws {
        let ctx = context ?? ModelContext(container)
        let record = LocalLibrarySchemaV3Models.RevisionRecord(
            id: id,
            itemID: itemID,
            durationSeconds: durationSeconds,
            byteCount: byteCount,
            contentHash: contentHash,
            mediaType: mediaType,
            mediaURL: mediaURL,
            createdAt: createdAt,
            schemaVersion: schemaVersion
        )
        ctx.insert(record)
        try ctx.save()
    }

    /// Convenience for seeding a malformed revision record.
    nonisolated internal func seedMalformedRevision(
        in context: ModelContext? = nil,
        id: String = "malformed-revision",
        itemID: String,
        durationSeconds: Double = -1,
        byteCount: Int64 = 128,
        contentHash: String = "sha256:" + String(repeating: "a", count: 64),
        mediaType: String = "audio/mp4",
        mediaURL: String? = "file:///tmp/malformed.mp4",
        createdAt: Date = Date(),
        schemaVersion: Int = 3
    ) throws {
        try seedRevisionRecord(
            in: context,
            id: id,
            itemID: itemID,
            durationSeconds: durationSeconds,
            byteCount: byteCount,
            contentHash: contentHash,
            mediaType: mediaType,
            mediaURL: mediaURL,
            createdAt: createdAt,
            schemaVersion: schemaVersion
        )
    }

    /// Test-only seam: inserts a work-ticket row directly against a fresh
    /// `ModelContext` on this store's container, bypassing
    /// `issueWorkTicket`'s find-or-insert check entirely. `nonisolated`, so a
    /// caller on any isolation domain -- including the main actor -- can run
    /// this genuinely concurrently with an actor-isolated `issueWorkTicket`
    /// call, to observe how a conflicting insert against `id`'s
    /// `@Attribute(.unique)` constraint actually behaves when the two race.
    nonisolated internal func seedRawWorkTicket(
        kind: WorkTicketKind, subjectID: String, requestSequence: Int, requestedAt: Timestamp
    ) throws {
        let context = ModelContext(container)
        let ticket = WorkTicket(kind: kind, subjectID: subjectID, requestSequence: requestSequence,
                                requestedAt: requestedAt, updatedAt: requestedAt)
        context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        try context.save()
    }
    #endif

    public func save(article: Article) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
        if let existing = records.first(where: { $0.id == article.itemID.rawValue }) {
            existing.canonicalURL = article.canonicalURL.absoluteString; existing.title = article.title
            existing.source = article.source; existing.author = article.author
            existing.publishedTime = article.publishedTime?.date; existing.createdAt = article.createdAt.date
            existing.isRemoved = article.isDeleted; existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else { context.insert(LocalLibrarySchemaV5Models.ArticleRecord(article)) }
        try context.save()
    }

    public func article(for itemID: ItemID) throws -> Article? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return nil }
        return try Article(itemID: try ItemID(rawValue: record.id), canonicalURL: URL(string: record.canonicalURL)!,
                           title: record.title, source: record.source, author: record.author,
                           publishedTime: record.publishedTime.map(Timestamp.init), createdAt: Timestamp(record.createdAt), isDeleted: record.isRemoved)
    }

    public func articles() throws -> [Article] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { record in
                guard let itemID = try? ItemID(rawValue: record.id),
                      let canonicalURL = URL(string: record.canonicalURL) else { return nil }
                return try? Article(
                    itemID: itemID, canonicalURL: canonicalURL, title: record.title, source: record.source,
                    author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                    createdAt: Timestamp(record.createdAt), isDeleted: record.isRemoved
                )
            }
    }

    public func saveReadyRevision(_ revision: AudioRevision, mediaURL: URL) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = records.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevision)
            }
            return
        }
        context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        try context.save()
    }

    public func save(revision: AudioRevision, mediaURL: URL) throws { try saveReadyRevision(revision, mediaURL: mediaURL) }

    /// Atomically saves immutable audio metadata and the transcript produced from the
    /// same extracted text. Identity mismatch fails before either value is committed.
    public func saveReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        let context = ModelContext(container)
        let revisionRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisionRecords.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevisionWithTranscript)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    /// The no-audio-change preparation success path: the ready revision and
    /// its outcome are inserted in the same save, so nothing can observe one
    /// durable without the other.
    public func saveReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        outcome: PodcastPreparationOutcome,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard outcome.episodeID == revision.itemID, outcome.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        let context = ModelContext(container)
        let revisionRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisionRecords.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevisionWithOutcome)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)
        try upsertPreparationOutcome(outcome, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    /// Saves one versioned transcript without changing its item or revision identity.
    public func save(transcript: Transcript) throws {
        let context = ModelContext(container)
        try upsert(transcript, in: context)
        try context.save()
    }

    /// Read-only transcript interface consumed by platform presentation layers.
    public func transcript(for itemID: ItemID, revisionID: RevisionID) throws -> Transcript? {
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
            .first(where: { $0.id == id }) else { return nil }
        return try decodeTranscript(record)
    }

    /// Item identifiers whose current transcript contains `query`.
    ///
    /// The search runs here rather than in a presentation layer because a
    /// transcript is tens of kilobytes of text the library list deliberately
    /// does not carry. Asking the store "which items say this" costs one
    /// query; loading every transcript into a view model to ask the same
    /// question does not survive a library of any size.
    ///
    /// Only an item's newest revision is consulted. Revisions accumulate -- a
    /// re-prepared episode keeps the transcript of the audio it replaced --
    /// and that older text still holds the advertising the cut removed. So
    /// matching every revision would hand the reader an episode whose
    /// transcript no longer contains the words they searched for, which reads
    /// as the search being broken rather than as history being kept.
    public func itemIDsWithTranscript(matching query: String) throws -> Set<ItemID> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let context = ModelContext(container)
        let matched = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
                predicate: #Predicate { ($0.text?.localizedStandardContains(needle)) == true }
            )
        )
        guard !matched.isEmpty else { return [] }

        var newestRevision: [String: (id: String, createdAt: Date)] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            if let held = newestRevision[record.itemID], held.createdAt >= record.createdAt { continue }
            newestRevision[record.itemID] = (record.id, record.createdAt)
        }

        var found: Set<ItemID> = []
        for record in matched where newestRevision[record.itemID]?.id == record.revisionID {
            guard let id = try? ItemID(rawValue: record.itemID) else { continue }
            found.insert(id)
        }
        return found
    }

    private func upsert(_ transcript: Transcript, in context: ModelContext) throws {
        let id = "\(transcript.itemID.rawValue)|\(transcript.revisionID.rawValue)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        if let existing = records.first(where: { $0.id == id }) {
            existing.availability = transcript.availability.rawValue
            existing.text = transcript.text
            existing.format = transcript.format.rawValue
            existing.languageCode = transcript.languageCode
            existing.updatedAt = transcript.updatedAt.date
            existing.schemaVersion = transcript.schemaVersion
            existing.timing = transcript.timing.rawValue
            existing.cues = try transcript.cues.map(TranscriptCueCodec.encode)
        } else {
            context.insert(try LocalLibrarySchemaV7Models.TranscriptRecord(transcript))
        }
    }

    private func decodeTranscript(_ record: LocalLibrarySchemaV7Models.TranscriptRecord) throws -> Transcript {
        guard let availability = TranscriptAvailability(rawValue: record.availability),
              let format = TranscriptFormat(rawValue: record.format) else {
            throw LocalLibraryStoreError.invalidPreparationStatus("transcript")
        }
        // A row written before store version 7 has a null `timing`, which is
        // exactly "untimed". A row with a value the running build does not
        // recognise is a different matter: reading it as untimed would drop
        // cues a newer build meant to keep, so it fails instead.
        let timing: TranscriptTiming
        if let raw = record.timing {
            guard let parsed = TranscriptTiming(rawValue: raw) else {
                throw LocalLibraryStoreError.invalidPreparationStatus("transcript.timing")
            }
            timing = parsed
        } else {
            timing = .none
        }
        let cues = try record.cues.map(TranscriptCueCodec.decode)
        return try Transcript(itemID: ItemID(rawValue: record.itemID),
                              revisionID: RevisionID(rawValue: record.revisionID),
                              availability: availability, text: record.text, format: format,
                              languageCode: record.languageCode, timing: timing, cues: cues,
                              updatedAt: Timestamp(record.updatedAt),
                              schemaVersion: record.schemaVersion)
    }

    public func readyRevision(for itemID: ItemID, revisionID: RevisionID? = nil) throws -> StoredAudioRevision? {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            .filter { $0.itemID == itemID.rawValue && (revisionID == nil || $0.id == revisionID?.rawValue) }
            .sorted { $0.createdAt > $1.createdAt }
        guard let record = records.first, let mediaURLString = record.mediaURL, let mediaURL = URL(string: mediaURLString) else { return nil }
        let revision = try AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                         byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                         createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
        return StoredAudioRevision(revision: revision, mediaURL: mediaURL)
    }

    /// Newest ready revision per item, from one fetch instead of one per
    /// item. Matches `readyRevision(for:)` with no `revisionID` exactly: only
    /// the newest revision counts, and a newest revision with no `mediaURL`
    /// means that item has no ready revision -- no fallback to an older one.
    /// A record that fails `AudioRevision` validation is skipped rather than
    /// thrown, matching every call site that fed this helper: two reconcile
    /// call sites resolved a single item's revision with `try?` and must
    /// keep processing the rest of the library on a malformed row, not abort
    /// reconciliation for every item because one is bad.
    nonisolated internal func newestReadyRevisionsByItemID(in context: ModelContext) throws -> [String: StoredAudioRevision] {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        var newestByItemID: [String: LocalLibrarySchemaV3Models.RevisionRecord] = [:]
        for record in records {
            if let existing = newestByItemID[record.itemID], existing.createdAt >= record.createdAt { continue }
            newestByItemID[record.itemID] = record
        }
        var result: [String: StoredAudioRevision] = [:]
        for (itemIDRaw, record) in newestByItemID {
            guard let mediaURLString = record.mediaURL, let mediaURL = URL(string: mediaURLString),
                  let itemID = try? ItemID(rawValue: itemIDRaw),
                  let revision = try? AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                                    byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                                    createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
            else { continue }
            result[itemIDRaw] = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        }
        return result
    }

    nonisolated internal func newestReadyRevisionsByItemID() throws -> [String: StoredAudioRevision] {
        try newestReadyRevisionsByItemID(in: ModelContext(container))
    }

    /// Resolves one podcast revision without migrating any existing identity.
    ///
    /// New podcast rows include their episode identity, while older rows only
    /// include their content hash. Looking up the new form first keeps new
    /// downloads item-safe; accepting a same-item legacy row keeps existing
    /// media, transcripts, and playback bindings intact.
    public func resolvePodcastRevision(itemID: ItemID, contentHash: String) throws -> RevisionID {
        let namespaced = try RevisionID.derive(
            podcastDownloadedAudioItemID: itemID,
            contentHash: contentHash
        )
        let legacy = try RevisionID.derive(downloadedAudioContentHash: contentHash)
        let records = try ModelContext(container)
            .fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())

        if records.contains(where: {
            $0.id == namespaced.rawValue &&
                $0.itemID == itemID.rawValue &&
                $0.contentHash == contentHash
        }) {
            return namespaced
        }
        if records.contains(where: {
            $0.id == legacy.rawValue &&
                $0.itemID == itemID.rawValue &&
                $0.contentHash == contentHash
        }) {
            return legacy
        }
        return namespaced
    }

    public func revisions(for itemID: ItemID) throws -> [StoredAudioRevision] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()).filter { $0.itemID == itemID.rawValue }.compactMap { record in
            guard let value = record.mediaURL, let mediaURL = URL(string: value) else { return nil }
            let revision = try? AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                              byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                              createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
            return revision.map { StoredAudioRevision(revision: $0, mediaURL: mediaURL) }
        }
    }

    public func record(preparation entry: PreparationJournalEntry) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        if let existing = records.first(where: { $0.id == entry.id }) {
            existing.itemID = entry.itemID.rawValue; existing.requestID = entry.requestID
            existing.statusData = try JSONEncoder().encode(entry.status); existing.emittedAt = entry.status.emittedAt.date
        } else { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        try context.save()
    }

    /// Forgets one request's journal. A request identifier names an item, not
    /// an attempt, so a second attempt writes over the first's rows; without
    /// this the first attempt's terminal row would outlive it and report the
    /// second as finished while it was still running.
    public func clearPreparationJournal(for requestID: String) throws {
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        where record.requestID == requestID {
            context.delete(record)
        }
        try context.save()
    }

    public func preparationJournal(for requestID: String) throws -> [PreparationJournalEntry] {
        let context = ModelContext(container)
        let entries: [PreparationJournalEntry] = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()).filter { $0.requestID == requestID }.compactMap { record in
            guard let status = try? JSONDecoder().decode(PreparationStatus.self, from: record.statusData), let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
            return PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
        }
        return entries.sorted(by: preparationEntryPrecedes)
    }

    /// Deletes any earlier recovery markers for this episode and writes a
    /// fresh durable marker naming the rule that condemned it, so a launch
    /// that dies before admitting the recovery still finds it on the next
    /// one -- see `resetEpisodeIDs`/`forcedRedownloadEpisodeIDs` on
    /// `PodcastPreparationInvalidationResult`.
    private func writeInvalidationMarker(
        for itemID: ItemID, ruleID: String, needsRedownload: Bool, currentFingerprint: String,
        existingMarkers: [LocalLibrarySchemaV3Models.PreparationRecord], in context: ModelContext
    ) throws {
        for marker in existingMarkers where marker.itemID == itemID.rawValue
            && (marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
            context.delete(marker)
        }
        if needsRedownload {
            let markerRequestID = Self.forcedRedownloadRequestPrefix + itemID.rawValue
            let markerID = markerRequestID + "|marker"
            let markerError = try ProducerError(
                code: .invalidRequest,
                message: "The preparation pipeline changed and this episode needs a fresh download.",
                retryable: true,
                stage: "pipeline-invalidation"
            )
            let markerEvidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
                "fingerprint": currentFingerprint,
                "requiresRedownload": "true",
                "ruleID": ruleID
            ])
            let markerStatus = try PreparationStatus(
                stage: .failed,
                detail: markerError.message,
                cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .failed, error: markerError),
                emittedAt: Timestamp(Date()),
                evidence: markerEvidence
            )
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(
                PreparationJournalEntry(id: markerID, itemID: itemID, requestID: markerRequestID, status: markerStatus)
            ))
        } else {
            let markerRequestID = Self.resetPreparationRequestPrefix + itemID.rawValue
            let markerID = markerRequestID + "|marker"
            let markerEvidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
                "fingerprint": currentFingerprint,
                "requiresRedownload": "false",
                "ruleID": ruleID
            ])
            let markerStatus = try PreparationStatus(
                stage: .preparing,
                detail: "The preparation pipeline changed; this episode will be prepared again.",
                cancellable: false,
                emittedAt: Timestamp(Date()),
                evidence: markerEvidence
            )
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(
                PreparationJournalEntry(id: markerID, itemID: itemID, requestID: markerRequestID, status: markerStatus)
            ))
        }
    }

    /// Atomically clears podcast preparation results an explicit rule
    /// condemns. The journal is the provenance record: the first pipeline
    /// event names the source revision and hash, while the terminal event
    /// names the successor revision when a cut was committed.
    ///
    /// A fingerprint drift with no rule that applies to it is left untouched
    /// -- neither the journal nor any durable outcome row is disturbed --
    /// because most pipeline-hash changes (a log message, a comment, a
    /// refactor with no output effect) do not make an existing artifact
    /// wrong. `rules` has no default: every caller must say, explicitly,
    /// what it considers incompatible.
    public func invalidateStalePodcastPreparations(
        currentFingerprint: String, rules: [PodcastPreparationInvalidationRule]
    ) throws -> PodcastPreparationInvalidationResult {
        let context = ModelContext(container)
        let decoder = JSONDecoder()
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let podcastRecords = records.filter { $0.requestID.hasPrefix("podcast-prepare|") }
        let grouped = Dictionary(grouping: podcastRecords, by: \.requestID)
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        let downloadByEpisode = Dictionary(uniqueKeysWithValues: downloads.map { ($0.episodeID, $0) })
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var resetIDs = Set<ItemID>()
        var forcedIDs = Set<ItemID>()
        var currentIDs = Set<ItemID>()
        var reconciledIDs = Set<ItemID>()
        var mutated = false

        for (_, rows) in grouped {
            let entries = rows.compactMap { record -> PreparationJournalEntry? in
                guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                      let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
                return PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            }.sorted(by: preparationEntryPrecedes)
            guard let itemID = entries.last?.itemID else { continue }
            let provenance = entries.lazy.compactMap(\.status.evidence)
                .first(where: { $0.kind == Self.pipelineProvenanceEvidenceKind })
            guard provenance?.fields["fingerprint"] != currentFingerprint else {
                currentIDs.insert(itemID)
                continue
            }

            let readyRevisionID = readyRevisions[itemID.rawValue]?.revisionID.rawValue
            let outcomeRecord = readyRevisionID.flatMap { revisionID in
                outcomes.first { $0.episodeID == itemID.rawValue && $0.revisionID == revisionID }
            }
            let subject = PodcastPreparationInvalidationSubject(
                episodeID: itemID,
                semanticVersion: outcomeRecord?.semanticVersion,
                pipelineFingerprint: outcomeRecord?.pipelineFingerprint ?? provenance?.fields["fingerprint"]
            )
            guard let rule = rules.first(where: { $0.applies(subject) }) else {
                // No rule condemns this drift: leave the journal and any
                // surviving recovery markers alone rather than treating a
                // harmless fingerprint change as a reason to re-prepare or
                // re-download.
                continue
            }

            let terminal = entries.last(where: { $0.status.terminal })?.status.terminalResult
            let sourceHash = provenance?.fields["sourceHash"].flatMap { $0.isEmpty ? nil : $0 }
            let sourceRevisionID = provenance?.fields["sourceRevisionID"].flatMap { $0.isEmpty ? nil : $0 }
            let download = downloadByEpisode[itemID.rawValue]
            let sourceIntact: Bool
            if download?.status == PodcastDownloadStatus.completed.rawValue,
               let sourceHash,
               download?.contentHash == sourceHash,
               let sourceURL = download?.localURL.flatMap(URL.init) {
                sourceIntact = Self.localFileContentHash(at: sourceURL) == sourceHash
            } else {
                sourceIntact = false
            }
            let preparedSuccess = terminal?.outcome == .succeeded
            let successorReplacedSource = preparedSuccess
                && (sourceHash == nil || download?.contentHash != sourceHash || sourceRevisionID != terminal?.revisionID?.rawValue)
            let needsRedownload = rule.consequence == .forceRedownload || !sourceIntact || successorReplacedSource

            for record in rows { context.delete(record) }
            for marker in records where marker.itemID == itemID.rawValue
                && (marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                    || marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
                context.delete(marker)
            }
            reconciledIDs.insert(itemID)
            mutated = true
            if let outcomeRecord {
                outcomeRecord.eligibility = PodcastPreparationEligibility.invalid.rawValue
                outcomeRecord.invalidationRuleID = rule.id
            }
            try writeInvalidationMarker(
                for: itemID, ruleID: rule.id, needsRedownload: needsRedownload,
                currentFingerprint: currentFingerprint, existingMarkers: records, in: context
            )
            if needsRedownload { forcedIDs.insert(itemID) } else { resetIDs.insert(itemID) }
        }

        // Pass 2 covers preparation outcomes left `.current` with no journal
        // group for the loop above to walk. That is not "no audio change,
        // so no journal was ever written" -- `PodcastPreparationPipeline.
        // prepare()` calls `journalTerminal` on both the success and catch
        // paths, cut or not -- it is a journal that was cleared or never
        // completed for this ready revision, e.g. a second run's
        // `clearPreparationJournal` wiping the
        // first run's entry before the second run itself finished. Either
        // way the provenance a redownload decision needs -- the source hash
        // recorded at download time, before any cut -- is gone with the
        // journal. `sourceIntact` cannot be reconstructed here: the download
        // record's `contentHash` is the CURRENT file's hash, so comparing it
        // against a fresh re-hash of that same file is always true, even
        // when the file is already-cut output. Resetting in place on that
        // false signal would re-run the pipeline over already-cut audio.
        // Always force a redownload instead -- it costs bandwidth, never
        // correctness.
        let visitedIDs = reconciledIDs.union(currentIDs)
        for outcomeRecord in outcomes where outcomeRecord.eligibility == PodcastPreparationEligibility.current.rawValue {
            guard let itemID = try? ItemID(rawValue: outcomeRecord.episodeID), !visitedIDs.contains(itemID),
                  let ready = readyRevisions[itemID.rawValue], ready.revisionID.rawValue == outcomeRecord.revisionID,
                  outcomeRecord.pipelineFingerprint != currentFingerprint else { continue }
            let subject = PodcastPreparationInvalidationSubject(
                episodeID: itemID, semanticVersion: outcomeRecord.semanticVersion,
                pipelineFingerprint: outcomeRecord.pipelineFingerprint
            )
            guard let rule = rules.first(where: { $0.applies(subject) }) else { continue }
            let needsRedownload = true
            outcomeRecord.eligibility = PodcastPreparationEligibility.invalid.rawValue
            outcomeRecord.invalidationRuleID = rule.id
            mutated = true
            reconciledIDs.insert(itemID)
            try writeInvalidationMarker(
                for: itemID, ruleID: rule.id, needsRedownload: needsRedownload,
                currentFingerprint: currentFingerprint, existingMarkers: records, in: context
            )
            if needsRedownload { forcedIDs.insert(itemID) } else { resetIDs.insert(itemID) }
        }

        for marker in records where marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix) {
            guard let itemID = try? ItemID(rawValue: marker.itemID) else { continue }
            guard !reconciledIDs.contains(itemID) else { continue }
            if currentIDs.contains(itemID) {
                context.delete(marker)
                mutated = true
            } else {
                forcedIDs.insert(itemID)
            }
        }
        for marker in records where marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix) {
            guard let itemID = try? ItemID(rawValue: marker.itemID) else { continue }
            guard !reconciledIDs.contains(itemID) else { continue }
            if currentIDs.contains(itemID) {
                context.delete(marker)
                mutated = true
            } else {
                resetIDs.insert(itemID)
            }
        }
        resetIDs.subtract(forcedIDs)
        if mutated { try context.save() }
        return PodcastPreparationInvalidationResult(
            resetEpisodeIDs: resetIDs.sorted { $0.rawValue < $1.rawValue },
            forcedRedownloadEpisodeIDs: forcedIDs.sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Re-hashes the bytes instead of trusting two persisted copies of the
    /// same download hash. A missing, unreadable, or changing file is not
    /// positive evidence that stale preparation can safely reuse its source.
    private static func localFileContentHash(at url: URL) -> String? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A forced download has replaced the ambiguous prepared bytes with a
    /// fresh source. Convert its durable marker instead of clearing it: if the
    /// app exits before preparation is admitted, the next launch still knows
    /// to resume without downloading the same source again.
    public func markForcedRedownloadCompleted(
        for episodeID: ItemID,
        currentFingerprint: String
    ) throws {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let forcedRequestID = Self.forcedRedownloadRequestPrefix + episodeID.rawValue
        guard rows.contains(where: { $0.requestID == forcedRequestID }) else { return }
        for row in rows where row.itemID == episodeID.rawValue
            && (row.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || row.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
            context.delete(row)
        }
        let resetRequestID = Self.resetPreparationRequestPrefix + episodeID.rawValue
        let evidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
            "fingerprint": currentFingerprint,
            "requiresRedownload": "false"
        ])
        let status = try PreparationStatus(
            stage: .preparing,
            detail: "The fresh download will be prepared with the current pipeline.",
            cancellable: false,
            emittedAt: Timestamp(Date()),
            evidence: evidence
        )
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: resetRequestID + "|marker", itemID: episodeID,
            requestID: resetRequestID, status: status
        )))
        try context.save()
    }

    /// Whether pipeline invalidation still requires bytes from the publisher.
    ///
    /// This is queried at transfer time, not only during bootstrap. A queued
    /// download claim can survive an app exit, and its automation resume must
    /// retain the forced-download requirement instead of accepting the stale
    /// file that caused the marker.
    public func requiresForcedRedownload(for episodeID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        let requestID = Self.forcedRedownloadRequestPrefix + episodeID.rawValue
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
            .contains { $0.requestID == requestID }
    }

    /// What the preparation that produced this revision removed.
    ///
    /// `preparationRuns()` decodes every journalled status in the library,
    /// which is the wrong shape for a lookup the player performs each time it
    /// loads a transcript. Only the terminal statuses of this item are
    /// decoded, and only a successful one carries a timeline.
    ///
    /// The revision is part of the question rather than a detail of the
    /// answer. Cutting an episode changes its bytes and therefore its
    /// identity, so a timeline belongs to exactly one revision; drawing the
    /// newest success over whatever is ready now would put cut markers on
    /// uncut audio if a re-download or a prune ever moved the ready revision
    /// back. Journal entries old enough to carry no revision are skipped, and
    /// they predate timelines anyway.
    public func latestPreparationTimeline(
        for itemID: ItemID,
        revisionID: RevisionID
    ) throws -> PreparationStatus.PreparationTimeline? {
        let raw = itemID.rawValue
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.itemID == raw },
            sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maximumTimelineLookupRecords
        let decoder = JSONDecoder()
        for record in try context.fetch(descriptor) {
            guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  status.terminal,
                  let result = status.terminalResult,
                  result.outcome == .succeeded,
                  result.revisionID == revisionID,
                  let timeline = status.timeline else { continue }
            return timeline
        }
        return nil
    }

    /// A ceiling on the newest-first scan above. An item that has been
    /// prepared repeatedly still finds its last success within a few rows,
    /// and a library whose journal was never pruned should not turn one
    /// transcript load into a full-table decode.
    private static let maximumTimelineLookupRecords = 64

    /// Every recorded preparation attempt, newest first.
    ///
    /// A run that emitted no terminal status is reported as non-terminal at
    /// whatever stage it last reached, rather than being dropped. A process
    /// that died mid-synthesis is exactly the run a reader most wants to see.
    public func preparationRuns(limit: Int = 200) throws -> [PreparationRunSummary] {
        let context = ModelContext(container)
        return try allPreparationRunSummaries(in: context).prefix(max(0, limit)).map { $0 }
    }

    /// Every recorded preparation attempt, newest first, with no cap.
    ///
    /// `preparationRuns(limit:)`'s cap exists for Prep's display list, not
    /// for correctness -- a caller that needs every subscribed episode's
    /// evidence (the Larder projection) reads this directly instead of
    /// passing an unbounded `limit`, which would otherwise make the display
    /// cap's own default meaningless as a contract.
    private func allPreparationRunSummaries(in context: ModelContext) throws -> [PreparationRunSummary] {
        let decoder = JSONDecoder()
        var byRequest: [String: [PreparationJournalEntry]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()) {
            // Pipeline invalidation markers are durable scheduling state, not
            // preparation attempts. Keeping them out of run history also
            // prevents bootstrap from closing a pending marker as an
            // interrupted preparation and showing a phantom failed job.
            guard !record.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix),
                  !record.requestID.hasPrefix(Self.resetPreparationRequestPrefix) else { continue }
            guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  let itemID = try? ItemID(rawValue: record.itemID) else { continue }
            byRequest[record.requestID, default: []].append(
                PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            )
        }
        return byRequest.compactMap { requestID, entries -> PreparationRunSummary? in
            let ordered = entries.sorted(by: preparationEntryPrecedes)
            guard let first = ordered.first, let last = ordered.last else { return nil }
            let terminal = ordered.last(where: { $0.status.terminal })?.status
            let representative = terminal ?? last.status
            return PreparationRunSummary(
                requestID: requestID,
                itemID: last.itemID,
                startedAt: first.status.emittedAt,
                updatedAt: last.status.emittedAt,
                stage: representative.stage,
                detail: representative.detail,
                fraction: representative.fraction,
                isTerminal: terminal != nil,
                outcome: terminal?.terminalResult?.outcome,
                failure: terminal?.terminalResult?.error,
                entries: ordered
            )
        }
        .sorted { $0.updatedAt.date > $1.updatedAt.date }
    }

    /// One batched, indexed read of everything the Larder projection needs.
    ///
    /// `loadLibrary` used to call `readyRevision(for:)`,
    /// `playbackState(for:revisionID:)`, `transcript(for:revisionID:)`,
    /// `preparationOutcome(for:revisionID:)`, `listeningState(for:)`, and
    /// `retiredAt(for:)` once per article/episode, each of those doing its
    /// own unfiltered full-table fetch -- a full-table scan repeated once per
    /// item per field. This fetches each table exactly once and hands back
    /// indexed dictionaries, so the read cost stays flat as the library
    /// grows.
    public struct PodcastLibrarySnapshot: Sendable {
        public let articles: [Article]
        public let episodes: [PodcastEpisode]
        public let feeds: [ItemID: PodcastFeed]
        public let subscriptions: [PodcastSubscription]
        public let downloads: [ItemID: PodcastDownload]
        public let readyRevisions: [ItemID: StoredAudioRevision]
        /// Keyed `"itemID|revisionID"`, matching every other composite-keyed table in this store.
        public let playbackStates: [String: PlaybackState]
        public let transcripts: [String: Transcript]
        public let preparationOutcomes: [String: PodcastPreparationOutcome]
        public let listeningStates: [ItemID: PodcastListeningState]
        public let retiredAtByEpisode: [ItemID: Timestamp]
        /// Every recorded preparation run, uncapped -- see `allPreparationRunSummaries`.
        public let preparationRuns: [PreparationRunSummary]
    }

    public func podcastLibrarySnapshot() throws -> PodcastLibrarySnapshot {
        let context = ModelContext(container)

        podcastLibrarySnapshotFetchCount += 1
        let articleValues = try articles()

        podcastLibrarySnapshotFetchCount += 1
        let episodeRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .sorted { ($0.publishedTime ?? $0.createdAt) > ($1.publishedTime ?? $1.createdAt) }
        let episodeValues = episodeRecords.compactMap(Self.decodePodcastEpisode)
        var retiredAtByEpisode: [ItemID: Timestamp] = [:]
        for record in episodeRecords {
            guard let itemID = try? ItemID(rawValue: record.id), let retiredAt = record.retiredAt else { continue }
            retiredAtByEpisode[itemID] = Timestamp(retiredAt)
        }

        podcastLibrarySnapshotFetchCount += 1
        let feeds = Dictionary(uniqueKeysWithValues: try podcastFeeds().map { ($0.itemID, $0) })

        podcastLibrarySnapshotFetchCount += 1
        let subscriptionValues = try subscriptions()

        podcastLibrarySnapshotFetchCount += 1
        let downloads = Dictionary(uniqueKeysWithValues: try self.downloads().map { ($0.episodeID, $0) })

        podcastLibrarySnapshotFetchCount += 1
        let readyRevisions = Dictionary(
            uniqueKeysWithValues: try newestReadyRevisionsByItemID(in: context).compactMap { itemIDRaw, revision -> (ItemID, StoredAudioRevision)? in
                guard let itemID = try? ItemID(rawValue: itemIDRaw) else { return nil }
                return (itemID, revision)
            }
        )

        podcastLibrarySnapshotFetchCount += 1
        var playbackStates: [String: PlaybackState] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()) {
            guard let itemID = try? ItemID(rawValue: record.itemID), let revisionID = try? RevisionID(rawValue: record.revisionID),
                  let state = try? PlaybackState(
                      itemID: itemID, revisionID: revisionID, sessionID: record.sessionID, sequence: record.sequence,
                      positionSeconds: record.positionSeconds, durationSeconds: record.durationSeconds, completed: record.completed,
                      intent: PlaybackIntent(rawValue: record.intent) ?? .progress, deviceID: record.deviceID,
                      encodedCloudKitRecordSystemFields: record.encodedCloudKitRecordSystemFields, updatedAt: Timestamp(record.updatedAt)
                  ) else { continue }
            playbackStates["\(record.itemID)|\(record.revisionID)"] = state
        }

        podcastLibrarySnapshotFetchCount += 1
        var transcripts: [String: Transcript] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()) {
            guard let transcript = try? decodeTranscript(record) else { continue }
            transcripts["\(record.itemID)|\(record.revisionID)"] = transcript
        }

        podcastLibrarySnapshotFetchCount += 1
        var preparationOutcomes: [String: PodcastPreparationOutcome] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
            guard let episodeID = try? ItemID(rawValue: record.episodeID), let revisionID = try? RevisionID(rawValue: record.revisionID),
                  let eligibility = PodcastPreparationEligibility(rawValue: record.eligibility) else { continue }
            preparationOutcomes["\(record.episodeID)|\(record.revisionID)"] = PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: revisionID, policyDigest: record.policyDigest,
                pipelineFingerprint: record.pipelineFingerprint, semanticVersion: record.semanticVersion,
                producedAt: Timestamp(record.producedAt), eligibility: eligibility,
                invalidationRuleID: record.invalidationRuleID
            )
        }

        podcastLibrarySnapshotFetchCount += 1
        var listeningStates: [ItemID: PodcastListeningState] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()) {
            guard let episodeID = try? ItemID(rawValue: record.id) else { continue }
            listeningStates[episodeID] = PodcastListeningState(
                episodeID: episodeID, completedAt: record.completedAt.map(Timestamp.init),
                lastRevisionID: record.lastRevisionID.flatMap { try? RevisionID(rawValue: $0) },
                updatedAt: Timestamp(record.updatedAt)
            )
        }

        podcastLibrarySnapshotFetchCount += 1
        let preparationRuns = try allPreparationRunSummaries(in: context)

        return PodcastLibrarySnapshot(
            articles: articleValues, episodes: episodeValues, feeds: feeds, subscriptions: subscriptionValues,
            downloads: downloads, readyRevisions: readyRevisions, playbackStates: playbackStates,
            transcripts: transcripts, preparationOutcomes: preparationOutcomes, listeningStates: listeningStates,
            retiredAtByEpisode: retiredAtByEpisode, preparationRuns: preparationRuns
        )
    }

    public func save(playback state: PlaybackState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
        if let existing = records.first(where: { $0.id == id }) {
            existing.sessionID = state.sessionID; existing.sequence = state.sequence; existing.positionSeconds = state.positionSeconds
            existing.durationSeconds = state.durationSeconds; existing.completed = state.completed; existing.intent = state.intent.rawValue
            existing.deviceID = state.deviceID
            if let systemFields = state.encodedCloudKitRecordSystemFields {
                existing.encodedCloudKitRecordSystemFields = systemFields
            }
            existing.updatedAt = state.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(state)) }
        try context.save()
    }

    /// Writes the completed playback checkpoint and the "finished listening"
    /// fact in one `ModelContext`/one save, so a crash between the two never
    /// leaves the checkpoint durable without the listening record, or vice
    /// versa.
    public func save(playback: PlaybackState, listening: PodcastListeningState) throws {
        let context = ModelContext(container)
        let playbackRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let playbackID = "\(playback.itemID.rawValue)|\(playback.revisionID.rawValue)"
        if let existing = playbackRecords.first(where: { $0.id == playbackID }) {
            existing.sessionID = playback.sessionID; existing.sequence = playback.sequence; existing.positionSeconds = playback.positionSeconds
            existing.durationSeconds = playback.durationSeconds; existing.completed = playback.completed; existing.intent = playback.intent.rawValue
            existing.deviceID = playback.deviceID
            if let systemFields = playback.encodedCloudKitRecordSystemFields {
                existing.encodedCloudKitRecordSystemFields = systemFields
            }
            existing.updatedAt = playback.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback)) }

        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = listeningRecords.first(where: { $0.id == listening.episodeID.rawValue }) {
            existing.completedAt = listening.completedAt?.date
            existing.lastRevisionID = listening.lastRevisionID?.rawValue
            existing.updatedAt = listening.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(listening))
        }
        try context.save()
    }

    public func playbackState(for itemID: ItemID, revisionID: RevisionID) throws -> PlaybackState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.itemID == itemID.rawValue && $0.revisionID == revisionID.rawValue }) else { return nil }
        return try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: record.sessionID, sequence: record.sequence,
                                 positionSeconds: record.positionSeconds, durationSeconds: record.durationSeconds, completed: record.completed,
                                 intent: PlaybackIntent(rawValue: record.intent) ?? .progress, deviceID: record.deviceID,
                                 encodedCloudKitRecordSystemFields: record.encodedCloudKitRecordSystemFields, updatedAt: Timestamp(record.updatedAt))
    }

    // MARK: CloudKit sidecars and reconciliation state

    /// Saves opaque sync state and replaces both optional operation timestamps.
    public func save(syncState state: LocalLibrarySyncState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        if let existing = records.first(where: { $0.key == state.key }) {
            existing.engineState = state.engineState
            existing.lastFetchAt = state.lastFetchAt?.date
            existing.lastSendAt = state.lastSendAt?.date
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(state))
        }
        try context.save()
    }

    /// Loads the persisted state for one sync-zone key.
    public func syncState(for key: String) throws -> LocalLibrarySyncState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>()).first(where: { $0.key == key }) else { return nil }
        return LocalLibrarySyncState(key: record.key, engineState: record.engineState,
                                     lastFetchAt: record.lastFetchAt.map(Timestamp.init), lastSendAt: record.lastSendAt.map(Timestamp.init))
    }

    /// Records a successful fetch without inspecting the opaque engine bytes.
    public func recordSuccessfulFetch(at date: Timestamp = Timestamp(Date()), for key: String = "private-zone") throws {
        let prior = try syncState(for: key)
        try save(syncState: LocalLibrarySyncState(key: key, engineState: prior?.engineState ?? Data(),
                                                  lastFetchAt: date, lastSendAt: prior?.lastSendAt))
    }

    /// Records a successful send without inspecting the opaque engine bytes.
    public func recordSuccessfulSend(at date: Timestamp = Timestamp(Date()), for key: String = "private-zone") throws {
        let prior = try syncState(for: key)
        try save(syncState: LocalLibrarySyncState(key: key, engineState: prior?.engineState ?? Data(),
                                                  lastFetchAt: prior?.lastFetchAt, lastSendAt: date))
    }

    /// Persists opaque playback system fields and the latest remote change tag.
    public func save(playbackSidecar sidecar: PlaybackSystemFieldsSidecar, for itemID: ItemID, revisionID: RevisionID) throws {
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.id == id }) else { return }
        record.encodedCloudKitRecordSystemFields = sidecar.encodedSystemFields
        record.encodedCloudKitRecordChangeTag = sidecar.changeTag
        try context.save()
    }

    /// Loads opaque playback system fields and the latest remote change tag.
    public func playbackSidecar(for itemID: ItemID, revisionID: RevisionID) throws -> PlaybackSystemFieldsSidecar? {
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.id == id }) else { return nil }
        return PlaybackSystemFieldsSidecar(encodedSystemFields: record.encodedCloudKitRecordSystemFields,
                                           changeTag: record.encodedCloudKitRecordChangeTag)
    }

    /// Saves a deletion tombstone while keeping remote acknowledgement monotonic.
    public func record(tombstone: LocalLibraryTombstone) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>())
        if let existing = records.first(where: { $0.id == tombstone.id }) {
            existing.itemID = tombstone.itemID.rawValue
            existing.generationID = tombstone.generationID
            existing.requestedAt = tombstone.requestedAt.date
            // Acknowledgement is monotonic and cannot be accidentally undone by replay.
            existing.remoteAcknowledged = existing.remoteAcknowledged || tombstone.remoteAcknowledged
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(tombstone))
        }
        try context.save()
    }

    /// Loads one deletion tombstone by its stable identifier.
    public func tombstone(for id: String) throws -> LocalLibraryTombstone? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).first(where: { $0.id == id }),
              let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
        return LocalLibraryTombstone(id: record.id, itemID: itemID, generationID: record.generationID,
                                     requestedAt: Timestamp(record.requestedAt), remoteAcknowledged: record.remoteAcknowledged)
    }

    /// Loads all persisted deletion tombstones.
    public func tombstones() throws -> [LocalLibraryTombstone] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).compactMap { record in
            guard let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
            return LocalLibraryTombstone(id: record.id, itemID: itemID, generationID: record.generationID,
                                         requestedAt: Timestamp(record.requestedAt), remoteAcknowledged: record.remoteAcknowledged)
        }
    }

    /// Marks a tombstone acknowledged; replaying an acknowledgement returns false.
    @discardableResult
    public func acknowledgeTombstone(id: String) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).first(where: { $0.id == id }) else { return false }
        guard !record.remoteAcknowledged else { return false }
        record.remoteAcknowledged = true
        try context.save()
        return true
    }

    /// Sets the local/remote status used by generation absence deletion.
    public func setSyncStatus(_ status: LocalLibrarySyncStatus, for itemID: ItemID) throws {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return }
        record.syncStatus = status.rawValue
        try context.save()
    }

    /// Loads the sync status for one local item.
    public func syncStatus(for itemID: ItemID) throws -> LocalLibrarySyncStatus? {
        let context = ModelContext(container)
        guard let raw = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue })?.syncStatus else { return nil }
        return LocalLibrarySyncStatus(rawValue: raw)
    }

    /// Finalizes one generation, deleting only unseen remote-acknowledged items.
    @discardableResult
    public func finalizeSnapshot(generationID: String, fetchComplete: Bool, seenRemoteItemIDs: Set<ItemID>) throws -> LocalLibrarySnapshotResult {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
        let seen = Set(seenRemoteItemIDs.map(\.rawValue))
        let deleted: [ItemID]
        if fetchComplete {
            deleted = records.compactMap { record in
                guard record.syncStatus == LocalLibrarySyncStatus.remoteAcknowledged.rawValue,
                      !seen.contains(record.id), let itemID = try? ItemID(rawValue: record.id) else { return nil }
                return itemID
            }
            for itemID in deleted {
                for revision in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(revision) }
                for transcript in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(transcript) }
                for playback in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(playback) }
                if let article = records.first(where: { $0.id == itemID.rawValue }) { context.delete(article) }
            }
            if !deleted.isEmpty { try context.save() }
        } else {
            deleted = []
        }
        let retained = records.compactMap { try? ItemID(rawValue: $0.id) }.filter { !deleted.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return LocalLibrarySnapshotResult(generationID: generationID, deletedItemIDs: deleted.sorted { $0.rawValue < $1.rawValue }, retainedItemIDs: retained, mutated: !deleted.isEmpty)
    }

    /// Applies one validated sync transaction in a single SwiftData context save.
    public func applySyncCommit(_ commit: LocalLibrarySyncCommit) throws {
        let context = ModelContext(container)
        let articles = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        let transcripts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        let playbacks = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())

        for deletion in commit.deletions {
            switch deletion.recordType {
            case .item:
                let itemID = String(deletion.recordName.dropFirst("item:".count))
                for revision in revisions where revision.itemID == itemID { context.delete(revision) }
                for transcript in transcripts where transcript.itemID == itemID { context.delete(transcript) }
                for playback in playbacks where playback.itemID == itemID { context.delete(playback) }
                for article in articles where article.id == itemID { context.delete(article) }
            case .revision:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for revision in revisions where revision.itemID == parts[1] && revision.id == parts[2] { context.delete(revision) } }
            case .transcript:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for transcript in transcripts where transcript.itemID == parts[1] && transcript.revisionID == parts[2] { context.delete(transcript) } }
            case .revisionChunk:
                // Chunk rows live only in the durable transport state.
                break
            case .playbackState:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for playback in playbacks where playback.id == "\(parts[1])|\(parts[2])" { context.delete(playback) } }
            }
        }

        for applied in commit.articles {
            if let existing = articles.first(where: { $0.id == applied.article.itemID.rawValue }) {
                existing.canonicalURL = applied.article.canonicalURL.absoluteString; existing.title = applied.article.title
                existing.source = applied.article.source; existing.author = applied.article.author
                existing.publishedTime = applied.article.publishedTime?.date; existing.createdAt = applied.article.createdAt.date
                existing.isRemoved = applied.article.isDeleted; existing.syncStatus = applied.status.rawValue
                existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                let record = LocalLibrarySchemaV5Models.ArticleRecord(applied.article)
                record.syncStatus = applied.status.rawValue
                context.insert(record)
            }
        }

        // A delete mutation has no article envelope, but its local item must
        // still advertise pending/conflicted ownership to library readers.
        for article in articles where !commit.articles.contains(where: { $0.article.itemID.rawValue == article.id }) {
            guard let itemID = try? ItemID(rawValue: article.id), let recordID = try? WiltedRecordID.item(itemID) else { continue }
            if commit.state.conflictedRecordIDs.contains(recordID) {
                article.syncStatus = LocalLibrarySyncStatus.conflicted.rawValue
            } else if commit.state.pendingChanges.contains(where: { $0.recordID == recordID }) {
                article.syncStatus = LocalLibrarySyncStatus.pendingUpload.rawValue
            }
        }

        for update in commit.statusUpdates where update.recordID.recordType == .item {
            let components = update.recordID.recordName.split(separator: ":")
            guard components.count == 2, let itemID = try? ItemID(rawValue: String(components[1])) else { continue }
            if let article = articles.first(where: { $0.id == itemID.rawValue }) {
                article.syncStatus = update.status.rawValue
            }
        }

        for applied in commit.revisions {
            if let existing = revisions.first(where: { $0.id == applied.revision.revisionID.rawValue }) {
                guard existing.itemID == applied.revision.itemID.rawValue,
                      existing.contentHash == applied.revision.contentHash,
                      existing.mediaURL == applied.mediaURL.absoluteString else {
                    throw LocalLibraryStoreError.immutableRevision(applied.revision.revisionID, site: .syncCommit)
                }
            } else {
                context.insert(LocalLibrarySchemaV3Models.RevisionRecord(applied.revision, mediaURL: applied.mediaURL))
            }
        }

        for applied in commit.transcripts {
            try upsert(applied.transcript, in: context)
        }

        for applied in commit.playbacks {
            let recordID = try WiltedRecordID.playback(applied.state.itemID, applied.state.revisionID)
            guard !commit.state.pendingChanges.contains(where: { $0.recordID == recordID }) else { continue }
            let id = "\(applied.state.itemID.rawValue)|\(applied.state.revisionID.rawValue)"
            if let existing = playbacks.first(where: { $0.id == id }) {
                let current = try PlaybackState(itemID: applied.state.itemID, revisionID: applied.state.revisionID,
                                                sessionID: existing.sessionID, sequence: existing.sequence,
                                                positionSeconds: existing.positionSeconds, durationSeconds: existing.durationSeconds,
                                                completed: existing.completed, intent: PlaybackIntent(rawValue: existing.intent) ?? .progress,
                                                deviceID: existing.deviceID, encodedCloudKitRecordSystemFields: existing.encodedCloudKitRecordSystemFields,
                                                updatedAt: Timestamp(existing.updatedAt))
                let incomingTag = applied.sidecar.changeTag
                let merge = mergePlayback(current: current, incoming: applied.state, changeTagMatches: true)
                if merge.acceptedStateIsIncoming {
                    existing.sessionID = applied.state.sessionID; existing.sequence = applied.state.sequence
                    existing.positionSeconds = applied.state.positionSeconds; existing.durationSeconds = applied.state.durationSeconds
                    existing.completed = applied.state.completed; existing.intent = applied.state.intent.rawValue
                    existing.deviceID = applied.state.deviceID; existing.updatedAt = applied.state.updatedAt.date
                }
                existing.encodedCloudKitRecordSystemFields = applied.sidecar.encodedSystemFields
                existing.encodedCloudKitRecordChangeTag = incomingTag
            } else {
                let record = LocalLibrarySchemaV3Models.PlaybackRecord(applied.state)
                record.encodedCloudKitRecordSystemFields = applied.sidecar.encodedSystemFields
                record.encodedCloudKitRecordChangeTag = applied.sidecar.changeTag
                context.insert(record)
            }
        }

        let tombstones = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>())
        for tombstone in commit.state.tombstones {
            let id = "item:\(tombstone.itemID.rawValue):\(tombstone.generationID)"
            if let existing = tombstones.first(where: { $0.id == id }) {
                existing.itemID = tombstone.itemID.rawValue; existing.generationID = tombstone.generationID
                existing.requestedAt = tombstone.requestedAt.date
                existing.remoteAcknowledged = existing.remoteAcknowledged || tombstone.remoteAcknowledged
                existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(
                    LocalLibraryTombstone(id: id, itemID: tombstone.itemID, generationID: tombstone.generationID,
                                          requestedAt: tombstone.requestedAt, remoteAcknowledged: tombstone.remoteAcknowledged)))
            }
        }

        let encodedRepositoryState = try JSONEncoder().encode(commit.state)
        let syncStates = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        if let existing = syncStates.first(where: { $0.key == "private-zone" }) {
            existing.engineState = commit.state.engineState ?? Data()
            if let lastFetchAt = commit.lastFetchAt { existing.lastFetchAt = lastFetchAt.date }
            if let lastSendAt = commit.lastSendAt { existing.lastSendAt = lastSendAt.date }
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(
                LocalLibrarySyncState(key: "private-zone", engineState: commit.state.engineState ?? Data(),
                                      lastFetchAt: commit.lastFetchAt, lastSendAt: commit.lastSendAt)))
        }
        let repositoryStates = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RepositoryStateRecord>())
        if let existing = repositoryStates.first(where: { $0.key == "private-zone" }) {
            existing.stateData = encodedRepositoryState
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.RepositoryStateRecord(stateData: encodedRepositoryState))
        }
        try context.save()
    }

    /// Loads the sync repository snapshot embedded in the SwiftData sync-state record.
    public func syncRepositoryState() throws -> SyncRepositoryState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RepositoryStateRecord>()).first(where: { $0.key == "private-zone" }) else { return nil }
        return try JSONDecoder().decode(SyncRepositoryState.self, from: record.stateData)
    }

    // MARK: Podcast catalog and local listening state

    public func save(feed: PodcastFeed) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>())
        if let existing = records.first(where: { $0.id == feed.itemID.rawValue }) {
            existing.canonicalURL = feed.canonicalURL.absoluteString; existing.title = feed.title
            existing.author = feed.author; existing.artworkURL = feed.artworkURL?.absoluteString; existing.createdAt = feed.createdAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastFeedRecord(feed)) }
        try context.save()
    }

    public func save(podcastFeed feed: PodcastFeed) throws { try save(feed: feed) }

    public func podcastFeed(for feedID: ItemID) throws -> PodcastFeed? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>()).first(where: { $0.id == feedID.rawValue }),
              let canonicalURL = URL(string: record.canonicalURL) else { return nil }
        return try PodcastFeed(itemID: feedID, canonicalURL: canonicalURL, title: record.title,
                               author: record.author, artworkURL: record.artworkURL.flatMap(URL.init), createdAt: Timestamp(record.createdAt))
    }

    public func podcastFeeds() throws -> [PodcastFeed] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>()).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.compactMap { record in
            guard let id = try? ItemID(rawValue: record.id), let url = URL(string: record.canonicalURL) else { return nil }
            return try? PodcastFeed(itemID: id, canonicalURL: url, title: record.title, author: record.author,
                                    artworkURL: record.artworkURL.flatMap(URL.init), createdAt: Timestamp(record.createdAt))
        }
    }

    public func save(episode: PodcastEpisode) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
        if let existing = records.first(where: { $0.id == episode.itemID.rawValue }) {
            try Self.apply(episode, to: existing)
        } else { context.insert(try LocalLibrarySchemaV10Models.PodcastEpisodeRecord(episode)) }
        try context.save()
    }

    public func save(podcastEpisode episode: PodcastEpisode) throws { try save(episode: episode) }

    public func podcastEpisode(for episodeID: ItemID) throws -> PodcastEpisode? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>()).first(where: { $0.id == episodeID.rawValue }),
              let feedID = try? ItemID(rawValue: record.feedID), let feedURL = URL(string: record.feedURL),
              let enclosureURL = URL(string: record.enclosureURL) else { return nil }
        return try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: record.rssGUID,
                                  title: record.title, author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                                  enclosureURL: enclosureURL, enclosureMediaType: record.enclosureMediaType,
                                  enclosureByteCount: record.enclosureByteCount, durationSeconds: record.durationSeconds,
                                  artworkURL: record.artworkURL.flatMap(URL.init),
                                  transcriptSources: try LocalLibrarySchemaV10Models.PodcastEpisodeRecord.decode(record.transcriptSources),
                                  notes: record.notes, createdAt: Timestamp(record.createdAt))
    }

    public func podcastEpisodes(for feedID: ItemID? = nil) throws -> [PodcastEpisode] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .filter { feedID == nil || $0.feedID == feedID!.rawValue }
            .sorted { ($0.publishedTime ?? $0.createdAt) > ($1.publishedTime ?? $1.createdAt) }
            .compactMap(Self.decodePodcastEpisode)
    }

    private static func decodePodcastEpisode(_ record: LocalLibrarySchemaV10Models.PodcastEpisodeRecord) -> PodcastEpisode? {
        guard let id = try? ItemID(rawValue: record.id), let fid = try? ItemID(rawValue: record.feedID),
              let feedURL = URL(string: record.feedURL), let enclosureURL = URL(string: record.enclosureURL) else { return nil }
        return try? PodcastEpisode(itemID: id, feedID: fid, feedURL: feedURL, rssGUID: record.rssGUID, title: record.title,
                                   author: record.author, publishedTime: record.publishedTime.map(Timestamp.init), enclosureURL: enclosureURL,
                                   enclosureMediaType: record.enclosureMediaType, enclosureByteCount: record.enclosureByteCount,
                                   durationSeconds: record.durationSeconds, artworkURL: record.artworkURL.flatMap(URL.init),
                                   transcriptSources: (try? LocalLibrarySchemaV10Models.PodcastEpisodeRecord.decode(record.transcriptSources)) ?? [],
                                   notes: record.notes, createdAt: Timestamp(record.createdAt))
    }

    public func save(subscription: PodcastSubscription) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        if let existing = records.first(where: { $0.feedID == subscription.feedID.rawValue }) {
            existing.subscribedAt = subscription.subscribedAt.date; existing.enabled = subscription.enabled
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription)) }
        try context.save()
    }

    public func save(feedSubscription subscription: PodcastSubscription) throws { try save(subscription: subscription) }

    public func subscription(for feedID: ItemID) throws -> PodcastSubscription? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>()).first(where: { $0.feedID == feedID.rawValue }) else { return nil }
        return PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(record.subscribedAt), enabled: record.enabled)
    }

    public func subscriptions() throws -> [PodcastSubscription] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>()).compactMap { record in
            guard let feedID = try? ItemID(rawValue: record.feedID) else { return nil }
            return PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(record.subscribedAt), enabled: record.enabled)
        }
    }

    /// Which horizon a feed load is admitted against.
    ///
    /// `backfill` is the load that creates the subscription; `incremental` is
    /// every later refresh.
    public enum PodcastEpisodeAdmission: Sendable {
        case backfill
        case incremental
    }

    public struct PodcastEpisodeAdmissionResult: Equatable, Sendable {
        public let saved: [ItemID]
        /// IDs inserted by this exact admission, excluding rows refreshed in place.
        public let newlyAdmitted: [ItemID]
        public let skipped: Int
    }

    public struct PodcastEpisodeRestoreResult: Equatable, Sendable {
        public let restored: Bool
        public let saved: [ItemID]
        public let skipped: Int
    }

    /// Persists only the episodes a subscribed feed should surface.
    ///
    /// Subscribing to a podcast must not empty its whole back catalogue into the
    /// Larder: a single feed in the 2026-08-31 survey carried 2,870 episodes. An
    /// episode is stored when Wilted already knows it -- so nothing already in
    /// the Larder can be evicted by this rule -- or when it published on or
    /// after the feed's admission horizon.
    ///
    /// The horizon is the subscription's own `subscribedAt` on a refresh, so
    /// every genuinely new episode arrives and nothing older does. On the load
    /// that creates the subscription it reaches back
    /// `podcastSubscriptionBackfillWindow`, and always admits at least
    /// `podcastSubscriptionMinimumBackfill` episodes, so subscribing to an
    /// infrequent podcast does not present an empty feed.
    ///
    /// An episode with no published date never clears a horizon, in either
    /// direction. Without a date there is no evidence it is new, and admitting
    /// undated items on refresh would leak an undated back catalogue a refresh
    /// at a time -- while admitting all of them on backfill would leak the same
    /// catalogue in one go. Undated episodes reach the Larder only through the
    /// `podcastSubscriptionMinimumBackfill` top-up, which is bounded. The cost
    /// is that a feed publishing no dates at all stalls at that count; every
    /// feed in the 2026-08-31 survey dates its episodes, and the withheld count
    /// on the Feeds card makes the stall visible rather than silent.
    ///
    /// Episodes whose feed has no subscription are saved unconditionally: the
    /// caller loaded a feed Wilted does not follow, and there is no horizon to
    /// judge them against.
    @discardableResult
    public func savePodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission
    ) throws -> PodcastEpisodeAdmissionResult {
        // One admission path, not two. A claiming limit of zero is exactly this
        // call, and keeping a second hand-written copy of the admit-and-upsert
        // sequence is how the two drift apart.
        try admitPodcastEpisodes(episodes, admission: admission, claimingNewest: 0).admission
    }

    /// What one admission claimed for automatic download.
    public struct PodcastAutomationAdmissionResult: Equatable, Sendable {
        public let admission: PodcastEpisodeAdmissionResult
        /// Episodes this call moved to `queued`. An episode that already has a
        /// download record is never claimed, so a manual transfer in flight
        /// keeps the state it is in.
        public let claimed: [ItemID]
    }

    /// Admits a feed's episodes and claims a bounded newest-first subset for
    /// automatic download in one save.
    ///
    /// Admitting and then enqueuing in two saves has a crash window that either
    /// loses the newly admitted set or replays it: the episode rows land, the
    /// process dies, and the next launch cannot tell which of them were new,
    /// because being new is a property of that one admission and nothing else
    /// records it. Claiming inside the same transaction closes the window --
    /// the rows and their claims are both durable or neither is.
    ///
    /// The claim is the download record itself rather than a parallel table.
    /// Automation must not restate download truth the store already owns, and a
    /// separate claim row is one more thing that can disagree with it.
    ///
    /// A `limit` of zero admits and claims nothing, which is what a manual
    /// download policy asks for, and `.backfill` claims nothing whatever the
    /// limit: subscribing is not a request to download a back catalogue.
    public func admitPodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission,
        claimingNewest limit: Int,
        claimedAt: Timestamp = Timestamp(Date())
    ) throws -> PodcastAutomationAdmissionResult {
        guard !episodes.isEmpty else {
            return PodcastAutomationAdmissionResult(
                admission: PodcastEpisodeAdmissionResult(saved: [], newlyAdmitted: [], skipped: 0),
                claimed: []
            )
        }
        let context = ModelContext(container)
        let existing = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>()).map(\.id)
        )
        let admitted = try admittedPodcastEpisodes(episodes, admission: admission, in: context)
        try upsertPodcastEpisodes(admitted, in: context)
        let newlyAdmitted = admitted.filter { !existing.contains($0.itemID.rawValue) }
        var claimed: [ItemID] = []
        // Backfill never claims, whatever the caller asks for. Subscribing is
        // not a request to download a back catalogue, and refusing here means a
        // future caller cannot make it one by passing a limit.
        if limit > 0, admission == .incremental {
            let tracked = Set(
                try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
                    .map(\.episodeID)
            )
            // Newest first, so a capped policy takes the episodes a listener
            // would reach for rather than whichever order the feed parsed in.
            let eligible = Self.newestFirst(newlyAdmitted.filter { !tracked.contains($0.itemID.rawValue) })
            for episode in eligible.prefix(limit) {
                let claim = try PodcastDownload(episodeID: episode.itemID, status: .queued, updatedAt: claimedAt)
                context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(claim))
                claimed.append(episode.itemID)
            }
        }
        try context.save()
        return PodcastAutomationAdmissionResult(
            admission: PodcastEpisodeAdmissionResult(
                saved: admitted.map(\.itemID),
                newlyAdmitted: newlyAdmitted.map(\.itemID),
                skipped: episodes.count - admitted.count
            ),
            claimed: claimed
        )
    }

    /// Claims one episode for download, or reports that something already holds it.
    ///
    /// Manual and automatic entry points race: the listener presses Download on
    /// the episode an app-open refresh just admitted. Both would otherwise reach
    /// the download coordinator, which writes its queued record unconditionally,
    /// and the episode would transfer twice. This is the serialisation point --
    /// the insert happens only when no download record exists, and the store
    /// actor makes the check and the insert one step.
    ///
    /// How much existing state blocks a new claim.
    public enum PodcastDownloadClaimScope: Sendable {
        /// Automation: any download record at all means the episode is spoken
        /// for. A completed, failed, or cancelled transfer is a decision
        /// already made, and re-running it is the listener's call.
        case untouched
        /// A deliberate request: only a transfer in flight blocks it, so
        /// retrying a failure from the row still works.
        case notInFlight
    }

    /// Claims one episode for download, or reports that something already holds it.
    ///
    /// Manual and automatic entry points race: the listener presses Download on
    /// the episode an app-open refresh just admitted. Both would otherwise reach
    /// the download coordinator, which writes its queued record unconditionally,
    /// and the episode would transfer twice. This is the serialisation point --
    /// the insert happens only when the scope allows, and the store actor makes
    /// the check and the insert one step.
    @discardableResult
    public func claimPodcastDownload(
        episodeID: ItemID,
        scope: PodcastDownloadClaimScope = .untouched,
        at claimedAt: Timestamp = Timestamp(Date())
    ) throws -> Bool {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        let existing = records.first(where: { $0.episodeID == episodeID.rawValue })
        switch scope {
        case .untouched:
            guard existing == nil else { return false }
        case .notInFlight:
            let inFlight = existing.flatMap { PodcastDownloadStatus(rawValue: $0.status) }
                .map { $0 == .queued || $0 == .downloading } ?? false
            guard !inFlight else { return false }
        }
        let claim = try PodcastDownload(episodeID: episodeID, status: .queued, updatedAt: claimedAt)
        if let existing {
            existing.status = claim.status.rawValue
            existing.bytesReceived = 0
            existing.expectedByteCount = nil
            existing.localURL = nil
            existing.contentHash = nil
            existing.updatedAt = claimedAt.date
            existing.failureKind = nil
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(claim))
        }
        try context.save()
        return true
    }

    /// Claims that outlived the process that made them.
    ///
    /// A launch reconciles against this rather than against anything automation
    /// persisted separately: `queued` is claimed and not started, `downloading`
    /// is a transfer with no process behind it any more. Both are resumable, and
    /// the store is the only thing that knows which episodes they are.
    public func unfinishedPodcastDownloads() throws -> [PodcastDownload] {
        try downloads().filter { $0.status == .queued || $0.status == .downloading }
    }

    /// Failures a relaunch should retry without asking the user.
    ///
    /// Distinct from `unfinishedPodcastDownloads()`: those rows never reached
    /// a terminal state, these did and were classified `.retryable` by the
    /// coordinator's final catch. A `.terminal` failure is excluded on
    /// purpose — it needs user action, not another automatic attempt.
    public func resumablePodcastDownloads() throws -> [PodcastDownload] {
        try downloads().filter { $0.status == .failed && $0.failureKind == .retryable }
    }

    /// Creates a subscription once without moving its original admission horizon.
    ///
    /// Equivalent canonical feed URLs derive the same feed ID, so repeated manual
    /// or automatic admission returns `false` and leaves the existing row intact.
    @discardableResult
    public func subscribeIfNeeded(_ subscription: PodcastSubscription) throws -> Bool {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        guard !records.contains(where: { $0.feedID == subscription.feedID.rawValue }) else { return false }
        context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription))
        try context.save()
        return true
    }

    /// Re-admits one exact feed entry and forgets its dismissal in the same save.
    ///
    /// `offeredEpisodes` must be fresh feed evidence. Only `target` bypasses the
    /// incremental horizon; every other entry is admitted exactly as a normal
    /// refresh would admit it. The dismissal is deleted last and the context is
    /// saved once, so a decode or store failure cannot turn a retryable restore
    /// into a permanent loss of the Removed row.
    @discardableResult
    public func restorePodcastEpisode(
        _ target: PodcastEpisode,
        from offeredEpisodes: [PodcastEpisode]
    ) throws -> PodcastEpisodeRestoreResult {
        let context = ModelContext(container)
        let identifier = target.itemID.rawValue
        let dismissals = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>()
        )
        guard let dismissal = dismissals.first(where: { $0.id == identifier }) else {
            return PodcastEpisodeRestoreResult(restored: false, saved: [], skipped: offeredEpisodes.count)
        }
        guard let offeredTarget = offeredEpisodes.first(where: { $0.itemID == target.itemID }) else {
            return PodcastEpisodeRestoreResult(restored: false, saved: [], skipped: offeredEpisodes.count)
        }

        var admitted = try admittedPodcastEpisodes(
            offeredEpisodes.filter { $0.itemID != target.itemID }, admission: .incremental, in: context
        )
        admitted.append(offeredTarget)
        try upsertPodcastEpisodes(admitted, in: context)
        context.delete(dismissal)
        // Clearing `lastRevisionID` (not `completedAt`) keeps "I listened to
        // this" intact while defeating the bootstrap sweep's exact-revision
        // match: a re-download that lands on the same content-addressed
        // revision would otherwise get silently re-retired on next launch,
        // undoing the restore the user just asked for.
        if let listening = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()
        ).first(where: { $0.id == identifier }) {
            listening.lastRevisionID = nil
        }
        try context.save()
        return PodcastEpisodeRestoreResult(
            restored: true,
            saved: admitted.map(\.itemID),
            skipped: offeredEpisodes.count - admitted.count
        )
    }

    private func admittedPodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission,
        in context: ModelContext
    ) throws -> [PodcastEpisode] {
        let dismissed = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>()).map(\.id)
        )
        let candidates = episodes.filter { !dismissed.contains($0.itemID.rawValue) }
        guard !candidates.isEmpty else { return [] }
        let subscriptions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        let horizons = Dictionary(
            subscriptions.map { ($0.feedID, Self.admissionHorizon(subscribedAt: $0.subscribedAt, admission: admission)) },
            uniquingKeysWith: { first, _ in first }
        )
        let existing = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>()).map(\.id)
        )
        var admitted: [PodcastEpisode] = []
        for (feedID, group) in Dictionary(grouping: candidates, by: \.feedID.rawValue) {
            guard let horizon = horizons[feedID] else {
                admitted.append(contentsOf: group)
                continue
            }
            var kept = group.filter { episode in
                if existing.contains(episode.itemID.rawValue) { return true }
                guard let published = episode.publishedTime?.date else { return false }
                return published >= horizon
            }
            if admission == .backfill, kept.count < Self.podcastSubscriptionMinimumBackfill {
                let keptIDs = Set(kept.map(\.itemID.rawValue))
                kept.append(contentsOf: Self.newestFirst(group)
                    .filter { !keptIDs.contains($0.itemID.rawValue) }
                    .prefix(Self.podcastSubscriptionMinimumBackfill - kept.count))
            }
            admitted.append(contentsOf: kept)
        }
        return admitted
    }

    private func upsertPodcastEpisodes(
        _ episodes: [PodcastEpisode], in context: ModelContext
    ) throws {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for episode in episodes {
            if let record = byID[episode.itemID.rawValue] {
                try Self.apply(episode, to: record)
            } else {
                let record = try LocalLibrarySchemaV10Models.PodcastEpisodeRecord(episode)
                context.insert(record)
                byID[episode.itemID.rawValue] = record
            }
        }
    }

    /// How far back the load that creates a subscription reaches.
    public static let podcastSubscriptionBackfillWindow: TimeInterval = 30 * 24 * 60 * 60
    /// The floor under that window, so an infrequent podcast is never empty.
    public static let podcastSubscriptionMinimumBackfill = 5

    /// A feed's episodes newest first, undated ones last.
    ///
    /// Ties keep the order the feed gave. That matters because Swift's sort is
    /// not stable: a group whose episodes share a date -- or carry no date at
    /// all -- would otherwise be shuffled, and the backfill top-up would admit
    /// an arbitrary handful instead of the ones the feed lists first.
    private static func newestFirst(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedTime?.date, rhs.element.publishedTime?.date) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func admissionHorizon(subscribedAt: Date, admission: PodcastEpisodeAdmission) -> Date {
        switch admission {
        case .backfill: subscribedAt.addingTimeInterval(-podcastSubscriptionBackfillWindow)
        case .incremental: subscribedAt
        }
    }

    /// One episode the listener removed, and when.
    public struct PodcastEpisodeDismissal: Equatable, Sendable {
        public let episodeID: ItemID
        public let feedID: ItemID?
        public let title: String?
        public let dismissedAt: Timestamp
    }

    /// Removes one episode from the Larder and remembers that it was removed.
    ///
    /// Both halves are needed. Deleting the row alone lasts until the next
    /// refresh, which parses the same episode out of the same feed and inserts
    /// it again; recording the dismissal alone leaves the row on screen. So the
    /// record is written, and the episode, queue, download, speed, artwork,
    /// revision, transcript, and playback records go. `savePodcastEpisodes`
    /// declines to re-admit the identity afterwards.
    ///
    /// The preparation journal stays. It is what lets the Removed list say a
    /// preparation happened for this episode, and restoring the episode should
    /// not resurrect a finished cut that no longer has a revision or transcript
    /// behind it.
    ///
    /// Downloaded media stays on disk for the reason `unsubscribeFromPodcast`
    /// gives: a `RevisionID` is derived from content, so two episodes with
    /// identical bytes share one audio revision and deleting the file here
    /// could break an episode that survives this call.
    ///
    /// Idempotent. Removing something already removed keeps the first
    /// dismissal's timestamp and returns false.
    @discardableResult
    public func dismissPodcastEpisode(_ episodeID: ItemID, at dismissedAt: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        let episode = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .first { $0.id == identifier }
        let dismissals = try context.fetch(FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>())
        if let existing = dismissals.first(where: { $0.id == identifier }) {
            // A dismissal written when the row was already gone carries no feed
            // or title. Fill them in if this call can see them.
            existing.feedID = existing.feedID ?? episode?.feedID
            existing.title = existing.title ?? episode?.title
        } else {
            context.insert(LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord(
                episodeID: identifier, feedID: episode?.feedID, title: episode?.title,
                dismissedAt: dismissedAt.date
            ))
        }
        guard let episode else { try context.save(); return false }
        context.delete(episode)
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        where record.episodeID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where record.episodeID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where record.ownerID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where record.itemID == identifier { context.delete(record) }
        try context.save()
        return true
    }

    /// Every episode removed from the Larder, newest removal first.
    public func dismissedPodcastEpisodes() throws -> [PodcastEpisodeDismissal] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>())
            .sorted { $0.dismissedAt > $1.dismissedAt }
            .compactMap { record in
                guard let episodeID = try? ItemID(rawValue: record.id) else { return nil }
                return PodcastEpisodeDismissal(
                    episodeID: episodeID,
                    feedID: record.feedID.flatMap { try? ItemID(rawValue: $0) },
                    title: record.title,
                    dismissedAt: Timestamp(record.dismissedAt)
                )
            }
    }

    /// Removes a subscription and every record Wilted stored on its behalf.
    ///
    /// Records only. Downloaded media files stay on disk because revision-aware
    /// reclamation is a separate job; unsubscribe does not guess whether a
    /// namespaced or same-item legacy revision is still referenced.
    @discardableResult
    public func unsubscribeFromPodcast(feedID: ItemID) throws -> Int {
        let context = ModelContext(container)
        let feed = feedID.rawValue
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        where record.feedID == feed { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>())
        where record.id == feed { context.delete(record) }

        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .filter { $0.feedID == feed }
        let episodeIDs = Set(episodes.map(\.id))
        for record in episodes { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        // Artwork is owned by the feed as well as by its episodes.
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where episodeIDs.contains(record.ownerID) || record.ownerID == feed { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        // Dismissals are records Wilted stored on the feed's behalf too, so
        // resubscribing starts clean rather than inheriting a blocklist the
        // listener can no longer see anywhere.
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>())
        where record.feedID == feed || episodeIDs.contains(record.id) { context.delete(record) }
        try context.save()
        return episodeIDs.count
    }

    private static func apply(
        _ episode: PodcastEpisode,
        to record: LocalLibrarySchemaV10Models.PodcastEpisodeRecord
    ) throws {
        record.feedID = episode.feedID.rawValue
        record.feedURL = episode.feedURL.absoluteString
        record.rssGUID = episode.rssGUID
        record.title = episode.title
        record.author = episode.author
        record.publishedTime = episode.publishedTime?.date
        record.enclosureURL = episode.enclosureURL.absoluteString
        record.enclosureMediaType = episode.enclosureMediaType
        record.enclosureByteCount = episode.enclosureByteCount
        record.durationSeconds = episode.durationSeconds
        record.artworkURL = episode.artworkURL?.absoluteString
        record.transcriptSources = try LocalLibrarySchemaV10Models.PodcastEpisodeRecord.encode(episode.transcriptSources)
        record.notes = episode.notes
        record.createdAt = episode.createdAt.date
    }

    public func save(download: PodcastDownload) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = records.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue; existing.bytesReceived = download.bytesReceived; existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString; existing.contentHash = download.contentHash; existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else { context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download)) }
        try context.save()
    }

    public func save(downloadState download: PodcastDownload) throws { try save(download: download) }

    /// Atomically commits immutable downloaded media metadata and its completed state.
    public func finalizePodcastDownload(revision: AudioRevision, mediaURL: URL, download: PodcastDownload) throws {
        guard revision.itemID == download.episodeID,
              download.status == .completed,
              download.localURL == mediaURL,
              download.contentHash == revision.contentHash,
              download.bytesReceived == revision.byteCount else {
            throw LocalLibraryStoreError.invalidPodcastState("completed download revision")
        }
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .finalizedDownload)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download))
        }
        try context.save()
    }

    /// Replaces one episode's audio revision with a prepared successor.
    ///
    /// Preparation rewrites the audio, so the superseded revision is not
    /// history: its bytes stop existing. Leaving its record behind would leave
    /// the store describing a file nothing can open, and `readyRevision` would
    /// hand it out the moment a newer record was missing. Revision records are
    /// immutable, so the old one is removed rather than edited, along with the
    /// transcript that described audio that is gone.
    ///
    /// Everything lands in one save. A partial commit here is the case that
    /// loses an episode: the caller deletes the original file once this
    /// returns, and it must never delete a file the store still points at.
    public func replaceReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        download: PodcastDownload,
        superseding superseded: RevisionID,
        outcome: PodcastPreparationOutcome,
        carrying playback: PlaybackState? = nil,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard outcome.episodeID == revision.itemID, outcome.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard revision.itemID == download.episodeID, download.status == .completed,
              download.localURL == mediaURL, download.contentHash == revision.contentHash,
              download.bytesReceived == revision.byteCount else {
            throw LocalLibraryStoreError.invalidPodcastState("prepared download revision")
        }
        guard playback == nil || (playback?.itemID == revision.itemID && playback?.revisionID == revision.revisionID) else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard superseded != revision.revisionID else {
            throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .replacementSupersedesItself)
        }
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .replacement)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)

        for record in revisions where record.id == superseded.rawValue && record.itemID == revision.itemID.rawValue {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where record.itemID == revision.itemID.rawValue && record.revisionID == superseded.rawValue {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where record.itemID == revision.itemID.rawValue && record.revisionID == superseded.rawValue {
            context.delete(record)
        }
        if let playback {
            context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback))
        }

        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download))
        }
        try upsertPreparationOutcome(outcome, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    // MARK: - Orphan media audit and reclaim (Task 4.4)

    /// Files a writer owns before its record commits. `nonisolated` because a
    /// download, synthesis, or assembly registers from its own actor without a
    /// hop through the store.
    public nonisolated let inFlightMedia = MediaInFlightRegistry()

    /// The paths any reachable record still names: revisions, downloads, and
    /// artwork. A file not in this set and not in flight is an orphan.
    private func reachableMediaPaths() throws -> Set<String> {
        let context = ModelContext(container)
        var paths: Set<String> = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            if let value = record.mediaURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()) {
            if let value = record.localURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>()) {
            if let value = record.localURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    /// The media files under `directories` that no reachable record names and no
    /// in-flight writer holds. Read-only: the audit deletes nothing, and it is
    /// what every reclaim sweep starts from.
    public func unreferencedMediaFiles(in directories: [URL]) throws -> [URL] {
        let reachable = try reachableMediaPaths()
        let inFlight = inFlightMedia.inFlightPaths
        let manager = FileManager.default
        var unreferenced: [URL] = []
        for directory in directories {
            guard let walker = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let path = url.standardizedFileURL.path
                guard !reachable.contains(path), !inFlight.contains(path) else { continue }
                unreferenced.append(url)
            }
        }
        return unreferenced.sorted { $0.path < $1.path }
    }

    /// Deletes only what the audit reports. The audit runs first, in this
    /// method, so no deletion can precede it; the in-flight set is consulted
    /// again immediately before each removal so a writer that registered in
    /// between keeps its file.
    @discardableResult
    public func reclaimUnreferencedMedia(in directories: [URL]) throws -> Int {
        let unreferenced = try unreferencedMediaFiles(in: directories)
        var reclaimed = 0
        for url in unreferenced {
            guard !inFlightMedia.isInFlight(url) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                reclaimed += 1
            } catch {}
        }
        return reclaimed
    }

    public func download(for episodeID: ItemID) throws -> PodcastDownload? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()).first(where: { $0.episodeID == episodeID.rawValue }),
              let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
        return try PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                   expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                   contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt),
                                   failureKind: record.failureKind.flatMap(PodcastDownloadFailureKind.init(rawValue:)))
    }

    public func downloads() throws -> [PodcastDownload] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()).compactMap { record in
            guard let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
            return try? PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                        expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                        contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt),
                                        failureKind: record.failureKind.flatMap(PodcastDownloadFailureKind.init(rawValue:)))
        }
    }

    // MARK: Preparation outcome, listening completion, and retirement (V10)

    public func savePreparationOutcome(_ outcome: PodcastPreparationOutcome) throws {
        let context = ModelContext(container)
        try upsertPreparationOutcome(outcome, in: context)
        try context.save()
    }

    /// Inserts or updates one outcome row without saving, so a caller can
    /// combine it with other writes (the revision it proves, the download it
    /// closes out) in a single atomic `context.save()`.
    private func upsertPreparationOutcome(_ outcome: PodcastPreparationOutcome, in context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        if let existing = records.first(where: { $0.id == outcome.id }) {
            existing.policyDigest = outcome.policyDigest
            existing.pipelineFingerprint = outcome.pipelineFingerprint
            existing.semanticVersion = outcome.semanticVersion
            existing.producedAt = outcome.producedAt.date
            existing.eligibility = outcome.eligibility.rawValue
            existing.invalidationRuleID = outcome.invalidationRuleID
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord(outcome))
        }
    }

    public func preparationOutcome(for episodeID: ItemID, revisionID: RevisionID) throws -> PodcastPreparationOutcome? {
        let context = ModelContext(container)
        let id = "\(episodeID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
            .first(where: { $0.id == id }),
            let eligibility = PodcastPreparationEligibility(rawValue: record.eligibility) else { return nil }
        return PodcastPreparationOutcome(
            episodeID: episodeID, revisionID: revisionID, policyDigest: record.policyDigest,
            pipelineFingerprint: record.pipelineFingerprint, semanticVersion: record.semanticVersion,
            producedAt: Timestamp(record.producedAt), eligibility: eligibility,
            invalidationRuleID: record.invalidationRuleID
        )
    }

    public func saveListening(_ state: PodcastListeningState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = records.first(where: { $0.id == state.episodeID.rawValue }) {
            existing.completedAt = state.completedAt?.date
            existing.lastRevisionID = state.lastRevisionID?.rawValue
            existing.updatedAt = state.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(state))
        }
        try context.save()
    }

    public func listeningState(for episodeID: ItemID) throws -> PodcastListeningState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .first(where: { $0.id == episodeID.rawValue }) else { return nil }
        return PodcastListeningState(
            episodeID: episodeID, completedAt: record.completedAt.map(Timestamp.init),
            lastRevisionID: record.lastRevisionID.flatMap { try? RevisionID(rawValue: $0) },
            updatedAt: Timestamp(record.updatedAt)
        )
    }

    /// Idempotent: retiring an already-retired episode is a no-op returning `false`.
    @discardableResult
    public func retireEpisode(_ episodeID: ItemID, at retiredAt: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == episodeID.rawValue }), record.retiredAt == nil else { return false }
        record.retiredAt = retiredAt.date
        try context.save()
        return true
    }

    public func retiredAt(for episodeID: ItemID) throws -> Timestamp? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == episodeID.rawValue })?.retiredAt.map(Timestamp.init)
    }

    /// Reverses `retireEpisode`, returning a skipped episode to the library.
    /// Idempotent: an episode with no retirement record returns `false`.
    @discardableResult
    public func restoreRetiredEpisode(_ episodeID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == episodeID.rawValue }), record.retiredAt != nil else { return false }
        record.retiredAt = nil
        try context.save()
        return true
    }

    /// Stable identifiers recorded on an outcome row translated from a legacy
    /// `podcast-invalidation|` or `podcast-reset-preparation|` marker by
    /// `reconcilePodcastStateV10()`.
    public static let legacyForcedRedownloadInvalidationRuleID = "legacy-forced-redownload"
    public static let legacyResetPreparationInvalidationRuleID = "legacy-reset-preparation"

    /// `semanticVersion` sentinel for a backfilled outcome row whose
    /// `pipelineFingerprint` is `nil` -- genuinely unknown provenance, not
    /// today's pipeline. Stamping today's version on such a row would be a
    /// false durable claim about what produced it.
    public static let legacyUnknownProvenanceSemanticVersion = "unknown-legacy"

    /// Idempotent post-open backfill translating pre-V10 evidence into the new
    /// durable outcome, listening, and retirement records.
    ///
    /// Each step only inserts where nothing already proves the fact, and step
    /// 4 deletes every marker it translates or supersedes, so a second call
    /// is a true no-op with respect to those: there is nothing left for it to
    /// find. The one exception is a forced-redownload marker with no
    /// matching outcome row, which step 4 deliberately leaves in place (see
    /// its doc comment) -- a second call finds it again and, correctly,
    /// leaves it again. Every step commits before the next reads, so a later
    /// step's fetch always sees a fully persisted prior step rather than
    /// racing an uncommitted `ModelContext`.
    public func reconcilePodcastStateV10() throws {
        let context = ModelContext(container)
        try backfillPreparationOutcomesForV10Reconciliation(in: context)
        try context.save()
        try backfillListeningRecordsForV10Reconciliation(in: context)
        try context.save()
        // Step 3: `retiredAt` is left `nil` for every existing row here. A
        // completed-but-unretired episode is a real, one-time retirement on
        // first launch after Phase 5, not a no-op backfill, so it is handled
        // by the separate `retireCompletedEpisodesMissingRetirement()` rather
        // than folded into this function's idempotent-by-construction steps.
        try translateLegacyInvalidationMarkersForV10Reconciliation(in: context)
        try context.save()
    }

    /// Retires every episode whose listening record says the listener
    /// reached the end of its current ready revision and whose episode row
    /// has no `retiredAt` yet.
    ///
    /// Scoped to the *current* ready revision (not just any completed
    /// listening fact) so a dismissed-then-restored episode, whose ready
    /// revision was deleted and has not been re-downloaded, is left alone
    /// rather than retired sight unseen. Separate from
    /// `reconcilePodcastStateV10` because, unlike every step there, this is
    /// not a no-op on repeat first launches: it is the completion flow's own
    /// retirement, run once for every episode that finished before this
    /// method existed. On first launch after this ships, every already-Played
    /// episode with a matching ready revision leaves the Larder at once.
    public func retireCompletedEpisodesMissingRetirement() throws {
        let context = ModelContext(container)
        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .filter { $0.completedAt != nil }
        guard !listeningRecords.isEmpty else { return }
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var changed = false
        for listening in listeningRecords {
            guard let episode = episodes.first(where: { $0.id == listening.id }), episode.retiredAt == nil,
                  let episodeID = try? ItemID(rawValue: listening.id),
                  let ready = readyRevisions[episodeID.rawValue],
                  listening.lastRevisionID == ready.revision.revisionID.rawValue else { continue }
            episode.retiredAt = Date()
            changed = true
        }
        if changed { try context.save() }
    }

    /// Step 1: an episode with a ready revision and no outcome row for it gets
    /// one manufactured from the newest matching journal success. A `nil`
    /// `pipelineFingerprint` means "prepared by an unknown earlier pipeline"
    /// and still evaluates to `.current` -- legacy artifacts must stay
    /// playable.
    private func backfillPreparationOutcomesForV10Reconciliation(in context: ModelContext) throws {
        let decoder = JSONDecoder()
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
        let existingOutcomeIDs = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()).map(\.id)
        )
        let journalRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for episodeRecord in episodes {
            guard let episodeID = try? ItemID(rawValue: episodeRecord.id),
                  let ready = readyRevisions[episodeID.rawValue] else { continue }
            let outcomeID = "\(episodeID.rawValue)|\(ready.revisionID.rawValue)"
            guard !existingOutcomeIDs.contains(outcomeID) else { continue }
            let entries: [PreparationJournalEntry] = journalRecords
                .filter {
                    $0.itemID == episodeID.rawValue
                        && !$0.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                        && !$0.requestID.hasPrefix(Self.resetPreparationRequestPrefix)
                }
                .compactMap { record in
                    guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData) else { return nil }
                    return PreparationJournalEntry(id: record.id, itemID: episodeID, requestID: record.requestID, status: status)
                }
                .sorted(by: preparationEntryPrecedes)
            guard let match = entries.last(where: {
                $0.status.terminal
                    && $0.status.terminalResult?.outcome == .succeeded
                    && $0.status.terminalResult?.revisionID == ready.revisionID
            }) else { continue }
            let fingerprint: String?
            if let evidence = match.status.evidence, evidence.kind == Self.pipelineProvenanceEvidenceKind,
               let value = evidence.fields["fingerprint"], !value.isEmpty {
                fingerprint = value
            } else {
                fingerprint = nil
            }
            let outcome = PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: ready.revisionID,
                // Cannot be reconstructed from history -- legacy rows carry no
                // digest. A deliberate, documented default, not a bug.
                policyDigest: "",
                pipelineFingerprint: fingerprint,
                // A nil fingerprint means no real provenance evidence was
                // found -- stamping today's semantic version would falsely
                // claim this artifact came from the current pipeline.
                semanticVersion: fingerprint != nil
                    ? PodcastPreparationPipeline.semanticVersion
                    : Self.legacyUnknownProvenanceSemanticVersion,
                producedAt: match.status.emittedAt, eligibility: .current, invalidationRuleID: nil
            )
            context.insert(LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord(outcome))
        }
    }

    /// Step 2: an episode whose ready revision has a completed `PlaybackRecord`
    /// and no listening row yet gets one, so "I finished this" survives the
    /// migration that introduced the item-scoped fact.
    private func backfillListeningRecordsForV10Reconciliation(in context: ModelContext) throws {
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>())
        let existingListeningIDs = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()).map(\.id)
        )
        let playbackRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for episodeRecord in episodes {
            guard let episodeID = try? ItemID(rawValue: episodeRecord.id),
                  !existingListeningIDs.contains(episodeID.rawValue),
                  let ready = readyRevisions[episodeID.rawValue] else { continue }
            guard let playback = playbackRecords.first(where: {
                $0.itemID == episodeID.rawValue && $0.revisionID == ready.revisionID.rawValue && $0.completed
            }) else { continue }
            let state = PodcastListeningState(
                episodeID: episodeID, completedAt: Timestamp(playback.updatedAt),
                lastRevisionID: ready.revisionID, updatedAt: Timestamp(playback.updatedAt)
            )
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(state))
        }
    }

    /// Step 4: legacy `podcast-invalidation|` / `podcast-reset-preparation|`
    /// markers -- ones written before the rule table in
    /// `invalidateStalePodcastPreparations` existed -- are translated onto
    /// the matching `.current` outcome row when one exists and the marker is
    /// at least as new as it, and dropped once their information is applied
    /// or superseded.
    ///
    /// A matching outcome row no longer proves a marker is legacy debt:
    /// `invalidateStalePodcastPreparations` itself writes a marker in the
    /// same transaction it sets an outcome's `eligibility` to `.invalid`,
    /// for episodes that DO have an outcome row (its pass 2 specifically
    /// targets those). Deleting that marker here unconditionally destroys
    /// the only durable record of a scheduled forced-redownload or reset
    /// before it is ever admitted, permanently: `requiresForcedRedownload`
    /// and the marker-rebuild pass in `invalidateStalePodcastPreparations`
    /// both derive solely from marker survival, not from `eligibility`.
    /// `.invalid` + a marker is therefore live scheduling state, not legacy
    /// debt, and must be left alone. Only a `.current` outcome is the true
    /// legacy case this step exists for: no rule has fired through the new
    /// mechanism for that episode, so a surviving marker can only be a
    /// leftover pre-V10 write.
    private func translateLegacyInvalidationMarkersForV10Reconciliation(in context: ModelContext) throws {
        let markers = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()).filter {
            $0.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || $0.requestID.hasPrefix(Self.resetPreparationRequestPrefix)
        }
        guard !markers.isEmpty else { return }
        let decoder = JSONDecoder()
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for marker in markers {
            let isForcedRedownload = marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
            let ruleID = isForcedRedownload
                ? Self.legacyForcedRedownloadInvalidationRuleID
                : Self.legacyResetPreparationInvalidationRuleID
            guard let episodeID = try? ItemID(rawValue: marker.itemID),
                  let ready = readyRevisions[episodeID.rawValue],
                  let outcome = outcomes.first(where: {
                      $0.episodeID == episodeID.rawValue && $0.revisionID == ready.revisionID.rawValue
                  }),
                  outcome.eligibility == PodcastPreparationEligibility.current.rawValue else {
                continue
            }
            // A matching `.current` outcome row exists with no invalidation
            // rule having fired for it, so this is the true legacy case: the
            // marker's information is either applied below or superseded by
            // a newer success -- either way the marker itself is spent and
            // gets deleted.
            context.delete(marker)
            guard let markerStatus = try? decoder.decode(PreparationStatus.self, from: marker.statusData),
                  markerStatus.emittedAt.date >= outcome.producedAt else {
                // Undecodable, or genuinely older than the outcome it would
                // invalidate: leave the outcome as `.current` rather than
                // mislabel a newer, good artifact as invalid.
                continue
            }
            outcome.eligibility = PodcastPreparationEligibility.invalid.rawValue
            outcome.invalidationRuleID = ruleID
        }
    }

    public func save(artwork: PodcastArtwork) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        if let existing = records.first(where: { $0.id == artwork.id }) {
            existing.ownerID = artwork.ownerID.rawValue; existing.remoteURL = artwork.remoteURL?.absoluteString; existing.localURL = artwork.localURL?.absoluteString
            existing.contentHash = artwork.contentHash; existing.byteCount = artwork.byteCount; existing.updatedAt = artwork.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastArtworkRecord(artwork)) }
        try context.save()
    }

    public func save(artworkAsset artwork: PodcastArtwork) throws { try save(artwork: artwork) }

    public func artwork(for id: String) throws -> PodcastArtwork? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>()).first(where: { $0.id == id }), let ownerID = try? ItemID(rawValue: record.ownerID) else { return nil }
        return try PodcastArtwork(id: record.id, ownerID: ownerID, remoteURL: record.remoteURL.flatMap(URL.init), localURL: record.localURL.flatMap(URL.init), contentHash: record.contentHash, byteCount: record.byteCount, updatedAt: Timestamp(record.updatedAt))
    }

    public func save(queueEntry: PodcastQueueEntry) throws {
        var state = try podcastQueueState()
        var ids = state.episodeIDs.filter { $0 != queueEntry.episodeID }
        ids.insert(queueEntry.episodeID, at: max(0, min(queueEntry.position, ids.count)))
        state = try PodcastQueueState(episodeIDs: ids, currentEpisodeID: state.currentEpisodeID)
        try replacePodcastQueue(state, addedAt: queueEntry.addedAt)
    }

    public func queue() throws -> [PodcastQueueEntry] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
            .sorted(by: Self.podcastQueueRecordPrecedes)
        return records.enumerated().compactMap { position, record in
            guard let episodeID = try? ItemID(rawValue: record.episodeID) else { return nil }
            return try? PodcastQueueEntry(episodeID: episodeID, position: position, addedAt: Timestamp(record.addedAt))
        }
    }

    public func upNext() throws -> [PodcastQueueEntry] { try queue() }

    public func save(upNext entry: PodcastQueueEntry) throws { try save(queueEntry: entry) }

    /// Replaces order and current identity in one context save. Public queue
    /// positions are always decoded to the contiguous range `0..<count`.
    public func replacePodcastQueue(_ state: PodcastQueueState, addedAt: Timestamp = Timestamp(Date())) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        let existingDates = Dictionary(uniqueKeysWithValues: records.map { ($0.episodeID, $0.addedAt) })
        for record in records { context.delete(record) }
        for (position, episodeID) in state.episodeIDs.enumerated() {
            let storedPosition = position + (episodeID == state.currentEpisodeID ? Self.podcastCurrentPositionOffset : 0)
            let entry = try PodcastQueueEntry(
                episodeID: episodeID,
                position: storedPosition,
                addedAt: Timestamp(existingDates[episodeID.rawValue] ?? addedAt.date)
            )
            context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(entry))
        }
        try context.save()
    }

    public func podcastQueueState() throws -> PodcastQueueState {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
            .sorted(by: Self.podcastQueueRecordPrecedes)
        let ids = records.compactMap { try? ItemID(rawValue: $0.episodeID) }
        let current = records.first(where: { $0.position >= Self.podcastCurrentPositionOffset })
            .flatMap { try? ItemID(rawValue: $0.episodeID) }
        return try PodcastQueueState(episodeIDs: ids, currentEpisodeID: current)
    }

    private static func decodedPodcastQueuePosition(_ position: Int) -> Int {
        position >= podcastCurrentPositionOffset ? position - podcastCurrentPositionOffset : position
    }

    /// The one total order every public queue read uses, so `queue()` and
    /// `podcastQueueState()` cannot disagree about stored order. Decoded position
    /// first, then episode ID: storage can hold two rows at the same decoded
    /// position, and without the second key their relative order would be
    /// whatever the sort happened to produce.
    private static func podcastQueueRecordPrecedes(
        _ lhs: LocalLibrarySchemaV6Models.PodcastQueueRecord,
        _ rhs: LocalLibrarySchemaV6Models.PodcastQueueRecord
    ) -> Bool {
        let lhsPosition = decodedPodcastQueuePosition(lhs.position)
        let rhsPosition = decodedPodcastQueuePosition(rhs.position)
        if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
        return lhs.episodeID < rhs.episodeID
    }

    public func addPodcastQueueEpisode(_ episodeID: ItemID, addedAt: Timestamp = Timestamp(Date())) throws {
        let state = try podcastQueueState()
        guard !state.episodeIDs.contains(episodeID) else { return }
        try replacePodcastQueue(try PodcastQueueState(
            episodeIDs: state.episodeIDs + [episodeID],
            currentEpisodeID: state.currentEpisodeID
        ), addedAt: addedAt)
    }

    public func removePodcastQueueEpisode(_ episodeID: ItemID) throws {
        let state = try podcastQueueState()
        let ids = state.episodeIDs.filter { $0 != episodeID }
        let current = state.currentEpisodeID == episodeID ? nil : state.currentEpisodeID
        try replacePodcastQueue(try PodcastQueueState(episodeIDs: ids, currentEpisodeID: current))
    }

    public func movePodcastQueueEpisode(from source: Int, to destination: Int) throws {
        let state = try podcastQueueState()
        guard state.episodeIDs.indices.contains(source), destination >= 0, destination < state.episodeIDs.count else {
            throw LocalLibraryStoreError.invalidPodcastState("queue move")
        }
        var ids = state.episodeIDs
        let value = ids.remove(at: source)
        ids.insert(value, at: destination)
        try replacePodcastQueue(try PodcastQueueState(episodeIDs: ids, currentEpisodeID: state.currentEpisodeID))
    }

    public func setCurrentPodcastQueueEpisode(_ episodeID: ItemID?) throws {
        let state = try podcastQueueState()
        try replacePodcastQueue(try PodcastQueueState(
            episodeIDs: state.episodeIDs,
            currentEpisodeID: episodeID
        ))
    }

    public func save(playbackSpeed: PodcastPlaybackSpeed) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        if let existing = records.first(where: { $0.itemID == playbackSpeed.itemID.rawValue }) {
            existing.speed = playbackSpeed.speed; existing.updatedAt = playbackSpeed.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord(playbackSpeed)) }
        try context.save()
    }

    public func save(playbackRate speed: PodcastPlaybackSpeed) throws { try save(playbackSpeed: speed) }

    public func playbackSpeed(for itemID: ItemID) throws -> PodcastPlaybackSpeed? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>()).first(where: { $0.itemID == itemID.rawValue }) else { return nil }
        return try PodcastPlaybackSpeed(itemID: itemID, speed: record.speed, updatedAt: Timestamp(record.updatedAt))
    }

    public func inspect() throws -> LocalLibraryInspection {
        let context = ModelContext(container)
        return LocalLibraryInspection(schemaVersion: .current,
                                      articleCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()),
                                      revisionCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()),
                                      preparationCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()),
                                      playbackCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()),
                                      transcriptCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()))
    }
}
