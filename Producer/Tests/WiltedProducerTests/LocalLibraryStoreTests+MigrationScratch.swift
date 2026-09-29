import Foundation
import XCTest
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testMigrationValidationScratchIsRemovedWhenCopyThrows() throws {
        var validationURL: URL?
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try LocalLibraryStore.withMigrationValidationDirectoryForTesting { destination in
                validationURL = destination
                try FileManager.default.copyItem(at: missingSource, to: destination)
            }
        )
        XCTAssertNotNil(validationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: validationURL!.deletingLastPathComponent().path))
    }
}
