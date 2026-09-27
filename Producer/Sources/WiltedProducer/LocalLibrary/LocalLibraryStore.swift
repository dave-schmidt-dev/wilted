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
    internal(set) var podcastLibrarySnapshotFetchCount = 0

    public init(url: URL, migrate: Bool = true) throws {
        try self.init(url: url, migrate: migrate, migrationFailure: nil, retainingAt: nil)
    }

    #if DEBUG
    /// Test-only seam used to prove that the retained copy is complete when a
    /// forward migration fails after preflight and before the live container opens.
    internal init(url: URL, migrate: Bool = true,
                  migrationFailure: (@Sendable () throws -> Void)?, retainingAt: URL? = nil) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retainedURL: URL?
        if migrate, FileManager.default.fileExists(atPath: url.path), !Self.hasV6PodcastTables(at: url) {
            // This runs before ModelContainer sees the source URL. The retained
            // copy is the rollback artifact if a forward migration fails.
            retainedURL = try Self.migrationPreflight(at: url, retainingAt: retainingAt).retainedURL
            try migrationFailure?()
        }
        migrationBackupURL = retainedURL
        let schema = Schema(versionedSchema: LocalLibrarySchemaV13.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    #else
    private init(url: URL, migrate: Bool, migrationFailure: (@Sendable () throws -> Void)?, retainingAt: URL?) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retainedURL: URL?
        if migrate, FileManager.default.fileExists(atPath: url.path), !Self.hasV6PodcastTables(at: url) {
            // This runs before ModelContainer sees the source URL. The retained
            // copy is the rollback artifact if a forward migration fails.
            retainedURL = try Self.migrationPreflight(at: url).retainedURL
        }
        migrationBackupURL = retainedURL
        let schema = Schema(versionedSchema: LocalLibrarySchemaV13.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: LocalLibraryMigrationPlan.self,
                                            configurations: [configuration])
        } else {
            container = try ModelContainer(for: schema, configurations: [configuration])
        }
    }
    #endif

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
