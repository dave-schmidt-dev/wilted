import XCTest
@testable import WiltedLibrary

final class PlaybackSpeedsTests: XCTestCase {
    func testTheListIsPinned() {
        XCTAssertEqual(PlaybackSpeeds.all, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(PlaybackSpeeds.step, 0.25)
        XCTAssertEqual(PlaybackSpeeds.range, 0.5...2.0)
    }

    func testEverySpeedIsAWholeStepAndTheListIsAscending() {
        XCTAssertEqual(PlaybackSpeeds.all, PlaybackSpeeds.all.sorted())
        for speed in PlaybackSpeeds.all { XCTAssertEqual(speed / PlaybackSpeeds.step, (speed / PlaybackSpeeds.step).rounded()) }
    }

    func testNearestRoundsClampsAndRepairs() {
        XCTAssertEqual(PlaybackSpeeds.nearest(1.4), 1.5)
        XCTAssertEqual(PlaybackSpeeds.nearest(1.35), 1.25)
        XCTAssertEqual(PlaybackSpeeds.nearest(0.1), 0.5)
        XCTAssertEqual(PlaybackSpeeds.nearest(9), 2)
        XCTAssertEqual(PlaybackSpeeds.nearest(.nan, fallback: 1.25), 1.25)
        XCTAssertEqual(PlaybackSpeeds.nearest(.infinity, fallback: 1.25), 1.25)
    }

    func testContainsIsExact() {
        XCTAssertTrue(PlaybackSpeeds.contains(1.75))
        XCTAssertTrue(PlaybackSpeeds.contains(0.5))
        XCTAssertFalse(PlaybackSpeeds.contains(1.1))
        XCTAssertFalse(PlaybackSpeeds.contains(3))
    }
}
