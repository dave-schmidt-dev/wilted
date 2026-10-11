import Foundation
import WiltedLibrary
import XCTest

final class LibrarySortKeyTests: XCTestCase {
    func testOnlyLeadingTheIsRemovedCaseInsensitively() {
        for title in ["The AI Daily Brief", "THE AI Daily Brief", "the AI Daily Brief", "tHe AI Daily Brief"] {
            XCTAssertEqual(LibrarySortKey.title(title), "AI Daily Brief")
        }
        XCTAssertEqual(LibrarySortKey.title("The The Daily"), "The Daily", "remove only one prefix")
        XCTAssertEqual(LibrarySortKey.title("The "), "")
    }

    func testTheoryAndWhitespaceStayUnchanged() {
        for title in ["Theory", "Theatre", "There", "The", "", " The Daily", "The\tDaily", "The\nDaily", "Thé Daily"] {
            XCTAssertEqual(LibrarySortKey.title(title), title)
        }
    }

    func testKeysPreserveDisplayAndExistingLocalizedNaturalComparison() {
        let titles = ["Theory", "The AI Daily Brief", "Episode 10", "Episode 2", "Beta"]
        let sorted = titles.sorted {
            LibrarySortKey.title($0).localizedStandardCompare(LibrarySortKey.title($1)) == .orderedAscending
        }
        XCTAssertEqual(sorted, ["The AI Daily Brief", "Beta", "Episode 2", "Episode 10", "Theory"])
        XCTAssertEqual(titles[1], "The AI Daily Brief")
        XCTAssertEqual(LibrarySortKey.title("The Épisode 2"), "Épisode 2", "keep case and accents for the existing comparator")
        XCTAssertEqual(LibrarySortKey.title("The Daily  "), "Daily  ", "do not trim the remainder")
    }
}
