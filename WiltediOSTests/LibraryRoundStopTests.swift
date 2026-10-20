import XCTest
@testable import WiltediOS

/// A sync round that stops early names the first reason, so the device log shows why it never synced.
final class LibraryRoundStopTests: XCTestCase {
    private func check(
        cancelled: Bool = false, generationMatches: Bool = true, savedOwner: String? = "owner",
        verifiedOwner: String? = "owner", reviewHold: Bool = false, quarantined: Bool = false, sameStore: Bool = true
    ) -> LibraryRoundStop? {
        LibraryRoundStop.check(
            cancelled: cancelled, generationMatches: generationMatches, savedOwner: savedOwner,
            verifiedOwner: verifiedOwner, reviewHold: reviewHold, quarantined: quarantined, sameStore: sameStore)
    }

    func testARoundWithAVerifiedOwnerOrNoSavedOwnerContinues() {
        XCTAssertNil(check())
        XCTAssertNil(check(savedOwner: nil, verifiedOwner: nil), "an unbound library has no owner to verify")
        XCTAssertNil(check(savedOwner: nil, verifiedOwner: "owner"))
    }

    func testEachStopIsNamed() {
        XCTAssertEqual(check(cancelled: true), .cancelled)
        XCTAssertEqual(check(generationMatches: false), .generationChanged)
        XCTAssertEqual(check(verifiedOwner: nil), .ownerUnverified)
        XCTAssertEqual(check(verifiedOwner: "someone-else"), .ownerDiffers)
        XCTAssertEqual(check(reviewHold: true), .reviewHold)
        XCTAssertEqual(check(quarantined: true), .quarantined)
        XCTAssertEqual(check(sameStore: false), .storeReplaced)
    }
}
