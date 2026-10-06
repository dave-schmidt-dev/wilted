import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The Larder's Sort and Group choices: a pure display transform over the play-ordered rows, persisted
/// per device, with the play order as the fallback for anything unknown.
@MainActor
final class LibraryDisplayOrganizationTests: XCTestCase {
    private let suite = "library-display-organization-tests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func row(
        _ raw: String, title: String? = nil, show: String = "Show", published: TimeInterval = 1_000,
        duration: Double? = 600
    ) -> LibraryRow {
        LibraryRow(
            id: try! ItemID(rawValue: raw), title: title ?? raw, showTitle: show,
            durationText: duration.map(LibraryClockFormat.duration), durationSeconds: duration,
            removal: .none, publishedAt: Date(timeIntervalSince1970: published), removalText: nil,
            checkpointText: nil)
    }

    /// Arrives in play order: a, b, c, d, e.
    private var rows: [LibraryRow] {
        [
            row("a", title: "Walnut", show: "Beta", published: 300, duration: 900),
            row("b", title: "apple 10", show: "Alpha", published: 100, duration: 300),
            row("c", title: "Apple 2", show: "Beta", published: 500, duration: nil),
            row("d", title: "Mango", show: "Alpha", published: 500, duration: 300),
            row("e", title: "Zebra", show: " ", published: 200, duration: 60),
        ]
    }

    private func flat(_ sort: LibrarySortOption, _ group: LibraryGroupOption = .none) -> [String] {
        LibraryListing.organize(rows, sort: sort, group: group).flatMap(\.rows).map(\.id.rawValue)
    }

    func testPlayOrderLeavesTheRowsExactlyAsTheyArrive() {
        XCTAssertEqual(flat(.playOrder), ["a", "b", "c", "d", "e"])
        let sections = LibraryListing.organize(rows, sort: .playOrder, group: .none)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
    }

    func testNewestAndOldestOrderByPublishedDateKeepingPlayOrderForTies() {
        XCTAssertEqual(flat(.newest), ["c", "d", "a", "e", "b"], "c and d tie, so c stays first")
        XCTAssertEqual(flat(.oldest), ["b", "e", "a", "c", "d"])
    }

    func testShortestPutsUnknownDurationsLastAndKeepsPlayOrderForTies() {
        XCTAssertEqual(flat(.shortest), ["e", "b", "d", "a", "c"], "b and d tie at 300 s; c has no duration")
    }

    func testTitleSortsNaturallyIgnoringCase() {
        XCTAssertEqual(flat(.title), ["c", "b", "d", "a", "e"], "Apple 2 before apple 10, then Mango, Walnut, Zebra")
    }

    func testGroupByFeedKeepsTheSortedOrderInsideEachGroupAndOrdersGroupsByTheirFirstRow() {
        let sections = LibraryListing.organize(rows, sort: .playOrder, group: .feed)
        XCTAssertEqual(sections.map(\.title), ["Beta", "Alpha", "Show unknown"])
        XCTAssertEqual(sections.map { $0.rows.map(\.id.rawValue) }, [["a", "c"], ["b", "d"], ["e"]])

        let newest = LibraryListing.organize(rows, sort: .newest, group: .feed)
        XCTAssertEqual(newest.map(\.title), ["Beta", "Alpha", "Show unknown"])
        XCTAssertEqual(newest.map { $0.rows.map(\.id.rawValue) }, [["c", "a"], ["d", "b"], ["e"]])
    }

    func testOrganizingNeverAddsDropsOrReordersTheSourceRows() {
        let source = rows
        for sort in LibrarySortOption.allCases {
            for group in LibraryGroupOption.allCases {
                let shown = LibraryListing.organize(source, sort: sort, group: group).flatMap(\.rows)
                XCTAssertEqual(Set(shown.map(\.id)), Set(source.map(\.id)))
                XCTAssertEqual(shown.count, source.count)
            }
        }
        XCTAssertEqual(source.map(\.id.rawValue), ["a", "b", "c", "d", "e"])
    }

    func testEmptyListOrganizesToNoRows() {
        for group in LibraryGroupOption.allCases {
            XCTAssertTrue(LibraryListing.organize([], sort: .newest, group: group).flatMap(\.rows).isEmpty)
        }
    }

    // MARK: persistence

    func testSortAndGroupDefaultToPlayOrderAndNone() {
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(store.listSort, .playOrder)
        XCTAssertEqual(store.listGroup, .none)
    }

    func testEachSortAndGroupOptionPersistsAcrossLaunches() {
        for sort in LibrarySortOption.allCases {
            for group in LibraryGroupOption.allCases {
                let store = LibrarySettingsStore(defaults: defaults)
                store.listSort = sort
                store.listGroup = group
                let reopened = LibrarySettingsStore(defaults: defaults)
                XCTAssertEqual(reopened.listSort, sort)
                XCTAssertEqual(reopened.listGroup, group)
            }
        }
    }

    func testUnknownStoredValuesFallBackToPlayOrderAndNoGrouping() {
        defaults.set("random", forKey: LibrarySettingsStore.listSortKey)
        defaults.set("series", forKey: LibrarySettingsStore.listGroupKey)
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(store.listSort, .playOrder)
        XCTAssertEqual(store.listGroup, .none)
        defaults.set(7, forKey: LibrarySettingsStore.listSortKey)
        XCTAssertEqual(LibrarySettingsStore(defaults: defaults).listSort, .playOrder)
    }

    func testTheFiveSortsAndTwoGroupsAreExactlyTheOnesOffered() {
        XCTAssertEqual(LibrarySortOption.allCases.map(\.label), ["Play order", "Newest", "Oldest", "Shortest", "Title"])
        XCTAssertEqual(LibraryGroupOption.allCases.map(\.label), ["No Grouping", "Feed"])
    }

    func testFeedGroupedRowsLeaveTheFeedNameToTheSectionHeader() throws {
        let grouped = LibraryListing.organize(rows, sort: .playOrder, group: .feed)
        let alpha = try XCTUnwrap(grouped.first { $0.title == "Alpha" })
        XCTAssertFalse(alpha.namesShowInRows, "the header carries the feed name")
        XCTAssertTrue(LibraryListing.organize(rows, sort: .playOrder, group: .none)[0].namesShowInRows,
                      "the untitled section names the feed on each row")
        for row in alpha.rows {
            let detail = LibraryRowView.detail(row: row, showsShowName: false)
            XCTAssertFalse(detail.localizedCaseInsensitiveContains("Alpha"), detail)
            XCTAssertTrue(detail.contains(row.durationText ?? "Unknown"), detail)
        }
        XCTAssertTrue(
            LibraryRowView.detail(row: try XCTUnwrap(alpha.rows.first)).contains("Alpha"),
            "the same row names its feed when the list is not grouped")
    }
}
