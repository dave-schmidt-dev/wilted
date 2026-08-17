import SnapshotTesting
import XCTest
@testable import WiltediOS

/// iOS keeps the same snapshot dependency and state vocabulary. Pixel
/// baselines are canonicalized on the Mac unit renderer until an iOS
/// simulator is available; this test prevents the iOS target from silently
/// losing the selectors or visual variants used by that canonical matrix.
final class WiltedSnapshotContractTests: XCTestCase {
    func testIOSSharesCompleteSnapshotSelectorContract() {
        XCTAssertEqual(WiltedPreviewState.allCases.count, 19)
        XCTAssertEqual(WiltedVisualVariant.matrix.count, 8)
        XCTAssertEqual(
            Set(WiltedPreviewState.allCases.map(\.id)).count,
            WiltedPreviewState.allCases.count
        )
        XCTAssertEqual(
            WiltedVisualVariant.matrix.map(\.id),
            [
                "light-standard-motion-full", "light-standard-motion-reduced",
                "light-xxxLarge-motion-full", "light-xxxLarge-motion-reduced",
                "dark-standard-motion-full", "dark-standard-motion-reduced",
                "dark-xxxLarge-motion-full", "dark-xxxLarge-motion-reduced"
            ]
        )
    }

    func testIOSSnapshotTestingDependencyIsCallable() {
        let strategy = Snapshotting<String, String>.lines
        XCTAssertEqual(strategy.pathExtension, "txt")
    }
}
