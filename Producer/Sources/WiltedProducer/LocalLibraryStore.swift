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

    public static let current: LocalLibrarySchemaVersion = .v4
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
}

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

private enum LocalLibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalLibrarySchemaV1.self, LocalLibrarySchemaV2.self, LocalLibrarySchemaV3.self, LocalLibrarySchemaV4.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LocalLibrarySchemaV1.self, toVersion: LocalLibrarySchemaV2.self),
         .lightweight(fromVersion: LocalLibrarySchemaV2.self, toVersion: LocalLibrarySchemaV3.self),
         .lightweight(fromVersion: LocalLibrarySchemaV3.self, toVersion: LocalLibrarySchemaV4.self)]
    }
}

/// Actor-isolated SwiftData adapter for the producer's local library.
public actor LocalLibraryStore {
    public let url: URL
    public let schemaVersion: LocalLibrarySchemaVersion = .current
    public let cloudKitDatabase: String? = nil

    private let container: ModelContainer

    public init(url: URL, migrate: Bool = true) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
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
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>())
        if let existing = records.first(where: { $0.id == article.itemID.rawValue }) {
            existing.canonicalURL = article.canonicalURL.absoluteString; existing.title = article.title
            existing.source = article.source; existing.author = article.author
            existing.publishedTime = article.publishedTime?.date; existing.createdAt = article.createdAt.date
            existing.isDeleted = article.isDeleted; existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else { context.insert(LocalLibrarySchemaV3Models.ArticleRecord(article)) }
        try context.save()
    }

    public func article(for itemID: ItemID) throws -> Article? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return nil }
        return try Article(itemID: try ItemID(rawValue: record.id), canonicalURL: URL(string: record.canonicalURL)!,
                           title: record.title, source: record.source, author: record.author,
                           publishedTime: record.publishedTime.map(Timestamp.init), createdAt: Timestamp(record.createdAt), isDeleted: record.isDeleted)
    }

    public func articles() throws -> [Article] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>())
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { record in
                guard let itemID = try? ItemID(rawValue: record.id),
                      let canonicalURL = URL(string: record.canonicalURL) else { return nil }
                return try? Article(
                    itemID: itemID, canonicalURL: canonicalURL, title: record.title, source: record.source,
                    author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                    createdAt: Timestamp(record.createdAt), isDeleted: record.isDeleted
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
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV4Models.TranscriptRecord>())
            .first(where: { $0.id == id }) else { return nil }
        return try decodeTranscript(record)
    }

    private func upsert(_ transcript: Transcript, in context: ModelContext) throws {
        let id = "\(transcript.itemID.rawValue)|\(transcript.revisionID.rawValue)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV4Models.TranscriptRecord>())
        if let existing = records.first(where: { $0.id == id }) {
            existing.availability = transcript.availability.rawValue
            existing.text = transcript.text
            existing.format = transcript.format.rawValue
            existing.languageCode = transcript.languageCode
            existing.updatedAt = transcript.updatedAt.date
            existing.schemaVersion = transcript.schemaVersion
        } else {
            context.insert(LocalLibrarySchemaV4Models.TranscriptRecord(transcript))
        }
    }

    private func decodeTranscript(_ record: LocalLibrarySchemaV4Models.TranscriptRecord) throws -> Transcript {
        guard let availability = TranscriptAvailability(rawValue: record.availability),
              let format = TranscriptFormat(rawValue: record.format) else {
            throw LocalLibraryStoreError.invalidPreparationStatus("transcript")
        }
        return try Transcript(itemID: ItemID(rawValue: record.itemID),
                              revisionID: RevisionID(rawValue: record.revisionID),
                              availability: availability, text: record.text, format: format,
                              languageCode: record.languageCode, updatedAt: Timestamp(record.updatedAt),
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

    public func preparationJournal(for requestID: String) throws -> [PreparationJournalEntry] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()).filter { $0.requestID == requestID }.sorted { $0.emittedAt < $1.emittedAt }.compactMap { record in
            guard let status = try? JSONDecoder().decode(PreparationStatus.self, from: record.statusData), let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
            return PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
        }
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
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return }
        record.syncStatus = status.rawValue
        try context.save()
    }

    /// Loads the sync status for one local item.
    public func syncStatus(for itemID: ItemID) throws -> LocalLibrarySyncStatus? {
        let context = ModelContext(container)
        guard let raw = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue })?.syncStatus else { return nil }
        return LocalLibrarySyncStatus(rawValue: raw)
    }

    /// Finalizes one generation, deleting only unseen remote-acknowledged items.
    @discardableResult
    public func finalizeSnapshot(generationID: String, fetchComplete: Bool, seenRemoteItemIDs: Set<ItemID>) throws -> LocalLibrarySnapshotResult {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>())
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
                for transcript in try context.fetch(FetchDescriptor<LocalLibrarySchemaV4Models.TranscriptRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(transcript) }
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
        let articles = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>())
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        let transcripts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV4Models.TranscriptRecord>())
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
                existing.isDeleted = applied.article.isDeleted; existing.syncStatus = applied.status.rawValue
                existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                let record = LocalLibrarySchemaV3Models.ArticleRecord(applied.article)
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

    public func inspect() throws -> LocalLibraryInspection {
        let context = ModelContext(container)
        return LocalLibraryInspection(schemaVersion: .current,
                                      articleCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.ArticleRecord>()),
                                      revisionCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()),
                                      preparationCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()),
                                      playbackCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()),
                                      transcriptCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV4Models.TranscriptRecord>()))
    }
}
