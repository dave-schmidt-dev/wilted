import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: - Feed management

    /// Builds a store-backed model whose library already holds `feeds`, each
    /// with one episode, so the Feeds card has something to manage.
    private func modelWithFeeds(
        _ titles: [String], directory: URL
    ) async throws -> (WiltedMacModel, [String: ItemID]) {
        var ids: [String: ItemID] = [:]
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                for title in titles {
                    let feedURL = URL(string: "https://feeds.example.test/\(title.lowercased()).xml")!
                    let enclosureURL = URL(string: "https://media.example.test/\(title.lowercased()).mp3")!
                    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
                    let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: title,
                                               createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
                    let episode = try PodcastEpisode(
                        itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: title, enclosureURL: enclosureURL),
                        feedID: feedID, feedURL: feedURL, rssGUID: title, title: "\(title) episode",
                        publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                        enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                        createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                    )
                    try await store.save(feed: feed)
                    try await store.save(episode: episode)
                    try await store.save(subscription: PodcastSubscription(
                        feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                    ))
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        for title in titles {
            let feedURL = URL(string: "https://feeds.example.test/\(title.lowercased()).xml")!
            ids[title] = try ItemID.derivePodcastFeed(from: feedURL)
        }
        return (model, ids)
    }

    /// The Feeds card was the reported gap: subscriptions existed in the store
    /// with no way to see or manage them. The model has to surface every one.
    func testEveryStoredSubscriptionAppearsInTheFeedsList() async throws {
        let directory = temporaryDirectory("feeds-list")

        let (model, _) = try await modelWithFeeds(["Beta", "Alpha"], directory: directory)

        XCTAssertEqual(model.subscriptions.map(\.title), ["Alpha", "Beta"], "feeds list by title")
        XCTAssertEqual(model.subscriptions.map(\.episodeCount), [1, 1])
        XCTAssertTrue(model.subscriptions.allSatisfy(\.enabled))
    }

    func testRefreshingARedirectedSubscriptionDoesNotReadOldEpisodesAsNew() async throws {
        let directory = temporaryDirectory("redirected-feed-refresh")

        let subscribedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/subscribed/feed.xml"))
        let finalURL = try XCTUnwrap(URL(string: "https://cdn.example.test/moved/feed.xml"))
        let feed = """
        <rss><channel><title>Moved show</title><item><title>Stable episode</title><guid>stable</guid>
        <enclosure url="https://cdn.example.test/stable.mp3" type="audio/mpeg" /></item></channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: RedirectingBodyLoader(body: Data(feed.utf8), finalURL: finalURL),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = subscribedURL.absoluteString
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.count, 1)
        XCTAssertEqual(model.episodes.count, 1)

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.lastPodcastRefreshNewEpisodeIDs, [])
        XCTAssertEqual(model.episodes.count, 1)
        XCTAssertEqual(model.podcastOperationMessage, "Podcast episodes are up to date.")
    }

    /// Disabling a feed hides its episodes from Larder but must not discard
    /// them: re-enabling has to bring the same episodes back.
    func testDisablingAFeedHidesItsEpisodesWithoutDiscardingThem() async throws {
        let directory = temporaryDirectory("feeds-disable")

        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })

        model.setSubscription(alpha, enabled: false)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.subscriptions.first { $0.title == "Alpha" }?.enabled, false)
        XCTAssertEqual(model.subscriptions.first { $0.title == "Alpha" }?.episodeCount, 1,
                       "a hidden feed still keeps its episodes")

        let hidden = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })
        model.setSubscription(hidden, enabled: true)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle).sorted(), ["Alpha", "Beta"])
    }

    /// Unsubscribing removes the feed and its episodes and leaves the rest of
    /// the library alone.
    func testUnsubscribingRemovesOnlyThatFeed() async throws {
        let directory = temporaryDirectory("feeds-unsubscribe")

        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })

        let removed = try await model.commitUnsubscribe(alpha)
        try await settle(model)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Beta"])
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
    }

    /// The reported bug: episodes removed from the Larder came back. Removal
    /// was an in-memory set, so it lasted exactly as long as the process, and
    /// the store kept re-admitting the identity on every refresh.
    func testRemovingAnEpisodeOutlivesTheProcess() async throws {
        let directory = temporaryDirectory("episode-remove")

        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let unwanted = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })

        model.removeEpisode(unwanted)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(unwanted.title).")

        let relaunched = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data()),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await settle(relaunched)
        XCTAssertEqual(relaunched.episodes.map(\.feedTitle), ["Beta"],
                       "a removal that only lives in memory reappears here")
    }

    /// The Undo button beside the removal message needs the removed episode's
    /// identity to restore it. `removeEpisode` must record that identity once
    /// the store confirms the dismissal, not just the optimistic hide.
    func testRemovingAnEpisodeRecordsItForUndo() async throws {
        let directory = temporaryDirectory("episode-remove-undo")

        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let unwanted = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })

        model.removeEpisode(unwanted)
        try await settle(model)

        XCTAssertEqual(model.undoableRemoval?.id, unwanted.id)
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(unwanted.title).")
    }

    /// A second removal must replace the first's undo record: only the most
    /// recent removal is one keystroke away from being undone.
    func testASecondRemovalReplacesTheFirstsUndoRecord() async throws {
        let directory = temporaryDirectory("episode-remove-undo-replace")

        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let first = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })
        let second = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Beta" })

        model.removeEpisode(first)
        try await settle(model)
        XCTAssertEqual(model.undoableRemoval?.id, first.id)

        model.removeEpisode(second)
        try await settle(model)
        XCTAssertEqual(model.undoableRemoval?.id, second.id,
                        "the newer removal must own the undo record, not the older one")
    }

    /// The manage actions run detached tasks, so a test has to let the
    /// MainActor drain before reading the result.
    func settle(_ model: WiltedMacModel, iterations: Int = 40) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testStartupSurfacesHaveDistinctAccessibilityIdentifiers() {
        XCTAssertEqual(WiltedMacStartupAccessibility.loading, "wilted-mac-startup-loading")
        XCTAssertEqual(WiltedMacStartupAccessibility.recovery, "wilted-mac-startup-recovery")
        XCTAssertNotEqual(WiltedMacStartupAccessibility.loading, WiltedMacStartupAccessibility.recovery)
    }

    func temporaryDirectory(_ suffix: String) -> URL {
        wiltedTemporaryDirectory(suffix)
    }

    /// Builds one downloaded, transcript-ready podcast episode -- the
    /// minimum a row needs to qualify as "ready" for continuous playback.
    static func addReadyEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, directory: URL, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
        let audioURL = directory.appendingPathComponent("\(guid).m4a")
        // Keep this well beyond the test's own scheduling window. A one-second
        // file can genuinely finish under a loaded full-suite run before the
        // deterministic completion seam below is asked to fire.
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * 10)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
            itemID: episodeID, destinationURL: audioURL
        )
        // `AudioAssembler` derives its revision from the audio's content hash
        // alone, which is right for synthesis and wrong here: every fixture
        // episode is assembled from the same samples, so they would all land on
        // one immutable revision and the second download could not finalize.
        // A downloaded podcast revision is keyed on the episode as well, which
        // is what production stores.
        let revision = try AudioRevision(
            itemID: episodeID,
            revisionID: try RevisionID.derive(
                podcastDownloadedAudioItemID: episodeID, contentHash: assembled.revision.contentHash
            ),
            durationSeconds: assembled.revision.durationSeconds,
            byteCount: assembled.revision.byteCount,
            contentHash: assembled.revision.contentHash,
            mediaType: assembled.revision.mediaType,
            createdAt: created,
            schemaVersion: assembled.revision.schemaVersion
        )
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: audioURL, contentHash: revision.contentHash, updatedAt: created
            )
        )
        try await store.save(transcript: try Transcript(
            itemID: episodeID, revisionID: revision.revisionID,
            availability: .available, text: "Line.", timing: .published,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "Line.")],
            updatedAt: created
        ))
        let requestID = WiltedMacModel.podcastRequestPrefix + episodeID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Ready · transcript synced from the feed", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: created
            )
        ))
    }

    /// Adds an episode with no download at all, so it can never qualify as
    /// ready for continuous playback to pick up.
    static func addUndownloadedEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
    }

    /// Adds a downloaded episode with no preparation outcome, so it has
    /// `downloadState == .completed` but `preparationState == .notPrepared`.
    static func addDownloadedUnpreparedEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, directory: URL, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
        let audioURL = directory.appendingPathComponent("\(guid).m4a")
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * 10)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
            itemID: episodeID, destinationURL: audioURL
        )
        let revision = try AudioRevision(
            itemID: episodeID,
            revisionID: try RevisionID.derive(
                podcastDownloadedAudioItemID: episodeID, contentHash: assembled.revision.contentHash
            ),
            durationSeconds: assembled.revision.durationSeconds,
            byteCount: assembled.revision.byteCount,
            contentHash: assembled.revision.contentHash,
            mediaType: assembled.revision.mediaType,
            createdAt: created,
            schemaVersion: assembled.revision.schemaVersion
        )
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: audioURL, contentHash: revision.contentHash, updatedAt: created
            )
        )
    }

}
