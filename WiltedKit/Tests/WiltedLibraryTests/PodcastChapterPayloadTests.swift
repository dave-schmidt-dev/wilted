import Foundation
import XCTest
import WiltedDomain
@testable import WiltedLibrary

final class PodcastChapterPayloadTests: XCTestCase {
    private let entryID = try! ItemID(rawValue: "episode-1")
    private let sourceID = try! ItemID(rawValue: "feed-1")
    private let revisionID = try! RevisionID(rawValue: "revision-1")

    func testLegacyPodcastPayloadDecodesWithoutOptionalChapters() throws {
        let legacy = Data(#"{"enclosureURL":"https://media.example.test/episode.mp3","rssGUID":"guid-1"}"#.utf8)
        let payload = try JSONDecoder().decode(PodcastEpisodePayload.self, from: legacy)
        XCTAssertNil(payload.preparedChapters)
        XCTAssertEqual(payload.rssGUID, "guid-1")
    }

    func testChapterPayloadBoundsAndStableOrderForCollapsedPoints() throws {
        let chapters = try XCTUnwrap(LibraryPodcastChapters.capped(
            entryID: entryID, revisionID: revisionID,
            chapters: [
                PodcastChapterMark(title: "Later", startSeconds: 9),
                PodcastChapterMark(title: "First collapsed", startSeconds: 3),
                PodcastChapterMark(title: "Second collapsed", startSeconds: 3)
            ]))
        XCTAssertEqual(chapters.chapters.map(\.title), ["First collapsed", "Second collapsed", "Later"])

        let oversized = (0..<LibraryPodcastChapters.maximumChapters + 20).map { index in
            PodcastChapterMark(title: String(repeating: "x", count: 120), startSeconds: Double(index))
        }
        let bounded = try XCTUnwrap(LibraryPodcastChapters.capped(
            entryID: entryID, revisionID: revisionID, chapters: oversized))
        let encoded = try bounded.encoded()
        XCTAssertLessThanOrEqual(bounded.chapters.count, LibraryPodcastChapters.maximumChapters)
        XCTAssertLessThanOrEqual(encoded.count, LibraryPodcastChapters.maximumEncodedBytes)
        XCTAssertLessThan(bounded.chapters.count, LibraryPodcastChapters.maximumChapters,
                          "the payload byte cap is enforced even when chapter count is within its cap")
    }

    func testNavigatorUsesChapterIdentityWhenStartsCollapseToOneSecond() throws {
        let chapters = [
            PodcastChapterMark(title: "Opening", startSeconds: 0),
            PodcastChapterMark(title: "Sponsor", startSeconds: 0),
            PodcastChapterMark(title: "Interview", startSeconds: 0),
            PodcastChapterMark(title: "Questions", startSeconds: 30)
        ]
        let navigator = PodcastChapterNavigator(chapters: chapters)

        var selected = try XCTUnwrap(navigator.index(at: 0))
        XCTAssertEqual(chapters[selected].title, "Opening")
        selected = try XCTUnwrap(navigator.nextIndex(at: 0, selectedIndex: selected))
        XCTAssertEqual(chapters[selected].title, "Sponsor")
        selected = try XCTUnwrap(navigator.nextIndex(at: 0, selectedIndex: selected))
        XCTAssertEqual(chapters[selected].title, "Interview")
        selected = try XCTUnwrap(navigator.previousIndex(at: 0, selectedIndex: selected))
        XCTAssertEqual(chapters[selected].title, "Sponsor")
    }

    func testPodcastEpisodePayloadKeepsOptionalPreparedChaptersUnderLegacyLimit() throws {
        let chapterSet = try LibraryPodcastChapters(
            entryID: entryID, revisionID: revisionID,
            chapters: [PodcastChapterMark(title: "Intro", startSeconds: 0)])
        let entry = try LibraryEntry.podcastEpisode(
            id: entryID, sourceID: sourceID, title: "Episode", summary: "", publishedAt: Date(),
            payload: PodcastEpisodePayload(
                enclosureURL: URL(string: "https://media.example.test/episode.mp3")!,
                preparedChapters: chapterSet))
        XCTAssertLessThan(entry.payload.count, LibraryEntry.payloadLimitBytes)
        XCTAssertEqual(try entry.podcastEpisodePayload().preparedChapters, chapterSet)
    }
}
