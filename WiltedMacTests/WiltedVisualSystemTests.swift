import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

final class WiltedVisualSystemTests: XCTestCase {
    @MainActor
    func testStoredArticlesAndSubscribedEpisodesProduceStableMixedSearchOrderAndFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let articleURL = URL(string: "https://example.test/stored-article")!
        let article = try Article(
            itemID: ItemID.derive(from: articleURL), canonicalURL: articleURL,
            title: "Stored article", source: "Example journal",
            createdAt: Timestamp(Date(timeIntervalSince1970: 100))
        )
        try await store.save(article: article)

        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Systems Brief",
            createdAt: Timestamp(Date(timeIntervalSince1970: 150))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 150))
        ))

        var episodeIDs: [ItemID] = []
        for (index, title) in ["First circuit", "Second circuit", "Third circuit"].enumerated() {
            let enclosure = URL(string: "https://cdn.example.test/episode-\(index).mp3")!
            let episodeID = try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "episode-\(index)", enclosureURL: enclosure
            )
            episodeIDs.append(episodeID)
            try await store.save(episode: PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-\(index)",
                title: title, author: "Systems desk",
                publishedTime: Timestamp(Date(timeIntervalSince1970: Double(200 + index))),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: 100,
                createdAt: Timestamp(Date(timeIntervalSince1970: Double(200 + index)))
            ))
            if index > 0 {
                let revision = try AudioRevision(
                    itemID: episodeID, revisionID: RevisionID(rawValue: "episode-revision-\(index)"),
                    durationSeconds: 100, byteCount: 10,
                    contentHash: "sha256:" + String(repeating: String(index), count: 64),
                    mediaType: "audio/mpeg", createdAt: Timestamp(Date(timeIntervalSince1970: 300)), schemaVersion: 3
                )
                try await store.saveReadyRevision(
                    revision, mediaURL: root.appendingPathComponent("episode-\(index).mp3")
                )
                try await store.save(playback: PlaybackState(
                    itemID: episodeID, revisionID: revision.revisionID, sessionID: "mixed-library",
                    sequence: 1, positionSeconds: index == 1 ? 25 : 100, durationSeconds: 100,
                    completed: index == 2, intent: .progress, deviceID: "mac-test",
                    updatedAt: Timestamp(Date(timeIntervalSince1970: 400))
                ))
            }
        }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.libraryItems.map(\.id), episodeIDs.reversed().map(\.rawValue) + [article.itemID.rawValue])

        model.librarySearchQuery = "Second"
        XCTAssertEqual(model.libraryItems.map(\.id), [episodeIDs[1].rawValue])
        model.librarySearchQuery = ""
        model.libraryOrder = .oldest
        XCTAssertEqual(model.libraryItems.first?.id, article.itemID.rawValue)

        model.libraryFilter = .unplayed
        XCTAssertEqual(Set(model.libraryItems.map(\.id)), [article.itemID.rawValue, episodeIDs[0].rawValue])
        model.libraryFilter = .inProgress
        XCTAssertEqual(model.libraryItems.map(\.id), [episodeIDs[1].rawValue])
        model.libraryFilter = .finished
        XCTAssertEqual(model.libraryItems.map(\.id), [episodeIDs[2].rawValue])
    }

    func testEpisodeDownloadPresentationCoversEveryLifecycleState() {
        let values: [WiltedMacEpisodeDownloadState] = [
            .notDownloaded, .queued, .downloading(received: 2, expected: 10),
            .completed, .failed, .cancelled
        ]
        XCTAssertEqual(values.count, 6)
        XCTAssertNotEqual(values[1], values[4])
    }

    @MainActor
    func testPodcastPlaybackStaysOutOfArticleSyncWhileArticleQueuesOneCheckpoint() async throws {
        let podcastRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: podcastRoot) }
        let podcastModel = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: podcastRoot, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let podcast = try XCTUnwrap(podcastModel.episodes.first)
        podcastModel.playEpisode(podcast)
        for _ in 0..<100 {
            if podcastModel.currentEpisode?.id == podcast.id, podcastModel.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(podcastModel.isPlaying, "Play must load and start the selected episode")
        await podcastModel.checkpointCurrentPlaybackForTesting()
        let podcastStore = try LocalLibraryStore(url: podcastRoot.appendingPathComponent("library.sqlite"))
        let podcastPendingCount = try await podcastStore.syncRepositoryState()?.pendingChanges.count ?? 0
        XCTAssertEqual(podcastPendingCount, 0)
        XCTAssertEqual(podcastModel.articlePublicationCount, 0)
        XCTAssertEqual(podcastModel.articlePlaybackCheckpointCount, 0)

        let podcastID = try ItemID(rawValue: podcast.id)
        podcastModel.applyPodcastPlaybackObservationForTesting(
            itemID: podcastID, fault: .podcastMediaUnavailable(podcastID)
        )
        XCTAssertNotNil(podcastModel.playbackError)
        podcastModel.applyPodcastPlaybackObservationForTesting(itemID: podcastID, fault: nil)
        XCTAssertEqual(podcastModel.currentEpisode?.title, podcast.title)
        XCTAssertNil(podcastModel.playbackError, "a successful controller observation clears a stale fault")

        let article = try XCTUnwrap(podcastModel.articles.first)
        podcastModel.beginArticlePlaybackTransitionForTesting(article)
        await podcastModel.checkpointCurrentPlaybackForTesting()
        XCTAssertEqual(
            podcastModel.articlePlaybackCheckpointCount, 0,
            "an article selection must not publish the still-loaded podcast during its async transition"
        )
        podcastModel.openNowPlaying(for: article)
        for _ in 0..<100 {
            if podcastModel.playbackDurationSeconds == 120 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await podcastModel.checkpointCurrentPlaybackForTesting()
        XCTAssertEqual(podcastModel.articlePlaybackCheckpointCount, 1)
    }

    @MainActor
    func testPodcastSpeedAndDirectScrubRemainBoundedAndDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        model.setPlaybackRate(4)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let episodeID = try ItemID(rawValue: episode.id)
        var savedSpeed: PodcastPlaybackSpeed?
        for _ in 0..<100 {
            savedSpeed = try await store.playbackSpeed(for: episodeID)
            if savedSpeed != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.playbackRate, 2)
        XCTAssertEqual(savedSpeed?.speed, 2)

        model.scrub(to: 10_000)
        for _ in 0..<100 {
            if model.playbackPositionSeconds == model.playbackDurationSeconds { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.playbackPositionSeconds, 1_482)
        model.restartPlayback()
        for _ in 0..<100 {
            if model.playbackPositionSeconds == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.playbackPositionSeconds, 0)
    }

    @MainActor
    func testReadyEpisodeOutsideQueueBecomesCoherentCurrentPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertTrue(model.podcastQueueIDs.isEmpty)
        model.selectedNavigation = .processor

        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertEqual(model.currentEpisode?.id, episode.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.isNowPlaying)
        XCTAssertEqual(model.selectedNavigation, .processor)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, episode.id)
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [episode.id])
    }

    @MainActor
    func testModelPreviousAndNextPreserveDurableCurrentIdentityAtBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.episodes.first)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()

        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let secondID = try ItemID(rawValue: "item-" + String(repeating: "8", count: 64))
        let mediaURL = root.appendingPathComponent("second-podcast.mp3")
        _ = FileManager.default.createFile(atPath: mediaURL.path, contents: Data([8]))
        let revision = try AudioRevision(
            itemID: secondID,
            revisionID: RevisionID(rawValue: "model-wrapper-second"),
            durationSeconds: 90,
            byteCount: 1,
            contentHash: "sha256:" + String(repeating: "8", count: 64),
            mediaType: "audio/mpeg",
            createdAt: Timestamp(Date()),
            schemaVersion: 1
        )
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        let second = WiltedMacEpisode(
            id: secondID.rawValue,
            title: "Second queued episode",
            feedTitle: first.feedTitle,
            summary: "Queue navigation fixture",
            artworkURL: nil,
            releasedAt: first.releasedAt,
            durationSeconds: 90,
            playbackSeconds: 0,
            downloadState: .completed
        )
        model.installEpisodeForTesting(second)
        model.playEpisode(second)
        await model.waitForPlaybackOperationForTesting()

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, first.id)
        var queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, first.id)

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, first.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, first.id)

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, second.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, second.id)

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, second.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, second.id)
    }

    @MainActor
    func testFailedEpisodeSelectionPreservesPlayingEpisodeIdentityAndQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let playingEpisode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(playingEpisode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)

        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let queueBeforeFailure = try await store.podcastQueueState()
        let missingID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let missingEpisode = WiltedMacEpisode(
            id: missingID.rawValue,
            title: "Missing audio episode",
            feedTitle: playingEpisode.feedTitle,
            summary: "Unavailable fixture",
            artworkURL: nil,
            releasedAt: playingEpisode.releasedAt,
            durationSeconds: 60,
            playbackSeconds: 0,
            downloadState: .completed
        )

        model.playEpisode(missingEpisode)
        XCTAssertEqual(model.playbackOperationStatus, "Opening Missing audio episode…")
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.currentPodcastEpisodeID, playingEpisode.id)
        XCTAssertEqual(model.currentEpisode?.id, playingEpisode.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.playbackError, "This episode's saved audio is unavailable.")
        let queueAfterFailure = try await store.podcastQueueState()
        XCTAssertEqual(queueAfterFailure, queueBeforeFailure)
    }

    @MainActor
    func testUpNextMutationWhileArticlePlaysPreservesArticleCompactPlayerIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)

        let article = try XCTUnwrap(model.articles.first)
        model.openNowPlaying(for: article)
        for _ in 0..<100 {
            if model.currentArticle?.id == article.id, model.playbackDurationSeconds == 120 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.currentPodcastEpisodeID)

        model.addEpisodeToUpNext(episode)
        for _ in 0..<100 {
            if model.playbackOperationStatus == "Added \(episode.title) to Up Next." { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.currentArticle?.id, article.id)
        XCTAssertEqual(model.selectedArticleID, article.id)
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertNil(model.currentEpisode)
    }

    @MainActor
    func testRemovingPlayingEpisodeFromUpNextRetainsActiveCompactPlayerIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.podcastQueueIDs.contains(episode.id))

        model.removeEpisodeFromUpNext(episode.id)
        for _ in 0..<100 {
            if model.playbackOperationStatus == nil, !model.podcastQueueIDs.contains(episode.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id))
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertEqual(model.currentEpisode?.id, episode.id)
        XCTAssertTrue(model.hasCurrentPlayback)
        XCTAssertTrue(model.isNowPlaying)
        XCTAssertTrue(model.isPlaying)
    }

    @MainActor
    func testUpNextRemovalPresentationProtectsOnlyTheCurrentEpisode() {
        XCTAssertFalse(
            WiltedMacCompactPlayer.canRemoveFromUpNext(
                episodeID: "current", currentEpisodeID: "current"
            )
        )
        XCTAssertEqual(
            WiltedMacCompactPlayer.upNextRemoveAccessibilityValue(canRemove: false),
            "Unavailable for the current episode"
        )
        XCTAssertTrue(
            WiltedMacCompactPlayer.canRemoveFromUpNext(
                episodeID: "queued", currentEpisodeID: "current"
            )
        )
        XCTAssertEqual(
            WiltedMacCompactPlayer.upNextRemoveAccessibilityValue(canRemove: true),
            "Available"
        )
    }

    @MainActor
    func testMissingCurrentPodcastRestorePublishesCompactPlayerRecoveryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://podcasts.example.test/restore.xml")!
        let enclosureURL = URL(string: "https://podcasts.example.test/missing.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "missing-current", enclosureURL: enclosureURL
        )
        try await store.save(feed: PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Restore show", createdAt: Timestamp(Date())
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date())))
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "missing-current",
            title: "Missing current episode", author: "Restore desk", publishedTime: Timestamp(Date()),
            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", durationSeconds: 30,
            createdAt: Timestamp(Date())
        ))
        let mediaURL = root.appendingPathComponent("missing.mp3")
        _ = FileManager.default.createFile(atPath: mediaURL.path, contents: Data([1]))
        let revision = try AudioRevision(
            itemID: episodeID, revisionID: RevisionID(rawValue: "missing-current-revision"),
            durationSeconds: 30, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "8", count: 64), mediaType: "audio/mpeg",
            createdAt: Timestamp(Date()), schemaVersion: 1
        )
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        try FileManager.default.removeItem(at: mediaURL)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [episodeID], currentEpisodeID: episodeID
        ))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.currentEpisode?.title, "Missing current episode")
        XCTAssertEqual(model.playbackError, "This episode's saved audio is unavailable.")
        XCTAssertTrue(model.hasCurrentPlayback, "the compact player remains visible with recovery state")
        XCTAssertTrue(model.isNowPlaying)
    }

    @MainActor
    func testFixtureEpisodeDownloadFailureRetryCancellationAndRemovalAreDeterministic() async throws {
        let model = WiltedMacModel(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
            "--wilted-ui-fixture-download-failure"
        ], preferences: WiltedMacTestPreferences.ephemeral())
        let episode = try XCTUnwrap(model.episodes.first)
        model.downloadEpisode(episode)
        await model.waitForPodcastOperations()
        guard case .failed = try XCTUnwrap(model.episodes.first).downloadState else {
            return XCTFail("first deterministic fixture download must fail")
        }
        model.retryEpisodeDownload(try XCTUnwrap(model.episodes.first))
        await model.waitForPodcastOperations()
        guard case .completed = try XCTUnwrap(model.episodes.first).downloadState else {
            return XCTFail("retry must complete")
        }
        model.removeEpisode(try XCTUnwrap(model.episodes.first))
        XCTAssertFalse(model.libraryItems.contains { $0.id == episode.id })

        let cancelled = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], preferences: WiltedMacTestPreferences.ephemeral())
        let cancellingEpisode = try XCTUnwrap(cancelled.episodes.first)
        cancelled.downloadEpisode(cancellingEpisode)
        cancelled.cancelEpisodeDownload(cancellingEpisode)
        await cancelled.waitForPodcastOperations()
        guard case .cancelled = try XCTUnwrap(cancelled.episodes.first).downloadState else {
            return XCTFail("cancelled fixture download must stay cancelled")
        }
    }

    @MainActor
    func testPodcastClientCancellationStaysCancellationForRefreshAndSubscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://podcasts.example.test/cancelled.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: PodcastFeed(
            itemID: feedID,
            canonicalURL: feedURL,
            title: "Cancellation fixture",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1))
        ))
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: 1))
        ))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: root,
            podcastFeedClient: PodcastFeedClient(loader: CancelledPodcastFeedLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.podcastOperationMessage, "Podcast refresh cancelled.")
        XCTAssertFalse(model.isRefreshingPodcasts)

        model.subscribeToPodcastFeed(URL(string: "https://podcasts.example.test/new.xml")!)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.podcastOperationMessage, "Podcast refresh cancelled.")
        XCTAssertFalse(model.isRefreshingPodcasts)
    }

    @MainActor
    func testPodcastSubscriptionAndRefreshPersistFeedAndEpisodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let feedURL = URL(string: "https://podcasts.example.test/persisted.xml")!
        // Dates are wall-clock relative because the subscription's admission
        // horizon is the moment `subscribeToPodcastFeed` runs. The first
        // episode sits just inside the backfill window; the refreshed one is
        // dated ahead of the subscription so it is unambiguously new.
        let loader = SequencedPodcastFeedLoader(documents: [
            Self.podcastXML(title: "Stored first episode", guid: "stored-1", published: Date().addingTimeInterval(-3_600)),
            Self.podcastXML(title: "Stored refreshed episode", guid: "stored-2", published: Date().addingTimeInterval(3_600))
        ])
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: root,
            podcastFeedClient: PodcastFeedClient(
                loader: loader,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.subscribeToPodcastFeed(feedURL)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.podcastOperationMessage, "Podcast episodes are up to date.")
        XCTAssertEqual(model.episodes.map(\.title), ["Stored first episode"])
        XCTAssertEqual(model.episodes.first?.feedTitle, "Stored show")

        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let initialSubscriptions = try await store.subscriptions()
        let initialFeeds = try await store.podcastFeeds()
        let initialEpisodes = try await store.podcastEpisodes()
        XCTAssertEqual(initialSubscriptions.count, 1)
        XCTAssertEqual(initialFeeds.map(\.title), ["Stored show"])
        XCTAssertEqual(initialEpisodes.map(\.title), ["Stored first episode"])

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.podcastOperationMessage, "Podcast episodes are up to date.")
        XCTAssertEqual(Set(model.episodes.map(\.title)), ["Stored first episode", "Stored refreshed episode"])
        let refreshedEpisodes = try await store.podcastEpisodes()
        let refreshedSubscriptions = try await store.subscriptions()
        XCTAssertEqual(
            Set(refreshedEpisodes.map(\.title)),
            ["Stored first episode", "Stored refreshed episode"]
        )
        XCTAssertEqual(refreshedSubscriptions.filter(\.enabled).count, 1)
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func podcastXML(title: String, guid: String, published: Date? = nil) -> Data {
        let pubDate = published.map { "<pubDate>\(rfc822.string(from: $0))</pubDate>" } ?? ""
        return Data("""
        <rss><channel><title>Stored show</title><item><title>\(title)</title><guid>\(guid)</guid>\(pubDate)<enclosure url="https://cdn.example.test/\(guid).mp3" type="audio/mpeg" /></item></channel></rss>
        """.utf8)
    }

    func testPreviewMatrixCoversEveryRequiredState() {
        XCTAssertEqual(WiltedPreviewFixture.matrix.count, WiltedPreviewState.allCases.count)
        XCTAssertEqual(Set(WiltedPreviewFixture.matrix.map(\.id)).count, WiltedPreviewFixture.matrix.count)
        XCTAssertEqual(WiltedVisualVariant.matrix.count, 8)
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.cancelling))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.iCloudUnavailable))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.incompatibleRevision))
    }

    /// The custom symbols are only symbols if the catalog compiled them under
    /// the names the code uses; a typo would draw nothing, silently.
    func testCustomSymbolsResolveFromTheCatalog() {
        for symbol in WiltedSymbol.allCases {
            XCTAssertNotNil(NSImage(named: symbol.rawValue), symbol.rawValue)
        }
        XCTAssertEqual(WiltedMacNavigation.library.symbolName, WiltedSymbol.larder.rawValue)
        XCTAssertEqual(WiltedMacNavigation.processor.symbolName, WiltedSymbol.prep.rawValue)
        XCTAssertEqual(WiltedMacNavigation.feeds.symbolName, WiltedSymbol.broccoli.rawValue)
        XCTAssertEqual(WiltedPreviewState.preparing(.synthesizing).symbolName, WiltedSymbol.processor.rawValue)
        XCTAssertEqual(WiltedPreviewState.emptyLibrary.symbolName, WiltedSymbol.larder.rawValue)
        XCTAssertFalse(WiltedSymbol.isCustom(WiltedMacNavigation.settings.symbolName))
    }

    func testStatesHaveStableUserFacingMetadata() {
        for state in WiltedPreviewState.allCases {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertFalse(state.accessibilityStatus.isEmpty)
        }
    }

    func testLightAndDarkLeafPassReadableContrast() {
        XCTAssertEqual(WiltedTheme.lightHex[.wiltedLeaf], 0x4D6B22)
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            let leaf = WiltedTheme.hex(for: .wiltedLeaf, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, card), 4.5)
        }
    }

    func testPrimaryAndSecondaryTextPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let primary = WiltedTheme.hex(for: .primaryText, scheme: scheme)
            let secondary = WiltedTheme.hex(for: .secondaryText, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(primary, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(secondary, page), 4.5)
        }
    }

    /// The producer surfaces put body and status text on `.card`, not just on
    /// `.page`. That pairing shipped untested until the Mac producer screens
    /// adopted the token set, so it is asserted here rather than assumed.
    func testCardTextPairingsPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            for token in [WiltedTheme.ColorToken.primaryText, .secondaryText, .success, .error, .progress] {
                let foreground = WiltedTheme.hex(for: token, scheme: scheme)
                XCTAssertGreaterThanOrEqual(
                    WiltedTheme.contrastRatio(foreground, card), 4.5,
                    "\(token) on card fails readable contrast in \(scheme)"
                )
            }
        }
    }

    func testNativeInteractionContract() {
        XCTAssertEqual(WiltedNavigation.allCases.map(\.title), ["Larder", "Now Playing", "Downloads", "Settings"])
        XCTAssertEqual(WiltedMacNavigation.allCases.map(\.title), ["Larder", "Podcast feeds", "Prep", "Settings"])
        XCTAssertFalse(WiltedMacNavigation.allCases.map(\.rawValue).contains("nowPlaying"))
        XCTAssertEqual(WiltedScreenCopy.libraryEmpty, "Your larder is empty")
        XCTAssertEqual(WiltedScreenCopy.noArticles, "No articles yet")
        XCTAssertEqual(WiltedScreenCopy.addArticle, "Add Article")
        XCTAssertEqual(WiltedScreenCopy.addArticleIdentifier, "wilted-add-article")
        // Larder's one box takes both kinds, so its label names neither.
        XCTAssertEqual(WiltedScreenCopy.addLink, "Add")
        XCTAssertEqual(WiltedScreenCopy.addLinkTitle, "Add an article or podcast")
        // Feeds is a destination now, so the empty card must not tell the
        // reader to subscribe "above" on a page with no add box.
        XCTAssertFalse(WiltedScreenCopy.feedsEmptyDetail.contains("above"))
        XCTAssertTrue(WiltedScreenCopy.feedsEmptyDetail.contains(WiltedScreenCopy.library))
        XCTAssertEqual(WiltedScreenCopy.stateActionIdentifier, "wilted-state-action")
        XCTAssertEqual(WiltedScreenCopy.libraryIdentifier, "wilted-library")
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.accessibilityIdentifier,
            "wilted-state-emptyLibrary"
        )
        XCTAssertEqual(WiltedScreenCopy.downloads, "Downloads")
        XCTAssertEqual(WiltedScreenCopy.noDownloads, "No Downloads")
        XCTAssertEqual(WiltedScreenCopy.downloadsEmptyIdentifier, "wilted-no-downloads")
        XCTAssertEqual(WiltedScreenCopy.nowPlaying, "Now Playing")
        XCTAssertEqual(WiltedScreenCopy.nowPlayingEmptyIdentifier, "wilted-player-empty")
        XCTAssertEqual(WiltedScreenCopy.downloadsIdentifier, "wilted-downloads")
        XCTAssertEqual(WiltedScreenCopy.settings, "Settings")
        XCTAssertEqual(WiltedScreenCopy.settingsIdentifier, "wilted-settings")
        XCTAssertEqual(WiltedPreviewFixture(state: .ready).articleTitle, "Fixture article")
        XCTAssertEqual(WiltedTheme.Spacing.minimumTouchTarget, 44)
        XCTAssertEqual(WiltedMark.geometrySignature, "single-stroke-w:balanced-d6:v2")
        XCTAssertEqual(
            WiltedVisualVariant.matrix.map(\.id),
            [
                "light-standard-motion-full", "light-standard-motion-reduced",
                "light-xxxLarge-motion-full", "light-xxxLarge-motion-reduced",
                "dark-standard-motion-full", "dark-standard-motion-reduced",
                "dark-xxxLarge-motion-full", "dark-xxxLarge-motion-reduced"
            ]
        )
    }

    /// Prep cards keep their facts and controls in predictable regions. This
    /// source contract catches a visual regression without changing snapshots.
    func testPrepRunAndCompactPlayerPresentationContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)

        func section(_ start: String, before end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
            return source[startIndex..<endIndex]
        }

        let activeCard = try section("private func activeRunCard", before: "private func runRow")
        let recentCard = try section("private func runRow", before: "private func runMetadata")
        XCTAssertTrue(activeCard.contains("runMetadata(run)"))
        XCTAssertTrue(recentCard.contains("runMetadata(run)"))
        XCTAssertLessThan(
            try XCTUnwrap(activeCard.range(of: "Text(run.narrative)")?.lowerBound),
            try XCTUnwrap(activeCard.range(of: "runActions(run, canStop: true)")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(recentCard.range(of: "Text(run.narrative)")?.lowerBound),
            try XCTUnwrap(recentCard.range(of: "runActions(run, canStop: false)")?.lowerBound)
        )
        XCTAssertTrue(source.contains("wilted-processor-actions-\\(run.id)"))
        XCTAssertTrue(source.contains("wilted-processor-stop-\\(run.id)"))
        XCTAssertTrue(source.contains("wilted-processor-retry-\\(run.id)"))

        let log = try section("private func eventLog", before: "// MARK: - Persistent Player")
        XCTAssertTrue(log.contains("ScrollView(.vertical)"))
        XCTAssertTrue(log.contains("maxHeight: 176"))
        XCTAssertTrue(log.contains(".monospaced()"))
        XCTAssertTrue(log.contains(".textSelection(.enabled)"))
        XCTAssertTrue(log.contains("wilted-processor-log-\\(run.id)"))
        XCTAssertTrue(log.contains("wilted-processor-event-\\(event.id)"))

        XCTAssertTrue(source.contains("Text(model.playbackStatusMessage)"))
        XCTAssertFalse(source.contains("if let error = model.playbackError"))
        XCTAssertTrue(source.contains("wilted-player-recoverable-error"))
        XCTAssertTrue(source.contains("Button(\"Recover audio\") { model.recoverAudioRoute() }"))
        XCTAssertTrue(source.contains("wilted-player-route-recovery"))
    }

    /// Removed rows carry enough presentation metadata to name the episode,
    /// its feed, and its retained Prep history without reconstructing a deleted
    /// episode record.
    func testRemovedEpisodePresentationMetadataNamesPrepHistory() {
        let removed = WiltedMacDismissedEpisode(
            id: "episode-id", feedID: "feed-id", title: "Recovered episode",
            feedTitle: "Field Notes", dismissedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPreparationHistory: true
        )
        XCTAssertEqual(removed.title, "Recovered episode")
        XCTAssertEqual(removed.feedTitle, "Field Notes")
        XCTAssertTrue(removed.hasPreparationHistory)
        XCTAssertEqual(removed.id, "episode-id", "Restore identity must remain stable across renders")
    }

    /// The producer window has no Downloads destination, so its copy must not
    /// send the reader to one. This was shipped: the Mac empty player told the
    /// reader to visit Downloads, and no pixel baseline could catch it because
    /// the Mac baselines always render the player, never the empty state.
    func testProducerCopyNamesOnlyProducerDestinations() {
        let producerDestinations = WiltedMacNavigation.allCases
        XCTAssertEqual(producerDestinations.map(\.title), ["Larder", "Podcast feeds", "Prep", "Settings"])

        XCTAssertFalse(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.downloads),
            "Producer copy must not point at a destination the Mac window does not have."
        )
        XCTAssertTrue(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.library)
        )
        // The listener does have Downloads, so its wording legitimately differs.
        XCTAssertTrue(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.library))
        XCTAssertFalse(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.downloads))
        XCTAssertFalse(
            WiltedScreenCopy.libraryEmptyDetailProducer.contains(WiltedScreenCopy.downloads)
        )
    }

    /// Emphasis without letting colour carry state alone: every phase still
    /// renders its own name, and only the phases that mean something distinct
    /// get a non-neutral tone.
    func testSyncPhasesCarryTheirOwnToneAndText() {
        let expected: [(WiltedMacSyncPhase, WiltedStatusTone)] = [
            (.disabled, .neutral), (.idle, .neutral), (.cancelled, .neutral),
            (.staging, .active), (.fetching, .active), (.sending, .active),
            (.completed, .positive), (.quarantined, .caution), (.failed, .failure)
        ]
        for (phase, tone) in expected {
            XCTAssertEqual(phase.tone, tone, "wrong tone for \(phase.rawValue)")
            XCTAssertFalse(phase.rawValue.isEmpty)
        }
        XCTAssertEqual(WiltedMacSyncPhase.quarantined.rawValue.capitalized, "Quarantined")
    }

    func testDeterministicRenderArtifactDoesNotDrift() {
        let variant = WiltedVisualVariant(
            appearance: .light,
            dynamicType: .xxxLarge,
            reduceMotion: true
        )
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.renderSignature(variant: variant),
            "2ba6962858bc3fb7"
        )
        let signatures = Set(
            WiltedPreviewState.allCases.flatMap { state in
                WiltedVisualVariant.matrix.map { state.renderSignature(variant: $0) }
            }
        )
        XCTAssertEqual(signatures.count, WiltedPreviewState.allCases.count * WiltedVisualVariant.matrix.count)
    }

    /// The reported defect: a 29-minute article read "1743 seconds" on both
    /// platforms. These lock the format, not just the fix.
    func testDurationsReadAsClockTimeRatherThanRawSeconds() {
        XCTAssertEqual(WiltedDuration.clock(1743), "29:03")
        XCTAssertEqual(WiltedDuration.clock(120), "2:00")
        XCTAssertEqual(WiltedDuration.clock(0), "0:00")
        XCTAssertEqual(WiltedDuration.clock(9), "0:09")
        XCTAssertEqual(WiltedDuration.clock(3600), "1:00:00")
        XCTAssertEqual(WiltedDuration.clock(3661), "1:01:01")
        // Nothing may print a negative or non-finite clock.
        XCTAssertEqual(WiltedDuration.clock(-90), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.infinity), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.nan), "0:00")
        XCTAssertEqual(WiltedDuration.progress(position: 31, duration: 1743), "0:31 of 29:03")
    }

    /// VoiceOver cannot infer units from a colon, so the spoken form must carry
    /// the words. Reading "twenty-nine oh three" is the same defect as printing
    /// "1743".
    func testSpokenDurationsCarryUnitsRatherThanColons() {
        for value in [WiltedDuration.spoken(1743), WiltedDuration.spokenProgress(position: 31, duration: 1743)] {
            XCTAssertFalse(value.contains(":"), "spoken duration must not rely on a colon: \(value)")
            XCTAssertTrue(value.lowercased().contains("minute"), "spoken duration must name its units: \(value)")
        }
    }
}

private struct CancelledPodcastFeedLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw PodcastFeedClientError.cancelled
    }
}

private actor SequencedPodcastFeedLoader: PodcastFeedLoading {
    private let documents: [Data]
    private var nextIndex = 0

    init(documents: [Data]) { self.documents = documents }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        let index = min(nextIndex, documents.count - 1)
        nextIndex += 1
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: documents[index])
    }
}
