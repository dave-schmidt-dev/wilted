import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

enum LocalLibrarySchemaV8Models {
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
enum LocalLibrarySchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV7.models + [LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord.self]
    }
}

enum LocalLibrarySchemaV9Models {
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
enum LocalLibrarySchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV8.models.filter { $0 != LocalLibrarySchemaV7Models.PodcastEpisodeRecord.self }
            + [LocalLibrarySchemaV9Models.PodcastEpisodeRecord.self]
    }
}

enum LocalLibrarySchemaV10Models {
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
enum LocalLibrarySchemaV10: VersionedSchema {
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
