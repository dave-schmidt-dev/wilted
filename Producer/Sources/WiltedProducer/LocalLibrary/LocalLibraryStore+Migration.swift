import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    /// Checkpoints the source WAL, migrates a disposable clone to the current
    /// schema and verifies its row counts, then writes a complete retained
    /// copy (main file plus every sidecar) before the live store may migrate.
    ///
    /// Works for every supported source version (V1 through the version
    /// before current). An unrecognised store is refused before the
    /// checkpoint, so it is never mutated.
    public nonisolated static func migrationPreflight(at sourceURL: URL, retainingAt destinationURL: URL? = nil) throws -> LocalLibraryMigrationPreflight {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("source store does not exist")
        }
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let sourceName = sourceURL.lastPathComponent
        if let destinationURL,
           destinationURL.deletingLastPathComponent().standardizedFileURL == sourceDirectory.standardizedFileURL {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained destination must not share the source directory")
        }
        let sourceVersion: Int
        switch try diskSchemaVersion(at: sourceURL) {
        case .known(let version): sourceVersion = version
        case .absent: throw LocalLibraryStoreError.migrationPreflightFailed("source store does not exist")
        case .unrecognized(let detail): throw LocalLibraryStoreError.incompatibleStoreVersion(detail)
        }
        try checkpointSQLite(at: sourceURL)
        let retainedDirectory = destinationURL?.deletingLastPathComponent()
            ?? sourceDirectory.appendingPathComponent("\(sourceName).v\(sourceVersion)-backup-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        let retainedURL = destinationURL ?? retainedDirectory.appendingPathComponent(sourceName)
        let retainedName = retainedURL.lastPathComponent
        // Count before capturing bytes: even a read-only SQLite open may touch
        // the shared-memory sidecar, and the backup must equal the source as left.
        let sourceCounts = try tableRowCounts(at: sourceURL)
        let files = try storeFiles(named: sourceName, in: sourceDirectory)
        guard files.contains(where: { $0.standardizedFileURL == sourceURL.standardizedFileURL }) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("source store disappeared")
        }
        let checkpointedFiles = try files.map { file in (url: file, bytes: try Data(contentsOf: file)) }
        // Validate a disposable clone. SwiftData may checkpoint or remove WAL
        // sidecars as it opens a store, so opening retainedURL itself would make
        // the rollback artifact differ from the post-checkpoint source.
        try withMigrationValidationDirectory(manager: manager, sourceName: sourceName) { validationURL in
            // The checkpointed main file is self-contained. Keep sidecars out of the
            // disposable validation clone because SQLite may delete them on open.
            try manager.copyItem(at: sourceURL, to: validationURL)
            do {
                let schema = Schema(versionedSchema: LocalLibraryCurrentSchema.self)
                try autoreleasepool {
                    let configuration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                    _ = try ModelContainer(for: schema, migrationPlan: LocalLibraryCurrentMigrationPlan.self,
                                           configurations: [configuration])
                }
                try autoreleasepool {
                    let reopened = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                    _ = try ModelContainer(for: schema, configurations: [reopened])
                }
                try verifyRowCounts(sourceCounts, preserved: try tableRowCounts(at: validationURL))
            } catch {
                throw LocalLibraryStoreError.migrationPreflightFailed(
                    "disposable V\(sourceVersion) clone did not migrate to V\(LocalLibrarySchemaVersion.current.rawValue): \(error)"
                )
            }
        }
        // Copy only after validation has closed so SQLite cannot clean up the
        // rollback artifact's sidecars. This preserves every post-checkpoint
        // source file, including zero-length WAL/SHM files.
        var retainedFiles: [URL] = []
        for file in checkpointedFiles {
            let suffix = String(file.url.lastPathComponent.dropFirst(sourceName.count))
            let copy = retainedDirectory.appendingPathComponent(retainedName + suffix)
            try file.bytes.write(to: copy, options: .atomic)
            retainedFiles.append(copy)
        }
        guard manager.fileExists(atPath: retainedURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained V\(sourceVersion) store was not written")
        }
        return LocalLibraryMigrationPreflight(sourceURL: sourceURL, retainedURL: retainedURL, retainedFiles: retainedFiles)
    }

    /// Replaces the source store's main file and sidecars with the retained
    /// backup's. Every source file is removed first and the backup is copied
    /// to new files, so a connection still holding the old files cannot write
    /// into the restored ones. The backup itself is never modified.
    public nonisolated static func restoreMigrationBackup(_ preflight: LocalLibraryMigrationPreflight) throws {
        let manager = FileManager.default
        let sourceDirectory = preflight.sourceURL.deletingLastPathComponent()
        let sourceName = preflight.sourceURL.lastPathComponent
        let retainedName = preflight.retainedURL.lastPathComponent
        guard manager.fileExists(atPath: preflight.retainedURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained backup is missing")
        }
        for file in try storeFiles(named: sourceName, in: sourceDirectory) {
            try manager.removeItem(at: file)
        }
        for file in try storeFiles(named: retainedName, in: preflight.retainedURL.deletingLastPathComponent()) {
            let suffix = String(file.lastPathComponent.dropFirst(retainedName.count))
            try manager.copyItem(at: file, to: sourceDirectory.appendingPathComponent(sourceName + suffix))
        }
    }

    /// The main store file plus its `-wal`/`-shm` (or other `-`) sidecars.
    private nonisolated static func storeFiles(named name: String, in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == name || $0.lastPathComponent.hasPrefix("\(name)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Row counts of every entity table (`Z*`, excluding Core Data's `Z_*`
    /// bookkeeping), read through a read-only SQLite connection.
    nonisolated static func tableRowCounts(at url: URL) throws -> [String: Int] {
        let tables = runSQLite(url: url, readOnly: true, sql:
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' AND name NOT LIKE 'Z\\_%' ESCAPE '\\';")
        guard tables.status == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("table listing failed: \(tables.output)")
        }
        let names = tables.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return [:] }
        let sql = names.map { "SELECT '\($0)', count(*) FROM \"\($0)\"" }.joined(separator: " UNION ALL ") + ";"
        let counts = runSQLite(url: url, readOnly: true, sql: sql)
        guard counts.status == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("row count failed: \(counts.output)")
        }
        var result: [String: Int] = [:]
        for line in counts.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|")
            guard fields.count == 2, let count = Int(fields[1]) else { continue }
            result[String(fields[0])] = count
        }
        return result
    }

    /// Every entity table that held rows before a migration must still exist
    /// afterwards with the same row count; a missing populated table is data
    /// loss. An empty table that vanishes loses nothing, so it does not refuse
    /// the open -- refusing would strand the owner's store over a table that
    /// never mattered. New tables are fine.
    nonisolated static func verifyRowCounts(_ before: [String: Int], preserved after: [String: Int]) throws {
        for (table, count) in before.sorted(by: { $0.key < $1.key }) {
            guard let migrated = after[table] else {
                guard count == 0 else {
                    throw LocalLibraryStoreError.migrationPreflightFailed(
                        "table \(table) had \(count) rows before migration and is missing after"
                    )
                }
                continue
            }
            guard migrated == count else {
                throw LocalLibraryStoreError.migrationPreflightFailed(
                    "table \(table) had \(count) rows before migration and \(migrated) after"
                )
            }
        }
    }

    private nonisolated static func checkpointSQLite(at url: URL) throws {
        let result = runSQLite(url: url, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        guard result.status == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("SQLite WAL checkpoint failed: \(result.output)")
        }
        let walURL = URL(fileURLWithPath: "\(url.path)-wal")
        let walByteCount = FileManager.default.fileExists(atPath: walURL.path)
            ? (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value
            : nil
        try validateWALCheckpointOutput(result.output, walByteCount: walByteCount)
    }

    private nonisolated static func withMigrationValidationDirectory<T>(
        manager: FileManager, sourceName: String, operation: (URL) throws -> T
    ) throws -> T {
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "wilted-migration-validation-\(UUID().uuidString)", isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        return try operation(directory.appendingPathComponent(sourceName))
    }

    private nonisolated static func validateWALCheckpointOutput(_ output: String, walByteCount: Int64?) throws {
        let fields = output.split { character in
            character == "|" || character == " " || character == "\t" || character == "\r" || character == "\n"
        }
        guard fields.count == 3, let busy = Int(fields[0]), let log = Int(fields[1]), let checkpointed = Int(fields[2]),
              busy == 0, log == checkpointed, walByteCount == nil || walByteCount == 0 else {
            throw LocalLibraryStoreError.migrationPreflightFailed("SQLite WAL checkpoint was busy or incomplete: \(output)")
        }
    }

    #if DEBUG
    /// Exercises the production validation-directory lifetime with a real
    /// throwing copy operation before any SwiftData container opens the file.
    internal nonisolated static func withMigrationValidationDirectoryForTesting(
        _ operation: (URL) throws -> Void
    ) throws {
        try withMigrationValidationDirectory(manager: .default, sourceName: "validation.sqlite", operation: operation)
    }

    /// Deterministic parser seam for WAL checkpoint failure cases.
    internal nonisolated static func validateWALCheckpointOutputForTesting(_ output: String, walByteCount: Int64? = nil) throws {
        try validateWALCheckpointOutput(output, walByteCount: walByteCount)
    }
    #endif

    private nonisolated static func runSQLite(url: URL, readOnly: Bool = false, sql: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = (readOnly ? ["-readonly"] : []) + [url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            // Drain before waiting: sqlite3 blocks once its output fills the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, String(describing: error))
        }
    }

}
