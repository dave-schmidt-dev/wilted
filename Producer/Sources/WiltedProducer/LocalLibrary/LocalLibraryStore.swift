import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// Actor-isolated SwiftData adapter for the producer's local library.
public actor LocalLibraryStore {
    public static let pipelineProvenanceEvidenceKind = "podcast-pipeline-provenance"
    public static let forcedRedownloadRequestPrefix = "podcast-invalidation|"
    public static let resetPreparationRequestPrefix = "podcast-reset-preparation|"
    /// Current-item identity is encoded inside the existing V6 queue record
    /// shape so Task 2.3 does not silently mutate a released SwiftData schema.
    static let podcastCurrentPositionOffset = 1_000_000_000
    public let url: URL
    public let schemaVersion: LocalLibrarySchemaVersion = .current
    public let cloudKitDatabase: String? = nil
    public let migrationBackupURL: URL?

    nonisolated internal let container: ModelContainer

    /// Number of `context.fetch` calls made by `podcastLibrarySnapshot()` since
    /// this store opened. Test-only: proves the snapshot's read cost stays
    /// flat as the library grows instead of scaling with episode count.
    var podcastLibrarySnapshotFetchCount = 0

    /// Number of ledger, high-water and summary fetches made by the lifetime
    /// statistics write and read paths since this store opened. Test-only:
    /// proves each checkpoint and summary read costs a constant number of
    /// exact-key fetches regardless of ledger size.
    var lifetimeStatisticsFetchCount = 0

    /// Whether a summary rebuild is running; only one may run at a time.
    var lifetimeStatisticsRebuildRunning = false

    /// Opens (creating, migrating or refusing) the store at `url`.
    ///
    /// An existing store that is older than the current schema is first
    /// copied to a retained backup and migrated on a disposable clone; only
    /// then is it migrated in place, and a failed migration restores the
    /// original. A store newer than this build, or unrecognised, is refused
    /// without any write. With `migrate: false`, a store that needs a
    /// migration is refused instead of migrated.
    public init(url: URL, migrate: Bool = true) throws {
        try self.init(url: url, migrate: migrate, hooks: LocalLibraryOpenHooks())
    }

    #if DEBUG
    /// Test-only seam used to prove that the retained copy is complete when a
    /// forward migration fails after preflight and before the live container opens.
    internal init(url: URL, migrate: Bool = true,
                  migrationFailure: (@Sendable () throws -> Void)?, retainingAt: URL? = nil) throws {
        try self.init(url: url, migrate: migrate,
                      hooks: LocalLibraryOpenHooks(beforeMigration: migrationFailure, retainingAt: retainingAt))
    }
    #endif

    init(url: URL, migrate: Bool, hooks: LocalLibraryOpenHooks) throws {
        self.url = url
        let opened = try Self.openContainer(at: url, migrate: migrate, hooks: hooks)
        container = opened.container
        migrationBackupURL = opened.backupURL
    }

    // MARK: - Orphan media audit and reclaim (Task 4.4)

    /// Files a writer owns before its record commits. `nonisolated` because a
    /// download, synthesis, or assembly registers from its own actor without a
    /// hop through the store.
    public nonisolated let inFlightMedia = MediaInFlightRegistry()

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
