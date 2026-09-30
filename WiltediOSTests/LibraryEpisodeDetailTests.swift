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
}
