import Foundation
import SwiftData
import WiltedDomain

enum LocalLibrarySchemaV21Models {
    /// The V3 playback shape without the retired sync engine's system fields and change tag.
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
        var updatedAt: Date
        var schemaVersion: Int

        init(_ state: PlaybackState, schemaVersion: Int = 3) {
            id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
            itemID = state.itemID.rawValue; revisionID = state.revisionID.rawValue
            sessionID = state.sessionID; sequence = state.sequence
            positionSeconds = state.positionSeconds; durationSeconds = state.durationSeconds
            completed = state.completed; intent = state.intent.rawValue; deviceID = state.deviceID
            updatedAt = state.updatedAt.date; self.schemaVersion = schemaVersion
        }
    }

    /// V17's article without the retired sync status.
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var source: String
        var author: String?
        var publishedTime: Date?
        var createdAt: Date
        @Attribute(originalName: "isDeleted") var isRemoved: Bool
        var schemaVersion: Int
        var feedID: String?

        init(_ article: Article, schemaVersion: Int = 5, feedID: String? = nil) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isRemoved = article.isDeleted
            self.schemaVersion = schemaVersion
            self.feedID = feedID
        }
    }
}

/// Drops the retired legacy sync engine's storage: its tombstone and repository-state
/// entities (rows and all), the playback system-fields and change-tag attributes, and
/// the article sync-status attribute.
enum LocalLibrarySchemaV21: VersionedSchema {
    static let versionIdentifier = Schema.Version(21, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV20.models.filter {
            $0 != LocalLibrarySchemaV3Models.PlaybackRecord.self
                && $0 != LocalLibrarySchemaV3Models.TombstoneRecord.self
                && $0 != LocalLibrarySchemaV3Models.RepositoryStateRecord.self
                && $0 != LocalLibrarySchemaV17Models.ArticleRecord.self
        } + [
            LocalLibrarySchemaV21Models.PlaybackRecord.self,
            LocalLibrarySchemaV21Models.ArticleRecord.self,
        ]
    }
}

enum LocalLibraryV21MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV20MigrationPlan.schemas + [LocalLibrarySchemaV21.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV20MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV20.self, toVersion: LocalLibrarySchemaV21.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV21
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV21MigrationPlan
typealias LocalLibraryCurrentSubscriptionRecord = LocalLibrarySchemaV18Models.PodcastSubscriptionRecord
