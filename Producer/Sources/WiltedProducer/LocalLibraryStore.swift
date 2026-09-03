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

    public static let current: LocalLibrarySchemaVersion = .v9
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

public enum LocalLibraryStoreError: Error, Equatable, Sendable {
    case immutableRevision(RevisionID)
    case revisionBelongsToDifferentItem
    case invalidPreparationStatus(String)
    case invalidPodcastState(String)
    case migrationPreflightFailed(String)
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

public struct PodcastDownload: Codable, Equatable, Sendable {
    public let episodeID: ItemID
    public let status: PodcastDownloadStatus
    public let bytesReceived: Int64
    public let expectedByteCount: Int64?
    public let localURL: URL?
    public let contentHash: String?
    public let updatedAt: Timestamp

    public var itemID: ItemID { episodeID }

    public init(episodeID: ItemID, status: PodcastDownloadStatus = .queued,
                bytesReceived: Int64 = 0, expectedByteCount: Int64? = nil,
                localURL: URL? = nil, contentHash: String? = nil, updatedAt: Timestamp) throws {
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
        self.contentHash = contentHash; self.updatedAt = updatedAt
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

private enum LocalLibrarySchemaV3Models {
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

private enum LocalLibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalLibrarySchemaV1.self, LocalLibrarySchemaV2.self, LocalLibrarySchemaV3.self,
         LocalLibrarySchemaV4.self, LocalLibrarySchemaV5.self, LocalLibrarySchemaV6.self,
         LocalLibrarySchemaV7.self, LocalLibrarySchemaV8.self, LocalLibrarySchemaV9.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LocalLibrarySchemaV1.self, toVersion: LocalLibrarySchemaV2.self),
         .lightweight(fromVersion: LocalLibrarySchemaV2.self, toVersion: LocalLibrarySchemaV3.self),
         .lightweight(fromVersion: LocalLibrarySchemaV3.self, toVersion: LocalLibrarySchemaV4.self),
         .lightweight(fromVersion: LocalLibrarySchemaV4.self, toVersion: LocalLibrarySchemaV5.self),
         .lightweight(fromVersion: LocalLibrarySchemaV5.self, toVersion: LocalLibrarySchemaV6.self),
         .lightweight(fromVersion: LocalLibrarySchemaV6.self, toVersion: LocalLibrarySchemaV7.self),
         .lightweight(fromVersion: LocalLibrarySchemaV7.self, toVersion: LocalLibrarySchemaV8.self),
         .lightweight(fromVersion: LocalLibrarySchemaV8.self, toVersion: LocalLibrarySchemaV9.self)]
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
    /// Current-item identity is encoded inside the existing V6 queue record
    /// shape so Task 2.3 does not silently mutate a released SwiftData schema.
    private static let podcastCurrentPositionOffset = 1_000_000_000
    public let url: URL
    public let schemaVersion: LocalLibrarySchemaVersion = .current
    public let cloudKitDatabase: String? = nil
    public let migrationBackupURL: URL?

