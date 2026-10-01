import XCTest
@testable import WiltediOS

@MainActor
final class ShortcutParameterRefresherTests: XCTestCase {
    private func make() -> (ShortcutParameterRefresher, () -> Int) {
        var count = 0
        return (ShortcutParameterRefresher(update: { count += 1 }), { count })
    }

    func testAnEmptyFirstStateDoesNotUpdate() {
        let (refresher, count) = make()
        refresher.names(changedTo: [])
        XCTAssertEqual(count(), 0)
    }

    func testTheFirstNonEmptySetUpdatesOnce() {
        let (refresher, count) = make()
        refresher.names(changedTo: ["TechCrunch Daily", "Hard Fork"])
        refresher.names(changedTo: ["Hard Fork", "TechCrunch Daily"])
        XCTAssertEqual(count(), 1)
    }

    func testAddingAShowUpdatesAgainButCaseAndEmptyTitlesDoNot() {
        let (refresher, count) = make()
        refresher.names(changedTo: ["Hard Fork"])
        refresher.names(changedTo: ["hard fork", ""])
        XCTAssertEqual(count(), 1)
        refresher.names(changedTo: ["Hard Fork", "Radiolab"])
        XCTAssertEqual(count(), 2)
    }

    func testRemovingEveryShowUpdatesOnceAfterShowsWereKnown() {
        let (refresher, count) = make()
        refresher.names(changedTo: ["Hard Fork"])
        refresher.names(changedTo: [])
        XCTAssertEqual(count(), 2)
    }
}
