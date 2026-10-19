import Foundation
import SQLite3
import XCTest
@testable import WiltedProducer

/// The migration preflight reads the store through the `sqlite3` tool. A lock
/// another connection holds for a moment must make it wait, not fail the
/// migration with "database is locked" (seen in a loaded gate run).
final class LocalLibraryMigrationLockTests: XCTestCase {
    func testPreflightRowCountWaitsOutABriefLock() throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-sqlite-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE ZFOO(x); INSERT INTO ZFOO VALUES (1);", nil, nil, nil), SQLITE_OK)
        // An exclusive lock in rollback-journal mode keeps every reader out until it is released.
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        let released = expectation(description: "the lock is released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            sqlite3_exec(connection, "COMMIT;", nil, nil, nil)
            sqlite3_close(connection)
            released.fulfill()
        }

        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), ["ZFOO": 1])
        wait(for: [released], timeout: 5)
    }
}
