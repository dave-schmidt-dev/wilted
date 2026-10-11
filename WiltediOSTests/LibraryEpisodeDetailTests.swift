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

    // MARK: - Row order

    func testShareSitsBelowPlayAndDownloadInTheEpisodeDetail() {
        XCTAssertGreaterThan(
            LibraryEpisodeDetailRow.share.index, LibraryEpisodeDetailRow.play.index,
            "the Share row follows the Play control")
        XCTAssertGreaterThan(
            LibraryEpisodeDetailRow.share.index, LibraryEpisodeDetailRow.download.index,
            "and the Download control")
        XCTAssertEqual(
            LibraryEpisodeDetailRow.drawn, [.artwork, .header, .download, .share, .notes, .transcript],
            "the shared action row draws Download and Play once; Share stacks after it")
    }

    func testTitleSortIgnoresLeadingTheAndKeepsPlayOrder() throws {
        let titles = ["Theory", "THE AI Daily Brief", "Beta", "AI Daily Brief", "Episode 10", "Episode 2"]
        let queue = try titles.enumerated().map { try row(link: nil, title: $0.element, rawID: "sort-\($0.offset)") }
        for grouping in [LibraryGroupOption.none, .feed] {
            let shown = LibraryListing.organize(queue, sort: .title, group: grouping).flatMap(\.rows)
            XCTAssertEqual(shown.map(\.id.rawValue), ["sort-1", "sort-3", "sort-2", "sort-5", "sort-4", "sort-0"],
                           "equal title keys keep incoming queue order")
            XCTAssertEqual(shown.first?.title, "THE AI Daily Brief", "the display title is unchanged")
        }
        XCTAssertEqual(queue.map(\.title), titles)
        XCTAssertEqual(LibraryListing.organize(queue, sort: .playOrder, group: .none).flatMap(\.rows), queue)
    }

    func testBothShareDestinationsKeepTheNormalLabelAndTextOnlyHelp() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltediOS/Library/LibraryEpisodeDetailView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "@ViewBuilder private func share("))
        let end = try XCTUnwrap(source.range(of: "private func", range: start.upperBound..<source.endIndex))
        let share = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(share.components(separatedBy: "Label(\"Share\", systemImage:").count - 1, 2)
        XCTAssertTrue(share.contains(".help(note)"), "the payload explanation belongs to the actual fallback control")
        XCTAssertTrue(share.contains(".accessibilityHint(note)"))
        XCTAssertTrue(share.contains("ShareLink(item: text, subject: Text(row.title), message: Text(text))"),
                      "fallback message shares the actual title/show payload")
        XCTAssertFalse(share.contains("message: Text(note)"), "control guidance is not shared metadata")
        let visibleNote = try NSRegularExpression(pattern: #"(?m)^[\t ]*Text\(note\)[\t ]*(?:$|\.)"#)
        func drawsNote(_ expression: String) -> Bool {
            visibleNote.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)) != nil
        }
        XCTAssertFalse(drawsNote("ShareLink(item: text, message: Text(note)) { Label(\"Share\", systemImage: \"square.and.arrow.up\") }"),
                       "ShareLink message metadata is not a visible warning")
        XCTAssertTrue(drawsNote("VStack {\n    Text(note)\n        .font(.caption)\n}"),
                      "the audit must detect a standalone visible warning")
        XCTAssertTrue(drawsNote("    Text(note).font(.caption)"))
        XCTAssertFalse(drawsNote(share), "text sharing adds no standalone warning view")
    }

    // MARK: - Share

    private func row(link: URL?, title: String = "The Cost of Everything", rawID: String = "episode") throws -> LibraryRow {
        let show = try ItemID(rawValue: "show"), episode = try ItemID(rawValue: rawID)
        let feed = URL(string: "https://feeds.example.test/waveform.xml")!
        let entry = try LibraryEntry.podcastEpisode(
            id: episode, sourceID: show, title: title, summary: "",
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
            .text("The Cost of Everything - Waveform", note: "Only title and show text is shared."))
        if case let .text(text, note) = LibraryEpisodeShare(row) {
            XCTAssertFalse(text.contains(note), "the shared title/show payload excludes control guidance")
            XCTAssertFalse(text.contains("feeds.example.test"), "never the feed address")
        }
    }

    func testOnlyWebAddressesBecomeAPage() throws {
        let row = try row(link: URL(string: "ftp://waveform.example.test/episode"))
        XCTAssertNil(row.episodeLink)
        XCTAssertEqual(LibraryEpisodeShare(row), .text("The Cost of Everything - Waveform", note: "Only title and show text is shared."))
    }

    /// The payload is decoded without the episode's own validation, so the row applies it again:
    /// credentials, a missing host or an over-long address fall back to text sharing.
    func testAnAddressThePodcastEpisodeWouldRefuseIsNotShareable() throws {
        let unusable = [
            "https://user:password@example.test/episode", "https:episode", "https:///nohost",
            "https://example.test/" + String(repeating: "a", count: 2_100),
        ]
        for link in unusable {
            let row = try row(link: URL(string: link))
            XCTAssertNil(row.episodeLink, link)
            XCTAssertEqual(LibraryEpisodeShare(row), .text("The Cost of Everything - Waveform", note: "Only title and show text is shared."), link)
        }
    }
}
