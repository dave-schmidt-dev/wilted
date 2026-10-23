import XCTest
import WiltedDomain
@testable import WiltedLibrary

/// Ad feedback's shared rules: mapping a prepared position onto the original episode, where cuts
/// land, the window a press counts as about a cut, and the wire values that carry them.
final class AdFeedbackTests: XCTestCase {
    /// 0..<100 kept, 100..<160 removed (ad), 160..<165 trimmed silence nobody names, 165..<300 kept,
    /// 300..<330 removed (promo), 330..<400 kept.
    private func timeline() throws -> PreparationStatus.PreparationTimeline {
        try PreparationStatus.PreparationTimeline(
            removed: [
                try .init(originalStartSeconds: 100, originalEndSeconds: 160, label: "ad_break", confidence: 0.9),
                try .init(originalStartSeconds: 300, originalEndSeconds: 330, label: "self_promo", confidence: 0.8),
            ],
            kept: [
                try .init(originalStartSeconds: 0, originalEndSeconds: 100, outputStartSeconds: 0),
                try .init(originalStartSeconds: 165, originalEndSeconds: 300, outputStartSeconds: 100),
                try .init(originalStartSeconds: 330, originalEndSeconds: 400, outputStartSeconds: 235),
            ])
    }

    func testCutsLandAtTheEndOfTheKeptAudioBeforeThem() throws {
        let cuts = try timeline().adCuts
        XCTAssertEqual(cuts.map(\.preparedSeconds), [100, 235])
        XCTAssertEqual(cuts.map(\.label), ["ad_break", "self_promo"])
        XCTAssertEqual(cuts.first?.originalStartSeconds, 100)
        XCTAssertEqual(cuts.first?.originalEndSeconds, 160)
    }

    func testACutAtTheStartLandsAtZero() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, label: "ad_break", confidence: 0.9)],
            kept: [try .init(originalStartSeconds: 30, originalEndSeconds: 90, outputStartSeconds: 0)])
        XCTAssertEqual(timeline.adCuts.map(\.preparedSeconds), [0])
        XCTAssertEqual(timeline.originalPosition(forPrepared: 0), AdFeedbackOriginalPosition(seconds: 30, clamped: false))
    }

    func testMappingInvertsKeptAudioAndSkipsUnnamedGaps() throws {
        let timeline = try timeline()
        XCTAssertEqual(timeline.originalPosition(forPrepared: 50)?.seconds, 50)
        // Just after the first seam: past both the ad and the 5 s of trimmed silence.
        XCTAssertEqual(timeline.originalPosition(forPrepared: 110)?.seconds, 175)
        XCTAssertEqual(timeline.originalPosition(forPrepared: 250)?.seconds, 345)
    }

    func testASeamMapsToTheAudioAfterTheCut() throws {
        let position = try timeline().originalPosition(forPrepared: 100)
        XCTAssertEqual(position, AdFeedbackOriginalPosition(seconds: 165, clamped: false))
    }

    func testAPositionPastTheEndIsPinnedAndFlagged() throws {
        let timeline = try timeline()
        XCTAssertEqual(timeline.originalPosition(forPrepared: 305), AdFeedbackOriginalPosition(seconds: 400, clamped: true))
        XCTAssertEqual(timeline.originalPosition(forPrepared: -3)?.seconds, 0)
        XCTAssertNil(timeline.originalPosition(forPrepared: .nan))
    }

    func testNothingKeptMapsNothing() throws {
        let empty = try PreparationStatus.PreparationTimeline(removed: [], kept: [])
        XCTAssertNil(empty.originalPosition(forPrepared: 10))
        XCTAssertTrue(empty.adCuts.isEmpty)
    }

    func testTheNearestCutMustBeInsideTheWindow() throws {
        let cuts = try timeline().adCuts
        XCTAssertEqual(AdCut.nearest(to: 96, in: cuts)?.preparedSeconds, 100)
        XCTAssertEqual(AdCut.nearest(to: 130, in: cuts)?.preparedSeconds, 100)
        XCTAssertNil(AdCut.nearest(to: 94, in: cuts), "more than 5 s before the seam")
        XCTAssertNil(AdCut.nearest(to: 131, in: cuts), "more than 30 s after the seam")
        XCTAssertEqual(AdCut.nearest(to: 240, in: cuts)?.label, "self_promo")
        XCTAssertNil(AdCut.nearest(to: .infinity, in: cuts))
    }

    func testTheNearerOfTwoSeamsWins() {
        let cuts = [
            AdCut(preparedSeconds: 100, originalStartSeconds: 100, originalEndSeconds: 120, label: "a"),
            AdCut(preparedSeconds: 110, originalStartSeconds: 130, originalEndSeconds: 150, label: "b"),
        ]
        XCTAssertEqual(AdCut.nearest(to: 104, in: cuts)?.label, "a")
        XCTAssertEqual(AdCut.nearest(to: 106, in: cuts)?.label, "b")
    }

    // MARK: Wire values

    func testAFeedbackIntentRoundTripsAndIsADecision() throws {
        let intent = try LibraryIntent.adFeedback(
            entryID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"), kind: .notAnAd,
            playedSeconds: 412.5, deviceID: "phone", createdAt: Date(timeIntervalSince1970: 1_000), id: "f1")
        let decoded = try JSONDecoder().decode(LibraryIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(decoded, intent)
        XCTAssertTrue(intent.action.isDecision)
        XCTAssertEqual(intent.action.entryID, try ItemID(rawValue: "item-a"))
        XCTAssertFalse(IntentRetention.isExpired(intent, now: Date(timeIntervalSince1970: 10_000_000)),
                       "feedback is about the past, so it never goes stale")
    }

    func testAFeedbackIntentRefusesABadPosition() {
        for bad in [-1, Double.nan, .infinity] {
            XCTAssertThrowsError(try LibraryIntent.adFeedback(
                entryID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"), kind: .adHere,
                playedSeconds: bad, deviceID: "phone"))
        }
    }

    func testTranscriptCutsAreOptionalOnTheWire() throws {
        let cut = AdCut(preparedSeconds: 100, originalStartSeconds: 100, originalEndSeconds: 160, label: "ad_break")
        let with = try XCTUnwrap(LibraryTranscript.capped(
            entryID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"), plainText: "words", cuts: [cut]))
        let decoded = try JSONDecoder().decode(LibraryTranscript.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(decoded.cuts, [cut])

        let older = #"{"entryID":"item-a","revisionID":"rev-1","plainText":"words"}"#
        XCTAssertNil(try JSONDecoder().decode(LibraryTranscript.self, from: Data(older.utf8)).cuts,
                     "a transcript from an older Mac says nothing about cuts")
        let none = try LibraryTranscript(entryID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"),
                                         plainText: "words", cuts: [])
        XCTAssertEqual(try JSONDecoder().decode(LibraryTranscript.self, from: JSONEncoder().encode(none)).cuts, [])
    }

    func testTranscriptRefusesAnInvalidCut() {
        let bad = AdCut(preparedSeconds: 10, originalStartSeconds: 50, originalEndSeconds: 40, label: "ad_break")
        XCTAssertThrowsError(try LibraryTranscript(
            entryID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"), plainText: "words", cuts: [bad]))
    }
}
