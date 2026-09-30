import Foundation
import WiltedDomain
import XCTest
@testable import WiltediOS

/// The car list: only on-phone episodes, Larder order, the cap, empty states, the playing flag and
/// driving-safe text. Pure logic over `LibraryRow` values.
final class CarEpisodeListTests: XCTestCase {
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func row(
        _ raw: String, title: String? = nil, show: String = "Show", published: TimeInterval = 1_000,
        duration: Double? = 600
    ) -> LibraryRow {
        LibraryRow(
            id: id(raw), title: title ?? raw, showTitle: show,
            durationText: duration.map(LibraryClockFormat.duration), durationSeconds: duration,
            removal: .none, publishedAt: Date(timeIntervalSince1970: published), removalText: nil,
            checkpointText: nil)
    }

    private func make(
        _ rows: [LibraryRow], onPhone: [String], sort: LibrarySortOrder = .custom,
        playingID: String? = nil, isLoading: Bool = false, limit: Int = CarEpisodeList.defaultLimit
    ) -> CarEpisodeList {
        CarEpisodeList.make(
            rows: rows, onPhone: Set(onPhone.map(id)), sort: sort, playingID: playingID.map(id),
            isLoading: isLoading, limit: limit)
    }

    private func episodes(_ list: CarEpisodeList) -> [CarEpisodeRow] {
        guard case let .episodes(rows) = list.content else { return [] }
        return rows
    }

    private func emptyText(_ list: CarEpisodeList) -> String? {
        guard case let .empty(message) = list.content else { return nil }
        return message
    }

    // MARK: selection

    func testOnlyOnPhoneEpisodesAppear() {
        let rows = ["a", "b", "c"].map { row($0) }
        let list = make(rows, onPhone: ["a", "c"])
        XCTAssertEqual(episodes(list).map(\.id.rawValue), ["a", "c"], "offered-but-not-on-phone rows never appear")
    }

    func testOrderFollowsTheLarderSort() {
        let rows = [
            row("a", published: 300),
            row("b", published: 100),
            row("c", published: 200),
        ]
        XCTAssertEqual(episodes(make(rows, onPhone: ["a", "b", "c"], sort: .custom)).map(\.id.rawValue), ["a", "b", "c"])
        XCTAssertEqual(episodes(make(rows, onPhone: ["a", "b", "c"], sort: .newest)).map(\.id.rawValue), ["a", "c", "b"])
    }

    // MARK: cap

    func testCapKeepsTheFirstRowsInOrderAndCountsTheRest() {
        let rows = (0..<30).map { row(String($0)) }
        let list = make(rows, onPhone: (0..<30).map { String($0) })
        XCTAssertEqual(episodes(list).count, 12)
        XCTAssertEqual(list.totalOnPhone, 30)
        XCTAssertEqual(episodes(list).map(\.id.rawValue), (0..<12).map { String($0) })
    }

    func testLimitClampsToOne() {
        let rows = ["a", "b"].map { row($0) }
        XCTAssertEqual(episodes(make(rows, onPhone: ["a", "b"], limit: 0)).map(\.id.rawValue), ["a"])
        XCTAssertEqual(episodes(make(rows, onPhone: ["a", "b"], limit: -3)).map(\.id.rawValue), ["a"])
    }

    // MARK: empty

    func testEmptyShowsThePlainMessageAndLoadingWhileFirstSyncRuns() {
        let rows = ["a"].map { row($0) }
        XCTAssertEqual(emptyText(make([], onPhone: [])), CarEpisodeList.emptyMessage)
        XCTAssertEqual(emptyText(make(rows, onPhone: [])), CarEpisodeList.emptyMessage)
        XCTAssertEqual(emptyText(make([], onPhone: [], isLoading: true)), CarEpisodeList.loadingMessage)
    }

    // MARK: playing

    func testOnlyThePlayingRowIsFlagged() {
        let rows = ["a", "b", "c"].map { row($0) }
        let list = make(rows, onPhone: ["a", "b", "c"], playingID: "b")
        XCTAssertEqual(episodes(list).map(\.isPlaying), [false, true, false])
    }

    // MARK: detail

    func testDetailJoinsShowAndDuration() {
        let timed = make([row("a", show: "Show", duration: 754)], onPhone: ["a"])
        XCTAssertEqual(episodes(timed).first?.detail, "Show · 12:34")
        let untimed = make([row("b", show: "Show", duration: nil)], onPhone: ["b"])
        XCTAssertEqual(episodes(untimed).first?.detail, "Show")
    }

    // MARK: driving safety

    func testMessagesNeverTellTheDriverToHandleThePhone() {
        for message in [CarEpisodeList.emptyMessage, CarEpisodeList.loadingMessage] {
            for verb in ["open", "pick up", "use your", "tap", "download"] {
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(verb),
                    "\"\(message)\" must not contain \"\(verb)\": the car never instructs the driver")
            }
        }
    }
}
