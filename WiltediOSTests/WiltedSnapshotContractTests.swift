import XCTest
@testable import WiltediOS

/// iOS shares the focused state vocabulary used by the canonical Mac pixel
/// renderer. The full state and appearance matrices retain their own semantic
/// coverage; pixel baselines exercise the highest-value shipping surfaces.
final class WiltedSnapshotContractTests: XCTestCase {
    func testIOSSharesTargetedSnapshotSelectorContract() {
        let targetedStateIDs = [
            "emptyLibrary",
            "preparing-fetching",
            "ready",
            "playing",
            "extractionFailure",
            "iCloudUnavailable"
        ]
        let targetedVariantIDs = [
            "light-standard-motion-full",
            "dark-xxxLarge-motion-reduced"
        ]
        XCTAssertEqual(
            targetedStateIDs.filter { WiltedPreviewState.allCases.map(\.id).contains($0) }.count,
            targetedStateIDs.count
        )
        XCTAssertEqual(
            targetedVariantIDs.filter { WiltedVisualVariant.matrix.map(\.id).contains($0) }.count,
            targetedVariantIDs.count
        )
    }
}
