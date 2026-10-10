import XCTest
@testable import WiltedDomain

final class PausePointFinderTests: XCTestCase {
    private func cues(_ spans: [(Double, Double)]) throws -> [TranscriptCue] {
        try spans.map { try TranscriptCue(startSeconds: $0.0, endSeconds: $0.1, text: "x") }
    }

    func testFindsTheStartOfTheNextGapOfAtLeastSevenTenthsOfASecond() throws {
        // 0-5, gap of 0.5 (too short), 5.5-9, gap of 1.0, 10-12.
        let found = PausePointFinder.next(after: 1, cues: try cues([(0, 5), (5.5, 9), (10, 12)]),
                                          timing: .published, waitLimit: 60)
        XCTAssertEqual(found, 9)
    }

    func testReturnsNowPlusLimitWhenNoGapComesInTime() throws {
        let found = PausePointFinder.next(after: 1, cues: try cues([(0, 5), (5.5, 9), (10, 12)]),
                                          timing: .aligned, waitLimit: 4)
        XCTAssertEqual(found, 5)
    }

    func testTimingNoneUsesTheWaitLimitEvenWithCues() throws {
        XCTAssertEqual(PausePointFinder.next(after: 10, cues: nil, timing: .none, waitLimit: 60), 70)
        XCTAssertEqual(PausePointFinder.next(after: 10, cues: try cues([(0, 1), (5, 6)]), timing: .none, waitLimit: 60), 70)
    }

    func testOverlappingCuesLeaveNoGapBeforeTheLongestEnds() throws {
        let overlapping = try cues([(0, 10), (1, 2), (3, 4)])
        XCTAssertEqual(PausePointFinder.next(after: 0, cues: overlapping, timing: .published, waitLimit: 60), 10)
        XCTAssertEqual(PausePointFinder.next(after: 0, cues: overlapping, timing: .published, waitLimit: 5), 5)
    }

    func testAGapAlreadyUnderWayIsUsableNow() throws {
        let found = PausePointFinder.next(after: 6, cues: try cues([(0, 5), (8, 9)]), timing: .published, waitLimit: 60)
        XCTAssertEqual(found, 6)
    }
}
