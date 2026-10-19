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
}
