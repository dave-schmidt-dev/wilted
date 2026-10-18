import Foundation
import WiltedLibrary
import XCTest

final class LibraryEpisodeOrderingTests: XCTestCase {
    func testLengthPlacesUnknownAndInvalidDurationsLastInBothDirections() {
        let keys = [
            key("unknown", "Unknown", duration: nil),
            key("long", "Long", duration: 300),
            key("short", "Short", duration: 60),
            key("invalid", "Invalid", duration: .nan),
            key("same-b", "Same", duration: 60),
            key("same-a", "Same", duration: 60),
        ]

        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .length, direction: .ascending).map(\.id),
            ["same-a", "same-b", "short", "long", "invalid", "unknown"]
        )
        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .length, direction: .descending).map(\.id),
            ["long", "same-a", "same-b", "short", "invalid", "unknown"]
        )
    }

    func testAgeDirectionMatchesLarderAndLeavesUnknownPublicationLast() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let keys = [
            key("unknown", "Unknown", publishedAt: nil),
            key("old", "Old", publishedAt: old),
            key("new-b", "New", publishedAt: new),
            key("new-a", "New", publishedAt: new),
        ]

        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .age, direction: .ascending).map(\.id),
            ["new-a", "new-b", "old", "unknown"],
            "Age ascending is newest first"
        )
        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .age, direction: .descending).map(\.id),
            ["old", "new-a", "new-b", "unknown"]
        )
    }

    func testAlphabeticalUsesLeadingTheAndNaturalNumbersWithStableIDTies() {
        let keys = [
            key("episode-10", "Episode 10"),
            key("the-ai", "The AI Daily Brief"),
            key("episode-2", "Episode 2"),
            key("beta-b", "Beta"),
            key("beta-a", "Beta"),
        ]

        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .alphabetical, direction: .ascending).map(\.id),
            ["the-ai", "beta-a", "beta-b", "episode-2", "episode-10"]
        )
        XCTAssertEqual(
            LibraryEpisodeOrdering.ordered(keys, sort: .alphabetical, direction: .descending).map(\.id),
            ["episode-10", "episode-2", "beta-a", "beta-b", "the-ai"]
        )
    }

    func testCustomReturnsTheCallerOrder() {
        let keys = [key("b", "B"), key("a", "A")]
        XCTAssertEqual(LibraryEpisodeOrdering.ordered(keys, sort: .custom, direction: .descending), keys)
    }

    private func key(
        _ id: String,
        _ title: String,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil
    ) -> LibraryEpisodeOrdering.Key {
        LibraryEpisodeOrdering.Key(id: id, title: title, durationSeconds: duration, publishedAt: publishedAt)
    }
}
