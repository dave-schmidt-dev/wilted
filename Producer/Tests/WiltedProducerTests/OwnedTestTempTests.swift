import Foundation
import XCTest
@testable import WiltedProducer

/// The temp audit (`scripts/check-temp-leaks.py`) exempts a concurrent run's
/// root only while its marker names a live pid with a matching start time.
final class OwnedTestTempTests: XCTestCase {
    func testRootIsMarkedWithThisProcessAndIsTheScratchParent() throws {
        let root = OwnedTestTemp.root
        let fields = try String(contentsOf: root.appendingPathComponent(OwnedTestTemp.markerName), encoding: .utf8)
            .split(separator: "\n").reduce(into: [String: String]()) { result, line in
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { result[pair[0]] = pair[1] }
            }
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(fields["pid"], String(pid))
        XCTAssertFalse((fields["started"] ?? "").isEmpty)
        XCTAssertEqual(fields["started"], OwnedTestTemp.processStart(pid))
        XCTAssertEqual(fields["path"], root.resolvingSymlinksInPath().path)
        XCTAssertTrue(root.lastPathComponent.hasPrefix("wilted-producer-tests-"))
        XCTAssertEqual(ScratchParent.url(), root)
    }

    func testStoreAndMigrationScratchLandUnderTheOwnedRoot() {
        let store = LocalLibraryStoreTests().makeURL("owned")
        XCTAssertTrue(store.path.hasPrefix(OwnedTestTemp.root.path))
    }
}
