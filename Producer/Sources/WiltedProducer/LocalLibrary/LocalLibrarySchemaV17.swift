import Foundation
import SwiftData
import WiltedDomain

enum LocalLibrarySchemaV17Models {
    /// V5's article plus the optional article-feed it came from. Nil for every
    /// article saved before V17.
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
        var feedID: String?

        init(_ article: Article, schemaVersion: Int = 5, feedID: String? = nil) {
            id = article.itemID.rawValue; canonicalURL = article.canonicalURL.absoluteString
            title = article.title; source = article.source; author = article.author
            publishedTime = article.publishedTime?.date; createdAt = article.createdAt.date
            isRemoved = article.isDeleted; syncStatus = LocalLibrarySyncStatus.localOnly.rawValue
            self.schemaVersion = schemaVersion
            self.feedID = feedID
        }
    }

    /// V6's feed plus an optional source kind. Nil reads as a podcast.
    @Model final class PodcastFeedRecord {
        @Attribute(.unique) var id: String
        var canonicalURL: String
        var title: String
        var author: String?
        var artworkURL: String?
        var createdAt: Date
        var sourceKind: String?

        static let podcastSourceKind = "podcast"

        /// The stored kind, with a missing one (every pre-V17 feed) read as a podcast.
        var resolvedSourceKind: String { sourceKind ?? Self.podcastSourceKind }

        init(_ value: PodcastFeed, sourceKind: String? = nil) {
            id = value.itemID.rawValue; canonicalURL = value.canonicalURL.absoluteString
            title = value.title; author = value.author; artworkURL = value.artworkURL?.absoluteString
            createdAt = value.createdAt.date
            self.sourceKind = sourceKind
        }
    }

    /// V16's policy plus an optional news flag. Nil reads as not news.
    @Model final class PodcastFeedPolicyRecord {
        @Attribute(.unique) var feedID: String
        var autoKeep: String
        var autoDownload: String
        var autoPrepare: String
        var keptLimit: Int?
        var updatedAt: Date
        var isNews: Bool?

        init(feedID: String, autoKeep: String, autoDownload: String, autoPrepare: String,
             keptLimit: Int?, updatedAt: Date, isNews: Bool? = nil) {
            self.feedID = feedID; self.autoKeep = autoKeep; self.autoDownload = autoDownload
            self.autoPrepare = autoPrepare; self.keptLimit = keptLimit; self.updatedAt = updatedAt
            self.isNews = isNews
        }
    }

    /// An audiobook. Its audio is an ordinary ready `AudioRevision` keyed by
    /// `id` (the book's ItemID); no path is stored here.
    @Model final class AudiobookRecord {
        @Attribute(.unique) var id: String
        var title: String
        var author: String?
        var durationSeconds: Double
        /// JSON-encoded chapter list.
        var chapters: Data
        var sourceFormat: String
        var volumeIndex: Int
        var volumeCount: Int
        var createdAt: Date
        var isRemoved: Bool

        init(id: String, title: String, author: String?, durationSeconds: Double, chapters: Data,
             sourceFormat: String, volumeIndex: Int, volumeCount: Int, createdAt: Date, isRemoved: Bool = false) {
            self.id = id; self.title = title; self.author = author
            self.durationSeconds = durationSeconds; self.chapters = chapters
            self.sourceFormat = sourceFormat; self.volumeIndex = volumeIndex
            self.volumeCount = volumeCount; self.createdAt = createdAt; self.isRemoved = isRemoved
        }
    }

    @Model final class PlaylistRecord {
        @Attribute(.unique) var id: String
        var name: String
        /// "manual" or "automatic".
        var kind: String
        var matchAll: Bool
        var sortIndex: Int

        init(id: String, name: String, kind: String, matchAll: Bool, sortIndex: Int) {
            self.id = id; self.name = name; self.kind = kind
            self.matchAll = matchAll; self.sortIndex = sortIndex
        }
    }

    @Model final class PlaylistEntryRecord {
        var playlistID: String
        var entryID: String
        var sortKey: Double

        init(playlistID: String, entryID: String, sortKey: Double) {
            self.playlistID = playlistID; self.entryID = entryID; self.sortKey = sortKey
        }
    }

    @Model final class PlaylistRuleRecord {
        var playlistID: String
        var field: String
        var comparator: String
        var value: String
        var sortIndex: Int

        init(playlistID: String, field: String, comparator: String, value: String, sortIndex: Int) {
            self.playlistID = playlistID; self.field = field; self.comparator = comparator
            self.value = value; self.sortIndex = sortIndex
        }
    }
}

/// Version 17 adds an optional feed source kind, article feed and news flag
/// (new classes beside the frozen V5, V6 and V16 ones; each only adds an
/// optional column) and the audiobook and playlist tables. Lightweight.
enum LocalLibrarySchemaV17: VersionedSchema {
    static let versionIdentifier = Schema.Version(17, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV16.models.filter {
            $0 != LocalLibrarySchemaV5Models.ArticleRecord.self
                && $0 != LocalLibrarySchemaV6Models.PodcastFeedRecord.self
                && $0 != LocalLibrarySchemaV16Models.PodcastFeedPolicyRecord.self
        } + [
            LocalLibrarySchemaV17Models.ArticleRecord.self,
            LocalLibrarySchemaV17Models.PodcastFeedRecord.self,
            LocalLibrarySchemaV17Models.PodcastFeedPolicyRecord.self,
            LocalLibrarySchemaV17Models.AudiobookRecord.self,
            LocalLibrarySchemaV17Models.PlaylistRecord.self,
            LocalLibrarySchemaV17Models.PlaylistEntryRecord.self,
            LocalLibrarySchemaV17Models.PlaylistRuleRecord.self,
        ]
    }
}

enum LocalLibraryV17MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV16MigrationPlan.schemas + [LocalLibrarySchemaV17.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV16MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV16.self, toVersion: LocalLibrarySchemaV17.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV17
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV17MigrationPlan
