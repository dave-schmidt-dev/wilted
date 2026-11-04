import CryptoKit
import Foundation
import SwiftData
import WiltedDomain

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
    /// Active subscription epochs last reconciled with the private ad-profile sidecar.
    /// This cache prevents common library projections from rereading/fsyncing it.
    var reconciledAdProfileSubscriptionEpochs: [String: Double]?

    /// Number of transcript payload decode attempts made by library and exact-key reads.
    /// Test-only: sync projections must leave this unchanged; targeted export increments only
    /// for the transcript rows it requested.
    var transcriptDecodeAttemptCount = 0

    /// Exact-key transcript fetches and rows returned by them. Test-only: export must not pay for
    /// unrelated transcript records.
    var targetedTranscriptFetchCount = 0
    var targetedTranscriptRowsRead = 0

    /// Number of retained preparation journal status decode attempts.
    /// Test-only: publication metadata reads must not materialize this history.
    var preparationJournalDecodeAttemptCount = 0

    /// Rows returned by the exact dismissed-item preparation-history lookup.
    /// Test-only: it must be bounded to the requested dismissed IDs.
    var dismissedPreparationHistoryRowsRead = 0

    /// Preparation-history rows returned by candidate/detail pages, plus the
    /// largest single page. These are materialized rows, not SQLite scan counts.
    var preparationRunRowsRead = 0
    var preparationRunMaximumBatchRows = 0

    /// Current-status history rows returned by targeted attempt-prefix or
    /// batched request-ID queries. These count materialized results, not
    /// SQLite scan counts.
    var preparationStatusRowsRead = 0
    var preparationStatusMaximumBatchRows = 0

    /// Number of ledger, high-water and summary fetches made by the lifetime
    /// statistics write and read paths since this store opened. Test-only:
    /// proves each checkpoint and summary read costs a constant number of
    /// exact-key fetches regardless of ledger size.
    var lifetimeStatisticsFetchCount = 0

    /// Number of journal rows materialized by exact event-ID upserts since
    /// this store opened. Test-only: proves preparation writes do not scan
    /// unrelated journal history.
    var preparationJournalLookupRowsRead = 0

    /// Rows returned by targeted work-ticket lookups and existence queries.
    /// This counts result rows, not SQLite rows scanned.
    var targetedWorkTicketRowsRead = 0

    /// Number of journal rows materialized by preparation history maintenance.
    /// Test-only: proves invalidation reads do not grow with retained depth.
    var preparationMaintenanceRowsRead = 0

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
                                      articleCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV21Models.ArticleRecord>()),
                                      revisionCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()),
                                      preparationCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()),
                                      playbackCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>()),
                                      transcriptCount: try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()))
    }
}
