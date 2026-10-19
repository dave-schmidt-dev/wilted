import Foundation
import WiltedDomain
import XCTest
@testable import WiltedMac

/// LG-6: every preparation and playback log line names its episode in one
/// format, with public metadata only.
@MainActor
final class WiltedMacEpisodeLogContextTests: XCTestCase {
    func testRendersEveryKnownFieldInOneFixedOrder() {
        let context = WiltedMacEpisodeLogContext(
            episodeID: "item-e1", feedID: "item-f1", title: "Quiet Machines", requestSequence: 4, attempt: 2)
        XCTAssertEqual(context.rendered, #"episode=item-e1 feed=item-f1 title="Quiet Machines" seq=4 attempt=2"#)
    }

    func testLeavesOutFieldsNobodyKnows() {
        XCTAssertEqual(WiltedMacEpisodeLogContext(episodeID: "item-e1").rendered, "episode=item-e1")
        XCTAssertEqual(
            WiltedMacEpisodeLogContext(episodeID: "item-e1", title: "T", attempt: 1).rendered,
            #"episode=item-e1 title="T" attempt=1"#)
    }

    func testTitleIsOneBoundedLineThatCannotForgeAField() {
        let forged = "Part 1\n\"} seq=99 attempt=\\\"7\tend"
        let title = WiltedMacEpisodeLogContext.sanitizedTitle(forged)
        XCTAssertEqual(title, "Part 1 '} seq=99 attempt=/'7 end")
        let rendered = WiltedMacEpisodeLogContext(episodeID: "item-e1", title: forged).rendered
        XCTAssertEqual(rendered.filter { $0 == "\"" }.count, 2, "only the field's own quotes: \(rendered)")
        XCTAssertFalse(rendered.contains("\n"))

        let long = String(repeating: "abcdefghij", count: 12)
        let bounded = WiltedMacEpisodeLogContext.sanitizedTitle(long)
        XCTAssertEqual(bounded.count, WiltedMacEpisodeLogContext.titleLimit)
        XCTAssertTrue(bounded.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(bounded.dropLast())))
    }

    func testIdentifiersStaySingleTokens() {
        XCTAssertEqual(WiltedMacEpisodeLogContext.token(#"item a"b"#), "item_a_b")
        XCTAssertEqual(WiltedMacEpisodeLogContext.token(""), "-")
    }

    /// The model fills the feed and title from the row it holds, and nothing
    /// else from that row reaches the line.
    func testModelContextNamesTheFeedAndTitleButNeverTheNotes() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "log-context", count: 1, directory: wiltedTemporaryDirectory("log-context"))
        let model = fixture.model
        let id = fixture.ids[0].rawValue
        let index = try XCTUnwrap(model.episodes.firstIndex { $0.id == id })
        let sentinel = "NOTES-SENTINEL-must-not-be-logged"
        model.episodes[index].notes = sentinel
        let episode = model.episodes[index]
        let feedID = try XCTUnwrap(episode.feedID, "a store-loaded row carries its feed")

        let context = model.episodeLogContext(id, requestSequence: 3, attempt: 1)

        XCTAssertEqual(context, WiltedMacEpisodeLogContext(
            episodeID: id, feedID: feedID, title: episode.title, requestSequence: 3, attempt: 1).rendered)
        XCTAssertTrue(context.contains("feed=\(feedID)"), context)
        XCTAssertTrue(context.contains(#"title=""# + episode.title + #"""#), context)
        XCTAssertFalse(context.contains(sentinel))
        if !episode.summary.isEmpty { XCTAssertFalse(context.contains(episode.summary)) }
        XCTAssertEqual(model.episodeLogContext("item-unknown", requestSequence: 5),
                       "episode=item-unknown seq=5", "a row the model does not hold logs its id only")
    }
}
