import Foundation
import XCTest
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testMigrationPreflightWritesEveryRetainedFileDurably() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "durable-preflight")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 21))
        let recorder = DurableFileEventRecorder()

        let preflight = try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try LocalLibraryStore.migrationPreflight(at: url)
        }

        let writes = Set(recorder.writtenURLs)
        XCTAssertFalse(writes.isEmpty)
        for file in preflight.retainedFiles {
            XCTAssertTrue(writes.contains(file), "no durable write for \(file.path)")
        }
    }

    func testRestoreFlushesTheMarkerAndEveryRestoredFile() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "durable-restore")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 21))
        let preflight = try LocalLibraryStore.migrationPreflight(at: url)
        let markerURL = LocalLibraryStore.restoreInProgressMarkerURL(for: url)
        let recorder = DurableFileEventRecorder()

        try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try LocalLibraryStore.restoreMigrationBackup(preflight)
        }

        let writes = recorder.writtenURLs
        guard let markerIndex = writes.firstIndex(of: markerURL) else {
            return XCTFail("restore did not durably write the marker")
        }
        XCTAssertEqual(markerIndex, 0, "the marker must be flushed before any restored file")
        XCTAssertTrue(writes.contains(url), "the source store itself was not restored durably")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(5))
    }

    // MARK: Directory-sync uncertainty stays strict

    func testMigrationPreflightWithUncertainRetainedCopyDirectorySyncDoesNotYieldAnAcceptedPreflight() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "uncertain-preflight")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 21))
        let retainedDirectory = url.deletingLastPathComponent().appendingPathComponent("retained", isDirectory: true)
        let retainedURL = retainedDirectory.appendingPathComponent(url.lastPathComponent)
        let sync = DirectorySyncScript(failing: .max)

        XCTAssertThrowsError(
            try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                try LocalLibraryStore.migrationPreflight(at: url, retainingAt: retainedURL)
            }
        )

        XCTAssertGreaterThanOrEqual(sync.attemptCount, 2, "the retained copy's folder sync was attempted and retried")
    }

    func testRestoreWithUncertainMarkerDirectorySyncLeavesTheOriginalSourceFilesIntact() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "uncertain-marker")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 21))
        let preflight = try LocalLibraryStore.migrationPreflight(at: url)
        let sourceDirectory = url.deletingLastPathComponent()
        let sourceName = url.lastPathComponent
        let sourceFiles = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == sourceName || $0.lastPathComponent.hasPrefix("\(sourceName)-") }
        var sourceBytes: [String: Data] = [:]
        for file in sourceFiles { sourceBytes[file.lastPathComponent] = try Data(contentsOf: file) }
        let sync = DirectorySyncScript(failing: .max)

        XCTAssertThrowsError(
            try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                try LocalLibraryStore.restoreMigrationBackup(preflight)
            }
        )

        for (name, bytes) in sourceBytes {
            XCTAssertEqual(try Data(contentsOf: sourceDirectory.appendingPathComponent(name)), bytes,
                           "the source file \(name) is not removed on an uncertain marker")
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(5))
        XCTAssertGreaterThanOrEqual(sync.attemptCount, 2)
    }

    func testRestoreWithUncertainRestoredFileDirectorySyncKeepsTheMarkerAndTheOpenRefuses() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "uncertain-restored")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 21))
        let preflight = try LocalLibraryStore.migrationPreflight(at: url)
        let markerURL = LocalLibraryStore.restoreInProgressMarkerURL(for: url)
        let sync = DirectorySyncScript(failingAfter: 1)

        XCTAssertThrowsError(
            try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                try LocalLibraryStore.restoreMigrationBackup(preflight)
            }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "an uncertain restored file keeps the marker")
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), preflight.retainedURL.path)
        XCTAssertGreaterThanOrEqual(sync.attemptCount, 3, "the marker sync succeeded, then the restored file failed twice")
        XCTAssertThrowsError(try LocalLibraryStore(url: url)) { error in
            guard case .migrationRestoreFailed? = error as? LocalLibraryStoreError else {
                return XCTFail("expected a restore-in-progress refusal, got \(error)")
            }
        }
    }
}
