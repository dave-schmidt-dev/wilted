import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {

    /// Builds one feed's worth of episodes at fixed offsets from `origin`, so a
    /// test can say "published 40 days ago" without arithmetic at every call.
    // MARK: Measurement (Task 3.2)

    /// Reports what the read paths cost on a library the size of a real one.
    ///
    /// Figures go into `docs/2026-09-17-queue-drawdown-measurements.md`. The
    /// assertions are loose ceilings, not the measurement: they exist so a
    /// change that makes a read an order of magnitude worse fails here rather
    /// than being noticed as a slow window. Set `WILTED_MEASURE=1` to print.
    func testMeasureTheLibrarySnapshotAndThePreparationRunQuery() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)

        // Twelve subscribed shows, fifty admitted episodes each: 600 episodes,
        // which is a year of weekly listening across a full subscription list.
        let feedCount = 12
        let perFeed = 50
        for feedIndex in 0..<feedCount {
            let feedURL = URL(string: "https://podcasts.example.test/measure-\(feedIndex)/feed.xml")!
            let (feed, built) = try episodes(
                feedURL: feedURL, origin: origin, daysAgo: Array(1...perFeed)
            )
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID,
                                                                   subscribedAt: Timestamp(origin)))
            _ = try await store.savePodcastEpisodes(built, admission: .backfill)
        }

        // The Prep poll reads the journal, so it needs one: 200 runs of four
        // statuses each, roughly a month of nightly preparation.
        let article = try article()
        let revision = try revision(for: article, id: "rev-measure")
        try await store.save(article: article)
        try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/rev-measure.m4a"))
        let stages: [(PreparationStage, String)] = [
            (.preparing, "queued"), (.fetching, "downloading"),
            (.assembling, "cutting"), (.completed, "ready")
        ]
        for run in 0..<200 {
            for (step, stage) in stages.enumerated() {
                let terminal = stage.0 == .completed
                    ? try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID)
                    : nil
                try await store.record(preparation: PreparationJournalEntry(
                    id: "measure-\(run)-\(step)", itemID: article.itemID,
                    requestID: "measure-request-\(run)",
                    status: try PreparationStatus(
                        stage: stage.0, detail: stage.1,
                        fraction: terminal == nil ? 0.5 : 1, cancellable: terminal == nil,
                        terminalResult: terminal,
                        emittedAt: Timestamp(origin.addingTimeInterval(Double(run * 10 + step)))
                    )
                ))
            }
        }

        func footprintBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }

        func measure(
            _ label: String, _ body: () async throws -> Int
        ) async rethrows -> (seconds: Double, bytes: Int64, rows: Int) {
            _ = try await body()  // warm the caches; the first call pays for page-in
            let beforeBytes = footprintBytes()
            let started = DispatchTime.now().uptimeNanoseconds
            var rows = 0
            for _ in 0..<5 { rows = try await body() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 5e9
            let delta = Int64(footprintBytes()) - Int64(beforeBytes)
            if ProcessInfo.processInfo.environment["WILTED_MEASURE"] == "1" {
                print("measure.\(label) seconds=\(String(format: "%.4f", elapsed)) "
                      + "residentDeltaBytes=\(delta) rows=\(rows)")
            }
            return (elapsed, delta, rows)
        }

        let snapshot = try await measure("podcastLibrarySnapshot") {
            try await store.podcastLibrarySnapshot().episodes.count
        }
        // Backfill admits a 30-day window plus the minimum floor, not the whole
        // back catalogue, so 600 published episodes become 360 admitted rows.
        XCTAssertEqual(snapshot.rows, 360)
        XCTAssertLessThan(snapshot.seconds, 1.0,
                          "the snapshot got an order of magnitude slower than its recorded figure")

        let runs = try await measure("preparationRuns") { try await store.preparationRuns().count }
        XCTAssertEqual(runs.rows, 200, "the journal collapses to one summary per request ID")
        XCTAssertLessThan(runs.seconds, 1.0,
                          "the preparation-run query got an order of magnitude slower")

        if ProcessInfo.processInfo.environment["WILTED_MEASURE"] == "1" {
            print("measure.fixture feeds=\(feedCount) episodesPerFeed=\(perFeed) "
                  + "episodesPublished=\(feedCount * perFeed) episodesAdmitted=\(snapshot.rows) "
                  + "preparationRuns=\(runs.rows) journalRows=\(200 * stages.count)")
        }
    }

    func episodes(
        feedURL: URL, origin: Date, daysAgo: [Int], undated: Int = 0
    ) throws -> (feed: PodcastFeed, episodes: [PodcastEpisode]) {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
                                   author: nil, artworkURL: nil, createdAt: Timestamp(origin))
        func episode(_ guid: String, published: Date?) throws -> PodcastEpisode {
            let enclosureURL = URL(string: "\(feedURL.absoluteString.replacingOccurrences(of: "/feed.xml", with: ""))/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                publishedTime: published.map(Timestamp.init), enclosureURL: enclosureURL,
                enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin)
            )
        }
        var built = try daysAgo.map { days in
            try episode("day-\(days)", published: origin.addingTimeInterval(-Double(days) * 86_400))
        }
        built.append(contentsOf: try (0..<undated).map { try episode("undated-\($0)", published: nil) })
        return (feed, built)
    }

    func testInitialSubscriptionMetadataLimitSelectsExactNewestFactualEpisodes() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        for limit in [5, 10] {
            let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let feedURL = URL(string: "https://podcasts.example.test/initial-\(limit)/feed.xml")!
            let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: Array(1...26))
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

            let result = try await store.savePodcastEpisodes(
                all, admission: .backfill, initialMetadataLimit: limit
            )
            let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
            XCTAssertEqual(result.saved.count, limit)
            XCTAssertEqual(stored, (1...limit).map { "day-\($0)" }.sorted())
        }
    }

    func testInitialMetadataLimitLeavesUnknownDatesOutsideTheFactualNewestCap() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/initial-undated/feed.xml")!
        let (feed, all) = try episodes(
            feedURL: feedURL, origin: origin, daysAgo: Array(1...24), undated: 2
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        _ = try await store.savePodcastEpisodes(all, admission: .backfill, initialMetadataLimit: 5)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()

        XCTAssertEqual(stored, ["day-1", "day-2", "day-3", "day-4", "day-5"])
    }

    func testInitialMetadataLimitBreaksTiesByCanonicalEpisodeIdentity() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000), feedURL = URL(string: "https://podcasts.example.test/initial-ties/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL), published = Timestamp(origin.addingTimeInterval(-86_400))
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Ties", createdAt: Timestamp(origin))
        let all = try (0..<6).map { index in
            let guid = "tie-\(index)"
            let enclosureURL = URL(string: "https://podcasts.example.test/audio/\(guid).mp3")!
            return try PodcastEpisode(itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL), feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid, publishedTime: published, enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin))
        }
        let expected = Array(all.map(\.itemID.rawValue).sorted().prefix(5))
        for offered in [all, Array(all.reversed())] {
            let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try LocalLibraryStore(url: url); try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
            _ = try await store.savePodcastEpisodes(offered, admission: .backfill, initialMetadataLimit: 5)
            let stored = try await store.podcastEpisodes(for: feed.itemID).map(\.itemID.rawValue).sorted()
            XCTAssertEqual(stored, expected, "equal dates choose the canonical identities independent of RSS order")
        }
    }

    func testInitialMetadataLimitRefreshesKnownOlderRowWithoutAdmittingNewOlderRows() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/initial-existing/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: Array(1...7))
        let existing = all[6]
        let updatedExisting = try PodcastEpisode(
            itemID: existing.itemID, feedID: existing.feedID, feedURL: existing.feedURL,
            rssGUID: existing.rssGUID, title: "Corrected older title", publishedTime: existing.publishedTime,
            enclosureURL: existing.enclosureURL, enclosureMediaType: existing.enclosureMediaType,
            createdAt: existing.createdAt
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: existing)
        let expectedListening = PodcastListeningState(episodeID: existing.itemID, completedAt: Timestamp(origin), lastRevisionID: try RevisionID(rawValue: "rev-initial-cap"), updatedAt: Timestamp(origin))
        try await store.saveListening(expectedListening)
        let revision = try AudioRevision(itemID: existing.itemID, revisionID: RevisionID(rawValue: "rev-initial-cap"), durationSeconds: 60, byteCount: 4, contentHash: "sha256:\(String(repeating: "a", count: 64))", mediaType: "audio/mp4", createdAt: Timestamp(origin), schemaVersion: 1)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("initial-cap.m4a"); try Data([0, 1, 2, 3]).write(to: mediaURL)
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        let outcome = PodcastPreparationOutcome(episodeID: existing.itemID, revisionID: revision.revisionID, policyDigest: "initial-cap", pipelineFingerprint: "fixture", semanticVersion: "1", producedAt: Timestamp(origin))
        try await store.savePreparationOutcome(outcome)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let result = try await store.savePodcastEpisodes(
            Array(all.dropLast()) + [updatedExisting], admission: .backfill, initialMetadataLimit: 5
        )
        let stored = try await store.podcastEpisodes(for: feed.itemID)
        let refreshed = try XCTUnwrap(stored.first(where: { $0.itemID == existing.itemID }))
        let listening = try await store.listeningState(for: existing.itemID)
        let retainedRevision = try await store.readyRevision(for: existing.itemID)
        let retainedOutcome = try await store.preparationOutcome(for: existing.itemID, revisionID: revision.revisionID)

        XCTAssertEqual(result.newlyAdmitted.count, 5)
        XCTAssertEqual(stored.count, 6, "only the five capped rows plus the known older row belong in the initial window")
        XCTAssertEqual(refreshed.title, "Corrected older title")
        XCTAssertEqual(listening, expectedListening, "metadata refresh must preserve a listener's completed revision")
        XCTAssertEqual(retainedRevision?.revision.revisionID, revision.revisionID)
        XCTAssertEqual(retainedRevision?.mediaURL, mediaURL)
        XCTAssertEqual(retainedOutcome, outcome, "metadata refresh must not discard prepared audio's durable outcome")
    }

    /// Subscribing must not empty a decade of back catalogue into the Larder,
    /// and must not present an empty feed either. The backfill window admits the
    /// recent episodes; a later refresh admits only what published after the
    /// subscription.
    func testSubscriptionBackfillAdmitsRecentEpisodesAndRefreshAdmitsOnlyNewerOnes() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/backfill/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 10, 29, 31, 400, 4_000])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        XCTAssertEqual(Set(backfill.saved.map(\.rawValue)).count, 5,
                       "backfill admits the 30-day window plus the minimum-backfill floor")
        XCTAssertEqual(backfill.skipped, 1)
        var stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()

        XCTAssertEqual(stored, ["day-1", "day-10", "day-29", "day-31", "day-400"],
                       "the oldest episode is beyond both the window and the floor")

        // A refresh three days later: one genuinely new episode, everything else
        // already seen or older than the subscription.
        let later = origin.addingTimeInterval(3 * 86_400)
        let (_, refreshed) = try episodes(feedURL: feedURL, origin: later, daysAgo: [0])
        let increment = try await store.savePodcastEpisodes(all + refreshed, admission: .incremental)
        XCTAssertEqual(increment.skipped, 1, "only the episode outside the store and older than the horizon is refused")
        stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-0", "day-1", "day-10", "day-29", "day-31", "day-400"])
    }

    /// An undated episode has no evidence it is new. Admitting it on every
    /// refresh would leak an undated back catalogue in one refresh at a time.
    func testUndatedEpisodesReachTheLarderOnlyThroughTheBackfillFloor() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/undated/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1], undated: 2)
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        // Subscribed before the dated episode published, so only the undated
        // ones are in question on the refresh.
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-10 * 86_400))
        ))

        let refresh = try await store.savePodcastEpisodes(all, admission: .incremental)
        let afterRefresh = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(refresh.skipped, 2)
        XCTAssertEqual(afterRefresh, 1)

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        let afterBackfill = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(backfill.skipped, 0)
        XCTAssertEqual(afterBackfill, 3)
    }

    /// The undated path is bounded, not open. A feed that dates nothing gets the
    /// backfill floor and no more, in the order the feed listed -- so the cap
    /// admits the newest items a dateless feed offers rather than an arbitrary
    /// five, and a later refresh adds none of the remainder.
    func testAnAllUndatedFeedIsCappedAtTheBackfillFloor() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/dateless/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [], undated: 8)
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(backfill.saved.count, LocalLibraryStore.podcastSubscriptionMinimumBackfill)
        XCTAssertEqual(backfill.skipped, 3)
        XCTAssertEqual(stored, ["undated-0", "undated-1", "undated-2", "undated-3", "undated-4"])

        let refresh = try await store.savePodcastEpisodes(all, admission: .incremental)
        let afterRefresh = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(refresh.skipped, 3, "the remainder stays out on every later refresh")
        XCTAssertEqual(afterRefresh, stored)
    }

    /// Nothing already in the Larder may be evicted by the horizon rule -- a
    /// seeded episode older than the subscription has to survive every refresh.
    func testAnEpisodeAlreadyInTheStoreSurvivesEveryRefresh() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/seeded/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [500])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: all[0])
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let result = try await store.savePodcastEpisodes(all, admission: .incremental)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(stored, ["day-500"])
    }

    /// A feed Wilted does not follow has no horizon to judge against, so the
    /// rule must not silently swallow it.
    func testEpisodesFromAnUnsubscribedFeedAreSavedUnconditionally() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/unfollowed/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 5_000])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)

        let result = try await store.savePodcastEpisodes(all, admission: .incremental)
        let stored = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(stored, 2)
    }

    /// Automation may only act on what one refresh actually brought in. `saved`
    /// includes every row the admission wrote, refreshed-in-place rows among
    /// them, so a download policy reading it would re-download the whole feed on
    /// every refresh. `newlyAdmitted` is the narrower answer.
    func testNewlyAdmittedNamesOnlyTheRowsOneAdmissionInserted() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/newly/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let first = try await store.savePodcastEpisodes(all, admission: .backfill)
        XCTAssertEqual(Set(first.newlyAdmitted), Set(first.saved), "a first admission inserts everything it saves")

        // The same feed, loaded again: every row is refreshed in place.
        let again = try await store.savePodcastEpisodes(all, admission: .incremental)
        XCTAssertEqual(again.saved.count, 2, "the rows are still written")
        XCTAssertEqual(again.newlyAdmitted, [], "but none of them is new")

        let later = origin.addingTimeInterval(86_400)
        let (_, refreshed) = try episodes(feedURL: feedURL, origin: later, daysAgo: [0])
        let increment = try await store.savePodcastEpisodes(all + refreshed, admission: .incremental)
        XCTAssertEqual(increment.newlyAdmitted, [refreshed[0].itemID],
                       "exactly the episode this refresh brought in")
    }

    /// Subscribing twice must not move the horizon. The backfill window is
    /// measured from `subscribedAt`, so re-subscribing through an equivalent URL
    /// -- a capitalised host, a fragment, an explicit :443 -- would otherwise
    /// silently re-admit a back catalogue the listener already dismissed.
    func testSubscribingAgainThroughAnEquivalentURLKeepsTheOriginalHorizon() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/idempotent/feed.xml")!
        let equivalentURL = URL(string: "https://Podcasts.Example.test:443/idempotent/feed.xml#latest")!
        let (feed, _) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)

        let inserted = try await store.subscribeIfNeeded(
            PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin))
        )
        XCTAssertTrue(inserted)

        let equivalentID = try ItemID.derivePodcastFeed(from: equivalentURL)
        XCTAssertEqual(equivalentID, feed.itemID, "canonicalisation collapses the two spellings")
        let repeated = try await store.subscribeIfNeeded(
            PodcastSubscription(feedID: equivalentID, subscribedAt: Timestamp(origin.addingTimeInterval(90 * 86_400)))
        )
        XCTAssertFalse(repeated, "the second subscription is refused, not merged")

        let subscriptions = try await store.subscriptions()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.subscribedAt.date, origin, "the original horizon is untouched")
    }

    /// Unsubscribing clears every record the feed owned and leaves other feeds
    /// untouched. Media files are deliberately not deleted.
    func testUnsubscribingRemovesTheFeedsRecordsAndSparesOtherFeeds() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let goingURL = URL(string: "https://podcasts.example.test/going/feed.xml")!
        let stayingURL = URL(string: "https://podcasts.example.test/staying/feed.xml")!
        let (going, goingEpisodes) = try episodes(feedURL: goingURL, origin: origin, daysAgo: [1, 2])
        let (staying, stayingEpisodes) = try episodes(feedURL: stayingURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        for (feed, list) in [(going, goingEpisodes), (staying, stayingEpisodes)] {
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
            for episode in list { try await store.save(episode: episode) }
        }
        for episode in goingEpisodes + stayingEpisodes {
            try await store.addPodcastQueueEpisode(episode.itemID)
            try await store.save(download: try PodcastDownload(episodeID: episode.itemID, updatedAt: Timestamp(origin)))
            try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.5, updatedAt: Timestamp(origin)))
        }

        let removed = try await store.unsubscribeFromPodcast(feedID: going.itemID)
        let goneSubscription = try await store.subscription(for: going.itemID)
        let goneFeed = try await store.podcastFeed(for: going.itemID)
        let goneEpisodes = try await store.podcastEpisodes(for: going.itemID)
        XCTAssertEqual(removed, 2)
        XCTAssertNil(goneSubscription)
        XCTAssertNil(goneFeed)
        XCTAssertTrue(goneEpisodes.isEmpty)
        for episode in goingEpisodes {
            let download = try await store.download(for: episode.itemID)
            let speed = try await store.playbackSpeed(for: episode.itemID)
            XCTAssertNil(download)
            XCTAssertNil(speed)
        }
        let queue = try await store.queue().map(\.episodeID)
        let survivingSubscription = try await store.subscription(for: staying.itemID)
        let survivingEpisodes = try await store.podcastEpisodes(for: staying.itemID)
        let survivingDownload = try await store.download(for: stayingEpisodes[0].itemID)
        XCTAssertEqual(queue, stayingEpisodes.map(\.itemID))
        XCTAssertNotNil(survivingSubscription)
        XCTAssertEqual(survivingEpisodes.count, 1)
        XCTAssertNotNil(survivingDownload)
    }

    func testForcedMigrationFailureLeavesEveryCheckpointedStoreFileIdentical() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-forced-failure")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 27))

        let failedURL = url.deletingLastPathComponent().appendingPathComponent("failed/library.sqlite")
        final class SnapshotCheck: @unchecked Sendable {
            var matched = false
            var retainedSidecar = false
        }
        let check = SnapshotCheck()
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true,
                                                   migrationFailure: {
                                                       do {
                                                           let manager = FileManager.default
                                                           let sourceDirectory = url.deletingLastPathComponent()
                                                           let sourceFiles = try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == url.lastPathComponent || $0.lastPathComponent.hasPrefix("\(url.lastPathComponent)-") }
                                                           let retainedFiles = try manager.contentsOfDirectory(at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
                                                           guard Set(sourceFiles.map(\.lastPathComponent)) == Set(retainedFiles.map(\.lastPathComponent)) else { throw ForcedMigrationFailure() }
                                                           check.retainedSidecar = sourceFiles.contains { $0.lastPathComponent.hasSuffix("-wal") || $0.lastPathComponent.hasSuffix("-shm") }
                                                           for sourceFile in sourceFiles {
                                                               let retainedFile = failedURL.deletingLastPathComponent().appendingPathComponent(sourceFile.lastPathComponent)
                                                               guard try Data(contentsOf: sourceFile) == Data(contentsOf: retainedFile) else { throw ForcedMigrationFailure() }
                                                           }
                                                           check.matched = true
                                                       } catch {
                                                           throw ForcedMigrationFailure()
                                                       }
                                                       throw ForcedMigrationFailure()
                                                   }, retainingAt: failedURL))
        XCTAssertTrue(check.retainedSidecar, "preflight must retain SQLite sidecars when the store provides them")
        XCTAssertTrue(check.matched, "retained post-checkpoint files must match the source before migration")
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
        XCTAssertFalse(retainedFiles.isEmpty)
    }

}
