import XCTest
import WiltedDomain
import WiltedLibrary

final class LibraryShowStartOffsetTests: XCTestCase {
    func testOffsetAppliesOnlyWhenThereIsNoSavedPlayback() {
        XCTAssertEqual(
            LibraryShowStartOffsetRules.freshStartPosition(
                configuredSeconds: 45, playableDurationSeconds: 600, hasSavedPlayback: false),
            45)
        XCTAssertEqual(
            LibraryShowStartOffsetRules.freshStartPosition(
                configuredSeconds: 45, playableDurationSeconds: 600, hasSavedPlayback: true),
            0)
    }

    func testUnknownOrShortDurationStartsAtZero() {
        for duration in [Double?.none, 45, 30] {
            XCTAssertEqual(
                LibraryShowStartOffsetRules.freshStartPosition(
                    configuredSeconds: 45, playableDurationSeconds: duration, hasSavedPlayback: false),
                0)
        }
    }

    func testInvalidAndExcessiveOffsetsNeverReachThePlayer() throws {
        let feedID = try ItemID(rawValue: "feed")
        XCTAssertThrowsError(try LibraryShowStartOffset(feedID: feedID, seconds: .infinity, revision: 0))
        XCTAssertThrowsError(try LibraryShowStartOffset(feedID: feedID, seconds: 601, revision: 0))
        XCTAssertThrowsError(try LibraryShowStartOffset(feedID: feedID, seconds: 0, revision: -1))
        XCTAssertEqual(
            LibraryShowStartOffsetRules.freshStartPosition(
                configuredSeconds: .nan, playableDurationSeconds: 60, hasSavedPlayback: false),
            0)
    }

    func testLegacyStatsDecodeWithoutShowOffsets() throws {
        let json = #"{"audioProcessedSeconds":1,"speechGeneratedSeconds":2,"confirmedAdTimeRemovedSeconds":3,"fasterPlaybackTimeSavedSeconds":4}"#
        let stats = try JSONDecoder().decode(LibraryStats.self, from: Data(json.utf8))
        XCTAssertNil(stats.showStartOffsets)
    }
}
