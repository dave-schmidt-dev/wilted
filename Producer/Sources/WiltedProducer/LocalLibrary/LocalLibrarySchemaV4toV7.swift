import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

enum LocalLibrarySchemaV4Models {
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

enum LocalLibrarySchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV3.models + [LocalLibrarySchemaV4Models.TranscriptRecord.self]
    }
}

enum LocalLibrarySchemaV5Models {
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

enum LocalLibrarySchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LocalLibrarySchemaV5Models.ArticleRecord.self, LocalLibrarySchemaV3Models.RevisionRecord.self,
         LocalLibrarySchemaV3Models.PreparationRecord.self, LocalLibrarySchemaV3Models.PlaybackRecord.self,
         LocalLibrarySchemaV3Models.SyncStateRecord.self, LocalLibrarySchemaV3Models.TombstoneRecord.self,
         LocalLibrarySchemaV3Models.RepositoryStateRecord.self, LocalLibrarySchemaV4Models.TranscriptRecord.self]
    }
}

enum LocalLibrarySchemaV6Models {
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

enum LocalLibrarySchemaV6: VersionedSchema {
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

enum LocalLibrarySchemaV7Models {
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

extension LocalLibrarySchemaV7Models {
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
enum LocalLibrarySchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV6.models.filter {
            $0 != LocalLibrarySchemaV4Models.TranscriptRecord.self
                && $0 != LocalLibrarySchemaV6Models.PodcastEpisodeRecord.self
        } + [LocalLibrarySchemaV7Models.TranscriptRecord.self,
             LocalLibrarySchemaV7Models.PodcastEpisodeRecord.self]
    }
}
