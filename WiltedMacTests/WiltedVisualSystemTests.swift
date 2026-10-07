import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

final class WiltedVisualSystemTests: XCTestCase {

    /// Every SF Symbol the Mac views name must exist in the system symbol set.
    ///
    /// `circle.grid.2x3.fill` did not, and SwiftUI does not fail on a missing
    /// symbol -- it logs "No symbol named ... found in system symbol set" and
    /// draws nothing, so the Larder's drag handle was an invisible control on
    /// every row and no test noticed. A name is cheap to typo and impossible
    /// to catch by reading, so the whole set is checked rather than the one
    /// that broke.
    func testEverySystemSymbolTheMacViewsNameResolves() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the Mac sources must be readable from the test bundle")

        let pattern = try NSRegularExpression(pattern: #"systemName:\s*"([^"]+)""#)
        var named: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let symbol = Range(match.range(at: 1), in: text) else { continue }
                named.insert(String(text[symbol]))
            }
        }
        XCTAssertFalse(named.isEmpty, "the views name at least one symbol")

        let missing = named
            .filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
            .sorted()
        XCTAssertEqual(missing, [],
                       "these symbols draw as nothing at runtime: \(missing.joined(separator: ", "))")
    }
    func testPodcastOperationMessageReservesEqualShortAndWrappingRows() {
        for scale in WiltedTheme.TextScale.allCases {
            let shortHeight = WiltedMacPodcastOperationMessageLayout.rowHeight(
                for: WiltedTheme.scaled(16, scale: scale), scale: scale
            )
            let wrappingHeight = WiltedMacPodcastOperationMessageLayout.rowHeight(
                for: WiltedTheme.scaled(32, scale: scale), scale: scale
            )

            XCTAssertEqual(shortHeight, wrappingHeight)
            XCTAssertEqual(
                shortHeight,
                WiltedMacPodcastOperationMessageLayout.minimumRowHeight(for: scale)
            )
        }
    }

    @MainActor
    func testStoredArticlesAndSubscribedEpisodesLoadIntoOneLibrary() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

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
                if index == 2 {
                    // A later restoration clears the completed revision and
                    // refreshes the listening timestamp. The retirement sweep
                    // must leave this completed episode visible in Feeds; this
                    // test exercises that library projection.
                    try await store.saveListening(PodcastListeningState(
                        episodeID: episodeID, completedAt: Timestamp(Date(timeIntervalSince1970: 400)),
                        lastRevisionID: nil, updatedAt: Timestamp(Date(timeIntervalSince1970: 500))
                    ))
                }
            }
        }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        // Articles and episodes load into one library; nothing is kept yet, so
        // every visible episode is a Feeds arrival and none waits on the Larder.
        XCTAssertEqual(model.articles.map(\.id), [article.itemID.rawValue])
        XCTAssertEqual(Set(model.larderVisibleEpisodes.map(\.id)), Set(episodeIDs.map(\.rawValue)))
        XCTAssertEqual(model.feedsEpisodes.count, 3)
        XCTAssertTrue(model.larderWaitingEpisodes.isEmpty)
    }


    @MainActor
    func testPodcastPlaybackStaysOutOfArticleSyncWhileArticleQueuesOneCheckpoint() async throws {
        let podcastRoot = wiltedTemporaryDirectory("visual-system")

        let podcastModel = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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
    func testTheFeedsFixtureEpisodesCarryTheNotesTheirTitleOpens() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        for _ in 0..<100 {
            if !model.feedsEpisodes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.feedsEpisodes.isEmpty)
        XCTAssertTrue(model.feedsEpisodes.allSatisfy { episode in
            guard let notes = episode.notes else { return false }
            return !notes.isEmpty
        })
    }

    @MainActor
    func testReadyEpisodeOutsideQueueBecomesCoherentCurrentPlayback() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.episodes.first)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()

        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        // The fixture supplies a ready revision and an in-memory completed
        // download state. Record the durable download too, since queue
        // navigation reloads episodes from the store.
        let firstID = try ItemID(rawValue: first.id)
        let firstReadyValue = try await store.readyRevision(for: firstID)
        let firstReady = try XCTUnwrap(firstReadyValue)
        try await store.save(download: try PodcastDownload(
            episodeID: firstID, status: .completed,
            bytesReceived: firstReady.revision.byteCount,
            expectedByteCount: firstReady.revision.byteCount,
            localURL: firstReady.mediaURL,
            contentHash: firstReady.revision.contentHash,
            updatedAt: Timestamp(Date())
        ))
        // The second episode is a row in the store as well as in the model. An
        // episode finishing reloads the library rows so the one just left
        // behind shows its Played badge, and a row that exists only in memory
        // does not survive that. A stored row also has to carry the identity
        // the store derives from its feed and enclosure, so the identifier is
        // derived rather than invented.
        let storedEpisodes = try await store.podcastEpisodes()
        let storedFirst = try XCTUnwrap(storedEpisodes.first(where: { $0.itemID.rawValue == first.id }))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/second-podcast.mp3"))
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: storedFirst.feedURL, rssGUID: "queue-boundary-second", enclosureURL: enclosureURL
        )
        try await store.save(episode: try PodcastEpisode(
            itemID: secondID,
            feedID: storedFirst.feedID,
            feedURL: storedFirst.feedURL,
            rssGUID: "queue-boundary-second",
            title: "Second queued episode",
            publishedTime: storedFirst.publishedTime,
            enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date())
        ))
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
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: secondID, revisionID: revision.revisionID,
            policyDigest: "fixture-policy", pipelineFingerprint: "fixture-fingerprint",
            semanticVersion: "fixture-semantic-version", producedAt: Timestamp(Date())
        ))
        let second = WiltedMacEpisode(
            id: secondID.rawValue,
            title: "Second queued episode",
            feedTitle: first.feedTitle,
            summary: "Queue navigation fixture",
            artworkURL: nil,
            releasedAt: first.releasedAt,
            durationSeconds: 90,
            playbackSeconds: 0,
            downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        model.installEpisodeForTesting(second)
        model.playEpisode(second)
        await model.waitForPlaybackOperationForTesting()

        // Play Now swaps the requested episode into the displaced episode's
        // slot, so the new current episode is the first queue item here.
        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, second.id)
        var queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, second.id)

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, second.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, second.id)

        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [second.id, first.id])
        let reloadedFirst = try XCTUnwrap(model.episodes.first(where: { $0.id == first.id }))
        XCTAssertTrue(model.canPlayEpisode(reloadedFirst),
                      "first queued episode must retain downloaded, prepared, ready media: "
                          + "download=\(reloadedFirst.downloadState) prep=\(reloadedFirst.preparationState) "
                          + "ready=\(reloadedFirst.isReadyMediaAvailable)")
        XCTAssertEqual(model.nextEligiblePodcastQueueEpisode()?.id, first.id)
        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, first.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, first.id)

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentEpisode?.id, first.id)
        queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, first.id)
    }

    @MainActor
    func testFailedEpisodeSelectionPreservesPlayingEpisodeIdentityAndQueue() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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

    /// Skip on the episode that is playing has to stop it.
    ///
    /// Removal took the row, the stored records and the Up Next entry and left
    /// the transport running, so the audio carried on for an episode the
    /// library no longer held while the rail and the system widget still
    /// offered controls for it.
    @MainActor
    func testRemovingThePlayingEpisodeStopsTheAudioItRemoved() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertTrue(model.isPlaying)

        model.removeEpisode(episode)
        for _ in 0..<300 {
            if model.currentPodcastEpisodeID == nil, !model.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.currentPodcastEpisodeID, "a removed episode must not remain the playing one")
        XCTAssertFalse(model.isPlaying, "Skip must stop the audio it removed")
        XCTAssertFalse(model.isNowPlaying, "Now Playing must not keep offering a removed episode")
    }

    @MainActor
    func testUpNextMutationWhileArticlePlaysPreservesArticleCompactPlayerIdentity() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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
            if model.playbackOperationStatus == "Added \(episode.title) to Larder." { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.currentArticle?.id, article.id)
        XCTAssertEqual(model.selectedArticleID, article.id)
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertNil(model.currentEpisode)
    }

    @MainActor
    func testRemovingPlayingEpisodeFromUpNextRetainsActiveCompactPlayerIdentity() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
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
    func testMissingCurrentPodcastRestorePublishesCompactPlayerRecoveryState() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

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
        ], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral())
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
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episode.id })

        let cancelled = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral())
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
        let root = wiltedTemporaryDirectory("visual-system")

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
        XCTAssertNil(model.lastPodcastRefreshAt)
        XCTAssertEqual(model.lastPodcastRefreshText, "Never")

        model.subscribeToPodcastFeed(URL(string: "https://podcasts.example.test/new.xml")!)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.podcastOperationMessage, "Podcast refresh cancelled.")
        XCTAssertFalse(model.isRefreshingPodcasts)
    }

    @MainActor
    func testPodcastSubscriptionAndRefreshPersistFeedAndEpisodes() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

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
        XCTAssertEqual(model.podcastOperationMessage, "Stored show added with 1 episode.")
        XCTAssertEqual(model.episodes.map(\.title), ["Stored first episode"])
        XCTAssertNil(model.lastPodcastRefreshAt, "subscription is not a successful manual refresh")
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
        // The count is the point: automation may only act on what this exact
        // refresh admitted, so the message reports that number and not the feed.
        XCTAssertEqual(model.podcastOperationMessage, "Added 1 new episode.")
        XCTAssertEqual(model.lastPodcastRefreshNewEpisodeIDs.count, 1)
        XCTAssertNotNil(model.lastPodcastRefreshAt)
        XCTAssertEqual(Set(model.episodes.map(\.title)), ["Stored first episode", "Stored refreshed episode"])
        let refreshedEpisodes = try await store.podcastEpisodes()
        let refreshedSubscriptions = try await store.subscriptions()
        XCTAssertEqual(
            Set(refreshedEpisodes.map(\.title)),
            ["Stored first episode", "Stored refreshed episode"]
        )
        XCTAssertEqual(refreshedSubscriptions.filter(\.enabled).count, 1)
    }

    @MainActor
    func testManualRefreshContinuesPastABrokenFeedAndReportsThePartialResult() async throws {
        let root = wiltedTemporaryDirectory("visual-system")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let brokenURL = URL(string: "https://podcasts.example.test/broken.xml")!
        let workingURL = URL(string: "https://podcasts.example.test/working.xml")!
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        for (url, title) in [(brokenURL, "Broken show"), (workingURL, "Working show")] {
            let feedID = try ItemID.derivePodcastFeed(from: url)
            try await store.save(feed: PodcastFeed(
                itemID: feedID, canonicalURL: url, title: title,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1))
            ))
            try await store.save(subscription: PodcastSubscription(
                feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1))
            ))
        }
        let loader = URLRoutingPodcastFeedLoader(documents: [
            workingURL: Self.podcastXML(
                title: "Working episode", guid: "working-1",
                published: Date().addingTimeInterval(3_600)
            )
        ])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: root,
            podcastFeedClient: PodcastFeedClient(loader: loader),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.map(\.title), ["Working episode"])
        XCTAssertEqual(model.lastPodcastRefreshNewEpisodeIDs.count, 1)
        XCTAssertNotNil(model.lastPodcastRefreshAt)
        XCTAssertEqual(
            model.podcastOperationMessage,
            "Added 1 new episode. 1 feed could not be refreshed."
        )
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
}
