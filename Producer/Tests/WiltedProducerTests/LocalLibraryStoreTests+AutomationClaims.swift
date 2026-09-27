import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: - Automation claims

    /// Automation admits and claims in one save, and the claim is the download
    /// record rather than a table beside it.
    ///
    /// The cap takes the newest episodes because that is what a listener reaches
    /// for; feed parse order is not a preference.
    func testAutomaticAdmissionClaimsTheNewestNewEpisodesWithinTheCap() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/claims/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [5, 1, 4, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-30 * 86_400))
        ))

        let claimedAt = Timestamp(origin.addingTimeInterval(60))
        let first = try await store.admitPodcastEpisodes(all, admission: .incremental,
                                                          claimingNewest: 3, claimedAt: claimedAt)
        XCTAssertEqual(first.admission.newlyAdmitted.count, 5)
        let claimedGUIDs = try await store.podcastEpisodes(for: feed.itemID)
            .filter { first.claimed.contains($0.itemID) }
            .compactMap(\.rssGUID).sorted()
        XCTAssertEqual(claimedGUIDs, ["day-1", "day-2", "day-3"],
                       "the cap takes the newest three, not the first three the feed listed")

        let downloads = try await store.downloads()
        XCTAssertEqual(downloads.count, 3)
        XCTAssertTrue(downloads.allSatisfy { $0.status == .queued && $0.updatedAt == claimedAt })

        // Nothing is newly admitted the second time, so nothing is claimed. This
        // is the duplicate-suppression case: a repeated refresh must not enqueue
        // the same episodes again.
        let repeated = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 3)
        XCTAssertEqual(repeated.admission.newlyAdmitted, [])
        XCTAssertEqual(repeated.claimed, [])
        let afterRepeat = try await store.downloads()
        XCTAssertEqual(afterRepeat.count, 3)
    }

    /// Subscribing is not a request to download a back catalogue.
    ///
    /// The refusal lives in the store rather than only at the caller, so no
    /// later wiring can turn subscribe-time admission into a download queue by
    /// passing a limit.
    func testBackfillAdmissionClaimsNothingEvenWhenAskedTo() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/catalogue/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let subscribed = try await store.admitPodcastEpisodes(all, admission: .backfill, claimingNewest: 20)
        XCTAssertEqual(subscribed.admission.newlyAdmitted.count, 3, "the episodes are still admitted")
        XCTAssertEqual(subscribed.claimed, [])
        let downloads = try await store.downloads()
        XCTAssertTrue(downloads.isEmpty, "nothing is queued by subscribing")
        let unfinished = try await store.unfinishedPodcastDownloads()
        XCTAssertTrue(unfinished.isEmpty, "and a relaunch has nothing to reconcile")
    }

    /// A manual download already in flight owns the episode. Automation admits
    /// it and moves on to the next one rather than starting a second transfer.
    func testAutomaticAdmissionSkipsAnEpisodeSomethingElseAlreadyHolds() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/held/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let newest = try XCTUnwrap(all.first { $0.rssGUID == "day-1" })
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-30 * 86_400))
        ))
        try await store.save(download: PodcastDownload(episodeID: newest.itemID, status: .downloading,
                                                        bytesReceived: 512, updatedAt: Timestamp(origin)))

        let result = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 2)
        XCTAssertTrue(result.admission.newlyAdmitted.contains(newest.itemID),
                      "the episode is still admitted; only the claim is declined")
        XCTAssertFalse(result.claimed.contains(newest.itemID))
        let claimedGUIDs = try await store.podcastEpisodes(for: feed.itemID)
            .filter { result.claimed.contains($0.itemID) }
            .compactMap(\.rssGUID).sorted()
        XCTAssertEqual(claimedGUIDs, ["day-2", "day-3"])
        let held = try await store.download(for: newest.itemID)
        XCTAssertEqual(held?.status, .downloading, "the transfer in flight keeps its own state")
        XCTAssertEqual(held?.bytesReceived, 512)
    }

    /// A claim outlives the process that made it, and a relaunch finds it
    /// through the store rather than through anything automation kept.
    func testClaimsAndTheirAdmissionSurviveRelaunchTogether() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/recovery/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        var store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-30 * 86_400))
        ))
        let admitted = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 2)
        XCTAssertEqual(admitted.claimed.count, 2)

        store = try LocalLibraryStore(url: url)
        let unfinished = try await store.unfinishedPodcastDownloads()
        let recovered = try await store.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(Set(unfinished.map(\.episodeID)), Set(admitted.claimed))
        XCTAssertEqual(recovered.count, 3,
                       "the episodes the claims refer to are durable in the same save")

        // A finished claim is not resumable work. Reconciliation must not pick
        // it up again on every launch.
        let settled = try XCTUnwrap(admitted.claimed.first)
        try await store.save(download: PodcastDownload(episodeID: settled, status: .cancelled,
                                                        updatedAt: Timestamp(origin)))
        let stillUnfinished = try await store.unfinishedPodcastDownloads()
        XCTAssertEqual(stillUnfinished.map(\.episodeID), admitted.claimed.filter { $0 != settled })
    }

    /// `resumablePodcastDownloads()` is the relaunch-retry set: a real transfer
    /// failure classified `.retryable`. It must not overlap with
    /// `unfinishedPodcastDownloads()` (still in flight when the process died)
    /// or with a `.terminal` failure (needs the user, not another attempt).
    func testResumablePodcastDownloadsReturnsOnlyRetryableFailures() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/resumable/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3, 4, 5, 6])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        _ = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 6)

        let queued = all[0].itemID
        let downloading = all[1].itemID
        let completed = all[2].itemID
        let cancelled = all[3].itemID
        let retryableFailure = all[4].itemID
        let terminalFailure = all[5].itemID

        try await store.save(download: PodcastDownload(episodeID: queued, status: .queued, updatedAt: Timestamp(origin)))
        try await store.save(download: PodcastDownload(episodeID: downloading, status: .downloading,
                                                        bytesReceived: 10, updatedAt: Timestamp(origin)))
        try await store.save(download: try PodcastDownload(
            episodeID: completed, status: .completed, bytesReceived: 1,
            localURL: URL(fileURLWithPath: "/tmp/resumable-completed.mp3"),
            contentHash: "sha256:" + String(repeating: "1", count: 64), updatedAt: Timestamp(origin)
        ))
        try await store.save(download: PodcastDownload(episodeID: cancelled, status: .cancelled, updatedAt: Timestamp(origin)))
        try await store.save(download: PodcastDownload(episodeID: retryableFailure, status: .failed,
                                                        updatedAt: Timestamp(origin), failureKind: .retryable))
        try await store.save(download: PodcastDownload(episodeID: terminalFailure, status: .failed,
                                                        updatedAt: Timestamp(origin), failureKind: .terminal))

        let resumable = try await store.resumablePodcastDownloads()
        XCTAssertEqual(resumable.map(\.episodeID), [retryableFailure])
    }

    /// Manual and automatic entry points race for the same episode. Exactly one
    /// wins, and the loser is told rather than left to start a second transfer.
    func testOnlyTheFirstClaimOnAnEpisodeWins() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let episodeID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let store = try LocalLibraryStore(url: url)

        let won = try await store.claimPodcastDownload(episodeID: episodeID, at: Timestamp(origin))
        let lost = try await store.claimPodcastDownload(episodeID: episodeID, at: Timestamp(origin.addingTimeInterval(1)))
        XCTAssertTrue(won)
        XCTAssertFalse(lost, "the second caller must not overwrite the first claim")
        let downloads = try await store.downloads()
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.first?.updatedAt, Timestamp(origin), "the first claim stands unchanged")

        // A settled download still blocks automation: retrying it is the
        // listener's call, not something a later launch resumes on its own.
        try await store.save(download: PodcastDownload(episodeID: episodeID, status: .failed,
                                                        updatedAt: Timestamp(origin)))
        let automationAfterSettled = try await store.claimPodcastDownload(episodeID: episodeID)
        XCTAssertFalse(automationAfterSettled)

        // The row's own Retry is deliberate, so it takes the episode back and
        // starts from zero rather than inheriting the failed transfer's bytes.
        let retry = try await store.claimPodcastDownload(
            episodeID: episodeID, scope: .notInFlight, at: Timestamp(origin.addingTimeInterval(9))
        )
        XCTAssertTrue(retry)
        let reclaimed = try await store.download(for: episodeID)
        XCTAssertEqual(reclaimed?.status, .queued)
        XCTAssertEqual(reclaimed?.bytesReceived, 0)

        // A transfer in flight blocks even a deliberate request, which is the
        // case that would otherwise download one episode twice.
        let duringFlight = try await store.claimPodcastDownload(episodeID: episodeID, scope: .notInFlight)
        XCTAssertFalse(duringFlight)
    }

    /// The manual download policy admits exactly as it does today and enqueues
    /// nothing, so turning automation off cannot start a transfer.
    func testALimitOfZeroAdmitsWithoutClaimingAnything() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/manual/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-30 * 86_400))
        ))

        let manual = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 0)
        let equivalent = try await store.savePodcastEpisodes([], admission: .incremental)
        XCTAssertEqual(manual.admission.newlyAdmitted.count, 2)
        XCTAssertEqual(manual.claimed, [])
        XCTAssertEqual(equivalent.newlyAdmitted, [])
        let noDownloads = try await store.downloads()
        let noClaims = try await store.unfinishedPodcastDownloads()
        XCTAssertTrue(noDownloads.isEmpty)
        XCTAssertTrue(noClaims.isEmpty)
    }

    /// Searching transcripts must read the audio the reader can actually play.
    ///
    /// A re-prepared episode keeps the transcript of the revision it replaced,
    /// and that superseded text still contains the advertising the cut removed.
    /// Matching it would offer an episode whose transcript no longer holds the
    /// searched words -- indistinguishable, from the reader's side, from the
    /// search being broken.
}
