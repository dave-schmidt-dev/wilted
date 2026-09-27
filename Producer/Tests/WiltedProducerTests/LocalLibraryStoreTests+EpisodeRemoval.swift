import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: - Episode removal

    /// The bug this covers: removing an episode used to hide it in memory only,
    /// so the next refresh -- which re-reads the same feed -- put it straight
    /// back, and so did the next launch. Dismissal now keeps the row (carrying
    /// a removal state) rather than deleting it, but the guarantee this test
    /// exists to prove is the same one: a refresh must never silently
    /// re-admit a dismissed episode, and the dismissal must survive relaunch.
    func testDismissedEpisodeKeepsItsRowAndIsNeverReadmittedByRefresh() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/dismiss/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let unwanted = all.first { $0.rssGUID == "day-2" }!

        let deleted = try await store.dismissPodcastEpisode(unwanted.itemID, at: Timestamp(origin))
        XCTAssertTrue(deleted)
        var stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-2", "day-3"], "the row survives, carrying a dismissed state")
        var kind = try await store.removalKind(for: unwanted.itemID)
        XCTAssertEqual(kind, .dismissed)

        // The feed still lists it, which used to be the whole problem: a
        // refresh must not treat the dismissed row as missing and re-admit it.
        let refreshed = try await store.savePodcastEpisodes(all, admission: .incremental)
        XCTAssertFalse(refreshed.saved.contains(unwanted.itemID))
        XCTAssertEqual(refreshed.skipped, 1)
        stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-2", "day-3"], "no duplicate row from the refresh")
        kind = try await store.removalKind(for: unwanted.itemID)
        XCTAssertEqual(kind, .dismissed)

        // And it survives the process, because it is a row rather than an
        // in-memory set.
        let reopened = try LocalLibraryStore(url: url)
        try await reopened.savePodcastEpisodes(all, admission: .incremental)
        stored = try await reopened.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-2", "day-3"])
        let log = try await reopened.dismissedPodcastEpisodes()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.episodeID, unwanted.itemID)
        XCTAssertEqual(log.first?.feedID, feed.itemID)
        XCTAssertEqual(log.first?.title, "day-2")
        XCTAssertEqual(log.first?.dismissedAt, Timestamp(origin))
    }

    /// Removing twice must not throw, must not duplicate the log, and must not
    /// move the timestamp: the second call is a listener clicking again.
    func testDismissingAnEpisodeTwiceIsIdempotent() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/idempotent/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)

        let first = try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin))
        let second = try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin.addingTimeInterval(60)))
        XCTAssertTrue(first)
        XCTAssertFalse(second, "the row was already gone, so there is nothing left to delete")
        let log = try await store.dismissedPodcastEpisodes()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.dismissedAt, Timestamp(origin), "the first removal is when it happened")
    }

    /// Removal takes the queue entry, the download record, the saved speed, and
    /// the artwork with it -- otherwise Up Next keeps an episode the Larder no
    /// longer has.
    func testDismissingAnEpisodeClearsTheRecordsHangingOffIt() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/cascade/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let doomed = all[0], kept = all[1]
        try await store.addPodcastQueueEpisode(doomed.itemID)
        try await store.addPodcastQueueEpisode(kept.itemID)

        try await store.dismissPodcastEpisode(doomed.itemID, at: Timestamp(origin))
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [kept.itemID.rawValue],
                       "Up Next must not hold an episode the Larder removed")
    }

    /// The bug this covers: dismissing a prepared episode deleted its download
    /// and queue rows but left the revision, transcript, and playback records
    /// behind. Restoring it later found the surviving revision and transcript
    /// and showed the old finished cut as ready, with no media to back it.
    func testDismissingAPreparedEpisodeClearsItsRevisionTranscriptAndPlayback() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/prepared-dismiss/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let doomed = all[0], kept = all[1]

        let revision = try AudioRevision(
            itemID: doomed.itemID, revisionID: RevisionID(rawValue: "rev-doomed"), durationSeconds: 278, byteCount: 4_096,
            contentHash: "sha256:\(String(repeating: "b", count: 64))", mediaType: "audio/mp4",
            createdAt: Timestamp(origin), schemaVersion: 1
        )
        let transcript = try Transcript(
            itemID: doomed.itemID, revisionID: revision.revisionID, availability: .available,
            text: "Aligned transcript text.", languageCode: "en", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 5, text: "Hello.")],
            updatedAt: Timestamp(origin)
        )
        try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/doomed.m4a"), transcript: transcript)

        let keptRevision = try AudioRevision(
            itemID: kept.itemID, revisionID: RevisionID(rawValue: "rev-kept"), durationSeconds: 200, byteCount: 2_048,
            contentHash: "sha256:\(String(repeating: "c", count: 64))", mediaType: "audio/mp4",
            createdAt: Timestamp(origin), schemaVersion: 1
        )
        try await store.saveReadyRevision(keptRevision, mediaURL: URL(fileURLWithPath: "/tmp/kept.m4a"))

        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-doomed", itemID: doomed.itemID, requestID: "request-doomed",
            status: try PreparationStatus(
                stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: Timestamp(origin)
            )
        ))
        try await store.save(playback: try PlaybackState(
            itemID: doomed.itemID, revisionID: revision.revisionID, sessionID: "session-1", sequence: 1,
            positionSeconds: 30, durationSeconds: revision.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-mac", updatedAt: Timestamp(origin)
        ))

        try await store.dismissPodcastEpisode(doomed.itemID, at: Timestamp(origin))

        let readyAfter = try await store.readyRevision(for: doomed.itemID)
        XCTAssertNil(readyAfter, "the revision must not survive dismissal")
        let revisionsAfter = try await store.revisions(for: doomed.itemID)
        XCTAssertTrue(revisionsAfter.isEmpty)
        let transcriptAfter = try await store.transcript(for: doomed.itemID, revisionID: revision.revisionID)
        XCTAssertNil(transcriptAfter)
        let playbackAfter = try await store.playbackState(for: doomed.itemID, revisionID: revision.revisionID)
        XCTAssertNil(playbackAfter)
        let runs = try await store.preparationRuns()
        XCTAssertTrue(runs.contains { $0.requestID == "request-doomed" },
                      "the preparation journal survives, so the Removed list can still say a preparation happened")

        // The sibling episode's revision is untouched.
        let keptReady = try await store.readyRevision(for: kept.itemID)
        XCTAssertEqual(keptReady?.revision.revisionID, keptRevision.revisionID)
    }

    /// Unsubscribing must clear every prepared episode's derived records, or a
    /// later resubscribe can show a cut whose source subscription no longer
    /// exists. Preparation journals and local media deliberately survive: they
    /// record history and may be shared by another revision identity.
    func testUnsubscribingPreparedEpisodesDoesNotResurrectTheirDerivedState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/prepared-unsubscribe/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)

        var prepared: [(episode: PodcastEpisode, revision: AudioRevision, mediaURL: URL)] = []
        for (index, episode) in all.enumerated() {
            let revision = try AudioRevision(
                itemID: episode.itemID, revisionID: RevisionID(rawValue: "rev-unsubscribe-\(index)"),
                durationSeconds: 180, byteCount: 4_096,
                contentHash: "sha256:\(String(repeating: String(index), count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(origin), schemaVersion: 1
            )
            let transcript = try Transcript(
                itemID: episode.itemID, revisionID: revision.revisionID, availability: .available,
                text: "Prepared transcript \(index).", updatedAt: Timestamp(origin)
            )
            let mediaURL = url.deletingLastPathComponent().appendingPathComponent("unsubscribe-\(index).m4a")
            try Data([UInt8(index)]).write(to: mediaURL)
            try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript)
            try await store.save(playback: try PlaybackState(
                itemID: episode.itemID, revisionID: revision.revisionID, sessionID: "session-\(index)", sequence: 1,
                positionSeconds: 30, durationSeconds: revision.durationSeconds, completed: false, intent: .progress,
                deviceID: "device-mac", updatedAt: Timestamp(origin)
            ))
            try await store.record(preparation: PreparationJournalEntry(
                id: "prep-unsubscribe-\(index)", itemID: episode.itemID, requestID: "request-unsubscribe-\(index)",
                status: try PreparationStatus(
                    stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                    terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                    emittedAt: Timestamp(origin)
                )
            ))
            prepared.append((episode, revision, mediaURL))
        }

        let removedCount = try await store.unsubscribeFromPodcast(feedID: feed.itemID)
        XCTAssertEqual(removedCount, all.count)
        for entry in prepared {
            let ready = try await store.readyRevision(for: entry.episode.itemID)
            let revisions = try await store.revisions(for: entry.episode.itemID)
            let transcript = try await store.transcript(for: entry.episode.itemID, revisionID: entry.revision.revisionID)
            let playback = try await store.playbackState(for: entry.episode.itemID, revisionID: entry.revision.revisionID)
            XCTAssertNil(ready)
            XCTAssertTrue(revisions.isEmpty)
            XCTAssertNil(transcript)
            XCTAssertNil(playback)
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.mediaURL.path), "media reclamation is not part of unsubscribe")
        }
        let preparationRuns = try await store.preparationRuns()
        XCTAssertEqual(preparationRuns.count, all.count, "preparation history survives unsubscribe")

        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        for entry in prepared {
            let ready = try await store.readyRevision(for: entry.episode.itemID)
            let transcript = try await store.transcript(for: entry.episode.itemID, revisionID: entry.revision.revisionID)
            let playback = try await store.playbackState(for: entry.episode.itemID, revisionID: entry.revision.revisionID)
            XCTAssertNil(ready, "resubscribing must not revive a stale revision")
            XCTAssertNil(transcript)
            XCTAssertNil(playback)
        }
    }

    /// Unsubscribing forgets the feed's dismissals too, so resubscribing does
    /// not inherit an invisible blocklist.
    func testUnsubscribingForgetsTheFeedsDismissals() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/forget/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin))

        try await store.unsubscribeFromPodcast(feedID: feed.itemID)
        let remaining = try await store.dismissedPodcastEpisodes()
        XCTAssertTrue(remaining.isEmpty)

        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-2"], "resubscribing starts from the feed, not from the old blocklist")
    }

    /// A dismissed episode keeps its row rather than being deleted, so
    /// restoring it needs nothing from a feed -- the store already has
    /// everything the row remembered. A normal admission afterwards
    /// (unrelated to the restore itself) still reaches a genuinely new
    /// sibling entry.
    func testDismissKeepsTheRowAndRestoreNeedsNoFeedEvidence() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/restore/feed.xml")!
        let (feed, oldEntries) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [500])
        let target = try XCTUnwrap(oldEntries.first)
        let newEnclosure = URL(string: "https://podcasts.example.test/restore/new.mp3")!
        let newEpisode = try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "new-entry", enclosureURL: newEnclosure
            ),
            feedID: feed.itemID, feedURL: feedURL, rssGUID: "new-entry", title: "New entry",
            publishedTime: Timestamp(origin.addingTimeInterval(60)), enclosureURL: newEnclosure,
            enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin.addingTimeInterval(60))
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin)
        ))
        try await store.save(episode: target)
        try await store.dismissPodcastEpisode(target.itemID, at: Timestamp(origin))

        // Still present, carrying the dismissed state, and excluded from the
        // feed-facing episode list while dismissed.
        let dismissedList = try await store.dismissedPodcastEpisodes()
        XCTAssertEqual(dismissedList.map(\.episodeID), [target.itemID])
        let whileDismissed = try await store.podcastEpisodes(for: feed.itemID)
        XCTAssertTrue(whileDismissed.contains { $0.itemID == target.itemID },
                      "the row survives; only its removal state hides it from the active list")

        let restored = try await store.restoreEpisode(target.itemID)
        XCTAssertTrue(restored)
        let dismissalsAfterRestore = try await store.dismissedPodcastEpisodes()
        XCTAssertTrue(dismissalsAfterRestore.isEmpty)
        let removalKindAfterRestore = try await store.removalKind(for: target.itemID)
        XCTAssertNil(removalKindAfterRestore)

        // Unrelated to the restore: a normal incremental admission still
        // reaches a genuinely new sibling entry from the same feed.
        try await store.savePodcastEpisodes([target, newEpisode], admission: .incremental)
        let stored = try await store.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(Set(stored.compactMap(\.rssGUID)), ["day-500", "new-entry"])
    }

    /// A feed refresh offering the same episode again must not re-admit a
    /// dismissed one back into view, and the dismissal survives a relaunch.
    func testFeedRefreshDoesNotReadmitADismissedEpisodeAndDismissalSurvivesRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/restore-miss/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let target = all[0]
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        try await store.dismissPodcastEpisode(target.itemID, at: Timestamp(origin))

        // The feed still lists both entries on its next refresh.
        try await store.savePodcastEpisodes(all, admission: .incremental)
        let afterRefresh = try await store.podcastEpisodes(for: feed.itemID)
            .filter { $0.itemID == target.itemID }
        XCTAssertEqual(afterRefresh.count, 1, "no duplicate row from the refresh")
        let kindAfterRefresh = try await store.removalKind(for: target.itemID)
        XCTAssertEqual(kindAfterRefresh, .dismissed, "the refresh must not clear the dismissal")

        let reopened = try LocalLibraryStore(url: url)
        let dismissals = try await reopened.dismissedPodcastEpisodes()
        XCTAssertEqual(dismissals.map(\.episodeID), [target.itemID])
    }

}
