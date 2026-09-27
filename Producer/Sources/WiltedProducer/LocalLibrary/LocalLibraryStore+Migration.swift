import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    /// Checkpoints the source WAL and verifies a complete V5 rollback copy before
    /// the live V6 migration is allowed to open the source database.
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
        try checkpointSQLite(at: sourceURL)
        let retainedDirectory = destinationURL?.deletingLastPathComponent()
            ?? sourceDirectory.appendingPathComponent("\(sourceName).v5-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        let retainedURL = destinationURL ?? retainedDirectory.appendingPathComponent(sourceName)
        let retainedName = retainedURL.lastPathComponent
        let files = try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == sourceName || $0.lastPathComponent.hasPrefix("\(sourceName)-") }
        guard files.contains(where: { $0.standardizedFileURL == sourceURL.standardizedFileURL }) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("source store disappeared")
        }
        let checkpointedFiles = try files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { file in
            (url: file, bytes: try Data(contentsOf: file))
        }
        // Validate a disposable clone. SwiftData may checkpoint or remove WAL
        // sidecars as it opens a store, so opening retainedURL itself would make
        // the rollback artifact differ from the post-checkpoint source.
        let validationDirectory = manager.temporaryDirectory.appendingPathComponent("wilted-v5-validation-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: validationDirectory, withIntermediateDirectories: true)
        let validationURL = validationDirectory.appendingPathComponent(sourceName)
        // The checkpointed main file is self-contained. Keep sidecars out of the
        // disposable validation clone because SQLite may delete them on open.
        try manager.copyItem(at: sourceURL, to: validationURL)
        do {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV5.self)
            let configuration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
            _ = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Legacy V1-V4 stores are still supported. Upgrade only the disposable
            // validation clone to V5; the retained copy and source remain untouched.
            do {
                let schema = Schema(versionedSchema: LocalLibrarySchemaV5.self)
                let configuration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                _ = try ModelContainer(for: schema, migrationPlan: LocalLibraryV5MigrationPlan.self,
                                        configurations: [configuration])
                let reopenedConfiguration = ModelConfiguration(schema: schema, url: validationURL, cloudKitDatabase: .none)
                _ = try ModelContainer(for: schema, configurations: [reopenedConfiguration])
            } catch {
                try? manager.removeItem(at: validationDirectory)
                throw LocalLibraryStoreError.migrationPreflightFailed("retained V5 copy could not be opened: \(error)")
            }
        }
        try? manager.removeItem(at: validationDirectory)
        // Copy only after validation has closed so SQLite cannot clean up the
        // rollback artifact's sidecars. This preserves every post-checkpoint
        // source file, including zero-length WAL/SHM files.
        var retainedFiles: [URL] = []
        for file in checkpointedFiles {
            let suffix = file.url.lastPathComponent == sourceName
                ? ""
                : String(file.url.lastPathComponent.dropFirst(sourceName.count))
            let copy = retainedDirectory.appendingPathComponent(retainedName + suffix)
            try file.bytes.write(to: copy, options: .atomic)
            retainedFiles.append(copy)
        }
        guard manager.fileExists(atPath: retainedURL.path) else {
            throw LocalLibraryStoreError.migrationPreflightFailed("retained V5 store was not written")
        }
        return LocalLibraryMigrationPreflight(sourceURL: sourceURL, retainedURL: retainedURL, retainedFiles: retainedFiles)
    }

    nonisolated static func hasV6PodcastTables(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let result = runSQLite(url: url, sql: "SELECT name FROM sqlite_master WHERE lower(name) LIKE '%podcastfeed%' LIMIT 1;")
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// Deterministic parser seam for WAL checkpoint failure cases.
    internal nonisolated static func validateWALCheckpointOutputForTesting(_ output: String, walByteCount: Int64? = nil) throws {
        try validateWALCheckpointOutput(output, walByteCount: walByteCount)
    }
    #endif

    private nonisolated static func runSQLite(url: URL, sql: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run(); process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, String(describing: error))
        }
    }

}
