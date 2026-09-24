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
    /// draws nothing, so the Menu's drag handle was an invisible control on
    /// every row and no test noticed. A name is cheap to typo and impossible
    /// to catch by reading, so the whole set is checked rather than the one
    /// that broke.
    func testEverySystemSymbolTheMacViewsNameResolves() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
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

    func testMacSettingsExposeThisMacLifetimeStatisticsWithStableIdentifiers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("WiltedScreenCopy.lifetimeStatisticsScope"))
        for identifierName in [
            "WiltedScreenCopy.audioProcessedIdentifier",
            "WiltedScreenCopy.speechGeneratedIdentifier",
            "WiltedScreenCopy.confirmedAdTimeRemovedIdentifier",
            "WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier",
        ] {
            XCTAssertTrue(source.contains(identifierName))
        }
    }

    @MainActor
    func testStoredArticlesAndSubscribedEpisodesLoadIntoOneLibrary() async throws {
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
        // every visible episode is a Feeds arrival and none waits on the Menu.
        XCTAssertEqual(model.articles.map(\.id), [article.itemID.rawValue])
        XCTAssertEqual(Set(model.larderVisibleEpisodes.map(\.id)), Set(episodeIDs.map(\.rawValue)))
        XCTAssertEqual(model.feedsEpisodes.count, 3)
        XCTAssertTrue(model.menuWaitingEpisodes.isEmpty)
    }

    func testEpisodeDownloadPresentationCoversEveryLifecycleState() {
        let values: [WiltedMacEpisodeDownloadState] = [
            .notDownloaded, .queued, .downloading(received: 2, expected: 10),
            .completed, .failed, .cancelled
        ]
        XCTAssertEqual(values.count, 6)
        XCTAssertNotEqual(values[1], values[4])
    }

    func testEpisodeRowsOwnOneDedicatedLifecycleLineAndKeepControlsActionOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let rowStart = try XCTUnwrap(source.range(of: "private func menuRow")?.lowerBound)
        let start = try XCTUnwrap(source.range(of: "@ViewBuilder private func nextStepControl")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private var addArticleButton", range: start..<source.endIndex)?.lowerBound)
        let row = source[rowStart..<start]
        let control = source[start..<end]

        // One dedicated state line: the row names the step it is waiting for,
        // derived from the model's single group accessor.
        XCTAssertTrue(row.contains("WiltedMacModel.menuGroup(for: episode)"))
        XCTAssertTrue(row.contains("episode.releasedAt.formatted(date: .numeric, time: .omitted)"))
        XCTAssertTrue(row.contains("showsGroupName"))
        XCTAssertTrue(source.contains("showsGroupName: section.statusGroup == nil"))
        XCTAssertTrue(row.contains("· \\(group.displayName)"))
        XCTAssertTrue(row.contains("wilted-menu-progress-\\(episode.id)"))
        XCTAssertTrue(row.contains("wilted-menu-row-\\(episode.id)"))

        XCTAssertTrue(control.contains("case .failed, .cancelled:"))
        XCTAssertEqual(control.components(separatedBy: "Label(\"Retry\", systemImage: \"arrow.clockwise\")").count - 1, 2)
        XCTAssertTrue(control.contains("wilted-menu-stop-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-retry-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-prepare-\\(episode.id)"))
        XCTAssertFalse(control.contains("Text(\"Download failed\")"))
        XCTAssertFalse(control.contains("Text(\"Download cancelled\")"))
        XCTAssertFalse(control.contains("accessibilityLabel(\"Available offline\")"))
    }

    func testLarderRowsUseIconsForShortWordsAndStateOnce() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let start = try XCTUnwrap(source.range(of: "private func menuRow")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private var addArticleButton", range: start..<source.endIndex)?.lowerBound)
        let larderRows = source[start..<end]

        for symbol in [
            "checkmark.circle.fill", "play.fill", "forward.end.fill", "checkmark", "minus.circle", "stop.fill",
            "arrow.clockwise", "xmark.circle", "arrow.down.circle",
        ] {
            XCTAssertTrue(larderRows.contains("\"\(symbol)\""), "missing \(symbol)")
        }
        for retiredRowStateSymbol in ["speaker.wave.2.fill", "speaker.fill", "circle.lefthalf.filled"] {
            XCTAssertFalse(larderRows.contains("\"\(retiredRowStateSymbol)\""),
                           "Now Playing owns \(retiredRowStateSymbol)")
        }
        XCTAssertTrue(larderRows.contains(".labelStyle(.iconOnly)"))
        for retiredTextControl in [
            "Text(\"Play now\")", "Button(\"Play now\")", "Button(\"Remove\")", "Button(\"Download\")",
            "Text(\"In Progress\")", "Text(\"Played\")",
        ] {
            XCTAssertFalse(larderRows.contains(retiredTextControl), "retired text control: \(retiredTextControl)")
        }
        XCTAssertTrue(larderRows.contains("Self.readyActionSlotWidth"))
        XCTAssertTrue(larderRows.contains("Self.trailingActionSlotsWidth"))
        XCTAssertTrue(larderRows.contains("HStack(spacing: 2)"))
        XCTAssertFalse(larderRows.contains("model.currentPodcastEpisodeID"))
        let modelRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacModel.swift")
        let modelSource = try String(contentsOf: modelRoot)
        XCTAssertTrue(modelSource.contains("var larderPresentationEpisodes"))
        XCTAssertTrue(modelSource.contains("guard isPodcastPlayback, let currentPodcastEpisodeID"))

        // Each icon-only control carries its own tooltip: the `.help` has to
        // come before the next control starts, not anywhere later in the row.
        let iconOnlyControls = larderRows.components(separatedBy: ".labelStyle(.iconOnly)").dropFirst()
        for control in iconOnlyControls {
            let ownModifiers = control.components(separatedBy: "Button").first ?? ""
            XCTAssertTrue(ownModifiers.contains(".help("), "icon-only control without its tooltip: \(ownModifiers.prefix(120))")
        }
        XCTAssertFalse(larderRows.contains("retirementLabel == \"Completed\""))
    }

    @MainActor
    func testPodcastPlaybackStaysOutOfArticleSyncWhileArticleQueuesOneCheckpoint() async throws {
        let podcastRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: podcastRoot) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episode.id })

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
        XCTAssertNil(model.lastPodcastRefreshAt)
        XCTAssertEqual(model.lastPodcastRefreshText, "Never")

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
        XCTAssertEqual(model.podcastOperationMessage, "Podcast subscription added with 1 episode.")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertEqual(WiltedMacNavigation.menu.symbolName, "list.number")
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
        XCTAssertEqual(WiltedNavigation.allCases.map(\.title), [WiltedScreenCopy.library, WiltedScreenCopy.nowPlaying, WiltedScreenCopy.downloads, WiltedScreenCopy.settings])
        XCTAssertEqual(WiltedMacNavigation.allCases.map(\.title), ["Larder", "Feeds", "Settings"])
        XCTAssertFalse(WiltedMacNavigation.allCases.map(\.rawValue).contains("nowPlaying"))
        XCTAssertEqual(WiltedScreenCopy.libraryEmpty, "Your larder is empty")
        XCTAssertEqual(WiltedScreenCopy.noArticles, "No articles yet")
        XCTAssertEqual(WiltedScreenCopy.addArticle, "Add Article")
        XCTAssertEqual(WiltedScreenCopy.addArticleIdentifier, "wilted-add-article")
        // Larder's box is for articles, and says so: a feed pasted there is
        // handed to Podcast feeds rather than saved as an episode.
        XCTAssertEqual(WiltedScreenCopy.addLink, "Add article")
        XCTAssertEqual(WiltedScreenCopy.addLinkTitle, "Add an article")
        XCTAssertTrue(WiltedScreenCopy.addLinkDetail.contains(WiltedScreenCopy.feeds))
        // Podcast feeds owns subscribing now, so the empty card explains what
        // its own composer accepts instead of sending the reader elsewhere.
        XCTAssertEqual(WiltedScreenCopy.subscribeToPodcast, "Subscribe to a podcast")
        XCTAssertFalse(WiltedScreenCopy.feedsEmptyDetail.contains("above"))
        XCTAssertFalse(WiltedScreenCopy.feedsEmptyDetail.contains(WiltedScreenCopy.library))
        XCTAssertTrue(WiltedScreenCopy.subscribeToPodcastDetail.contains("RSS"))
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

    /// Prep controls live in the Menu row that owns the run, and the player's
    /// facts keep their predictable regions. This source contract catches a
    /// visual regression without changing snapshots.
    func testPrepRunAndCompactPlayerPresentationContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)

        func section(_ start: String, before end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
            return source[startIndex..<endIndex]
        }

        let row = try section("private func menuRow", before: "@ViewBuilder private func nextStepControl")
        XCTAssertTrue(row.contains("nextStepControl(episode, group: group)"))
        XCTAssertTrue(row.contains("wilted-menu-progress-\\(episode.id)"))

        let control = try section("@ViewBuilder private func nextStepControl", before: "private var addArticleButton")
        XCTAssertTrue(control.contains("wilted-menu-stop-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-retry-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-prepare-\\(episode.id)"))

        XCTAssertTrue(source.contains("Text(model.playbackStatusMessage)"))
        XCTAssertTrue(source.contains("if model.playbackStatusMessage != \"Playing\""))
        XCTAssertTrue(source.contains("model.playbackStatusMessage != \"Paused\""))
        XCTAssertFalse(source.contains(".opacity(model.playbackStatusMessage =="))
        XCTAssertFalse(source.contains("if let error = model.playbackError"))
        XCTAssertTrue(source.contains("wilted-player-recoverable-error"))
        XCTAssertTrue(source.contains("Button(\"Recover audio\") { model.recoverAudioRoute() }"))
        XCTAssertTrue(source.contains("wilted-player-route-recovery"))
        XCTAssertTrue(source.contains("if model.audioRouteFault"))

        // The finished-with-it control keys on the retirement rather than the
        // written record. Keying it on `playbackCompleted` disabled the only
        // control that could retire an episode whose completion was written
        // without one, so the predicate is pinned here as well as tested.
        XCTAssertTrue(source.contains(
            "Button(model.playbackCompletionIsSettled ? \"Completed\" : \"Mark completed\")"))
        XCTAssertTrue(source.contains(
            ".disabled(!model.hasCurrentPlayback || model.playbackCompletionIsSettled)"))
        XCTAssertFalse(source.contains(".disabled(!model.hasCurrentPlayback || model.playbackCompleted)"))

        let modelRoot = root.deletingLastPathComponent().appendingPathComponent("WiltedMacModel.swift")
        let modelSource = try String(contentsOf: modelRoot)
        XCTAssertTrue(modelSource.contains("guard !audioRouteRecoveryAttempted else { return }"))
        XCTAssertTrue(modelSource.contains("audioRouteRecoveryAttempted = true"))
        XCTAssertTrue(modelSource.contains("self.audioRouteFault = true"))
    }

    /// The rail opens a detail presentation rather than growing a short pane
    /// under its controls. Both forms must render through the same content
    /// implementation, or their transport affordances will drift apart.
    func testFullWindowPlayerPresentationContracts() throws {
        XCTAssertEqual(
            WiltedMacPlayerSection.allCases.map(\.expandedAccessibilityIdentifier),
            [
                "wilted-player-transcript-expanded",
                "wilted-player-notes-expanded"
            ]
        )

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let player = try XCTUnwrap(source.range(of: "private struct WiltedMacPlayerContent")?.lowerBound)
        let playerSource = source[player...]

        XCTAssertTrue(source.contains("WiltedMacFullWindowPlayer("))
        XCTAssertTrue(source.contains("wilted-player-full-window"))
        XCTAssertTrue(source.contains("wilted-player-collapse"))
        XCTAssertTrue(source.contains("wilted-player-item-title"))
        XCTAssertTrue(source.contains("WiltedMacPlayerContent("))
        XCTAssertFalse(playerSource.contains("maxHeight: 170"))
        XCTAssertTrue(playerSource.contains("maxHeight: .infinity"))
        // Menu owns its compact player inside the destination, so it stays
        // live while the full-window presentation is set; every other
        // destination is still made unavailable behind the overlay, which is
        // what keeps duplicate live controls out of the accessibility tree.
        XCTAssertTrue(source.contains(
            ".allowsHitTesting(playerPresentation == nil || model.selectedNavigation == .menu)"))
        XCTAssertTrue(source.contains(
            ".accessibilityHidden(playerPresentation != nil && model.selectedNavigation != .menu)"))
        XCTAssertTrue(source.contains(
            ".disabled(playerPresentation != nil && model.selectedNavigation != .menu)"))
        // The sidebar no longer clears the presentation itself: every
        // navigation change is retired by the detail's onChange, while
        // collapsing keeps its own clear.
        XCTAssertTrue(source.contains("playerFocusRequest = nil\n                            model.selectedNavigation = destination"))
        XCTAssertTrue(source.contains(".onChange(of: model.selectedNavigation) {"))
        XCTAssertTrue(source.contains("playerPresentation = nil\n                            playerFocusRequest = section"))
        XCTAssertTrue(source.contains("case .menu:"))
        XCTAssertTrue(source.contains("WiltedMacMenuView("))
        XCTAssertTrue(source.contains("presentation: $playerPresentation"))
        XCTAssertTrue(source.contains("presentation: $presentation"))
        XCTAssertTrue(source.contains("wilted-mac-menu-detail"))
        XCTAssertTrue(source.contains(".draggable(episode.id)"))
        XCTAssertTrue(source.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(source.contains("Prepare all now (\\(model.menuPreparableEpisodes.count))"))
        XCTAssertTrue(source.contains("\"Needs preparation\""))
        XCTAssertTrue(source.contains("Label(\"Group by: \\(model.menuGrouping.rawValue)\""))
        XCTAssertTrue(source.contains("Label(\"Sort by: \\(model.menuSort.displayName)\""))
        XCTAssertTrue(source.contains("wilted-menu-grouping"))
        XCTAssertFalse(source.contains("Picker(\"Sort order\""),
                       "the Larder sort menu must not nest a Picker submenu")
        XCTAssertTrue(source.contains("model.menuSort = option"),
                      "each sort order must be a directly clickable menu action")
        XCTAssertTrue(source.contains("Button {\n                            model.menuSort = option"))
        XCTAssertTrue(source.contains("wilted-player-share"))
        XCTAssertTrue(source.contains("if let shareURL = model.currentPlaybackShareURL"))
        XCTAssertTrue(source.contains("else if let shareText = model.currentPlaybackShareText"))
        XCTAssertTrue(source.contains(".opacity(dropTargetID == episode.id ? 1 : 0)"))
        let menuRowStart = try XCTUnwrap(source.range(of: "private func menuRow")?.lowerBound)
        let menuRowEnd = try XCTUnwrap(source.range(
            of: "@ViewBuilder private func nextStepControl", range: menuRowStart..<source.endIndex
        )?.lowerBound)
        XCTAssertFalse(source[menuRowStart..<menuRowEnd].contains(
            "WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)"
        ))
        XCTAssertTrue(source.contains("model.menuEpisodes(in: .playable)"))
        XCTAssertTrue(source.contains("model.menuPreparableEpisodes"))
        XCTAssertTrue(source.contains(".disabled(model.isSearchingMenu)"))
        XCTAssertTrue(source.contains("model.prepareAllDownloadedMenuEpisodes()"))
        XCTAssertTrue(source.contains("wilted-menu-prepare-all"))
        XCTAssertFalse(source.contains("expansionButton(\"Up Next\""))
    }

    func testBulkActionsBecomeTheirProgressWhileRowsAreInFlight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let start = try XCTUnwrap(source.range(of: "private func bulkAction("))
        let end = try XCTUnwrap(source.range(
            of: "private func ", range: start.upperBound..<source.endIndex
        )?.lowerBound)
        let bulkAction = source[start.lowerBound..<end]

        XCTAssertTrue(bulkAction.contains("ProgressView()"))
        XCTAssertTrue(bulkAction.contains("\"\\(identifier)-progress\""))
        XCTAssertTrue(bulkAction.contains("inFlight.isEmpty"))
        XCTAssertTrue(bulkAction.contains(".disabled(model.isSearchingMenu)"))
        // Every call site pairs an in-flight set with the actionable set of the same kind,
        // however many call sites there are.
        let compact = source.filter { !$0.isWhitespace }
        for (actionable, inFlight) in [
            ("model.menuDownloadableEpisodes", "model.menuDownloadsInFlight"),
            ("model.menuPreparableEpisodes", "model.menuPreparationsInFlight"),
        ] {
            let uses = compact.components(separatedBy: "inFlight:\(inFlight)").count - 1
            let paired = compact.components(separatedBy: "actionable:\(actionable),inFlight:\(inFlight)").count - 1
            XCTAssertGreaterThan(uses, 0, inFlight)
            XCTAssertEqual(paired, uses, inFlight)
        }
        // The button is its own branch, not the else of the progress branch, so new
        // arrivals can still be started while earlier rows run.
        XCTAssertFalse(bulkAction.contains("} else if !actionable.isEmpty"))
        XCTAssertTrue(source.contains("inFlightVerb: \"Downloading\""))
        XCTAssertTrue(source.contains("inFlightVerb: \"Preparing\""))
        XCTAssertFalse(source.contains("Button(\"Download all new ("))
    }

    /// Which cue carries a speaker name, and what its spoken label says, are
    /// unit-tested in `WiltedMacModelTests`. This pins the wiring that puts
    /// that label on each transcript row, which the Mac UI suite used to prove
    /// by reading the live tree (W-INV-012 moved it here).
    func testTranscriptRowsSpeakTheSpeakerExactlyWhereTheHeadingIsDrawn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/WiltedSurfaces.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(source.contains("let headings = speakerHeadingCueIDs"))
        XCTAssertTrue(source.contains("case .cue(let cue): line(cue, showsSpeaker: headings.contains(cue.id))"))
        XCTAssertTrue(source.contains(".accessibilityLabel(spokenLabel(cue, showsSpeaker: showsSpeaker))"))
    }

    func testFeedsTitleOpensShowNotesWithTheSameTwoAnswers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let start = try XCTUnwrap(source.range(of: "struct WiltedMacFeedsEpisodeRow")?.lowerBound)
        // The struct ends at its own column-zero closing brace, so nothing
        // declared after it can satisfy an assertion meant for the row.
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start..<source.endIndex)?.upperBound)
        let row = source[start..<end]

        XCTAssertTrue(row.contains(".popover(isPresented: $isShowingNotes"))
        XCTAssertTrue(row.contains("WiltedShowNotes.linked("))
        XCTAssertTrue(row.contains("wilted-feeds-show-notes-\\(episode.id)"))
        XCTAssertTrue(row.contains("This episode's feed did not include show notes."))
        XCTAssertTrue(row.contains("wilted-feeds-decide-"))
        XCTAssertEqual(row.components(separatedBy: "ForEach(WiltedMacFeedsAction.allCases)").count - 1, 2)
        XCTAssertFalse(source.contains("private func feedsEpisodeRow"))
    }

    func testAutomationSettingsPresentationFollowsThePipelineAndOnlyShowsLiveControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let start = try XCTUnwrap(source.range(of: "private var automationCard")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private var syncCard", range: start..<source.endIndex)?.lowerBound)
        let card = source[start..<end]

        let feeds = try XCTUnwrap(card.range(of: "automationSectionTitle(\"Feeds\")")?.lowerBound)
        let processing = try XCTUnwrap(card.range(of: "automationSectionTitle(\"Processing\")")?.lowerBound)
        XCTAssertLessThan(feeds, processing)
        XCTAssertFalse(card.contains("wilted-automation-download-policy"))
        XCTAssertTrue(card.contains("wilted-automation-feeds-admission-policy"))
        XCTAssertTrue(card.contains("wilted-automation-refresh-policy"))
        XCTAssertTrue(card.contains("wilted-automation-processing-policy"))
        XCTAssertTrue(card.contains("wilted-automation-transcript-policy"))
        XCTAssertTrue(card.contains("wilted-automation-remove-ads"))
        // The notice is conditional, so the pane only says the pair is
        // unworkable while it is actually selected.
        XCTAssertTrue(card.contains("wilted-automation-transcript-conflict"))
        XCTAssertTrue(card.contains("if model.automationSettings.transcriptPolicyBlocksAdRemoval"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-start"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-end"))
        XCTAssertTrue(card.contains("Uses local time. The window may continue overnight."))
        XCTAssertTrue(card.contains("if isOffPeakProcessing"))
        XCTAssertTrue(card.contains("value: model.automationStatus.settingsStatusText"))
        XCTAssertTrue(card.contains("if model.automationStatus.isCancellable"))
        XCTAssertTrue(card.contains("wilted-automation-status"))
        XCTAssertTrue(card.contains("wilted-automation-stop"))
        XCTAssertTrue(card.contains("model.updateAutomationSettings"))
        XCTAssertFalse(card.contains("UserDefaults"), "Settings must reuse the model's validated persistence")
    }

    func testSettingsOffersTheRemovedAdChime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        let removeAds = try XCTUnwrap(source.range(of: "wilted-automation-remove-ads")?.lowerBound)
        let marker = try XCTUnwrap(source.range(of: "wilted-automation-ad-marker")?.lowerBound)
        XCTAssertTrue(source.contains("Toggle(\"Chime where an ad was removed\""))
        XCTAssertLessThan(removeAds, marker)
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

    // The removed-episodes card and its rows were deleted with the Larder in
    // Phase 0b; the accessibility-containment assertion that lived here is
    // waiting on Task 2.4 to decide where restore lives. Reinstate it against
    // that surface rather than reconstructing the old one.

    /// The producer window has no Downloads destination, so its copy must not
    /// send the reader to one. This was shipped: the Mac empty player told the
    /// reader to visit Downloads, and no pixel baseline could catch it because
    /// the Mac baselines always render the player, never the empty state.
    func testProducerCopyNamesOnlyProducerDestinations() {
        let producerDestinations = WiltedMacNavigation.allCases
        XCTAssertEqual(producerDestinations.map(\.title), ["Larder", "Feeds", "Settings"])

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

private struct URLRoutingPodcastFeedLoader: PodcastFeedLoading {
    let documents: [URL: Data]

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        guard let body = documents[url] else { throw URLError(.cannotConnectToHost) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
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
