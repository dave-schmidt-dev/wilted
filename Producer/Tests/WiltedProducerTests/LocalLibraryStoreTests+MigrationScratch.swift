import Foundation
import XCTest
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testMigrationValidationScratchIsRemovedWhenCopyThrows() throws {
        var validationURL: URL?
        let missingSource = OwnedTestTemp.root.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try LocalLibraryStore.withMigrationValidationDirectoryForTesting { destination in
                validationURL = destination
                try FileManager.default.copyItem(at: missingSource, to: destination)
            }
        )
        XCTAssertNotNil(validationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: validationURL!.deletingLastPathComponent().path))
    }

    /// A populated table that vanishes during migration is data loss, never a
    /// skip. An empty table that vanishes, added tables and equal counts pass.
    func testRowCountVerificationRejectsMissingTablesAndAcceptsAddedOnes() throws {
        func assertPreflightFailure(_ before: [String: Int], _ after: [String: Int], mentions text: String,
                                    line: UInt = #line) {
            XCTAssertThrowsError(try LocalLibraryStore.verifyRowCounts(before, preserved: after), line: line) { error in
                guard case LocalLibraryStoreError.migrationPreflightFailed(let reason) = error else {
                    return XCTFail("expected migrationPreflightFailed, got \(error)", line: line)
                }
                XCTAssertTrue(reason.contains(text), reason, line: line)
            }
        }
        assertPreflightFailure(["ZARTICLERECORD": 3, "ZPLAYBACKRECORD": 1], ["ZPLAYBACKRECORD": 1],
                               mentions: "ZARTICLERECORD had 3 rows before migration and is missing after")
        XCTAssertNoThrow(try LocalLibraryStore.verifyRowCounts(["ZTOMBSTONERECORD": 0], preserved: [:]))
        assertPreflightFailure(["ZARTICLERECORD": 3], ["ZARTICLERECORD": 2],
                               mentions: "ZARTICLERECORD had 3 rows before migration and 2 after")
        XCTAssertNoThrow(try LocalLibraryStore.verifyRowCounts(
            ["ZARTICLERECORD": 3, "ZTOMBSTONERECORD": 0],
            preserved: ["ZARTICLERECORD": 3, "ZTOMBSTONERECORD": 0, "ZLIFETIMEMEASUREEVENTRECORD": 0]
        ))
    }
}
