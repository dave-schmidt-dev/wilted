import XCTest
@testable import WiltedMac

final class WiltedMacEpisodeLabelTests: XCTestCase {
    func testEpisodeLabelFixture() {
        XCTAssertEqual(labels("Season Preview Episode").map(\.kind), [.trailer])
        XCTAssertEqual(labels("PROMO: The next show").map(\.kind), [.promo])
        XCTAssertEqual(labels("Bonus Episode: The Interview").map(\.kind), [.bonus])
        XCTAssertTrue(labels("Preview of our upcoming show").first?.kind == .promo)
    }

    func testEarlierExactTitleAndRelativeDurationIdentifyLikelyRerunAndTrailer() {
        let prior = (0..<4).map { index in
            episode("old-\(index)", "A Regular Show", day: index, duration: 3_600)
        }
        let rerun = episode("rerun", "A Regular Show", day: 5, duration: 3_600)
        XCTAssertEqual(WiltedMacEpisodeLabeler.labels(for: rerun, history: prior + [rerun]).map(\.kind), [.rerun])

        let short = episode("short", "A Tiny Preview", day: 5, duration: 600)
        let trailer = try! XCTUnwrap(WiltedMacEpisodeLabeler.labels(for: short, history: prior + [short]).first)
        XCTAssertEqual(trailer.kind, .trailer)
        XCTAssertTrue(trailer.reason.contains("40%"))
        XCTAssertTrue(trailer.reason.contains("earlier episodes"))
    }

    func testDurationAloneDoesNotMislabelRecurringShortEpisodes() {
        let prior = (0..<5).map { index in
            episode("short-old-\(index)", "Short Stuff: Topic \(index)", day: index, duration: 420)
        }
        let candidate = episode("short-new", "Short Stuff: Another Topic", day: 6, duration: 360)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: candidate, history: prior + [candidate]).isEmpty)
    }

    func testAmbiguousPreviewNeedsCorroborationButClearPreviewDoesNot() {
        let prior = (0..<4).map { index in
            episode("preview-history-\(index)", "A Regular Show \(index)", day: index, duration: 3_600)
        }
        let longAmbiguous = episode("long-preview", "A Tiny Preview", day: 5, duration: 2_400)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: longAmbiguous, history: prior + [longAmbiguous]).isEmpty)

        let clear = episode("clear-preview", "Preview: Season Two", day: 5, duration: 3_600)
        XCTAssertEqual(WiltedMacEpisodeLabeler.labels(for: clear, history: [clear]).map(\.kind), [.trailer])
    }

    func testExplicitTrailerAndRerunCuesAreMeaningful() {
        let trailer = episode("trailer", "Official Trailer: Field Notes", day: 5, duration: 3_600)
        let trailerLabel = try! XCTUnwrap(WiltedMacEpisodeLabeler.labels(for: trailer, history: [trailer]).first)
        XCTAssertEqual(trailerLabel.kind, .trailer)
        XCTAssertTrue(trailerLabel.reason.contains("official trailer"))

        let rerun = episode("rerun", "Rebroadcast: Field Notes", day: 5, duration: 3_600)
        let rerunLabel = try! XCTUnwrap(WiltedMacEpisodeLabeler.labels(for: rerun, history: [rerun]).first)
        XCTAssertEqual(rerunLabel.kind, .rerun)
        XCTAssertTrue(rerunLabel.reason.contains("rebroadcast"))

        let show = episode("show", "Trailer Park Boys: A New Episode", day: 5, duration: 3_600)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: show, history: [show]).isEmpty)
    }

    func testOrdinaryShortAndFullEpisodesRemainUnlabelled() {
        let prior = (0..<4).map { index in
            episode("old-\(index)", "A Regular Show", day: index, duration: 3_600)
        }
        let short = episode("short", "A Short Interview", day: 5, duration: 1_500)
        let full = episode("full", "A Full Interview", day: 6, duration: 3_600)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: short, history: prior + [short]).isEmpty)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: full, history: prior + [short, full]).isEmpty)
    }

    func testSparseHistory() {
        let sparse = [episode("one", "A Regular Show", day: 1, duration: 3_600)]
        let noDate = episode("candidate", "New Interview", day: nil, duration: 300)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: noDate, history: sparse + [noDate]).isEmpty)
        let noDuration = episode("candidate-2", "New Interview Two", day: 3, duration: nil)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: noDuration, history: sparse + [noDuration]).isEmpty)
        let shortHistoryCandidate = episode("candidate-3", "New Interview Three", day: 3, duration: 300)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: shortHistoryCandidate, history: sparse + [shortHistoryCandidate]).isEmpty)
    }

    func testFlaggedFeedList() {
        let current = episode("current", "Coming Soon Promo", day: 4, duration: 3_600)
        let laterDuplicate = episode("later", "Archive Episode", day: 5, duration: 3_600)
        let earlierDuplicate = episode("earlier", "Archive Episode", day: 2, duration: 3_600)
        XCTAssertTrue(WiltedMacEpisodeLabeler.labels(for: laterDuplicate, history: [current, laterDuplicate]).isEmpty)
        XCTAssertEqual(WiltedMacEpisodeLabeler.labels(for: laterDuplicate, history: [earlierDuplicate, laterDuplicate]).map(\.kind), [.rerun])
        let rows = WiltedMacEpisodeLabeler.reviewRows(
            candidates: [current], history: [current, laterDuplicate]
        )
        XCTAssertEqual(rows.map(\.showTitle), ["Field Notes"])
        XCTAssertEqual(rows.map(\.episodeTitle), ["Coming Soon Promo"])
        XCTAssertEqual(rows.first?.labels.first?.kind, .promo)
    }

    func testBulkLabelingMatchesSingleEpisodeResultsAndSameTimePeersAreNotReruns() {
        let first = episode("peer-a", "Field Notes: Weekly", day: 1, duration: 3_600)
        let sameTimePeer = episode("peer-b", "Field Notes: Weekly", day: 1, duration: 3_600)
        let later = episode("later", "Field Notes: Weekly", day: 2, duration: 3_600)
        let preview = episode("preview", "Season Preview Episode", day: 3, duration: 3_600)
        let episodes = [first, sameTimePeer, later, preview]
        let bulk = WiltedMacEpisodeLabeler.labelsByID(for: episodes)

        XCTAssertTrue(bulk[first.id]?.isEmpty == true)
        XCTAssertTrue(bulk[sameTimePeer.id]?.isEmpty == true)
        XCTAssertEqual(bulk[later.id]?.map(\.kind), [.rerun])
        XCTAssertEqual(bulk[preview.id]?.map(\.kind), [.trailer])
        for episode in episodes {
            XCTAssertEqual(bulk[episode.id], WiltedMacEpisodeLabeler.labels(for: episode, history: episodes))
        }
    }

    private func labels(_ title: String) -> [WiltedMacEpisodeLabel] {
        let candidate = episode("candidate", title, day: 5, duration: 3_600)
        return WiltedMacEpisodeLabeler.labels(for: candidate, history: [candidate])
    }

    private func episode(
        _ id: String, _ title: String, day: Int?, duration: TimeInterval?
    ) -> WiltedMacEpisode {
        let date = day.map { Date(timeIntervalSince1970: TimeInterval($0 * 86_400)) }
        return WiltedMacEpisode(
            id: id, title: title, feedTitle: "Field Notes", summary: "Fixture",
            artworkURL: nil, releasedAt: date ?? .distantPast, publishedAt: date,
            sourceDurationSeconds: duration, durationSeconds: duration,
            playbackSeconds: 0, downloadState: .notDownloaded, feedID: "fixture-feed"
        )
    }
}
