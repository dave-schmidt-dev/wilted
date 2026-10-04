import CoreData
import Foundation
import SwiftData
import WiltedDomain

/// Test seams for the open sequence. Production passes the empty value.
struct LocalLibraryOpenHooks: Sendable {
    /// Runs after the backup is retained and validated, before the source is
    /// migrated in place.
    var beforeMigration: (@Sendable () throws -> Void)?
    /// Runs after the in-place migration has mutated the source and before
    /// its row counts are verified.
    var afterMigration: (@Sendable () throws -> Void)?
    /// Where to retain the backup instead of the default sibling directory.
    var retainingAt: URL?
    /// Clock for the durable tracking-start row.
    var now: @Sendable () -> Date = { Date() }
}

/// What the store found on disk before opening it.
enum LocalLibraryStoreDiskVersion: Equatable, Sendable {
    case absent
    case known(Int)
    case unrecognized(String)
}

extension LocalLibraryStore {
    /// The single open sequence shared by every build configuration.
    ///
    /// 1. A missing store is created at the current schema.
    /// 2. An unrecognised (newer or foreign) store is refused before any
    ///    checkpoint, copy or open can mutate it.
    /// 3. A current store opens directly.
    /// 4. An older store is checkpointed, copied to a retained backup and
    ///    migrated on a disposable clone first; then it is migrated in place,
    ///    its row counts are verified, and any failure restores the backup.
    nonisolated static func openContainer(
        at url: URL, migrate: Bool, hooks: LocalLibraryOpenHooks
    ) throws -> (container: ModelContainer, backupURL: URL?) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = LocalLibrarySchemaVersion.current.rawValue
        var backupURL: URL?
        switch try diskSchemaVersion(at: url) {
        case .absent:
            break
        case .unrecognized(let detail):
            throw LocalLibraryStoreError.incompatibleStoreVersion(detail)
        case .known(let version) where version == current:
            break
        case .known(let version) where version > current:
            throw LocalLibraryStoreError.incompatibleStoreVersion("store schema V\(version) is newer than V\(current)")
        case .known(let version):
            guard migrate else { throw LocalLibraryStoreError.migrationRequired(fromVersion: version) }
            let preflight = try migrationPreflight(at: url, retainingAt: hooks.retainingAt)
            backupURL = preflight.retainedURL
            try migrateInPlace(url: url, preflight: preflight, hooks: hooks)
        }
        let schema = Schema(versionedSchema: LocalLibraryCurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: LocalLibraryCurrentMigrationPlan.self,
                                           configurations: [configuration])
        try ensureLifetimeStatisticsRows(in: container, now: hooks.now())
        return (container, backupURL)
    }

    /// Identifies the on-disk schema by comparing the store's entity version
    /// hashes with each released schema. Reads metadata only.
    nonisolated static func diskSchemaVersion(at url: URL) throws -> LocalLibraryStoreDiskVersion {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true]
            )
        } catch {
            return .unrecognized("store metadata could not be read: \(error.localizedDescription)")
        }
        for schema in LocalLibraryCurrentMigrationPlan.schemas.reversed() {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: schema.models) else { continue }
            if model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                return .known(schema.versionIdentifier.major)
            }
        }
        return .unrecognized("store matches no schema from V1 through V\(LocalLibrarySchemaVersion.current.rawValue)")
    }

    /// Migrates the checkpointed source in place. Any failure -- including a
    /// row-count mismatch afterwards -- restores the retained backup.
    private nonisolated static func migrateInPlace(
        url: URL, preflight: LocalLibraryMigrationPreflight, hooks: LocalLibraryOpenHooks
    ) throws {
        do {
            try hooks.beforeMigration?()
            let before = try tableRowCounts(at: url)
            try autoreleasepool {
                let schema = Schema(versionedSchema: LocalLibraryCurrentSchema.self)
                let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
                _ = try ModelContainer(for: schema, migrationPlan: LocalLibraryCurrentMigrationPlan.self,
                                       configurations: [configuration])
            }
            try hooks.afterMigration?()
            try verifyRowCounts(before, preserved: try tableRowCounts(at: url))
        } catch {
            do {
                try restoreMigrationBackup(preflight)
            } catch let restoreError {
                throw LocalLibraryStoreError.migrationRestoreFailed(
                    backupURL: preflight.retainedURL,
                    reason: "\(error); restore failed: \(restoreError)"
                )
            }
            throw LocalLibraryStoreError.migrationFailedRestored(
                backupURL: preflight.retainedURL, reason: String(describing: error)
            )
        }
    }

    /// Inserts the tracking-start row on the first V14 open and a ready, zero
    /// summary when both ledgers are empty. A store that already holds ledger
    /// rows without a summary stays `rebuildRequired`: opening never rebuilds.
    private nonisolated static func ensureLifetimeStatisticsRows(in container: ModelContainer, now: Date) throws {
        typealias Models = LocalLibrarySchemaV14Models
        let context = ModelContext(container)
        var changed = false
        var tracking = FetchDescriptor<Models.LifetimeStatisticsTrackingRecord>()
        tracking.fetchLimit = 1
        if try context.fetch(tracking).isEmpty {
            context.insert(Models.LifetimeStatisticsTrackingRecord(
                startedAt: now, schemaVersion: LocalLibrarySchemaVersion.current.rawValue
            ))
            changed = true
        }
        var summary = FetchDescriptor<Models.LifetimeStatisticsSummaryRecord>()
        summary.fetchLimit = 1
        if try context.fetch(summary).isEmpty {
            var legacy = FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
            legacy.fetchLimit = 1
            var measured = FetchDescriptor<Models.LifetimeMeasureEventRecord>()
            measured.fetchLimit = 1
            if try context.fetch(legacy).isEmpty, try context.fetch(measured).isEmpty {
                context.insert(Models.LifetimeStatisticsSummaryRecord(state: .ready, updatedAt: now))
                changed = true
            }
        }
        if changed { try context.save() }
    }
}
