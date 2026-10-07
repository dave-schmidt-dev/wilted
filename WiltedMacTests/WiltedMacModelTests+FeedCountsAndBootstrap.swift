import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Phase 2 — feed counts, completion, Prep, bootstrap, skip

    /// A feed's "in Larder" count is the set the shelf draws, not every record
    /// the snapshot holds: retired and hidden episodes are not on the shelf.
    func testFeedCountCountsOnlyTheRowsFeedsRenders() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let feedID = "feed-alpha"
        let visible = WiltedMacEpisode(
            id: "feed-visible", title: "Visible", feedTitle: "Alpha", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, feedID: feedID
        )
        var retired = WiltedMacEpisode(
            id: "feed-retired", title: "Retired", feedTitle: "Alpha", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, feedID: feedID
        )
        retired.retiredAt = Date(timeIntervalSince1970: 1_700_000_500)
        let hidden = WiltedMacEpisode(
            id: "feed-hidden", title: "Hidden", feedTitle: "Alpha", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_002),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, feedID: feedID
        )
        let otherFeed = WiltedMacEpisode(
            id: "feed-other", title: "Other", feedTitle: "Beta", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_003),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, feedID: "feed-beta"
        )
        model.installEpisodeForTesting(visible)
        model.installEpisodeForTesting(retired)
        model.installEpisodeForTesting(hidden)
        model.installEpisodeForTesting(otherFeed)
        // The production route that populates the optimistic hide set. Its
        // store round-trip has nothing to talk to here and is irrelevant to
        // the count; the hide itself lands synchronously.
        model.removeEpisode(hidden)

        let rendered = Set(model.larderVisibleEpisodes.filter { $0.feedID == feedID }.map(\.id))
        XCTAssertEqual(rendered, Set([visible.id]))
        XCTAssertEqual(model.larderEpisodeCount(forFeedID: feedID), rendered.count,
                       "the feed row's count must equal the rows the app renders for it")
        XCTAssertEqual(model.larderEpisodeCount(forFeedID: "feed-beta"), 1)
        XCTAssertEqual(model.larderEpisodeCount(forFeedID: "feed-missing"), 0)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("model.larderEpisodeCount(forFeedID: subscription.id)"),
                      "the Feeds row must render that count, not the raw snapshot one")
    }

    func testLarderInProgressIndicatorUsesLiveOrSavedPositionAndExcludesFinishedRows() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func episode(_ id: String, position: TimeInterval, played: Bool = false) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 100, playbackSeconds: position, isPlayed: played,
                downloadState: .completed, preparationState: .prepared(summary: "Ready")
            )
        }

        let saved = episode("saved", position: 12)
        let fresh = episode("fresh", position: 0)
        let nearFinished = episode("near-finished", position: 99)
        XCTAssertTrue(model.isEpisodeInProgress(saved))
        XCTAssertFalse(model.isEpisodeInProgress(fresh))
        XCTAssertTrue(model.isEpisodeInProgress(nearFinished),
                      "a near-end position remains resumable until a durable completion exists")

        model.installPlaybackStateForTesting(
            episode: episode("live", position: 0), isPlaying: true, position: 0, duration: 100
        )
        XCTAssertFalse(model.isEpisodeInProgress(episode("live", position: 0)),
                       "a current row at zero seconds is not yet in progress")
        model.installPlaybackStateForTesting(
            episode: episode("live", position: 0), isPlaying: true, position: 12, duration: 100
        )
        XCTAssertTrue(model.isEpisodeInProgress(episode("live", position: 0)),
                      "the live playhead must override the stale saved row position")

        let stalePodcastMarker = episode("stale-podcast-marker", position: 0)
        model.installEpisodeForTesting(stalePodcastMarker)
        model.installArticlePlaybackWithPodcastMarkerForTesting(
            episodeID: stalePodcastMarker.id, position: 12, duration: 100
        )
        XCTAssertFalse(model.isEpisodeInProgress(stalePodcastMarker),
                       "article playback must not lend its live position to a podcast row")
    }

    func testCurrentPlaybackShareUsesCanonicalOrEpisodePageWithTextFallback() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let articleURL = URL(string: "https://example.test/article")!
        let article = WiltedMacArticle(
            id: "share-article", title: "An article", source: "A source", url: articleURL,
            isReady: true, durationSeconds: 100, playbackSeconds: 12
        )
        model.installPlaybackStateForTesting(article: article, isPlaying: false, position: 12, duration: 100)
        XCTAssertEqual(model.currentPlaybackShareURL, articleURL)

        let feedURL = URL(string: "https://example.test/show.xml")!
        let episode = WiltedMacEpisode(
            id: "share-episode", title: "An episode", feedTitle: "A show", summary: "",
            artworkURL: nil, releasedAt: Date(), durationSeconds: 100, playbackSeconds: 12,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"),
            feedURL: feedURL, episodeLink: URL(string: "https://example.test/show/episode-1")
        )
        model.installPlaybackStateForTesting(episode: episode, isPlaying: false, position: 12, duration: 100)
        XCTAssertEqual(model.currentPlaybackShareURL, URL(string: "https://example.test/show/episode-1"))
        XCTAssertNotEqual(model.currentPlaybackShareURL, feedURL, "the feed is never the episode's page")

        let fallback = WiltedMacEpisode(
            id: "fallback-episode", title: "An episode", feedTitle: "A show", summary: "",
            artworkURL: nil, releasedAt: Date(), durationSeconds: 100, playbackSeconds: 12,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"),
            feedURL: feedURL
        )
        model.installPlaybackStateForTesting(episode: fallback, isPlaying: false, position: 12, duration: 100)
        XCTAssertNil(model.currentPlaybackShareURL)
        XCTAssertEqual(model.currentPlaybackShareText, "An episode — A show")
    }

    /// The Larder row says Played only when the durable listening record says
    /// completed. Near-end progress is still a playable, explicit-completion row.
    func testPlayedHasOneDurableDefinitionForTheLarderRow() throws {
        let cases: [(position: TimeInterval, duration: TimeInterval?, isPlayed: Bool, finished: Bool)] = [
            (0, 100, true, true),       // finished by hand, never reached the end
            (96, 100, false, false),    // no durable completion at 96%
            (95, 100, false, false),    // no durable completion at the boundary
            (94.9, 100, false, false),
            (0, nil, false, false),
            (0, 0, false, false),
            (0, nil, true, true),       // a record with no duration is still finished
        ]
        for (position, duration, isPlayed, expected) in cases {
            XCTAssertEqual(
                WiltedMacModel.isFinished(isPlayed: isPlayed),
                expected,
                "position \(position), duration \(String(describing: duration)), played \(isPlayed)"
            )
        }

        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func episode(_ id: String, position: TimeInterval, played: Bool) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 100, playbackSeconds: position, isPlayed: played,
                downloadState: .completed, preparationState: .prepared(summary: "Ready")
            )
        }
        let handFinished = episode("finished-by-hand", position: 0, played: true)
        let stoppedShort = episode("stopped-short", position: 96, played: false)
        let stillGoing = episode("still-going", position: 50, played: false)
        let notStarted = episode("not-started", position: 0, played: false)
        for value in [handFinished, stoppedShort, stillGoing, notStarted] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        // The Larder row asks the model's one predicate before it offers Play.
        // A near-end row remains playable until the listening record exists.
        XCTAssertTrue(model.isEpisodeFinished(handFinished),
                      "finished by hand never reached the end")
        XCTAssertFalse(model.isEpisodeFinished(stoppedShort))
        XCTAssertFalse(model.isEpisodeFinished(stillGoing))
        XCTAssertFalse(model.isEpisodeFinished(notStarted))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try WiltedMacSource.model(root: root)
        XCTAssertTrue(modelSource.contains("Self.isFinished(isPlayed:"),
                      "the row's Played state reads the model's one definition")
        XCTAssertEqual(modelSource.components(separatedBy: "func isFinished").count - 1, 1,
                       "exactly one implementation of the finished predicate")
        let source = try WiltedMacSource.views(root: root)
        XCTAssertTrue(source.contains("model.isEpisodeFinished(episode)"),
                      "the Larder row must read the model's one definition")
        XCTAssertFalse(source.contains("0.95"), "the view must not infer Played from progress")
    }

    /// The retry message names the surface that holds the restore control:
    /// Feeds, not a retired destination.
    func testRetryForADismissedPrepRunPointsAtFeeds() async throws {
        let directory = temporaryDirectory("dismissed-prep-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/dismissed-retry.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosure = try XCTUnwrap(URL(string: "https://cdn.example.test/dismissed-retry.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "dismissed", enclosureURL: enclosure
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Dismissed Show", createdAt: created
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "dismissed",
            title: "Dismissed episode", enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
            createdAt: created
        ))
        try await store.dismissPodcastEpisode(episodeID)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.dismissedEpisodes.map(\.id), [episodeID.rawValue])

        let run = WiltedMacProcessorRun(
            id: "dismissed-run", itemID: episodeID.rawValue, isPodcast: true, title: "Dismissed episode",
            source: "Dismissed Show", stage: "failed", detail: "Failed", fraction: nil,
            outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(run)
        XCTAssertEqual(
            model.processorOperationMessage,
            "Restore Dismissed episode from Feeds before retrying preparation."
        )
        let message = model.processorOperationMessage ?? ""
        XCTAssertTrue(message.contains("Feeds"))
        XCTAssertFalse(message.contains("Removed"))
    }

    func testAStaleInvalidationFailureIsReportedApartFromAStoreOpenFailure() async throws {
        let directory = temporaryDirectory("stale-invalidation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprint: "current-fingerprint",
            staleInvalidationOverride: { _, _ in throw StartupTestError.expectedFailure },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        guard case let .failed(failure) = model.startupState else {
            return XCTFail("a failed stale-preparation pass must report itself")
        }
        XCTAssertEqual(failure.message, WiltedMacModel.staleInvalidationFailureMessage)
        XCTAssertNotEqual(
            failure.message,
            "Wilted could not open your larder. The existing library was left in place.",
            "the store opened cleanly; the failure is the invalidation pass"
        )
    }

    func testAStoreThatWillNotOpenKeepsItsPriorMessage() async throws {
        let directory = temporaryDirectory("store-open-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in throw StartupTestError.expectedFailure },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        guard case let .failed(failure) = model.startupState else {
            return XCTFail("a store that will not open must report itself")
        }
        XCTAssertEqual(
            failure.message,
            "Wilted could not open your larder. The existing library was left in place."
        )
    }

    func testStartupReadoutNamesEachAwaitedBootstrapStepInOrder() async throws {
        let directory = temporaryDirectory("startup-steps")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprint: "build-fingerprint",
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        // Counted recovery steps are progress inside the reconciliation phase:
        // they may appear, but only between reconcilingWork and loadingLibrary.
        func isRecovery(_ step: WiltedMacStartupStep) -> Bool {
            if case .recoveringWork = step { return true }
            return false
        }
        let named = steps.filter { !isRecovery($0) }
        XCTAssertEqual(named, [
            .openingStore,
            .updatingLibraryFormat,
            .retiringFinishedEpisodes,
            .checkingPreparationFingerprint,
            .closingInterruptedRuns,
            .reconcilingWork,
            .reclaimingStorage,
            .loadingLibrary,
            .restoringPlayback,
        ])
        let reconciling = try XCTUnwrap(steps.firstIndex(of: .reconcilingWork))
        let loading = try XCTUnwrap(steps.firstIndex(of: .loadingLibrary))
        for (index, step) in steps.enumerated() where isRecovery(step) {
            XCTAssertTrue(
                index > reconciling && index < loading,
                "a recovery step at position \(index) must sit between reconciliation (\(reconciling)) and loading (\(loading))"
            )
        }
        let labels = named.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "every awaited step renders one distinct string")
        XCTAssertEqual(model.startupState, .ready)
    }

    func testReclaimingStorageIsAnnouncedAfterReconcilingWorkAndBeforeLoadingLibrary() async throws {
        let directory = temporaryDirectory("reclaim-step-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprint: "build-fingerprint",
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let reconciling = try XCTUnwrap(steps.firstIndex(of: .reconcilingWork))
        let reclaiming = try XCTUnwrap(steps.firstIndex(of: .reclaimingStorage))
        let loading = try XCTUnwrap(steps.firstIndex(of: .loadingLibrary))
        XCTAssertTrue(reconciling < reclaiming, "the sweep is announced after work reconciliation")
        XCTAssertTrue(reclaiming < loading, "the sweep is announced before the library loads")
        XCTAssertEqual(model.startupState, .ready)
    }

    func testAThrowingStorageSweepStillReachesLoadingLibraryAndReady() async throws {
        let directory = temporaryDirectory("reclaim-throwing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            reclaimOverride: { _, _, _ in throw StartupTestError.expectedFailure },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready,
                       "a throwing sweep never blocks launch or fails startup")
        func isRecovery(_ step: WiltedMacStartupStep) -> Bool {
            if case .recoveringWork = step { return true }
            return false
        }
        let reachedLoading = steps.contains(.loadingLibrary)
        let recoveryLines = steps.filter(isRecovery)
        XCTAssertTrue(reachedLoading || !recoveryLines.isEmpty,
                      "loading is still announced, or the recovery line replaces it")
        let storageErrors = steps.flatMap { step -> [String] in
            guard case let .recoveringWork(_, _, _, errors) = step else { return [] }
            return errors.filter { $0.hasPrefix("storage: ") }
        }
        XCTAssertEqual(storageErrors.count, 1,
                       "the readout step list carries the storage error text exactly once")
    }

    func testTheLaunchSweepDeletesAnUnreferencedFileUnderPodcastAudioAndKeepsAReferencedOne() async throws {
        let directory = temporaryDirectory("launch-sweep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioDirectory = directory.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("PodcastAudio", isDirectory: true)
        let preparationDirectory = directory.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("preparation", isDirectory: true)
        for folder in [audioDirectory, preparationDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let orphanURL = audioDirectory.appendingPathComponent("orphan.mp3")
        let referencedURL = audioDirectory.appendingPathComponent("referenced.mp3")
        let preparationURL = preparationDirectory.appendingPathComponent("in-progress.wav")
        let payload = Data("audio-bytes".utf8)
        for url in [orphanURL, referencedURL, preparationURL] {
            try payload.write(to: url)
        }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try ItemID(rawValue: "sweep-referenced-episode")
        try await store.save(download: PodcastDownload(
            episodeID: episodeID, status: .completed,
            bytesReceived: Int64(payload.count), expectedByteCount: Int64(payload.count),
            localURL: referencedURL, contentHash: Self.sha256Hex(payload), updatedAt: Timestamp(Date())
        ))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "a file under PodcastAudio that no record names is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path),
                       "a file a saved download record names stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparationURL.path),
                      "the preparation work directory is never swept")
    }

    func testTheLaunchSweepExcludesTheCurrentPlaybackFile() async throws {
        let directory = temporaryDirectory("launch-sweep-exclusion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioDirectory = directory.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let currentURL = audioDirectory.appendingPathComponent("current.mp3")
        let payload = Data("current-episode-audio".utf8)
        try payload.write(to: currentURL)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try ItemID(rawValue: "sweep-current-episode")
        try await store.save(download: PodcastDownload(
            episodeID: episodeID, status: .completed,
            bytesReceived: Int64(payload.count), expectedByteCount: Int64(payload.count),
            localURL: currentURL, contentHash: Self.sha256Hex(payload), updatedAt: Timestamp(Date())
        ))
        try await store.replacePodcastQueue(PodcastQueueState(
            episodeIDs: [episodeID], currentEpisodeID: episodeID
        ))

        let recorder = ExcludedSetRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store },
            reclaimOverride: { store, directories, excluded in
                recorder.record(excluded)
                return try await store.sweepUnreferencedMedia(in: directories, excluding: excluded)
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        let excludedSets = recorder.sets
        XCTAssertEqual(excludedSets.count, 1, "the sweep runs once per launch")
        XCTAssertTrue(excludedSets.first?.contains(currentURL) ?? false,
                      "the queue's current episode file is excluded from the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path),
                      "the current playback file survives the launch sweep")
    }

    private static func sha256Hex(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testStartupLoadingRendersTheCurrentStepNotOneFixedSentence() throws {
        XCTAssertEqual(WiltedMacStartupStep.openingStore.label, "Opening your larder…")
        XCTAssertNotEqual(
            WiltedMacStartupStep.openingStore.label,
            WiltedMacStartupStep.loadingLibrary.label,
            "two phases must not render the same text"
        )
        XCTAssertEqual(
            WiltedMacStartupState.loading(attempt: 1, step: .closingInterruptedRuns).loadingStep,
            .closingInterruptedRuns
        )
        XCTAssertNil(WiltedMacStartupState.ready.loadingStep)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        XCTAssertTrue(source.contains("model.startupStepLabel"),
                      "the loading surface must render the step the model is on")
        XCTAssertFalse(source.contains("Opening and updating your larder"),
                       "the fixed sentence must be gone")
    }

}

/// Records the exclusion sets handed to an injected sweep. The seam is
/// `@Sendable`, so it cannot capture and mutate a local variable the way the
/// step observer does.
private final class ExcludedSetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSets: [Set<URL>] = []

    func record(_ set: Set<URL>) {
        lock.lock()
        recordedSets.append(set)
        lock.unlock()
    }

    var sets: [Set<URL>] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSets
    }
}
