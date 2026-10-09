import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Measurement (Task 3.2)

    /// Reports what the Prep poll and the queue lists cost on a library the
    /// size of a real one.
    ///
    /// Figures go into `docs/2026-09-17-queue-drawdown-measurements.md`. Two
    /// costs are measured separately because they are paid in different
    /// places: `refreshProcessorRuns` reads the store off the main actor,
    /// while the Feeds and Larder lists are rebuilt on the main actor, where
    /// the cost is a dropped frame. Set `WILTED_MEASURE=1` to print.
    func testMeasureThePrepPollAndTheEagerlyBuiltQueueLists() async throws {
        let directory = temporaryDirectory("measure-queue-lists")
        let created = Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        let feedCount = 12
        let perFeed = 30
        let queuedCount = 180

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                var queued = 0
                for feedIndex in 0..<feedCount {
                    let feedURL = try XCTUnwrap(
                        URL(string: "https://podcasts.example.test/measure-\(feedIndex)/feed.xml")
                    )
                    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
                    try await store.save(feed: try PodcastFeed(
                        itemID: feedID, canonicalURL: feedURL,
                        title: "Measure Show \(feedIndex)", createdAt: created
                    ))
                    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                    for episodeIndex in 0..<perFeed {
                        let guid = "measure-\(feedIndex)-\(episodeIndex)"
                        let enclosureURL = try XCTUnwrap(
                            URL(string: "https://podcasts.example.test/measure-\(feedIndex)/\(episodeIndex).mp3")
                        )
                        let episodeID = try ItemID.derivePodcastEpisode(
                            feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL
                        )
                        // Titles and dates vary so every Larder sort has real
                        // work to do rather than comparing equal keys.
                        try await store.save(episode: try PodcastEpisode(
                            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
                            title: "Episode \((episodeIndex * 7 + feedIndex) % perFeed) of \(feedIndex)",
                            publishedTime: Timestamp(created.date.addingTimeInterval(
                                Double((episodeIndex * 13 + feedIndex) % 900) * 86_400
                            )),
                            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: created
                        ))
                        if queued < queuedCount {
                            try await store.addPodcastQueueEpisode(episodeID)
                            queued += 1
                        }
                    }
                }
                // 200 preparation runs of four statuses each, the journal the
                // Prep poll reads.
                for run in 0..<200 {
                    let itemID = try ItemID(rawValue: "measure-run-\(run)")
                    for (step, stage) in [PreparationStage.preparing, .fetching, .assembling, .completed].enumerated() {
                        let terminal = stage == .completed
                            ? try PreparationTerminalResult(
                                outcome: .succeeded, revisionID: RevisionID(rawValue: "rev-measure-\(run)")
                              )
                            : nil
                        try await store.record(preparation: PreparationJournalEntry(
                            id: "measure-\(run)-\(step)", itemID: itemID,
                            requestID: "podcast-prepare|measure-\(run)",
                            status: try PreparationStatus(
                                stage: stage, detail: "step-\(step)",
                                fraction: terminal == nil ? 0.5 : 1, cancellable: terminal == nil,
                                terminalResult: terminal,
                                emittedAt: Timestamp(created.date.addingTimeInterval(Double(run * 10 + step)))
                            )
                        ))
                    }
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.episodes.count, feedCount * perFeed)

        let shouldPrint = ProcessInfo.processInfo.environment["WILTED_MEASURE"] == "1"
        func measure(_ label: String, _ body: () -> Int) -> (seconds: Double, rows: Int) {
            _ = body()  // warm the caches; the first call pays for page-in
            let started = DispatchTime.now().uptimeNanoseconds
            var rows = 0
            for _ in 0..<5 { rows = body() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 5e9
            if shouldPrint {
                print("measure.\(label) seconds=\(String(format: "%.4f", elapsed)) rows=\(rows)")
            }
            return (elapsed, rows)
        }

        // Main-actor cost: the lists a queue screen rebuilds on every change.
        let feeds = measure("feedsEpisodes") { model.feedsEpisodes.count }
        XCTAssertEqual(feeds.rows, feedCount * perFeed - queuedCount)
        XCTAssertLessThan(feeds.seconds, 0.5, "the Feeds list got an order of magnitude slower")

        // One Larder view pass: every group's chip count, its rows, and the
        // continue button's check all call `larderEpisodes(in:)`, and each call
        // rebuilds the whole waiting set.
        let larder = measure("larderEpisodesOneViewPass") {
            var total = 0
            for group in WiltedMacLarderGroup.allCases {
                total += model.larderEpisodes(in: group).count   // the chip count
                total += model.larderEpisodes(in: group).count   // the rows
            }
            total += model.larderEpisodes(in: .playable).count   // the continue check
            return total
        }
        XCTAssertEqual(larder.rows, queuedCount * 2 + model.larderEpisodes(in: .playable).count)
        XCTAssertLessThan(larder.seconds, 0.5, "building the Larder's lists got an order of magnitude slower")

        // Off-main cost: the Prep poll's store reads.
        let pollStarted = DispatchTime.now().uptimeNanoseconds
        model.refreshProcessorRuns()
        var polledRuns = 0
        for _ in 0..<600 {
            if !model.processorRuns.isEmpty { polledRuns = model.processorRuns.count; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pollSeconds = Double(DispatchTime.now().uptimeNanoseconds - pollStarted) / 1e9
        XCTAssertEqual(polledRuns, 200, "the poll publishes the journal's capped run list")
        if shouldPrint {
            print("measure.refreshProcessorRuns seconds=\(String(format: "%.4f", pollSeconds)) rows=\(polledRuns)")
            print("measure.fixture feeds=\(feedCount) episodes=\(model.episodes.count) "
                  + "queued=\(queuedCount) preparationRuns=\(polledRuns) journalRows=\(200 * 4)")
        }
    }

    /// Replaces the UI test testLarderBulkActionsAreDisabledWithHonestEmptyState.
    func testAReadyLibraryWithNothingKeptOffersNoBulkLarderWork() throws {
        let directory = temporaryDirectory("ready-no-bulk-work")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        XCTAssertTrue(model.larderDownloadableEpisodes.isEmpty)
        XCTAssertTrue(model.larderPreparableEpisodes.isEmpty)
    }

    /// Replaces the playback half of testSidebarListsDestinationsOnlyAndNotTheArticleList.
    func testAnArticleStillBeingReadCannotOpenThePlayer() throws {
        let directory = temporaryDirectory("preparing-no-player")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-preparing"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        XCTAssertFalse(model.articles.isEmpty)
        XCTAssertFalse(model.articles.contains { $0.isReady })
    }
}
