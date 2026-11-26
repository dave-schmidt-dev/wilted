import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class PlaybackJournalRecordTests: XCTestCase {
    func testItemTagIsStableNamespacedAndDoesNotRepeatTheRawIdentifier() throws {
        let raw = "fixture-private-episode-7d63"
        let item = try ItemID(rawValue: raw)

        let first = PlaybackJournalRecord.itemTag(item)
        let second = PlaybackJournalRecord.itemTag(try ItemID(rawValue: raw))

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("item-"))
        XCTAssertEqual(first.count, 25)
        XCTAssertNotEqual(first, raw)
        XCTAssertFalse(first.contains(raw))
        XCTAssertNotEqual(first, PlaybackJournalRecord.itemTag(try ItemID(rawValue: "fixture-private-episode-7d64")))
    }

    func testTypedRecordContainsOnlyVersionedCorrelationAndPlaybackState() throws {
        let item = try ItemID(rawValue: "fixture-private-episode")
        let line = PlaybackJournalRecord(
            source: .phone, event: .routeLost, itemID: item,
            positionSeconds: 55.4, epoch: 8, cause: .routeLoss,
            result: .paused, isPlaying: false, speechHeld: true).line

        XCTAssertTrue(line.hasPrefix("schema=2 source=phone event=route-lost"), line)
        XCTAssertTrue(line.contains("item=\(PlaybackJournalRecord.itemTag(item))"), line)
        XCTAssertTrue(line.contains("position=55.4 epoch=8 cause=route-loss result=paused playing=false speech-held=true"), line)
        XCTAssertFalse(line.contains(item.rawValue))
        let publicLine = PlaybackJournalRecord(
            source: .phone, event: .routeLost, itemID: item,
            positionSeconds: 55.4, epoch: 8, cause: .routeLoss,
            result: .paused, isPlaying: false, speechHeld: true).publicLogLine
        XCTAssertEqual(publicLine, "schema=2 source=phone event=route-lost cause=route-loss result=paused")
        XCTAssertFalse(publicLine.contains("item="))
        XCTAssertFalse(publicLine.contains("position="))
    }

    func testLegacyFreeFormLineDropsContentAndPseudonymizesItemIDs() throws {
        let raw = "fixture-private-episode"
        let item = try ItemID(rawValue: raw)
        let line = PlaybackJournalPrivacy.sanitizeLegacyLine(
            "start entry=\(raw) title=\"Private show and episode\" position=15 autoplay=true account=owner-secret")

        XCTAssertEqual(
            line,
            "schema=2 start item=\(PlaybackJournalRecord.itemTag(item)) position=15.0 autoplay=true")
        XCTAssertFalse(line.contains(raw))
        XCTAssertFalse(line.contains("Private show"))
        XCTAssertFalse(line.contains("owner-secret"))
    }

    func testUnloadLegacyLineKeepsBoundedReasonAndTriggerAndHashesItem() throws {
        let raw = "entry-1"
        let item = try ItemID(rawValue: raw)
        let line = PlaybackJournalPrivacy.sanitizeLegacyLine(
            "stop reason=unload trigger=explicit-stop entry=\(raw) position=51.0")

        XCTAssertEqual(
            line,
            "schema=2 stop reason=unload trigger=explicit-stop item=\(PlaybackJournalRecord.itemTag(item)) position=51.0")
        XCTAssertEqual(
            PlaybackJournalPrivacy.publicLogLine(from: line),
            "schema=2 source=phone event=stop cause=unload")
        XCTAssertFalse(line.contains(raw))
        XCTAssertFalse(PlaybackJournalPrivacy.publicLogLine(from: line).contains("item="))
    }

    func testUnknownLegacyEventAndQuotedValuesAreNotWritten() {
        let line = PlaybackJournalPrivacy.sanitizeLegacyLine(
            "private-title question=\"Delete Show?\" reason=\"raw account details\" owner=owner-id")

        XCTAssertEqual(line, "schema=2 event-unknown")
        XCTAssertFalse(line.contains("Delete Show"))
        XCTAssertFalse(line.contains("account"))
        XCTAssertFalse(line.contains("owner-id"))
    }
}
