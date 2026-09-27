import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
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

    /// Builds a frozen V12 store for the V13 episode-removal reconciliation
    /// test: episode rows (some already carrying a bare `retiredAt`) plus
    /// standalone dismissal tombstones, exactly the shape `reconcileEpisodeRemovals`
    /// must fold onto `removalKind` without losing or duplicating anything.
    nonisolated internal static func createV12MigrationFixture(
        at url: URL, episodes: [PodcastEpisode], retiredEpisodeIDs: Set<String>,
        dismissals: [(episodeID: String, feedID: String?, title: String?, dismissedAt: Date)]
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for episode in episodes {
            let record = try LocalLibrarySchemaV10Models.PodcastEpisodeRecord(episode)
            if retiredEpisodeIDs.contains(episode.itemID.rawValue) {
                record.retiredAt = Date()
            }
            context.insert(record)
        }
        for dismissal in dismissals {
            context.insert(LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord(
                episodeID: dismissal.episodeID, feedID: dismissal.feedID, title: dismissal.title,
                dismissedAt: dismissal.dismissedAt
            ))
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

}
