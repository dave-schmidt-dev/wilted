import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    /// The row never left the store under the unified removal column, so
    /// restore needs no feed fetch and no re-matched evidence -- it commits
    /// the old target directly and clears the durable dismissal. (Until this
    /// task, dismissal deleted the row and restore had to re-fetch the known
    /// feed to reconstruct it; that path no longer exists.)
    func testKnownFeedRestoreReappearsInLarderAndClearsRemovedWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("restore-known-feed")
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/restore.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/old.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "old", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Restore Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "old", title: "Old episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-removed", itemID: targetID, requestID: WiltedMacModel.podcastRequestPrefix + targetID.rawValue,
            status: try PreparationStatus(
                stage: .assembling, detail: "Detector started", cancellable: true,
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010))
            )
        ))
        try await store.dismissPodcastEpisode(targetID)
        // No feed loader is wired up: a loader failing this test would prove
        // restore reached the network at all, which it must not.
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader(), now: { Date(timeIntervalSince1970: 1_700_000_100) }),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let removed = try XCTUnwrap(model.dismissedEpisodes.first)
        XCTAssertEqual(removed.title, "Old episode")
        XCTAssertEqual(removed.feedTitle, "Restore Show")
        XCTAssertTrue(removed.hasPreparationHistory, "Removed metadata must retain the link to its Prep run")
        model.withheldPodcastEpisodeCount = 7
        model.restoreEpisode(removed)
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        XCTAssertEqual(Set(model.episodes.map(\.title)), ["Old episode"])
        let restoredEpisode = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertNil(restoredEpisode.removalKind)
        XCTAssertEqual(model.podcastOperationMessage, "Restored Old episode to Feeds.")
        XCTAssertEqual(model.withheldPodcastEpisodeCount, 7, "restore must not replace the last full-refresh summary")
        let reopened = try LocalLibraryStore(url: libraryURL)
        let persistedDismissals = try await reopened.dismissedPodcastEpisodes()
        XCTAssertTrue(persistedDismissals.isEmpty)
        let removalKind = try await reopened.removalKind(for: targetID)
        XCTAssertNil(removalKind)
    }

    /// The reported bug (2026-09-05): skipping the Waveform episode, then
    /// restoring it in the same session, left the store saying "Restored X to
    /// Larder." while the row stayed off screen until relaunch. `removeEpisode`
    /// hides the row through `hiddenEpisodeIDs` immediately, ahead of the
    /// store round-trip that `restoreEpisode` waits on, and nothing cleared
    /// that id when the store confirmed the restore. The fixture above
    /// dismisses with `store.dismissPodcastEpisode` directly, which never
    /// populates the set and so never reproduces this; this one dismisses
    /// through the model, the way Skip actually does.
    func testRestoringAnEpisodeSkippedThisSessionReturnsItToTheLarder() async throws {
        let directory = temporaryDirectory("restore-same-session")
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertTrue(model.larderVisibleEpisodes.contains { $0.id == episode.id })

        model.removeEpisode(episode)
        try await settle(model)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episode.id },
                        "Skip must hide the row this session, not just once the store round-trip lands")

        let dismissal = try XCTUnwrap(model.dismissedEpisodes.first { $0.id == episode.id })
        model.restoreEpisode(dismissal)
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        XCTAssertTrue(model.larderVisibleEpisodes.contains { $0.id == episode.id },
                       "Restoring a same-session dismissal must clear the in-memory hide, not just the store record")
    }

    /// The reported bug (2026-09-05): an episode that had been prepared (ads
    /// removed, transcript aligned), then skipped and restored from the
    /// Removed list, came back with no media -- Download button showing,
    /// `downloadState` `.notDownloaded` -- while still reading "Ready · 3 ads
    /// removed (4:38) · transcript synced". `dismissPodcastEpisode` deleted
    /// the episode, queue, download, speed, and artwork rows but left the
    /// revision, transcript, and playback records behind, so `loadLibrary`
    /// found the surviving revision and transcript after restore and reported
    /// the old finished cut as ready. The fix deletes those three record kinds
    /// too, while keeping the preparation journal so the Removed list can
    /// still say a preparation happened.
    func testARestoredEpisodeDoesNotPresentItsOldFinishedCutAsReady() async throws {
        let directory = temporaryDirectory("restore-clears-old-cut")
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)

        let created = Timestamp(Date(timeIntervalSince1970: 1_600_000_500))
        let revision = try AudioRevision(
            itemID: targetID,
            revisionID: try RevisionID.derive(podcastDownloadedAudioItemID: targetID, contentHash: "sha256:\(String(repeating: "d", count: 64))"),
            durationSeconds: 278, byteCount: 4_096,
            contentHash: "sha256:\(String(repeating: "d", count: 64))", mediaType: "audio/mp4",
            createdAt: created, schemaVersion: 1
        )
        let mediaURL = directory.appendingPathComponent("wave.m4a")
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(
                episodeID: targetID, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: mediaURL, contentHash: revision.contentHash, updatedAt: created
            )
        )
        try await store.save(transcript: try Transcript(
            itemID: targetID, revisionID: revision.revisionID, availability: .available,
            text: "Aligned words.", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Aligned words.")],
            updatedAt: created
        ))
        let requestID = WiltedMacModel.podcastRequestPrefix + targetID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: targetID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Ready · 3 ads removed (4:38) · transcript synced",
                fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: created
            )
        ))

        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let prepared = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertEqual(prepared.downloadState, .completed)
        XCTAssertEqual(prepared.preparationState, .prepared(summary: "Ready · 3 ads removed (4:38) · transcript synced"))

        model.removeEpisode(prepared)
        try await settle(model)
        let dismissal = try XCTUnwrap(model.dismissedEpisodes.first { $0.id == prepared.id })
        XCTAssertTrue(dismissal.hasPreparationHistory, "the journal must survive so the Removed list can still say a preparation happened")

        model.restoreEpisode(dismissal)
        await model.waitForPodcastOperations()

        let restored = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertEqual(restored.downloadState, .notDownloaded)
        XCTAssertEqual(restored.preparationState, .notPrepared)
        XCTAssertNil(restored.preparationState.label)
    }

    /// The Undo button beside the removal message calls
    /// `restoreEpisode(model.undoableRemoval!)`. Undo must clear the record it
    /// used, so the button does not linger offering to restore an episode a
    /// second time, and must actually bring the episode back to the Larder.
    func testUndoingARemovalClearsTheRecordAndRestoresTheEpisode() async throws {
        let directory = temporaryDirectory("restore-same-session-undo")
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        model.removeEpisode(episode)
        try await settle(model)

        let undoable = try XCTUnwrap(model.undoableRemoval)
        XCTAssertEqual(undoable.id, episode.id)

        model.restoreEpisode(undoable)
        XCTAssertNil(model.undoableRemoval, "Undo must clear the record it just used")
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.larderVisibleEpisodes.contains { $0.id == episode.id },
                       "Undo must actually bring the episode back to the Larder")
    }

    /// A legacy or never-admitted dismissal -- an id with no episode row at
    /// all -- still sticks: the store backs it with a placeholder row rather
    /// than refusing it, the same guarantee the old separate tombstone table
    /// gave for free. Restoring it needs no feed and no network, because the
    /// row (placeholder or not) is what restore reads and clears; there is no
    /// re-fetch-and-match path left to tolerate a broken feed or a missing
    /// episode on.
    func testDismissingAnEpisodeWithNoRowStillCreatesADismissalAndRestoresWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("restore-feedless")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try ItemID(rawValue: "legacy-" + String(repeating: "1", count: 64))
        let created = try await store.dismissPodcastEpisode(episodeID)
        XCTAssertTrue(created, "a dismissal with no matching row must still stick")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.dismissedEpisodes.map(\.id), [episodeID.rawValue])
        let reopened = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let persisted = try await reopened.dismissedPodcastEpisodes()
        XCTAssertEqual(persisted.map(\.episodeID), [episodeID])

        model.restoreEpisode(try XCTUnwrap(model.dismissedEpisodes.first))
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        XCTAssertEqual(model.podcastOperationMessage, "Restored Removed podcast episode to Feeds.")
        let removalKind = try await reopened.removalKind(for: episodeID)
        XCTAssertNil(removalKind)
    }

    func testRetryForRemovedPrepRunPublishesActionableProcessorMessage() {
        let directory = temporaryDirectory("removed-prep-retry")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let run = WiltedMacProcessorRun(
            id: "removed-run", itemID: "removed-item", isPodcast: true, title: "Vanished episode",
            source: "Show", stage: "failed", detail: "Failed", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(run)
        XCTAssertEqual(
            model.processorOperationMessage,
            "Vanished episode is no longer in Feeds. Add it again before retrying preparation."
        )
        let message = model.processorOperationMessage ?? ""
        XCTAssertTrue(message.contains("Feeds"))
        XCTAssertFalse(message.contains("Removed"))
    }

}