    private let container: ModelContainer

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
        let schema = Schema(versionedSchema: LocalLibrarySchemaV9.self)
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
        let schema = Schema(versionedSchema: LocalLibrarySchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }
    #endif

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
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID)
            }
            return
        }
        context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        try context.save()
    }

    public func save(revision: AudioRevision, mediaURL: URL) throws { try saveReadyRevision(revision, mediaURL: mediaURL) }

    /// Atomically saves immutable audio metadata and the transcript produced from the
    /// same extracted text. Identity mismatch fails before either value is committed.
    public func saveReadyRevision(_ revision: AudioRevision, mediaURL: URL, transcript: Transcript) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        let context = ModelContext(container)
        let revisionRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisionRecords.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)
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

    /// Every recorded preparation attempt, newest first.
    ///
    /// A run that emitted no terminal status is reported as non-terminal at
    /// whatever stage it last reached, rather than being dropped. A process
    /// that died mid-synthesis is exactly the run a reader most wants to see.
    public func preparationRuns(limit: Int = 200) throws -> [PreparationRunSummary] {
        let context = ModelContext(container)
        let decoder = JSONDecoder()
        var byRequest: [String: [PreparationJournalEntry]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()) {
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
        .prefix(max(0, limit))
        .map { $0 }
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
                    throw LocalLibraryStoreError.immutableRevision(applied.revision.revisionID)
                }
            } else {
                context.insert(LocalLibrarySchemaV3Models.RevisionRecord(applied.revision, mediaURL: applied.mediaURL))
            }
        }

        for applied in commit.transcripts {
            try upsert(applied.transcript, in: context)
        }

        for applied in commit.playbacks {
            let id = "\(applied.state.itemID.rawValue)|\(applied.state.revisionID.rawValue)"
            if let existing = playbacks.first(where: { $0.id == id }) {
                let current = try PlaybackState(itemID: applied.state.itemID, revisionID: applied.state.revisionID,
                                                sessionID: existing.sessionID, sequence: existing.sequence,
                                                positionSeconds: existing.positionSeconds, durationSeconds: existing.durationSeconds,
                                                completed: existing.completed, intent: PlaybackIntent(rawValue: existing.intent) ?? .progress,
                                                deviceID: existing.deviceID, encodedCloudKitRecordSystemFields: existing.encodedCloudKitRecordSystemFields,
                                                updatedAt: Timestamp(existing.updatedAt))
                let currentTag = existing.encodedCloudKitRecordChangeTag
                let incomingTag = applied.sidecar.changeTag
                let merge = mergePlayback(current: current, incoming: applied.state, changeTagMatches: currentTag == incomingTag)
                guard merge.acceptedStateIsIncoming else { continue }
                existing.sessionID = applied.state.sessionID; existing.sequence = applied.state.sequence
                existing.positionSeconds = applied.state.positionSeconds; existing.durationSeconds = applied.state.durationSeconds
                existing.completed = applied.state.completed; existing.intent = applied.state.intent.rawValue
                existing.deviceID = applied.state.deviceID; existing.encodedCloudKitRecordSystemFields = applied.sidecar.encodedSystemFields
                existing.encodedCloudKitRecordChangeTag = incomingTag; existing.updatedAt = applied.state.updatedAt.date
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
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>())
        if let existing = records.first(where: { $0.id == episode.itemID.rawValue }) {
            try Self.apply(episode, to: existing)
        } else { context.insert(try LocalLibrarySchemaV9Models.PodcastEpisodeRecord(episode)) }
        try context.save()
    }

    public func save(podcastEpisode episode: PodcastEpisode) throws { try save(episode: episode) }

    public func podcastEpisode(for episodeID: ItemID) throws -> PodcastEpisode? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>()).first(where: { $0.id == episodeID.rawValue }),
              let feedID = try? ItemID(rawValue: record.feedID), let feedURL = URL(string: record.feedURL),
              let enclosureURL = URL(string: record.enclosureURL) else { return nil }
        return try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: record.rssGUID,
                                  title: record.title, author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                                  enclosureURL: enclosureURL, enclosureMediaType: record.enclosureMediaType,
                                  enclosureByteCount: record.enclosureByteCount, durationSeconds: record.durationSeconds,
                                  artworkURL: record.artworkURL.flatMap(URL.init),
                                  transcriptSources: try LocalLibrarySchemaV9Models.PodcastEpisodeRecord.decode(record.transcriptSources),
                                  notes: record.notes, createdAt: Timestamp(record.createdAt))
    }

    public func podcastEpisodes(for feedID: ItemID? = nil) throws -> [PodcastEpisode] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>()).filter { feedID == nil || $0.feedID == feedID!.rawValue }.sorted { ($0.publishedTime ?? $0.createdAt) > ($1.publishedTime ?? $1.createdAt) }.compactMap { record in
            guard let id = try? ItemID(rawValue: record.id), let fid = try? ItemID(rawValue: record.feedID), let feedURL = URL(string: record.feedURL), let enclosureURL = URL(string: record.enclosureURL) else { return nil }
            return try? PodcastEpisode(itemID: id, feedID: fid, feedURL: feedURL, rssGUID: record.rssGUID, title: record.title,
                                       author: record.author, publishedTime: record.publishedTime.map(Timestamp.init), enclosureURL: enclosureURL,
                                       enclosureMediaType: record.enclosureMediaType, enclosureByteCount: record.enclosureByteCount,
                                       durationSeconds: record.durationSeconds, artworkURL: record.artworkURL.flatMap(URL.init),
                                       transcriptSources: (try? LocalLibrarySchemaV9Models.PodcastEpisodeRecord.decode(record.transcriptSources)) ?? [],
                                       notes: record.notes, createdAt: Timestamp(record.createdAt))
        }
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
        guard !episodes.isEmpty else { return PodcastEpisodeAdmissionResult(saved: [], skipped: 0) }
        let context = ModelContext(container)
        let admitted = try admittedPodcastEpisodes(episodes, admission: admission, in: context)
        try upsertPodcastEpisodes(admitted, in: context)
        try context.save()
        return PodcastEpisodeAdmissionResult(
            saved: admitted.map(\.itemID),
            skipped: episodes.count - admitted.count
        )
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
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>()).map(\.id)
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
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>())
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for episode in episodes {
            if let record = byID[episode.itemID.rawValue] {
                try Self.apply(episode, to: record)
            } else {
                let record = try LocalLibrarySchemaV9Models.PodcastEpisodeRecord(episode)
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
    /// record is written, the row and everything hanging off it goes, and
    /// `savePodcastEpisodes` declines to re-admit the identity afterwards.
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
        let episode = try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>())
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
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>())
        where record.episodeID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where record.ownerID == identifier { context.delete(record) }
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
    /// Records only. Downloaded media files stay on disk because `RevisionID` is
    /// derived from content alone: two episodes with identical bytes share one
    /// audio revision, so deleting a file here could break an episode that
    /// survives this call. Reclaiming that storage is a separate, revision-aware
    /// job.
    @discardableResult
    public func unsubscribeFromPodcast(feedID: ItemID) throws -> Int {
        let context = ModelContext(container)
        let feed = feedID.rawValue
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        where record.feedID == feed { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>())
        where record.id == feed { context.delete(record) }

        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV9Models.PodcastEpisodeRecord>())
            .filter { $0.feedID == feed }
        let episodeIDs = Set(episodes.map(\.id))
        for record in episodes { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        // Artwork is owned by the feed as well as by its episodes.
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where episodeIDs.contains(record.ownerID) || record.ownerID == feed { context.delete(record) }
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
        to record: LocalLibrarySchemaV9Models.PodcastEpisodeRecord
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
        record.transcriptSources = try LocalLibrarySchemaV9Models.PodcastEpisodeRecord.encode(episode.transcriptSources)
        record.notes = episode.notes
        record.createdAt = episode.createdAt.date
    }

    public func save(download: PodcastDownload) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>())
        if let existing = records.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue; existing.bytesReceived = download.bytesReceived; existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString; existing.contentHash = download.contentHash; existing.updatedAt = download.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastDownloadRecord(download)) }
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
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV6Models.PodcastDownloadRecord(download))
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
        carrying playback: PlaybackState? = nil
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
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
            throw LocalLibraryStoreError.immutableRevision(revision.revisionID)
        }
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID)
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

        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV6Models.PodcastDownloadRecord(download))
        }
        try context.save()
    }

    public func download(for episodeID: ItemID) throws -> PodcastDownload? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>()).first(where: { $0.episodeID == episodeID.rawValue }),
              let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
        return try PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                   expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                   contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt))
    }

    public func downloads() throws -> [PodcastDownload] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastDownloadRecord>()).compactMap { record in
            guard let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
            return try? PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                        expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                        contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt))
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
