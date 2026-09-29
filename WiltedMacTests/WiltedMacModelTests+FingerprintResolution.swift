import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Fingerprint resolution off the launch path (Task 3.1)

    /// Polls until `condition` holds, so a test can observe a bootstrap that is
    /// deliberately parked mid-step rather than racing it with a fixed sleep.
    private func awaitCondition(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held within \(timeout)s")
    }

    func testNoCallerForcesTheSourceTreeHashOnTheLaunchPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacApp.swift"))

        // `semanticFingerprintResolution` is a lazy static let that memory-maps
        // the worker and hashes two Python source trees. Whoever touches it
        // first pays for it; in `init` that was the main thread, before the
        // first frame.
        XCTAssertFalse(app.contains("PodcastPreparationPipeline.semanticFingerprintResolution"),
                       "the composition root must not force resolution during init")
        XCTAssertTrue(app.contains("pipelineFingerprintResolutionForLaunch"),
                      "the app must hand the model a resolver, not a resolved value")

        let model = try WiltedMacSource.model(root: root)
        XCTAssertTrue(model.contains("await pipelineFingerprintResolution()"),
                      "the model must await resolution rather than read a stored value")
    }

    func testHostedTestAppResolvesNoFingerprintAtAll() async {
        let hosted = WiltedMacApp.pipelineFingerprintResolutionForLaunch(hostsTests: true)
        let resolved = await hosted()
        XCTAssertNil(resolved, "a hosted test run must not migrate the owner's store")
    }

    func testTheReadoutNamesFingerprintingWhileResolutionIsStillInFlight() async throws {
        let directory = temporaryDirectory("fingerprint-in-flight")
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = FingerprintGate()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await released.wait(); return "build-fingerprint" },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()

        // The step must be announced before resolution returns, not after.
        try await awaitCondition { steps.contains(.checkingPreparationFingerprint) }
        XCTAssertFalse(steps.contains(.closingInterruptedRuns),
                       "bootstrap must still be waiting on the fingerprint")
        await released.open()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
    }

    func testBootstrapAwaitsAResolvedFingerprintBeforeInvalidating() async throws {
        let directory = temporaryDirectory("fingerprint-await")
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = FingerprintGate()
        let invalidated = FingerprintRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await released.wait(); return "resolved-fingerprint" },
            staleInvalidationOverride: { _, fingerprint in
                await invalidated.record(fingerprint)
                return PodcastPreparationInvalidationResult()
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        try await awaitCondition { model.startupState.loadingStep == .checkingPreparationFingerprint }
        let beforeRelease = await invalidated.values
        XCTAssertEqual(beforeRelease, [], "invalidation ran before the fingerprint resolved")
        await released.open()
        await model.waitForStoreBootstrap()

        let afterRelease = await invalidated.values
        XCTAssertEqual(afterRelease, ["resolved-fingerprint"],
                       "invalidation must see the resolved value, exactly once")
    }

    func testAFailedResolutionSkipsInvalidationAndNeverPassesTheSentinel() async throws {
        let directory = temporaryDirectory("fingerprint-failed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidated = FingerprintRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { nil },
            staleInvalidationOverride: { _, fingerprint in
                await invalidated.record(fingerprint)
                return PodcastPreparationInvalidationResult()
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let attempted = await invalidated.values
        XCTAssertEqual(attempted, [],
                       "a failed resolution must invalidate nothing, not compare the sentinel")
        XCTAssertEqual(model.startupState, .ready,
                       "an unresolved fingerprint is not a startup failure")
    }

    func testNoDurableWriteCarriesTheUnresolvedSentinel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pipeline = try WiltedMacSource.pipeline(root: root)
        // `semanticFingerprint` is the sentinel-bearing value. Every stamping
        // site must take the optional resolution and omit the field instead:
        // a stored `-unresolved` becomes false provenance once a real
        // fingerprint resolves, and reads as drift that invalidates good work.
        XCTAssertFalse(pipeline.contains("Self.semanticFingerprint,"),
                       "a stamping site still passes the sentinel-bearing value")
        XCTAssertFalse(pipeline.contains("Self.semanticFingerprint)"),
                       "a stamping site still passes the sentinel-bearing value")
        XCTAssertFalse(pipeline.contains("\"pipelineFingerprint\": Self.semanticFingerprint"),
                       "the worker request still carries the sentinel")

        let model = try WiltedMacSource.model(root: root)
        XCTAssertFalse(model.contains("?? PodcastPreparationPipeline.semanticFingerprint\n"),
                       "the recovery checkpoint still falls back to the sentinel")
        XCTAssertTrue(model.contains("WiltedMacUnresolvedFingerprint"),
                      "the recovery checkpoint must withhold the marker instead")
    }

    func testTheResolvedFingerprintEqualsTheSynchronousPathsValue() async {
        let asynchronous = await PodcastPreparationPipeline.resolveSemanticFingerprintOffMainPath()
        XCTAssertEqual(asynchronous, PodcastPreparationPipeline.semanticFingerprintResolution,
                       "deferring the work must not change the value it produces")
    }

    /// One downloaded, prepared episode with its media on disk and a store,
    /// for the skip tests.
    private func skipFixture(
        _ suffix: String
    ) async throws -> (directory: URL, model: WiltedMacModel, episodeID: ItemID, mediaURL: URL) {
        let directory = temporaryDirectory("skip-\(suffix)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/skip-\(suffix).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/skip-\(suffix).mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "skip-\(suffix)", enclosureURL: enclosure
        )
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Skip Show", createdAt: created
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        try await Self.addReadyEpisode(
            episodeID, guid: "skip-\(suffix)", feedID: feedID, feedURL: feedURL,
            enclosureURL: enclosure, publishedAt: Date(timeIntervalSince1970: 1_600_000_000),
            directory: directory, store: store, created: created
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store },
            // No feed can be reached, so every recovery this test sees has to
            // be local.
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (directory, model, episodeID, directory.appendingPathComponent("skip-\(suffix).m4a"))
    }

    /// Skipping a started episode marks it finished and leaves every artifact
    /// in place, the reversible exclusion the Menu mockup names.
    func testSkippingAStartedEpisodeMarksItPlayedAndKeepsItsMedia() async throws {
        let fixture = try await skipFixture("started")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        fixture.model.installPlaybackStateForTesting(
            episode: episode, isPlaying: false, position: 120, duration: 12
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path))

        fixture.model.skipEpisode(episode)
        try await settle(fixture.model)
        await fixture.model.waitForPodcastOperations()

        let skipped = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertTrue(fixture.model.isEpisodeFinished(skipped),
                      "a skipped episode is finished, so the Menu row cannot offer Play again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path),
                      "skip must not delete the media the undo needs")
        XCTAssertTrue(fixture.model.dismissedEpisodes.isEmpty, "skip is an exclusion, not a dismissal")
        XCTAssertEqual(fixture.model.undoableSkip?.id, fixture.episodeID.rawValue)
    }

    /// Completing a started Larder row must retire it immediately, otherwise
    /// Feeds mistakes the completed episode for a new active row. Undo clears
    /// that completion and makes the same row active again without a feed read.
    func testCompletingLarderRowRetiresItFromFeedsAndUndoRestoresIt() async throws {
        let fixture = try await skipFixture("retired-feeds")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        fixture.model.installPlaybackStateForTesting(
            episode: episode, isPlaying: false, position: 120, duration: 12
        )
        fixture.model.skipEpisode(episode)
        try await settle(fixture.model)
        await fixture.model.waitForPodcastOperations()

        let store = try LocalLibraryStore(url: fixture.directory.appendingPathComponent("library.sqlite"))
        let skippedRemovalKind = try await store.removalKind(for: fixture.episodeID)
        let skippedListening = try await store.listeningState(for: fixture.episodeID)
        XCTAssertEqual(skippedRemovalKind, .retired)
        XCTAssertNotNil(skippedListening?.completedAt)
        XCTAssertFalse(fixture.model.feedsEpisodes.contains { $0.id == episode.id },
                       "a completed Larder row must not remain new in Feeds")

        let skipped = try XCTUnwrap(fixture.model.episodes.first { $0.id == episode.id })
        fixture.model.undoSkipEpisode(skipped)
        try await settle(fixture.model)
        await fixture.model.waitForPlaybackOperationForTesting()

        let restoredRemovalKind = try await store.removalKind(for: fixture.episodeID)
        let restoredListening = try await store.listeningState(for: fixture.episodeID)
        XCTAssertNil(restoredRemovalKind)
        XCTAssertNil(restoredListening?.completedAt)
        XCTAssertTrue(fixture.model.podcastQueueIDs.contains(episode.id),
                      "Undo resumes local playback, so the restored episode belongs in Larder rather than Feeds")
    }

    /// A skip on an episode that was never started changes nothing about it.
    func testSkippingANeverStartedEpisodeChangesNothing() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let episode = WiltedMacEpisode(
            id: "skip-untouched", title: "Untouched", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed
        )
        model.installEpisodeForTesting(episode)

        model.skipEpisode(episode)

        XCTAssertNil(model.undoableSkip)
        XCTAssertEqual(model.podcastOperationMessage, "Untouched was not started, so nothing was marked completed.")
        guard let stored = model.episodes.first(where: { $0.id == episode.id }) else {
            return XCTFail("the skipped row must stay exactly where it was")
        }
        XCTAssertFalse(stored.isPlayed, "nothing may be marked finished")
        XCTAssertNil(stored.retiredAt, "nothing may be retired")
        XCTAssertEqual(stored.downloadState, .completed)
    }

    /// Undo Skip restores the episode and plays it from the media already on
    /// disk; no feed is reachable, so a network-dependent restore would fail.
    func testUndoSkipRestoresPlaybackFromLocalMediaWithoutNetwork() async throws {
        let fixture = try await skipFixture("undo")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        fixture.model.installPlaybackStateForTesting(
            episode: episode, isPlaying: false, position: 120, duration: 12
        )

        fixture.model.skipEpisode(episode)
        try await settle(fixture.model)
        let skipped = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertTrue(skipped.isPlayed)

        fixture.model.undoSkipEpisode(skipped)
        try await settle(fixture.model)
        await fixture.model.waitForPlaybackOperationForTesting()

        XCTAssertNil(fixture.model.undoableSkip)
        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertFalse(restored.isPlayed, "undo clears the listening record it wrote")
        XCTAssertEqual(fixture.model.currentPodcastEpisodeID, fixture.episodeID.rawValue,
                       "the episode plays again from local media")
        XCTAssertNil(fixture.model.playbackError)
    }

    func testTheSkipButtonCallsTheReversibleExclusionNotRemoval() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        XCTAssertTrue(source.contains("model.skipFeedEpisode("),
                      "Feeds' Skip must call the non-destructive exclusion, not removal")
        XCTAssertFalse(source.contains("model.removeEpisode("),
                       "the destructive path must not stay on any row")
        XCTAssertTrue(source.contains("wilted-podcast-undo-skip"), "and its offline undo must remain offered")
    }

    /// 2.4: a Feeds skip is reversible from the same page with no feed check,
    /// and the row returns to the set Feeds renders.
    func testASkippedFeedEpisodeRestoresToFeedsFromFeeds() async throws {
        let fixture = try await skipFixture("feeds-restore")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try LocalLibraryStore(url: fixture.directory.appendingPathComponent("library.sqlite"))
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertTrue(fixture.model.feedsEpisodes.contains { $0.id == episode.id })

        fixture.model.skipFeedEpisode(episode)
        await waitForFeedDecisionWriters(fixture.model)
        let skipped = try XCTUnwrap(fixture.model.skippedFeedEpisodes.first { $0.id == episode.id })
        let skippedRemovalKind = try await store.removalKind(for: fixture.episodeID)
        XCTAssertNotNil(skipped.retiredAt)
        XCTAssertEqual(skippedRemovalKind, .retired)
        XCTAssertFalse(fixture.model.feedsEpisodes.contains { $0.id == episode.id })

        fixture.model.restoreSkippedFeedEpisode(skipped)
        await waitForFeedDecisionWriters(fixture.model)

        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == episode.id })
        let restoredRemovalKind = try await store.removalKind(for: fixture.episodeID)
        XCTAssertNil(restored.retiredAt, "restore clears the retirement")
        XCTAssertNil(restoredRemovalKind, "restore clears the durable retirement")
        XCTAssertFalse(restored.isPlayed, "restore does not write a completion record")
        XCTAssertTrue(fixture.model.feedsEpisodes.contains { $0.id == episode.id },
                      "the row returns to the set Feeds renders")
        XCTAssertEqual(fixture.model.podcastOperationMessage, "Restored 1 episode.")
    }

    /// 2.4: Feeds renders a restore control for skipped and removed rows, with
    /// stable identifiers.
    func testFeedsRendersRestoreControlsForSkippedAndRemovedEpisodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("wilted-feeds-restore-skipped-\\(episode.id)"))
        XCTAssertTrue(view.contains("wilted-feeds-restore-removed-\\(dismissal.id)"))
        XCTAssertTrue(view.contains("model.restoreSkippedFeedEpisode(episode)"))
        XCTAssertTrue(view.contains("model.restoreEpisode(dismissal)"))
        XCTAssertTrue(view.contains("model.skippedFeedEpisodes"))
        XCTAssertTrue(view.contains("model.dismissedEpisodes"))
        XCTAssertTrue(view.contains("wilted-feeds-restorable"))
        XCTAssertTrue(view.contains("@State private var isOffListExpanded = false"))
        XCTAssertTrue(view.contains("wilted-feeds-off-list-toggle"))
        XCTAssertTrue(view.contains("if isOffListExpanded"))
    }

    /// Task 4.5: retirement and dismissal are one idea expressed two ways, so
    /// restoring either must land on the same store operation and leave the
    /// same durable state -- `removalKind` cleared, read back from the store
    /// itself, not inferred from the in-memory projection. One episode is
    /// retired (Feeds' Skip), the other dismissed (Menu's Remove), each
    /// restored through its own surface control.
    func testRetiredAndDismissedEpisodesBothRestoreThroughTheSameStoreOperation() async throws {
        let directory = temporaryDirectory("unified-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/unified-restore.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Unified Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let retiredURL = URL(string: "https://cdn.example.test/unified-retired.mp3")!
        let retiredID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "retired", enclosureURL: retiredURL)
        let dismissedURL = URL(string: "https://cdn.example.test/unified-dismissed.mp3")!
        let dismissedID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "dismissed", enclosureURL: dismissedURL)
        try await store.save(episode: try PodcastEpisode(
            itemID: retiredID, feedID: feedID, feedURL: feedURL, rssGUID: "retired", title: "Retired episode",
            enclosureURL: retiredURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        ))
        try await store.save(episode: try PodcastEpisode(
            itemID: dismissedID, feedID: feedID, feedURL: feedURL, rssGUID: "dismissed", title: "Dismissed episode",
            enclosureURL: dismissedURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        ))
        let retired = try await store.retireEpisode(retiredID)
        XCTAssertTrue(retired)
        let dismissed = try await store.dismissPodcastEpisode(dismissedID)
        XCTAssertTrue(dismissed)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store },
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let skipped = try XCTUnwrap(model.skippedFeedEpisodes.first { $0.id == retiredID.rawValue })
        let removed = try XCTUnwrap(model.dismissedEpisodes.first { $0.id == dismissedID.rawValue })

        model.restoreSkippedFeedEpisode(skipped)
        await waitForFeedDecisionWriters(model)
        model.restoreEpisode(removed)
        await model.waitForPodcastOperations()

        // Read the durable outcome back from the store, not the in-memory
        // projection: both restores must clear the same column the same way.
        let retiredKind = try await store.removalKind(for: retiredID)
        let dismissedKind = try await store.removalKind(for: dismissedID)
        XCTAssertNil(retiredKind, "restoring the retired episode must clear removalKind")
        XCTAssertNil(dismissedKind, "restoring the dismissed episode must clear removalKind through the same operation")
        XCTAssertTrue(model.skippedFeedEpisodes.isEmpty)
        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
    }

}
