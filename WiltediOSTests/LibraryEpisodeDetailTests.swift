import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The pure parts of the episode detail screen.
final class LibraryEpisodeDetailTests: XCTestCase {
    func testNotesSplitIntoTrimmedParagraphs() {
        XCTAssertEqual(
            LibraryNotes.paragraphs("First line.\n\n  Second paragraph.  \r\nThird."),
            ["First line.", "Second paragraph.", "Third."])
    }

    func testEmptyOrWhitespaceNotesGiveNoParagraphs() {
        XCTAssertEqual(LibraryNotes.paragraphs(""), [])
        XCTAssertEqual(LibraryNotes.paragraphs("  \n \n"), [])
    }

    // MARK: - Share

    private func row(link: URL?) throws -> LibraryRow {
        let show = try ItemID(rawValue: "show"), episode = try ItemID(rawValue: "episode")
        let feed = URL(string: "https://feeds.example.test/waveform.xml")!
        let entry = try LibraryEntry.podcastEpisode(
            id: episode, sourceID: show, title: "The Cost of Everything", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: PodcastEpisodePayload(
                enclosureURL: URL(string: "https://media.example.test/a.mp3")!, feedURL: feed, episodeLink: link))
        let content = LibrarySnapshot(
            sources: [LibrarySource(id: show, kind: .podcastFeed, title: "Waveform", locator: feed.absoluteString)],
            entries: [entry], slots: [try QueueSlot(entryID: episode, sortKey: 1)])
        return try XCTUnwrap(LibraryRowBuilder.rows(
            content: content, checkpoints: [:], clock: LibraryClockFormat(timeZone: TimeZone(identifier: "UTC")!)).first)
    }

    /// A Waveform-style episode: the feed published a page, and the Mac carried it to the row.
    func testAnEpisodeWithAPageSharesThatPageNotTheFeed() throws {
        let page = URL(string: "https://waveform.example.test/episodes/the-cost-of-everything")!
        let row = try row(link: page)
        XCTAssertEqual(row.episodeLink, page)
        XCTAssertEqual(LibraryEpisodeShare(row), .page(page, message: "The Cost of Everything · Waveform"))
    }

    func testAnEpisodeWithNoPageSharesTitleAndShowAndSaysNoEpisodePage() throws {
        let row = try row(link: nil)
        XCTAssertNil(row.episodeLink)
        XCTAssertEqual(
            LibraryEpisodeShare(row),
            .text("The Cost of Everything — Waveform", note: "No episode page"))
        if case let .text(text, _) = LibraryEpisodeShare(row) {
            XCTAssertFalse(text.contains("feeds.example.test"), "never the feed address")
        }
    }

    func testOnlyWebAddressesBecomeAPage() throws {
        let row = try row(link: URL(string: "ftp://waveform.example.test/episode"))
        XCTAssertNil(row.episodeLink)
        XCTAssertEqual(LibraryEpisodeShare(row), .text("The Cost of Everything — Waveform", note: "No episode page"))
    }

    /// The payload is decoded without the episode's own validation, so the row applies it again:
    /// credentials, a missing host or an over-long address fall back to "No episode page".
    func testAnAddressThePodcastEpisodeWouldRefuseIsNotShareable() throws {
        let unusable = [
            "https://user:password@example.test/episode", "https:episode", "https:///nohost",
            "https://example.test/" + String(repeating: "a", count: 2_100),
        ]
        for link in unusable {
            let row = try row(link: URL(string: link))
            XCTAssertNil(row.episodeLink, link)
            XCTAssertEqual(LibraryEpisodeShare(row), .text("The Cost of Everything — Waveform", note: "No episode page"), link)
        }
    }
}
