import XCTest
@testable import WiltedMac

final class WiltedMacTranscriptSearchTests: XCTestCase {
    func testSearchMatchesCaseInsensitivelyOncePerLine() {
        var search = WiltedMacTranscriptSearch()
        search.setQuery("budget")

        XCTAssertEqual(search.matchingLineIndices(in: [
            "The budget, the BUDGET, and one more budget.",
            "Nothing about costs here.",
            "A Budget appears in this line."
        ]), [0, 2])
    }

    func testNextAndPreviousWrapAcrossResults() {
        var search = WiltedMacTranscriptSearch()
        search.setQuery("match")
        XCTAssertEqual(search.matchingLineIndices(in: ["match one", "match two", "other"]), [0, 1])

        search.selectPrevious(matchCount: 2)
        XCTAssertEqual(search.selectedMatchIndex, 1)
        search.selectNext(matchCount: 2)
        XCTAssertEqual(search.selectedMatchIndex, 0)
    }

    func testChangingQueryResetsSelectedResult() {
        var search = WiltedMacTranscriptSearch()
        search.selectNext(matchCount: 4)
        search.selectNext(matchCount: 4)
        XCTAssertEqual(search.selectedMatchIndex, 2)

        search.setQuery("another word")
        XCTAssertEqual(search.selectedMatchIndex, 0)
    }

    func testBlankQueryHasNoMatches() {
        var search = WiltedMacTranscriptSearch()
        search.setQuery("   \n")
        XCTAssertTrue(search.matchingLineIndices(in: ["some transcript text"]).isEmpty)
    }

    func testUntimedTranscriptIsSplitIntoSearchableLinesWithoutSeekTargets() {
        var search = WiltedMacTranscriptSearch()
        search.setQuery("budget")
        let transcript = WiltedMacTranscript(availability: .available,
                                            text: "Budget mentioned.\n\nThe budget is discussed twice: budget.")

        let lines = search.lines(in: transcript)
        XCTAssertEqual(lines, ["Budget mentioned.", "The budget is discussed twice: budget."])
        XCTAssertEqual(search.matchingLineIndices(in: lines), [0, 1])
        XCTAssertFalse(transcript.isSynchronized, "untimed results remain searchable without seek targets")
    }
}
