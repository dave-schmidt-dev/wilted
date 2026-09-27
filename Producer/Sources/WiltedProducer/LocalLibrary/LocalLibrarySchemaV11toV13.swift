import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

enum LocalLibrarySchemaV11Models {
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
enum LocalLibrarySchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV10.models + [
            LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord.self,
            LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord.self,
        ]
    }
}

enum LocalLibrarySchemaV12Models {
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

        /// Overwrites every field but `id`/`kind`/`subjectID`. A re-admission
        /// keeps that durable key but replaces its attempt identity and intake
        /// time with the newer request.
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
            requestedAt = value.requestedAt.date
            updatedAt = value.updatedAt.date
        }
    }
}

/// Version 12 adds the work-ticket queue only. Lightweight: the addition is
/// a wholly new table and no existing column changes shape -- same
/// justification V10 and V11 already carry.
enum LocalLibrarySchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV11.models + [
            LocalLibrarySchemaV12Models.WorkTicketRecord.self,
        ]
    }
}

enum LocalLibrarySchemaV13Models {
    /// The episode entity as of store version 13: version ten's columns
    /// verbatim, plus `removalKind`. Retirement and dismissal used to be two
    /// mechanisms -- a nullable `retiredAt` column on this same row, and a
    /// deletion of the row paired with a tombstone in a standalone table.
    /// This column folds them into one state so un-retire and un-dismiss are
    /// the same store operation. `retiredAt` keeps its name and shape on
    /// purpose: SwiftData's lightweight migration matches columns by name, so
    /// renaming it would read as a brand-new nullable column and silently
    /// drop every existing retirement instead of carrying it forward. It is
    /// reused, unrenamed, as the removal timestamp for both kinds.
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
        var retiredAt: Date?
        /// Nullable: a pre-V13 row migrates to "neither" (nil), matching what
        /// was true of it -- a dismissal never survived as a row before this
        /// version, so reconciliation (not this lightweight stage) is what
        /// turns a tombstone into a dismissed row here. Values are
        /// `PodcastEpisodeRemovalKind.rawValue`. Lifecycle-owned like
        /// `retiredAt` -- `apply(_:to:)` must never write this column from
        /// feed data.
        var removalKind: String?

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
            removalKind = nil
        }

        /// A stand-in row for a dismissal tombstone whose episode row is
        /// already gone -- the ordinary case, since dismissal used to delete
        /// it. Carries exactly what the tombstone knew: an identity, a
        /// removal timestamp, and optionally a feed and a title. Every other
        /// column gets an inert sentinel rather than a guess, and a later
        /// feed refresh's `apply(_:to:)` overwrites the sentinel content in
        /// place if the feed still lists the episode -- `id` is what admission
        /// matches on, not any of these fields.
        init(
            placeholderForDismissalID id: String, feedID: String?, title: String?, dismissedAt: Date
        ) {
            self.id = id
            self.feedID = feedID ?? "removed-episode-unknown-feed"
            self.feedURL = "https://wilted.invalid/removed-episode"
            self.title = title ?? "Removed podcast episode"
            self.enclosureURL = "https://wilted.invalid/removed-episode"
            self.enclosureMediaType = "application/octet-stream"
            self.createdAt = dismissedAt
            self.retiredAt = dismissedAt
            self.removalKind = PodcastEpisodeRemovalKind.dismissed.rawValue
        }

        static func encode(_ sources: [PodcastTranscriptSource]) throws -> Data? {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.encode(sources)
        }

        static func decode(_ payload: Data?) throws -> [PodcastTranscriptSource] {
            try LocalLibrarySchemaV7Models.PodcastEpisodeRecord.decode(payload)
        }
    }
}

/// Version 13 replaces the episode entity with one that also carries
/// `removalKind`. Lightweight: the addition is nullable and no existing
/// column changes shape. `PodcastEpisodeDismissalRecord` stays in the model
/// list unchanged -- dropping it here would make it unfetchable before
/// `reconcileEpisodeRemovals` gets a chance to read and retire the tombstones
/// it holds, the same reason `reconcileWorkTickets` runs as a post-open pass
/// rather than a migration stage.
enum LocalLibrarySchemaV13: VersionedSchema {
    static let versionIdentifier = Schema.Version(13, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV12.models.filter { $0 != LocalLibrarySchemaV10Models.PodcastEpisodeRecord.self }
            + [LocalLibrarySchemaV13Models.PodcastEpisodeRecord.self]
    }
}

/// One episode's removal state: retired by finishing it, dismissed by the
/// listener removing it, or neither. Replaces the pair of mechanisms
/// `retiredAt` (alone) and `PodcastEpisodeDismissalRecord` used to express.
public enum PodcastEpisodeRemovalKind: String, Codable, Equatable, Sendable {
    case retired
    case dismissed
}

enum LocalLibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LocalLibrarySchemaV1.self, LocalLibrarySchemaV2.self, LocalLibrarySchemaV3.self,
         LocalLibrarySchemaV4.self, LocalLibrarySchemaV5.self, LocalLibrarySchemaV6.self,
         LocalLibrarySchemaV7.self, LocalLibrarySchemaV8.self, LocalLibrarySchemaV9.self,
         LocalLibrarySchemaV10.self, LocalLibrarySchemaV11.self, LocalLibrarySchemaV12.self,
         LocalLibrarySchemaV13.self]
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
         .lightweight(fromVersion: LocalLibrarySchemaV11.self, toVersion: LocalLibrarySchemaV12.self),
         .lightweight(fromVersion: LocalLibrarySchemaV12.self, toVersion: LocalLibrarySchemaV13.self)]
    }
}

enum LocalLibraryV5MigrationPlan: SchemaMigrationPlan {
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
