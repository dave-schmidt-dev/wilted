import Foundation
import WiltedDomain
import WiltedLibrary
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
        _ rows: [LibraryRow], onPhone: [String],
        playingID: String? = nil, isLoading: Bool = false, limit: Int = CarEpisodeList.defaultLimit
    ) -> CarEpisodeList {
        CarEpisodeList.make(
            rows: rows, onPhone: Set(onPhone.map(id)), playingID: playingID.map(id),
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

    func testOrderIsTheSharedPlayOrder() {
        let rows = [
            row("a", published: 300),
            row("b", published: 100),
            row("c", published: 200),
        ]
        XCTAssertEqual(episodes(make(rows, onPhone: ["a", "b", "c"])).map(\.id.rawValue), ["b", "c", "a"])
    }

    func testCompletedEpisodesComeLastAndReadPlayed() {
        var done = row("a", published: 100)
        done.completedAt = Date(timeIntervalSince1970: 500)
        let rows = [done, row("b", published: 200), row("c", published: 300)]
        let list = episodes(make(rows, onPhone: ["a", "b", "c"]))
        XCTAssertEqual(list.map(\.id.rawValue), ["b", "c", "a"])
        XCTAssertTrue(list.last?.detail.hasSuffix("Played") == true)
        let finished = CarEpisodeList.make(
            rows: [row("a", published: 100), row("b", published: 200)], onPhone: [id("a"), id("b")], playingID: nil,
            isLoading: false, finished: [try! ItemID(rawValue: "a"): Date(timeIntervalSince1970: 9)])
        XCTAssertEqual(episodes(finished).map(\.id.rawValue), ["b", "a"], "played to the end counts as completed")
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

    func testDetailIsTimeLeftWhenStartedAndFullLengthMarkedNewWhenNot() {
        let unstarted = make([row("a", show: "Show", duration: 754)], onPhone: ["a"])
        XCTAssertEqual(episodes(unstarted).first?.detail, "Show · 12:34 · New")
        XCTAssertNil(episodes(unstarted).first?.listenedFraction)
        let started = CarEpisodeList.make(
            rows: [row("a", show: "Show", duration: 600)], onPhone: [id("a")], playingID: nil, isLoading: false,
            progress: [id("a"): EpisodeProgress(positionSeconds: 150, lastPlayedAt: Date(timeIntervalSince1970: 5))])
        XCTAssertEqual(episodes(started).first?.detail, "Show · 07:30 left")
        XCTAssertEqual(episodes(started).first?.listenedFraction, 0.25)
        let untimed = make([row("b", show: "Show", duration: nil)], onPhone: ["b"])
        XCTAssertEqual(episodes(untimed).first?.detail, "Show")
    }

    func testInProgressEpisodesComeFirst() {
        let rows = [row("a", published: 3), row("b", published: 2), row("c", published: 1)]
        let progress = [
            id("c"): EpisodeProgress(positionSeconds: 10, lastPlayedAt: Date(timeIntervalSince1970: 100)),
            id("b"): EpisodeProgress(positionSeconds: 10, lastPlayedAt: Date(timeIntervalSince1970: 200)),
        ]
        let list = CarEpisodeList.make(
            rows: rows, onPhone: Set(rows.map(\.id)), playingID: nil, isLoading: false, progress: progress)
        XCTAssertEqual(episodes(list).map(\.id.rawValue), ["b", "c", "a"])
    }

    // MARK: shows

    func testShowsAreOneRowEachWithCountsAndInProgressShowsFirst() {
        var rows = [row("a", show: "Alpha"), row("b", show: "Beta"), row("c", show: "Alpha"), row("d", show: "Gamma")]
        rows[3].showArtworkURL = URL(string: "https://example.com/g.png")
        let progress = [id("d"): EpisodeProgress(positionSeconds: 5, lastPlayedAt: Date(timeIntervalSince1970: 9))]
        let shows = CarShowList.make(rows: rows, onPhone: Set(["a", "b", "c", "d"].map(id)), progress: progress)
        XCTAssertEqual(shows.map(\.title), ["Gamma", "Alpha", "Beta"])
        XCTAssertEqual(shows.map(\.detail), ["1 downloaded", "2 downloaded", "1 downloaded"])
        XCTAssertEqual(shows.first?.artworkURL?.absoluteString, "https://example.com/g.png")
        let notOnPhone = CarShowList.make(rows: rows, onPhone: [id("b")])
        XCTAssertEqual(notOnPhone.map(\.title), ["Beta"], "a show with nothing on the phone has no row")
        XCTAssertEqual(CarShowList.make(rows: rows, onPhone: Set(rows.map(\.id)), limit: 2).count, 2, "the car's cap applies")
    }

    func testSameTitleShowsStaySeparateByFeedAndShowTheirPublishers() {
        var rows = [
            row("a", show: "Daily Briefing"), row("b", show: "Daily Briefing"),
            row("c", show: "Daily Briefing"),
        ]
        rows[0].showID = id("feed-one")
        rows[0].showPublisher = "North Audio"
        rows[1].showID = id("feed-two")
        rows[1].showPublisher = "South Radio"
        rows[2].showID = id("feed-one")
        rows[2].showPublisher = "North Audio"

        let progress = [id("b"): EpisodeProgress(positionSeconds: 10, lastPlayedAt: Date(timeIntervalSince1970: 20))]
        let shows = CarShowList.make(rows: rows, onPhone: Set(rows.map(\.id)), progress: progress)

        XCTAssertEqual(shows.map(\.identity), [.source(id("feed-two")), .source(id("feed-one"))])
        XCTAssertEqual(shows.map(\.title), ["Daily Briefing", "Daily Briefing"])
        XCTAssertEqual(shows.map(\.downloaded), [1, 2])
        XCTAssertEqual(shows.map(\.detail), ["South Radio · 1 downloaded", "North Audio · 2 downloaded"])
        let secondShow = CarShowList.episodes(
            of: .source(id("feed-two")), rows: rows,
            onPhone: Set(rows.map(\.id)), playingID: nil)
        XCTAssertEqual(episodes(secondShow).map(\.id.rawValue), ["b"], "opening a show uses its feed identity")
    }

    func testMissingIdentityFallbackDoesNotMergeIntoAnIdentifiedShow() {
        var identified = row("a", show: "Daily Briefing")
        identified.showID = id("feed")
        let anonymous = row("b", show: "Daily Briefing")

        let shows = CarShowList.make(rows: [anonymous, identified], onPhone: [id("a"), id("b")])

        XCTAssertEqual(shows.map(\.identity), [.title("Daily Briefing"), .source(id("feed"))])
        let identifiedEpisodes = CarShowList.episodes(
            of: .source(id("feed")), rows: [anonymous, identified], onPhone: [id("a"), id("b")], playingID: nil)
        XCTAssertEqual(episodes(identifiedEpisodes).map(\.id.rawValue), ["a"])
    }

    func testRowsCarryTheSourcePublisherAndFeedIdentity() throws {
        let showID = id("feed")
        let episodeID = id("episode")
        let source = LibrarySource(
            id: showID, kind: .podcastFeed, title: "Daily Briefing", publisher: "North Audio",
            locator: "https://feeds.example.test/daily.xml")
        let episode = try LibraryEntry.podcastEpisode(
            id: episodeID, sourceID: showID, title: "Today", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_000),
            payload: PodcastEpisodePayload(enclosureURL: URL(string: "https://media.example.test/today.mp3")!))
        let content = LibrarySnapshot(
            sources: [source], entries: [episode], slots: [try QueueSlot(entryID: episodeID, sortKey: 0)])

        let projected = try XCTUnwrap(LibraryRowBuilder.rows(
            content: content, checkpoints: [:], clock: LibraryClockFormat(timeZone: .gmt)).first)

        XCTAssertEqual(projected.showID, showID)
        XCTAssertEqual(projected.showPublisher, "North Audio")
    }

    func testShowsAndDownloadedTabsShareEmptyAndLoadingMessages() {
        XCTAssertEqual(CarEpisodeList.emptyMessage(forInitialLoad: false), "No episodes on this iPhone")
        XCTAssertEqual(CarEpisodeList.emptyMessage(forInitialLoad: true), "Loading episodes")
        XCTAssertTrue(CarEpisodeList.isInitialLoad(localStateLoaded: false, lastSynchronizedAt: nil, isRefreshing: false))
        XCTAssertTrue(CarEpisodeList.isInitialLoad(localStateLoaded: true, lastSynchronizedAt: nil, isRefreshing: true))
        XCTAssertFalse(CarEpisodeList.isInitialLoad(localStateLoaded: true, lastSynchronizedAt: nil, isRefreshing: false))
        XCTAssertFalse(CarEpisodeList.isInitialLoad(
            localStateLoaded: true, lastSynchronizedAt: Date(timeIntervalSince1970: 1), isRefreshing: true))
    }

    func testAShowsEpisodesUseTheSameRowsAndPutInProgressFirst() {
        let rows = [row("a", show: "Alpha"), row("b", show: "Beta"), row("c", show: "Alpha")]
        let progress = [id("c"): EpisodeProgress(positionSeconds: 60, lastPlayedAt: Date(timeIntervalSince1970: 9))]
        let list = CarShowList.episodes(
            of: .title("Alpha"), rows: rows, onPhone: Set(rows.map(\.id)), playingID: nil, progress: progress)
        XCTAssertEqual(episodes(list).map(\.id.rawValue), ["c", "a"])
        XCTAssertEqual(episodes(list).first?.detail, "Alpha · 09:00 left")
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
