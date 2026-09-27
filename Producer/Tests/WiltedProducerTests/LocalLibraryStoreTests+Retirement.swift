import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testCompletedLarderEpisodeRetiresAndUndoRestoresOnlyThatRetirement() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: episode)
        let completedAt = Timestamp(Date(timeIntervalSince1970: 1_700_003_000))
        let listening = PodcastListeningState(
            episodeID: episode.itemID, completedAt: completedAt,
            lastRevisionID: nil, updatedAt: completedAt
        )

        let didCompleteAndRetire = try await store.completeAndRetireEpisode(listening: listening, at: completedAt)
        let completedListening = try await store.listeningState(for: episode.itemID)
        let completedRemovalKind = try await store.removalKind(for: episode.itemID)
        let completedRetiredAt = try await store.retiredAt(for: episode.itemID)
        XCTAssertTrue(didCompleteAndRetire)
        XCTAssertEqual(completedListening, listening)
        XCTAssertEqual(completedRemovalKind, .retired)
        XCTAssertEqual(completedRetiredAt, completedAt)

        let restoredAt = Timestamp(Date(timeIntervalSince1970: 1_700_003_100))
        let didUndo = try await store.undoCompletedAndRetiredEpisode(episode.itemID, updatedAt: restoredAt)
        let restoredRemovalKind = try await store.removalKind(for: episode.itemID)
        let restoredListening = try await store.listeningState(for: episode.itemID)
        XCTAssertTrue(didUndo)
        XCTAssertNil(restoredRemovalKind)
        XCTAssertNil(restoredListening?.completedAt)
        XCTAssertNil(restoredListening?.lastRevisionID)
        XCTAssertEqual(restoredListening?.updatedAt, restoredAt)

        let didRetireAgain = try await store.completeAndRetireEpisode(listening: listening, at: completedAt)
        let didDismiss = try await store.dismissPodcastEpisode(episode.itemID)
        let didUndoDismissal = try await store.undoCompletedAndRetiredEpisode(episode.itemID)
        let dismissedRemovalKind = try await store.removalKind(for: episode.itemID)
        let dismissedListening = try await store.listeningState(for: episode.itemID)
        XCTAssertTrue(didRetireAgain)
        XCTAssertTrue(didDismiss)
        XCTAssertFalse(didUndoDismissal)
        XCTAssertEqual(dismissedRemovalKind, .dismissed)
        XCTAssertNotNil(dismissedListening?.completedAt)
    }

    /// `retireCompletedEpisodesMissingRetirement()` is the bootstrap sweep that
    /// heals pre-Phase-5 data: a finished episode with no `retiredAt` gets one,
    /// but only when its listening fact matches the *current* ready revision --
    /// a dismissed-then-restored episode, or one whose listening fact predates
    /// a later re-download, must be left alone.
    func testRetireCompletedEpisodesMissingRetirementOnlyRetiresCurrentRevisionMatches() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)

        func makeEpisode(_ guid: String) throws -> (PodcastFeed, PodcastEpisode) {
            let feedURL = URL(string: "https://podcasts.example.test/retire-sweep/\(guid)/feed.xml")!
            let enclosureURL = URL(string: "https://podcasts.example.test/retire-sweep/\(guid).mp3")!
            let feedID = try ItemID.derivePodcastFeed(from: feedURL)
            let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: guid, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
            let episode = try PodcastEpisode(
                itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
            return (feed, episode)
        }

        // Episode A: completed listening matches the current ready revision,
        // no retiredAt yet -- the exact pre-Phase-5 stranded case. Must retire.
        let (feedA, episodeA) = try makeEpisode("matches-ready-revision")
        let revisionA = try podcastRevision(itemID: episodeA.itemID, id: "rev-retire-a", hashDigit: "a")
        try await store.save(feed: feedA)
        try await store.save(episode: episodeA)
        try await store.finalizePodcastDownload(
            revision: revisionA, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-a.m4a"),
            download: try completedPodcastDownload(episodeID: episodeA.itemID, revision: revisionA, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-a.m4a"))
        )
        try await store.saveListening(PodcastListeningState(
            episodeID: episodeA.itemID, completedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)),
            lastRevisionID: revisionA.revisionID, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        ))

        // Episode B: completed listening for a revision the episode no longer
        // has ready (superseded by a later re-download, or the ready revision
        // was cleared by a dismiss the episode row itself survived). Must not
        // retire sight unseen.
        let (feedB, episodeB) = try makeEpisode("stale-revision-mismatch")
        let revisionB = try podcastRevision(itemID: episodeB.itemID, id: "rev-retire-b-current", hashDigit: "b")
        try await store.save(feed: feedB)
        try await store.save(episode: episodeB)
        try await store.finalizePodcastDownload(
            revision: revisionB, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-b.m4a"),
            download: try completedPodcastDownload(episodeID: episodeB.itemID, revision: revisionB, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-b.m4a"))
        )
        try await store.saveListening(PodcastListeningState(
            episodeID: episodeB.itemID, completedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)),
            lastRevisionID: try RevisionID(rawValue: "rev-retire-b-superseded"),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        ))

        // Episode C: already retired -- the sweep must be a no-op, not an
        // overwrite of the original timestamp.
        let (feedC, episodeC) = try makeEpisode("already-retired")
        let revisionC = try podcastRevision(itemID: episodeC.itemID, id: "rev-retire-c", hashDigit: "c")
        try await store.save(feed: feedC)
        try await store.save(episode: episodeC)
        try await store.finalizePodcastDownload(
            revision: revisionC, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-c.m4a"),
            download: try completedPodcastDownload(episodeID: episodeC.itemID, revision: revisionC, mediaURL: URL(fileURLWithPath: "/tmp/retire-sweep-c.m4a"))
        )
        try await store.saveListening(PodcastListeningState(
            episodeID: episodeC.itemID, completedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)),
            lastRevisionID: revisionC.revisionID, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        ))
        let originalRetirement = Timestamp(Date(timeIntervalSince1970: 1_700_000_600))
        _ = try await store.retireEpisode(episodeC.itemID, at: originalRetirement)

        try await store.retireCompletedEpisodesMissingRetirement()

        let retiredAtA = try await store.retiredAt(for: episodeA.itemID)
        XCTAssertNotNil(retiredAtA, "a stranded completion matching the ready revision is retired")
        let retiredAtB = try await store.retiredAt(for: episodeB.itemID)
        XCTAssertNil(retiredAtB, "a completion for a superseded revision is left alone")
        let retiredAtC = try await store.retiredAt(for: episodeC.itemID)
        XCTAssertEqual(retiredAtC, originalRetirement, "an already-retired episode's timestamp is untouched")

        // Idempotent: a second call changes nothing further.
        try await store.retireCompletedEpisodesMissingRetirement()
        let retiredAtBAfterSecondSweep = try await store.retiredAt(for: episodeB.itemID)
        XCTAssertNil(retiredAtBAfterSecondSweep)
    }

    /// Legacy listening rows can lack `lastRevisionID`. They retire only when
    /// the current ready revision predates completion, retaining the prepared
    /// media and leaving a later re-download active.
    func testRetireCompletedEpisodesMissingRetirementHandlesNilRevisionIDOnlyWhenReadyRevisionPredatesCompletion() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)

        func makeEpisode(_ guid: String) throws -> (PodcastFeed, PodcastEpisode) {
            let feedURL = URL(string: "https://podcasts.example.test/retire-nil-revision/\(guid)/feed.xml")!
            let enclosureURL = URL(string: "https://podcasts.example.test/retire-nil-revision/\(guid).mp3")!
            let feedID = try ItemID.derivePodcastFeed(from: feedURL)
            let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: guid, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
            let episode = try PodcastEpisode(
                itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
            return (feed, episode)
        }

        let completedAt = Timestamp(Date(timeIntervalSince1970: 1_700_001_000))

        let (priorFeed, priorEpisode) = try makeEpisode("ready-before-completion")
        let priorRevision = try AudioRevision(
            itemID: priorEpisode.itemID, revisionID: RevisionID(rawValue: "rev-nil-before"), durationSeconds: 90,
            byteCount: 4_096, contentHash: "sha256:" + String(repeating: "e", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)), schemaVersion: 3
        )
        let priorMediaURL = URL(fileURLWithPath: "/tmp/retire-nil-before.m4a")
        try await store.save(feed: priorFeed)
        try await store.save(episode: priorEpisode)
        try await store.finalizePodcastDownload(
            revision: priorRevision, mediaURL: priorMediaURL,
            download: try completedPodcastDownload(episodeID: priorEpisode.itemID, revision: priorRevision, mediaURL: priorMediaURL)
        )
        try await store.saveListening(PodcastListeningState(
            episodeID: priorEpisode.itemID, completedAt: completedAt, lastRevisionID: nil, updatedAt: completedAt
        ))

        let (laterFeed, laterEpisode) = try makeEpisode("ready-after-completion")
        let laterRevision = try AudioRevision(
            itemID: laterEpisode.itemID, revisionID: RevisionID(rawValue: "rev-nil-after"), durationSeconds: 90,
            byteCount: 4_096, contentHash: "sha256:" + String(repeating: "f", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_001_001)), schemaVersion: 3
        )
        let laterMediaURL = URL(fileURLWithPath: "/tmp/retire-nil-after.m4a")
        try await store.save(feed: laterFeed)
        try await store.save(episode: laterEpisode)
        try await store.finalizePodcastDownload(
            revision: laterRevision, mediaURL: laterMediaURL,
            download: try completedPodcastDownload(episodeID: laterEpisode.itemID, revision: laterRevision, mediaURL: laterMediaURL)
        )
        try await store.saveListening(PodcastListeningState(
            episodeID: laterEpisode.itemID, completedAt: completedAt, lastRevisionID: nil, updatedAt: completedAt
        ))

        try await store.retireCompletedEpisodesMissingRetirement()

        let priorRemovalKind = try await store.removalKind(for: priorEpisode.itemID)
        let priorRetiredAt = try await store.retiredAt(for: priorEpisode.itemID)
        let priorReadyRevision = try await store.readyRevision(for: priorEpisode.itemID)
        let laterRemovalKind = try await store.removalKind(for: laterEpisode.itemID)
        let laterRetiredAt = try await store.retiredAt(for: laterEpisode.itemID)
        let laterReadyRevision = try await store.readyRevision(for: laterEpisode.itemID)
        XCTAssertEqual(priorRemovalKind, .retired)
        XCTAssertNotNil(priorRetiredAt)
        XCTAssertEqual(priorReadyRevision?.mediaURL, priorMediaURL,
                       "retirement keeps the prepared file available")
        XCTAssertNil(laterRemovalKind,
                     "a ready revision created after a legacy completion stays active")
        XCTAssertNil(laterRetiredAt)
        XCTAssertEqual(laterReadyRevision?.mediaURL, laterMediaURL)
    }

    /// Dismiss deletes the episode row but, since Phase 5, not the listening
    /// row -- so a restore re-inserts a fresh row with `retiredAt == nil`
    /// while the listening fact's `lastRevisionID` still points at the
    /// original download. A re-download is content-addressed, so it lands on
    /// that exact same revision ID; without clearing `lastRevisionID` on
    /// restore, the next bootstrap sweep would see a completed listening
    /// fact matching the current ready revision and silently re-retire the
    /// episode the user just asked to have back.
    func testRestoreSurvivesTheRetirementSweepAfterARedownloadOntoTheSameRevision() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let feedURL = URL(string: "https://podcasts.example.test/restore-sweep/feed.xml")!
        let enclosureURL = URL(string: "https://podcasts.example.test/restore-sweep/episode.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Restore Sweep",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let episode = try PodcastEpisode(
            itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "restore-sweep", enclosureURL: enclosureURL),
            feedID: feedID, feedURL: feedURL, rssGUID: "restore-sweep", title: "Restore Sweep",
            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let revision = try podcastRevision(itemID: episode.itemID, id: "rev-restore-sweep", hashDigit: "d")
        let mediaURL = URL(fileURLWithPath: "/tmp/restore-sweep.m4a")
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: episode)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: mediaURL)
        )
        let completedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        try await store.saveListening(PodcastListeningState(
            episodeID: episode.itemID, completedAt: completedAt,
            lastRevisionID: revision.revisionID, updatedAt: completedAt
        ))
        _ = try await store.retireEpisode(episode.itemID, at: Timestamp(Date(timeIntervalSince1970: 1_700_000_600)))

        try await store.dismissPodcastEpisode(episode.itemID, at: Timestamp(Date(timeIntervalSince1970: 1_700_000_700)))
        let restored = try await store.restoreEpisode(episode.itemID)
        XCTAssertTrue(restored)

        let listeningAfterRestore = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(listeningAfterRestore?.completedAt, completedAt, "restore keeps the listening history intact")
        XCTAssertNil(listeningAfterRestore?.lastRevisionID,
                      "clearing this defeats the sweep's exact-match guard until a fresh completion re-sets it")
        XCTAssertGreaterThan(try XCTUnwrap(listeningAfterRestore?.updatedAt), completedAt,
                             "restore refreshes the listening mutation timestamp")
        let retiredAtAfterRestore = try await store.retiredAt(for: episode.itemID)
        XCTAssertNil(retiredAtAfterRestore, "the re-inserted row starts active again")

        // A re-download is content-addressed and lands on the same revision.
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: mediaURL)
        )

        try await store.retireCompletedEpisodesMissingRetirement()
        let retiredAfterSweep = try await store.retiredAt(for: episode.itemID)
        XCTAssertNil(retiredAfterSweep, "the sweep must not silently undo a restore")
    }

}
