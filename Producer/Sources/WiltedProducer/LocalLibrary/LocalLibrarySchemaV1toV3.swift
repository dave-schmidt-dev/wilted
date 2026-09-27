import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

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

enum LocalLibrarySchemaV2Models {
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

enum LocalLibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV1Models.ArticleRecord.self, LocalLibrarySchemaV1Models.RevisionRecord.self,
         LocalLibrarySchemaV1Models.PreparationRecord.self, LocalLibrarySchemaV1Models.PlaybackRecord.self]
    }
}

enum LocalLibrarySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV2Models.ArticleRecord.self, LocalLibrarySchemaV2Models.RevisionRecord.self,
         LocalLibrarySchemaV2Models.PreparationRecord.self, LocalLibrarySchemaV2Models.PlaybackRecord.self]
    }
}

enum LocalLibrarySchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV3Models.ArticleRecord.self, LocalLibrarySchemaV3Models.RevisionRecord.self,
         LocalLibrarySchemaV3Models.PreparationRecord.self, LocalLibrarySchemaV3Models.PlaybackRecord.self,
         LocalLibrarySchemaV3Models.SyncStateRecord.self, LocalLibrarySchemaV3Models.TombstoneRecord.self,
         LocalLibrarySchemaV3Models.RepositoryStateRecord.self]
    }
}
