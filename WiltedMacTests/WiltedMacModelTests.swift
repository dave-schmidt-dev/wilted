import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

private enum StartupTestError: Error {
    case expectedFailure
}

private actor BootstrapGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor StoreCapture {
    private(set) var store: LocalLibraryStore?
    func capture(_ store: LocalLibraryStore) { self.store = store }
}

private actor FailingBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        if attempts == 1 {
            let retainedDirectory = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).v5-test", isDirectory: true)
            try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
            try Data("retained-v5".utf8).write(to: retainedDirectory.appendingPathComponent(url.lastPathComponent))
        }
        throw StartupTestError.expectedFailure
    }
}

private actor SuccessfulBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        return try LocalLibraryStore(url: url)
    }
}

@MainActor
final class WiltedMacModelTests: XCTestCase {
    func testBootstrapPublishesOnlyDeviceLocalLedgerTotals() async throws {
        let directory = temporaryDirectory("lifetime-statistics")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                _ = try await store.recordLifetimeStatistic(
                    id: "audio-one", kind: .audioProcessed, seconds: 120
                )
                _ = try await store.recordLifetimeStatistic(
                    id: "speech-one", kind: .speechGenerated, seconds: 45
                )
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.lifetimeStatistics, LifetimeStatistics(
            audioProcessedSeconds: 120,
            speechGeneratedSeconds: 45
        ))
    }

    func testHostedTestAppNeverActivatesPipelineInvalidation() {
        XCTAssertNil(WiltedMacApp.pipelineFingerprintForLaunch(
            hostsTests: true, resolvedFingerprint: "live-pipeline"
        ))
        XCTAssertEqual(WiltedMacApp.pipelineFingerprintForLaunch(
            hostsTests: false, resolvedFingerprint: "live-pipeline"
        ), "live-pipeline")
    }

    func testLoadingIsObservableUntilBootstrapAndInitialRefreshComplete() async throws {
        let directory = temporaryDirectory("loading")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = BootstrapGate()
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/migrated-article"))
        let itemID = try ItemID.derive(from: articleURL)
        let article = try Article(
            itemID: itemID,
            canonicalURL: articleURL,
            title: "Migrated article",
            source: "Example",
            createdAt: Timestamp(Date())
        )
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                await gate.hold()
                let store = try LocalLibraryStore(url: url)
                try await store.save(article: article)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        XCTAssertEqual(model.startupState, .loading(attempt: 0, step: .openingStore))
        XCTAssertTrue(model.articles.isEmpty)
        model.startStoreBootstrap()
        await gate.waitUntilHeld()
        XCTAssertEqual(model.startupState, .loading(attempt: 1, step: .openingStore),
                       "the readout names the phase the bootstrap is waiting on")

        await gate.release()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Migrated article"])
    }

    func testFailureExposesRetainedV5ArtifactAndInjectedRecoveryAction() async throws {
        let directory = temporaryDirectory("failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        var presentedURL: URL?
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) },
            retainedArtifactPresenter: { presentedURL = $0 }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("A failed store bootstrap must not look like a ready empty larder")
        }
        let retainedURL = try XCTUnwrap(failure.retainedV5StoreURL)
        XCTAssertTrue(failure.detail?.contains("expectedFailure") == true)
        XCTAssertEqual(retainedURL.lastPathComponent, "library.sqlite")
        XCTAssertTrue(retainedURL.path.contains("library.sqlite.v5-test"))
        XCTAssertTrue(failure.canRetry)
        XCTAssertTrue(model.articles.isEmpty)

        model.presentRetainedV5Store()
        XCTAssertEqual(presentedURL, retainedURL)
    }

    func testRetryIsBoundedToOneRecoveryAttempt() async {
        let directory = temporaryDirectory("retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.retryStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("The second failure must remain a recovery state")
        }
        XCTAssertFalse(failure.canRetry)
        XCTAssertNil(failure.retainedV5StoreURL, "a retained copy from an earlier attempt is not this attempt's recovery artifact")
        XCTAssertTrue(failure.detail?.contains("expectedFailure") == true)
        model.retryStoreBootstrap()
        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testReadyModelDoesNotBootstrapAgainWhenRootTaskReappears() async {
        let directory = temporaryDirectory("ready-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = SuccessfulBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testFixtureModeRemainsImmediatelyUsable() {
        let directory = temporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )

        XCTAssertTrue(model.fixtureMode)
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Fixture article"])
    }

    func testStoreBootstrapReadmitsStaleKnownSourceFailureWithoutRedownloading() async throws {
        let directory = temporaryDirectory("pipeline-invalidation-bootstrap")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("source.mp3")
        let sourceBytes = Data("source-audio".utf8)
        try sourceBytes.write(to: audioURL)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/invalidation.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/invalidation.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "legacy-failure", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let sourceHash = "sha256:" + SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
        let preferences = WiltedMacTestPreferences.ephemeral()
        let obsoleteWindow = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: try XCTUnwrap(WiltedAutomationLocalTime(hour: 1, minute: 0)),
            end: try XCTUnwrap(WiltedAutomationLocalTime(hour: 2, minute: 0))
        ))
        WiltedMacModel.persistDeferredAutomaticPreparations([
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: episodeID.rawValue,
                processingPolicy: .offPeak(obsoleteWindow),
                policySnapshot: PodcastPreparationPolicySnapshot(
                    transcriptPolicy: .noLocalSTT, removeAds: false
                )
            )
        ], to: preferences)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Legacy feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "legacy-failure",
                    title: "Legacy failed episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let revision = try AudioRevision(
                    itemID: episodeID, revisionID: RevisionID(rawValue: "legacy-source"),
                    durationSeconds: 12, byteCount: 12, contentHash: sourceHash,
                    mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3
                )
                try await store.finalizePodcastDownload(
                    revision: revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed, bytesReceived: 12,
                        expectedByteCount: 12, localURL: audioURL, contentHash: sourceHash,
                        updatedAt: created
                    )
                )
                let requestID = PodcastPreparationPipeline.requestID(for: episodeID)
                let failure = try ProducerError(
                    code: .failed, message: "legacy pipeline failure", retryable: true,
                    stage: "podcast-preparation"
                )
                let evidence = try PreparationEvidence(
                    kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                    fields: [
                        "fingerprint": "podcast-preparation-v1",
                        "sourceRevisionID": revision.revisionID.rawValue,
                        "sourceHash": sourceHash
                    ]
                )
                try await store.record(preparation: PreparationJournalEntry(
                    id: requestID + "|terminal", itemID: episodeID, requestID: requestID,
                    status: try PreparationStatus(
                        stage: .failed, detail: failure.message, cancellable: false,
                        terminalResult: try PreparationTerminalResult(outcome: .failed, error: failure),
                        emittedAt: created, evidence: evidence
                    )
                ))
                return store
            }, pipelineFingerprint: "test-current",
            invalidationRules: [PodcastPreparationInvalidationRule(
                id: "test.blanket-drift", consequence: .resetPreparation, applies: { _ in true }
            )],
            preferences: preferences
        )
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: Date())
        let offPeakStart = try XCTUnwrap(WiltedAutomationLocalTime(hour: (currentHour + 2) % 24, minute: 0))
        let offPeakEnd = try XCTUnwrap(WiltedAutomationLocalTime(hour: (currentHour + 3) % 24, minute: 0))
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try XCTUnwrap(WiltedAutomationOffPeakWindow(
                start: offPeakStart, end: offPeakEnd
            ))),
            transcriptPolicy: .alwaysTranscribe, removeAds: true
        ))

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        XCTAssertEqual(episode.downloadState, .completed)
        XCTAssertEqual(episode.preparationState, .preparing(stage: WiltedMacModel.preparationQueuedStage))
        XCTAssertEqual(model.deferredAutomaticPreparations.map(\.episodeID), [episodeID.rawValue])
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.policySnapshot,
                       PodcastPreparationPolicySnapshot(transcriptPolicy: .alwaysTranscribe, removeAds: true),
                       "the current policy replaces the invalidated job's obsolete snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testAudioRouteRecoveryAutomaticallyAttemptsOnceThenExposesManualRetry() async throws {
        let directory = temporaryDirectory("audio-route-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = try XCTUnwrap(model.articles.first)
        model.openNowPlaying(for: article)
        try await settle(model)

        model.failNextAudioRouteRecoveryForTesting()
        model.reportAudioRouteFault("Playback is unavailable.")
        try await settle(model)

        XCTAssertTrue(model.audioRouteFault, "failed automatic recovery exposes manual retry")
        XCTAssertEqual(model.playbackError, "Audio route recovery failed.")

        model.reportAudioRouteFault("Playback is unavailable.")
        try await settle(model)
        XCTAssertTrue(model.audioRouteFault, "a repeated fault must not start another automatic retry")

        model.recoverAudioRoute()
        try await settle(model)
        XCTAssertFalse(model.audioRouteFault)
        XCTAssertNil(model.playbackError)
    }

    // MARK: - Real-wiring seams

    /// Proves the model's injected transport/validator factories reach a real
    /// `PodcastDownloadCoordinator` end to end -- store row, coordinator
    /// validation, media file on disk -- rather than exercising a parallel
    /// implementation that never touches the coordinator at all.
    func testDownloadEpisodeDrivesTheRealCoordinatorThroughAnInjectedTransport() async throws {
        let directory = temporaryDirectory("real-wiring-download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/real-wiring.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/real-wiring.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "real-wiring-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let body = Data("stub-audio-bytes".utf8)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Real wiring feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "real-wiring-1",
                    title: "Real wiring episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: {
                StubPodcastDownloadTransport(events: [
                    .response(.init(url: enclosureURL, statusCode: 200, mediaType: "audio/mpeg",
                                     expectedByteCount: Int64(body.count))),
                    .data(body)
                ])
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        model.downloadEpisode(episode)

        for _ in 0..<200 {
            if model.episodes.first(where: { $0.id == episodeID.rawValue })?.downloadState == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let downloaded = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        XCTAssertEqual(downloaded.downloadState, .completed)

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let revisions = try await store.revisions(for: episodeID)
        let revision = try XCTUnwrap(revisions.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: revision.mediaURL.path),
                      "the injected transport's bytes must land on disk through the real coordinator, not a fixture stand-in")
        XCTAssertEqual(try Data(contentsOf: revision.mediaURL), body)
    }

    /// Phase 7's bounded-admission gate: bootstrap recovery must serialize
    /// forced-redownload episodes rather than firing one download task per
    /// episode the instant they are discovered. Two episodes both carry a
    /// durable forced-redownload marker as if a prior launch's invalidation
    /// pass had already scheduled them; this proves this launch admits them
    /// one at a time.
    func testBootstrapRecoveryDownloadsAreSerializedNotFiredAllAtOnce() async throws {
        let directory = temporaryDirectory("bootstrap-recovery-serialized")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/bootstrap-recovery.xml"))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/bootstrap-recovery-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/bootstrap-recovery-2.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let firstID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "recovery-1", enclosureURL: firstEnclosure)
        let secondID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "recovery-2", enclosureURL: secondEnclosure)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstBody = Data("first-body".utf8)
        let secondBody = Data("second-body".utf8)

        @Sendable func forcedMarker(for episodeID: ItemID) throws -> PreparationJournalEntry {
            let requestID = LocalLibraryStore.forcedRedownloadRequestPrefix + episodeID.rawValue
            let error = try ProducerError(code: .invalidRequest, message: "needs a fresh download",
                                          retryable: true, stage: "pipeline-invalidation")
            let evidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
                "fingerprint": "old", "requiresRedownload": "true", "ruleID": "test-seeded-rule"
            ])
            let status = try PreparationStatus(
                stage: .failed, detail: error.message, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .failed, error: error),
                emittedAt: Timestamp(Date()), evidence: evidence
            )
            return PreparationJournalEntry(id: requestID + "|marker", itemID: episodeID, requestID: requestID, status: status)
        }

        let transport = ConcurrencyTrackingPodcastDownloadTransport(eventsByURL: [
            firstEnclosure: [
                .response(.init(url: firstEnclosure, statusCode: 200, mediaType: "audio/mpeg",
                                 expectedByteCount: Int64(firstBody.count))),
                .data(firstBody)
            ],
            secondEnclosure: [
                .response(.init(url: secondEnclosure, statusCode: 200, mediaType: "audio/mpeg",
                                 expectedByteCount: Int64(secondBody.count))),
                .data(secondBody)
            ]
        ])

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Recovery feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: firstID, feedID: feedID, feedURL: feedURL, rssGUID: "recovery-1",
                    title: "Recovery episode 1", publishedTime: created, enclosureURL: firstEnclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                try await store.save(episode: try PodcastEpisode(
                    itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "recovery-2",
                    title: "Recovery episode 2", publishedTime: Timestamp(created.date.addingTimeInterval(60)),
                    enclosureURL: secondEnclosure, enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                try await store.record(preparation: forcedMarker(for: firstID))
                try await store.record(preparation: forcedMarker(for: secondID))
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            pipelineFingerprint: "current-fp",
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForPodcastOperations()

        let observedInFlight = await transport.maxObservedInFlight
        XCTAssertEqual(observedInFlight, 1,
                       "bootstrap recovery must admit forced-redownload episodes one at a time, not task-per-ID")
        let first = try XCTUnwrap(model.episodes.first(where: { $0.id == firstID.rawValue }))
        let second = try XCTUnwrap(model.episodes.first(where: { $0.id == secondID.rawValue }))
        XCTAssertEqual(first.downloadState, .completed)
        XCTAssertEqual(second.downloadState, .completed)
    }

    /// A real transfer failure through `downloadEpisode` must reach
    /// `waitForPodcastOperations()` without escaping it: that function's job is
    /// to let everything in flight settle before proceeding (e.g. before
    /// quitting), not to propagate one episode's failure to whoever is waiting
    /// on the whole set.
    func testWaitForPodcastOperationsSwallowsAFailedDownload() async throws {
        let directory = temporaryDirectory("failed-download-swallow")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/swallow.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/swallow.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "swallow-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Swallow feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "swallow-1",
                    title: "Swallow episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: {
                FailingPodcastDownloadTransport(enclosureURL: enclosureURL, statusCode: 503)
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        model.downloadEpisode(episode)
        // The failure is real: `waitForPodcastOperations` completing at all
        // (its signature carries no `throws`) is the proof the `try?` swallow
        // inside it is doing its job rather than this call hanging or trapping.
        await model.waitForPodcastOperations()

        let settled = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        XCTAssertEqual(settled.downloadState, .failed)

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let download = try await store.download(for: episodeID)
        XCTAssertEqual(download?.status, .failed)
        XCTAssertEqual(download?.failureKind, .retryable, "a 503 is `.invalidResponse`, classified retryable")
    }

    /// The Phase 3 gate's automation integration test: a real transfer failure
    /// must propagate out of `startClaimedDownload` through the automation
    /// adapter's `startDownload` closure and into `WiltedAutomationCoordinator`'s
    /// `drain`/`withRetries`, which is the only thing standing between a single
    /// failed transfer and automation silently treating it as done. The
    /// coordinator has no injectable clock at the model level, so this proves
    /// the real bounded-backoff schedule (2s, 4s, 8s) actually elapses --
    /// `maximumRetries + 1` attempts total for a retryable failure.
    func testAutomationAdapterPropagatesADownloadFailureThroughBoundedRetries() async throws {
        let directory = temporaryDirectory("automation-retry-propagation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/retry.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/retry.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "retry-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Retry feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "retry-1",
                    title: "Retry episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // A claim that outlived the process that made it: automation's
                // `reconcile()` finds this through `unfinishedPodcastDownloads()`
                // and drains it with `alreadyClaimed: true`, exactly as a
                // relaunch after a crash mid-download would.
                try await store.save(download: PodcastDownload(episodeID: episodeID, status: .queued, updatedAt: created))
                try await store.addPodcastQueueEpisode(episodeID)
                return store
            },
            podcastDownloadTransportFactory: {
                CountingFailingPodcastDownloadTransport(enclosureURL: enclosureURL, statusCode: 503, counter: counter)
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        // `startAutomationOnLaunch()` already reconciled the stranded claim
        // above in the background; wait for that pass (retries included)
        // to finish rather than racing it.
        await model.waitForAutomation()

        XCTAssertEqual(counter.count, WiltedAutomationCoordinator.maximumRetries + 1,
                       "one initial attempt plus every bounded retry, not silently one and done")

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let download = try await store.download(for: episodeID)
        XCTAssertEqual(download?.status, .failed)
        XCTAssertEqual(download?.failureKind, .retryable)
    }

    /// The other half of the Phase 3 gate: a `.terminal`-classified failure
    /// (here `invalidAudio`, from a media validator that rejects everything)
    /// must reach exactly one attempt through the automation path, never the
    /// bounded retry a `.retryable` failure gets. `startClaimedDownload`'s
    /// wrapping into `WiltedAutomationNonRetryableDownloadFailure` is what
    /// stops `withRetries` from trying this three more times.
    func testAutomationAdapterMakesExactlyOneAttemptForATerminalFailure() async throws {
        let directory = temporaryDirectory("automation-terminal-no-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/terminal.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/terminal.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "terminal-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()
        let body = Data("stub-audio-bytes".utf8)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Terminal feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "terminal-1",
                    title: "Terminal episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // A stranded claim, exactly as in the retryable-propagation
                // test above, so this exercises the same automation path.
                try await store.save(download: PodcastDownload(episodeID: episodeID, status: .queued, updatedAt: created))
                try await store.addPodcastQueueEpisode(episodeID)
                return store
            },
            podcastDownloadTransportFactory: {
                CountingPodcastDownloadTransport(counter: counter, events: [
                    .response(.init(url: enclosureURL, statusCode: 200, mediaType: "audio/mpeg",
                                     expectedByteCount: Int64(body.count))),
                    .data(body)
                ])
            },
            // Duration 0 fails the coordinator's `duration.isFinite, duration > 0`
            // guard, which is `.invalidAudio` -- `.terminal` per Phase 3's
            // classification, unlike the HTTP-503 `.invalidResponse` above.
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 0) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        await model.waitForAutomation()

        XCTAssertEqual(counter.count, 1, "a terminal failure must not be retried in-process")

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let download = try await store.download(for: episodeID)
        XCTAssertEqual(download?.status, .failed)
        XCTAssertEqual(download?.failureKind, .terminal)
    }

    /// Finding 5's whole premise: a `.failed`/`.retryable` row from a prior
    /// launch is picked up by `resumablePodcastDownloads()` and routed through
    /// `unfinishedAutomationClaims()` into the same serial `drain` queue as a
    /// stranded `.queued` claim -- not started directly by bootstrap. This is
    /// the one path the rest of Phase 3's tests never actually exercised: a
    /// `.failed` row (not `.queued`) reaching `startClaimedDownload`.
    func testRelaunchResumesAFailedRetryableDownloadThroughTheSameSerialQueue() async throws {
        let directory = temporaryDirectory("automation-resume-retryable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/resume.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/resume.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "resume-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()
        let body = Data("stub-audio-bytes".utf8)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Resume feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "resume-1",
                    title: "Resume episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // A transport hiccup from the prior launch, already classified
                // `.retryable` by the coordinator's final catch -- exactly the
                // row `resumablePodcastDownloads()` filters for.
                try await store.save(download: PodcastDownload(
                    episodeID: episodeID, status: .failed, updatedAt: created, failureKind: .retryable
                ))
                try await store.addPodcastQueueEpisode(episodeID)
                return store
            },
            podcastDownloadTransportFactory: {
                CountingPodcastDownloadTransport(counter: counter, events: [
                    .response(.init(url: enclosureURL, statusCode: 200, mediaType: "audio/mpeg",
                                     expectedByteCount: Int64(body.count))),
                    .data(body)
                ])
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        await model.waitForAutomation()

        XCTAssertEqual(counter.count, 1, "one attempt, and it succeeds -- no bounded retry needed")

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let download = try await store.download(for: episodeID)
        XCTAssertEqual(download?.status, .completed)
    }

    /// The sibling case: a `.failed`/`.terminal` row must never appear in
    /// `resumablePodcastDownloads()` at all, so a relaunch makes zero attempts
    /// at it -- it needs a person, not another automatic try.
    func testRelaunchNeverResumesAFailedTerminalDownload() async throws {
        let directory = temporaryDirectory("automation-resume-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/noresume.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/noresume.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "noresume-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "No-resume feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "noresume-1",
                    title: "No-resume episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // A hash mismatch or similarly terminal failure from the prior
                // launch. `resumablePodcastDownloads()` filters this out, so
                // it must never reach the transport at all.
                try await store.save(download: PodcastDownload(
                    episodeID: episodeID, status: .failed, updatedAt: created, failureKind: .terminal
                ))
                return store
            },
            podcastDownloadTransportFactory: {
                CountingFailingPodcastDownloadTransport(enclosureURL: enclosureURL, statusCode: 503, counter: counter)
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        await model.waitForAutomation()

        XCTAssertEqual(counter.count, 0, "a terminal failure is excluded from relaunch resume entirely")

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let download = try await store.download(for: episodeID)
        XCTAssertEqual(download?.status, .failed)
        XCTAssertEqual(download?.failureKind, .terminal)
    }

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
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Beta", "Alpha"], directory: directory)

        XCTAssertEqual(model.subscriptions.map(\.title), ["Alpha", "Beta"], "feeds list by title")
        XCTAssertEqual(model.subscriptions.map(\.episodeCount), [1, 1])
        XCTAssertTrue(model.subscriptions.allSatisfy(\.enabled))
    }

    /// Disabling a feed hides its episodes from Larder but must not discard
    /// them: re-enabling has to bring the same episodes back.
    func testDisablingAFeedHidesItsEpisodesWithoutDiscardingThem() async throws {
        let directory = temporaryDirectory("feeds-disable")
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })

        model.unsubscribe(alpha)
        try await settle(model)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Beta"])
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.podcastOperationMessage, "Unsubscribed from Alpha and removed 1 episode.")
    }

    /// The reported bug: episodes removed from the Larder came back. Removal
    /// was an in-memory set, so it lasted exactly as long as the process, and
    /// the store kept re-admitting the identity on every refresh.
    func testRemovingAnEpisodeOutlivesTheProcess() async throws {
        let directory = temporaryDirectory("episode-remove")
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
    private func settle(_ model: WiltedMacModel, iterations: Int = 40) async throws {
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

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-mac-model-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Builds one downloaded, transcript-ready podcast episode -- the
    /// minimum a row needs to qualify as "ready" for continuous playback.
    private static func addReadyEpisode(
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
    private static func addUndownloadedEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
    }

    // MARK: Library preferences

    func testLarderSortIsTheOnlyOrderPreference() throws {
        // A fixed suite: `removePersistentDomain` empties the file but leaves
        // it, so a per-run name would litter ~/Library/Preferences.
        let suite = "com.zerodelta.wilted.mac.model-order-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.larderSort, .newest, "a fresh install lists newest first")
        // The retired `libraryOrder` view writes the Larder's own sort, so the
        // Menu bulk order and auto-advance can no longer disagree with what
        // the shelf shows.
        first.libraryOrder = .oldest
        XCTAssertEqual(first.larderSort, .oldest, "the legacy view and the Larder are one preference")
        first.larderSort = .title

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.larderSort, .title, "the choice must outlive the model that made it")
        XCTAssertEqual(second.libraryOrder, .newest, "a non-date sort reads as its newest projection")
    }

    func testStoredLegacyLibraryOrderMigratesForward() throws {
        let suite = "com.zerodelta.wilted.mac.model-order-migration-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("order-migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)

        let migrated = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(migrated.larderSort, .oldest,
                       "a host that only ever stored the retired key keeps its oldest-first shelf")
        XCTAssertEqual(
            preferences.string(forKey: WiltedMacModel.larderSortPreferenceKey),
            WiltedMacLarderSort.oldest.rawValue,
            "the migration writes the choice forward under the surviving key"
        )

        preferences.set(WiltedMacLarderSort.title.rawValue, forKey: WiltedMacModel.larderSortPreferenceKey)
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        let again = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(again.larderSort, .title, "a surviving sort wins over the retired key")
    }

    /// 2.7: only `menuSort` orders the Menu. The Feeds sort and the retired
    /// projection can change without moving a single Menu row.
    func testMenuOrderReadsOnlyMenuSortNotTheFeedsSort() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String, title: String) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: title, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let zulu = ready("order-zulu", title: "Zulu")
        let alpha = ready("order-alpha", title: "Alpha")
        for value in [zulu, alpha] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }
        model.menuSort = .title
        let before = model.menuDisplayEpisodeIDs
        XCTAssertEqual(before, [alpha.id, zulu.id])

        model.larderSort = .oldest
        model.libraryOrder = .oldest

        XCTAssertEqual(model.menuDisplayEpisodeIDs, before,
                       "the Feeds sort and the retired projection do not order the Menu")
        XCTAssertEqual(model.larderSort, .oldest, "the two legacy spellings stay one preference")
        XCTAssertEqual(model.libraryOrder, .oldest)
    }

    func testMenuAudioSummariesCountKnownDurationsAndExposeUnknowns() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = WiltedMacEpisode(
            id: "summary-ready", title: "Ready", feedTitle: "Show", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        let unknown = WiltedMacEpisode(
            id: "summary-unknown", title: "Unknown", feedTitle: "Show", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationSeconds: nil, playbackSeconds: 0, downloadState: .notDownloaded,
            preparationState: .notPrepared
        )
        for value in [ready, unknown] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        // The whole-Menu total sums the waiting set; an unknown duration is
        // visible as a count rather than silently counted as zero.
        XCTAssertEqual(model.menuAudioSummary, WiltedMacQueueAudioSummary(episodes: [ready, unknown]))
        XCTAssertEqual(model.menuAudioSummary.seconds, 600)
        XCTAssertEqual(model.menuAudioSummary.unknownCount, 1)
        XCTAssertEqual(model.menuAudioSummary.detailLabel, "10m · 1 unknown")
    }

    func testTheRetiredLarderKindGroupingIsGone() {
        // Commit 4f83343's kind grouping was withdrawn with the Larder. The
        // Menu has one grouping axis -- readiness -- and a second orthogonal
        // grouping by kind must not return beside it.
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WiltedMac/WiltedMacModel.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source?.contains("WiltedMacLibraryKind") == true,
                       "the kind renderer must be deleted, not moved")
        XCTAssertFalse(source?.contains("WiltedMacQueueGrouping") == true,
                       "the queue grouping type itself is retired")
        XCTAssertFalse(source?.contains("id: .kind(") == true,
                       "no queue-section kind case may remain")
    }

    func testTheOrderingPreferencesSurviveRelaunch() {
        let suite = "com.zerodelta.wilted.mac.queue-controls-tests"
        let preferences = UserDefaults(suiteName: suite) ?? UserDefaults()
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        first.larderSort = .title
        first.menuSort = .title
        first.menuGrouping = .date
        first.selectedNavigation = .feeds

        let second = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(second.larderSort, .title)
        XCTAssertEqual(second.menuSort, .title)
        XCTAssertEqual(second.menuGrouping, .date)
        XCTAssertEqual(second.selectedNavigation, .feeds,
                       "the selected destination must outlive the model that chose it")
    }

    func testMenuGroupingDefaultsToStatusAndBuildsFeedDateAndStatusSections() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func episode(
            _ id: String,
            feed: String,
            daysAgo: Int,
            download: WiltedMacEpisodeDownloadState,
            preparation: WiltedMacEpisodePreparationState = .notPrepared
        ) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: feed, summary: "", artworkURL: nil,
                releasedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                durationSeconds: 600, playbackSeconds: 0, downloadState: download,
                preparationState: preparation
            )
        }
        let ready = episode(
            "group-ready", feed: "Daily Field", daysAgo: 0, download: .completed,
            preparation: .prepared(summary: "Ready")
        )
        let downloaded = episode("group-downloaded", feed: "Quiet Season", daysAgo: 1, download: .completed)
        let available = episode("group-available", feed: "Daily Field", daysAgo: 3, download: .notDownloaded)
        for value in [ready, downloaded, available] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertEqual(model.menuGrouping, .status)
        XCTAssertEqual(model.menuSections(calendar: calendar, now: now).map(\.title), [
            "Ready", "Downloaded", "Not downloaded",
        ])
        XCTAssertTrue(model.menuSections(calendar: calendar, now: now).allSatisfy { $0.statusGroup != nil })

        model.menuGrouping = .feed
        let feedSections = model.menuSections(calendar: calendar, now: now)
        XCTAssertEqual(feedSections.map(\.title), ["Daily Field", "Quiet Season"])
        XCTAssertEqual(feedSections.flatMap(\.episodes).count, 3)
        XCTAssertTrue(feedSections.allSatisfy { $0.statusGroup == nil })

        model.menuGrouping = .date
        let dateSections = model.menuSections(calendar: calendar, now: now)
        XCTAssertEqual(dateSections.prefix(2).map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(dateSections.flatMap(\.episodes).count, 3)
        XCTAssertTrue(dateSections.allSatisfy { $0.statusGroup == nil })
    }

    func testMenuSortReordersOnlyUpcomingEpisodesAndKeepsCurrentInPlace() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        func episode(_ id: String, title: String, length: TimeInterval, published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: title, feedTitle: "Show", summary: "Fixture", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: published), durationSeconds: length,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready · transcript synced")
            )
        }
        let current = episode("menu-sort-current", title: "Current", length: 900, published: 100)
        let long = episode("menu-sort-long", title: "Alpha", length: 1_200, published: 300)
        let short = episode("menu-sort-short", title: "Zulu", length: 120, published: 200)
        let middle = episode("menu-sort-middle", title: "Middle", length: 600, published: 400)
        model.installEpisodeForTesting(long)
        model.installEpisodeForTesting(short)
        model.installEpisodeForTesting(middle)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 900,
            queue: [current.id, long.id, short.id, middle.id]
        )

        model.menuSort = .shortest
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [current.id, short.id, middle.id, long.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [current.id, short.id, middle.id, long.id],
                       "the Menu renders the whole waiting set, not only the rows after the current one")
        XCTAssertEqual(model.menuAudioSummary.seconds, 2_820)
        XCTAssertEqual(model.currentPodcastEpisodeID, current.id)

        model.menuSort = .title
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [current.id, long.id, middle.id, short.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [current.id, long.id, middle.id, short.id])
        XCTAssertEqual(model.currentPodcastEpisodeID, current.id)

        model.moveMenuEpisode(short.id, before: long.id)
        XCTAssertEqual(model.menuSort, .custom, "a manual move must preserve the listener's custom order")
    }

    func testPlaybackSpeedSurvivesRelaunch() throws {
        let suite = "com.zerodelta.wilted.mac.model-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("speed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.playbackRate, 1.25, "a fresh install listens at 1.25×, the owner's default")
        first.setPlaybackRate(1.5)

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.playbackRate, 1.5, "the chosen speed must outlive the model that chose it")

        preferences.set(9.0, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let third = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(third.playbackRate, 2, "a stored value outside the picker's range is clamped, not trusted")
    }

    func testFixtureLaunchesStartFromTheDefaultOrderAndLeaveNothingBehind() {
        let directory = temporaryDirectory("fixture-order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(fixture.libraryOrder, .newest)
        fixture.libraryOrder = .oldest

        let relaunched = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(relaunched.libraryOrder, .newest, "a fixture launch leaves nothing behind for the next one")
    }

    // MARK: Automation settings

    private func automationSettingsPreferences() throws -> UserDefaults {
        let suite = "com.zerodelta.wilted.mac.automation-settings-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        return preferences
    }

    private func offPeakWindow() throws -> WiltedAutomationOffPeakWindow {
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: 22, minute: 30))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 15))
        return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
    }

    private func localDate(hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 6, hour: hour, minute: minute
        )))
    }

    private func automationFixture(_ suffix: String) throws -> (URL, WiltedMacModel, WiltedMacEpisode) {
        let directory = temporaryDirectory(suffix)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        return (directory, model, try XCTUnwrap(model.episodes.first))
    }

    func testAutomaticAdmissionStartsImmediatePreparation() async throws {
        let (directory, model, episode) = try automationFixture("automatic-immediate")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
    }

    func testAutomaticAdmissionSkipsPreparationUnderManualPolicy() throws {
        let (directory, model, episode) = try automationFixture("automatic-manual")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .notPrepared
        )
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    /// A deferred job is stored as `.preparing(stage: "Queued")`, which makes
    /// `isRunning` true, so the row is indistinguishable from one actually
    /// being prepared unless something else answers the question.
    func testADeferredEpisodeIsDistinguishableFromOneBeingPrepared() throws {
        let (directory, model, episode) = try automationFixture("deferred-is-distinguishable")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        XCTAssertFalse(model.isDeferredForOffPeak(episode.id))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertTrue(model.isDeferredForOffPeak(episode.id))
        XCTAssertEqual(model.episodes.first(where: { $0.id == episode.id })?.preparationState,
                       .preparing(stage: WiltedMacModel.preparationQueuedStage),
                       "the stored state alone still reads as running, which is why the row "
                       + "needs isDeferredForOffPeak rather than preparationState")
    }

    /// The off-peak window is a default, not a rule: a listener about to leave
    /// should not have to edit a Settings policy and wait for the next
    /// re-evaluation to get this one episode prepared.
    func testPreparingADeferredEpisodeNowTakesItOutOfTheOffPeakQueue() throws {
        let (directory, model, episode) = try automationFixture("prepare-now-overrides")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])

        XCTAssertTrue(model.prepareDeferredEpisodeNow(episode))

        XCTAssertFalse(model.isDeferredForOffPeak(episode.id),
                       "the episode is being prepared now, so nothing should still be holding "
                       + "it for a window hours away")
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
    }

    /// The Mac UI suite reaches Prepare now only through a fixture launch, so
    /// the deferral the fixture seeds has to survive initialisation. It did not:
    /// `installFixture` runs before the stored preferences are read, and a
    /// fixture host has nothing stored, so the load emptied the seed before the
    /// first render and the control never appeared.
    func testADeferredFixtureLaunchStillHoldsItsDeferralAfterInitialisation() throws {
        let directory = temporaryDirectory("deferred-fixture-survives-init")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                        "--wilted-ui-fixture-deferred"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let deferredID = try XCTUnwrap(model.deferredAutomaticPreparations.first?.episodeID,
                                       "a --wilted-ui-fixture-deferred launch must reach the "
                                       + "first render still holding its deferral, or Prepare "
                                       + "now has nothing to override")
        let episode = try XCTUnwrap(model.episodes.first { $0.id == deferredID })
        XCTAssertTrue(model.isDeferredForOffPeak(episode.id))
        XCTAssertEqual(WiltedMacModel.menuGroup(for: episode), .downloaded,
                       "the deferred row sits in the group whose control offers Prepare now")

        // The UI leg does not reach the Menu directly: it opens Feeds and
        // presses the first Keep. Replaying that here keeps this a proxy for
        // the journey rather than for initialisation alone.
        let kept = try XCTUnwrap(model.feedsEpisodes.first,
                                 "Feeds must offer the row the leg keeps")
        model.keepEpisode(kept)
        XCTAssertEqual(kept.id, deferredID,
                       "the leg keeps the first Feeds row, so that row has to be the deferred "
                       + "one or the Menu never draws a Prepare now control")
        XCTAssertTrue(model.isDeferredForOffPeak(deferredID),
                      "keeping the episode must not clear its deferral")
    }

    /// An episode nothing deferred has no deferral to override, and saying so
    /// keeps the control from appearing to do something on a row it cannot act on.
    func testPreparingANonDeferredEpisodeNowReportsThatItDidNothing() throws {
        let (directory, model, episode) = try automationFixture("prepare-now-no-deferral")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(model.prepareDeferredEpisodeNow(episode))
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    func testSkippingAnEpisodeGivesUpItsPlaceInThePreparationQueue() throws {
        let (directory, model, episode) = try automationFixture("skip-leaves-queue")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])

        model.removeEpisode(episode)

        XCTAssertTrue(model.preparationQueue.isEmpty,
                      "a removed episode kept its turn, so Prep counted one more waiting than "
                      + "the Larder could show and the run slot went to a row nobody has")
    }

    func testOffPeakAdmissionKeepsItsOriginalWindowAndSnapshotUntilEligible() async throws {
        let (directory, model, episode) = try automationFixture("automatic-off-peak")
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalWindow = try offPeakWindow()
        let originalSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(originalWindow),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        model.setAutomationSettings(originalSettings)

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertEqual(admitted.episodeID, episode.id)
        XCTAssertEqual(admitted.processingPolicy, .offPeak(originalWindow))
        XCTAssertEqual(admitted.policySnapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])
        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .preparing(stage: WiltedMacModel.preparationQueuedStage)
        )

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        model.startEligibleAutomaticPreparations(at: try localDate(hour: 21))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "later settings cannot skip or rewrite the admitted job")

        model.startEligibleAutomaticPreparations(at: try localDate(hour: 23))
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        try await Task.sleep(for: .milliseconds(10))
    }

    /// David hit a queued episode and had to press Stop and then Prepare to run
    /// it. That workaround is worse than it looks: cancelling drops the stored
    /// policy snapshot, so the job came back under whatever Settings said at
    /// the time rather than what it was admitted with.
    func testAQueuedOffPeakJobCanBeRunWithoutCancellingIt() async throws {
        let (directory, model, episode) = try automationFixture("off-peak-prepare-now")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertTrue(model.isDeferredToOffPeak(episode.id),
                      "a row waiting on the clock is the one that can be started early")

        // Changing Settings afterwards must not decide anything here: this runs
        // the admitted job, not a fresh one.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "the snapshot is still the admitted one when the button is pressed")

        model.prepareDeferredPreparationNow(episode.id)

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
                      "the queued job runs instead of waiting for the window")
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty, "and is no longer deferred")
        XCTAssertTrue(model.preparationQueue.isEmpty, "and has left the visible queue")
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id))
        try await Task.sleep(for: .milliseconds(10))
    }

    /// The button is offered only for the off-peak case. A row queued behind the
    /// single-run admission gate says "Queued" too, and starting it early would
    /// run two preparations at once, which is what the gate is for.
    func testARowThatIsNotWaitingOnTheClockIsNotOfferedTheButton() throws {
        let (directory, model, episode) = try automationFixture("off-peak-not-offered")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id),
                       "nothing is deferred before anything is admitted")

        model.prepareDeferredPreparationNow(episode.id)
        XCTAssertEqual(model.episodes.first(where: { $0.id == episode.id })?.preparationState, .notPrepared,
                       "asking to run a job that was never deferred does nothing")
    }

    /// Walkthrough frame 6.4 -- an episode started while an article is playing --
    /// has never captured successfully. This is the model half of that path,
    /// held down so a future failure can be attributed to the view or the
    /// capture harness rather than re-argued from scratch.
    func testStartingAnEpisodeWhileAnArticlePlaysSwitchesCleanly() async throws {
        let directory = temporaryDirectory("article-to-episode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle(model)
        XCTAssertNotNil(model.selectedArticleID, "the fixture starts with an article playing")

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, episode.id,
                       "the episode takes over, which is what puts Notes in the rail")
        XCTAssertNil(model.selectedArticleID, "and the article lets go")
        XCTAssertNil(model.playbackError)
        XCTAssertNil(model.playbackOperationStatus, "a rail left spinning never goes idle for XCUITest")
    }

    func testOnlyNoLocalSpeechToTextWithRemovalOnBlocksAdRemoval() throws {
        // The pane offers the two controls side by side, so every pair a reader
        // can reach is checked, not only the one that fails.
        for policy in [WiltedAutomationTranscriptPolicy.bestAvailable, .alwaysTranscribe, .noLocalSTT] {
            for removeAds in [true, false] {
                let settings = WiltedAutomationSettings(
                    refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                    transcriptPolicy: policy, removeAds: removeAds
                )
                let blocked = policy == .noLocalSTT && removeAds
                XCTAssertEqual(settings.transcriptPolicyBlocksAdRemoval, blocked,
                               "\(policy.settingsControlLabel) with removeAds \(removeAds)")
            }
        }
    }

    func testTheBlockedAdRemovalExplanationNamesTheCauseAndBothWaysOut() throws {
        let explanation = WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation

        // Naming one control would leave a reader looking at the other one
        // wondering which of them is wrong.
        XCTAssertTrue(explanation.contains("Remove ads"), explanation)
        XCTAssertTrue(explanation.contains(WiltedAutomationTranscriptPolicy.noLocalSTT.settingsControlLabel),
                      explanation)
        XCTAssertTrue(explanation.contains("no episode will prepare"), explanation)
    }

    func testABlockedConfigurationStillDecodesAndSurvivesRelaunch() throws {
        // Removal once ran from a publisher's cues, so this pair is a file that
        // legitimately exists. It is reported, not rejected: refusing to decode
        // it would lose every other preference saved beside it.
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("blocked-transcript-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))

        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.automationSettings.transcriptPolicy, .noLocalSTT)
        XCTAssertTrue(relaunched.automationSettings.removeAds)
        XCTAssertTrue(relaunched.automationSettings.transcriptPolicyBlocksAdRemoval)
    }

    func testPreparationPolicySnapshotMapsEveryFutureWorkerChoice() throws {
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )

        let snapshot = WiltedMacModel.preparationPolicySnapshot(from: settings)

        XCTAssertEqual(snapshot.transcriptPolicy, .alwaysTranscribe)
        XCTAssertFalse(snapshot.removeAds)

        let laterSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        XCTAssertEqual(snapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ), "a queued job retains the snapshot captured at admission")
        XCTAssertNotEqual(snapshot, WiltedMacModel.preparationPolicySnapshot(from: laterSettings))
    }

    func testDeferredAutomaticPreparationPersistsItsAdmissionOrderWindowAndSnapshot() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let window = try offPeakWindow()
        let firstSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        let secondSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        let jobs = [
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "first", processingPolicy: .offPeak(window), policySnapshot: firstSnapshot
            ),
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "second", processingPolicy: .offPeak(window), policySnapshot: secondSnapshot
            )
        ]

        WiltedMacModel.persistDeferredAutomaticPreparations(jobs, to: preferences)
        let restored = WiltedMacModel.loadDeferredAutomaticPreparations(from: preferences)

        XCTAssertEqual(restored, jobs)
        XCTAssertEqual(restored.map(\.episodeID), ["first", "second"])
        XCTAssertEqual(restored.first?.policySnapshot, firstSnapshot)
        XCTAssertEqual(restored.first?.processingPolicy, .offPeak(window))
    }

    func testExplicitPreparationStartsEvenWhenAutomaticProcessingIsManual() async throws {
        let directory = temporaryDirectory("manual-preparation-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let episode = try XCTUnwrap(model.episodes.first)

        model.prepareEpisode(episode)
        XCTAssertTrue(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
            "the explicit action bypasses the automatic-processing policy"
        )
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .failed("No preparation worker in fixture mode")
        )
    }

    /// Automation is stall-prone by construction: it refreshes feeds and pulls
    /// audio with nobody watching. Every stage it can sit in has to be readable
    /// from the model, and stopping it has to say so rather than going quiet.
    func testAutomationStatusIsObservableAndCancellationIsAnnounced() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-status")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationStatus, .idle)

        model.cancelAutomation()
        XCTAssertEqual(model.automationStatus, .cancelled,
                       "a stop request is a state the surface can show, not silence")
    }

    /// Automation starts from the launch path, and the shipped defaults keep it
    /// inert.
    ///
    /// Both halves matter. Without the launch wiring a persisted claim is never
    /// resumed, so "a claim survives a crash" would be true of the store and
    /// false of the product. And because the default policy is manual, a launch
    /// that reaches this point must still do nothing, which is what preserves
    /// the behaviour of every build before automation existed.
    func testLaunchStartsAutomationAndTheDefaultPolicyDoesNothing() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-launch")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationSettings.refreshPolicy, .manual)
        XCTAssertEqual(model.automationSettings.downloadPolicy, .manual)

        XCTAssertEqual(model.startupState, .loading(attempt: 0, step: .openingStore))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready,
                       "the launch pass is started from the ready transition, so it has to be reached")
        await model.waitForAutomation()

        XCTAssertEqual(model.automationStatus, .idle,
                       "the launch pass ran and the manual policy declined it")
        XCTAssertNil(model.lastAutomationRefreshAt,
                     "a declined pass records no refresh, so an interval policy set later starts fresh")
        model.stopAutomationTicker()
    }

    /// Hiding the app checkpoints and stops the ticker. The scene has to start
    /// it again on the way back, or a window left open past the first focus dip
    /// never ticks again for the rest of the process, which is the only case the
    /// ticker exists for.
    /// Progress is written only on a transport press or a clean quit, so the
    /// periodic tick is the only thing standing between an abrupt exit and a
    /// listener sent back to wherever they last pressed a button. Unlike the
    /// automation tick it must survive the app losing focus, because audio
    /// keeps running with the window closed and that is exactly when nothing
    /// else is checkpointing.
    func testThePlaybackCheckpointTickerOutlivesFocusLoss() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("playback-checkpoint-ticker")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "nothing ticks before a store is loaded")
        model.startPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "and asking early is a no-op")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "the ready transition starts it")

        model.startPlaybackCheckpointTicker()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "a repeated call is harmless")

        model.checkpointForBackground()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning,
                      "hiding the app stops the automation tick, not this one")

        // With nothing loaded the tick is a no-op rather than a write of an
        // empty position over whatever the store already holds.
        await model.checkpointPlaybackIfAdvancing()

        model.stopPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning)
    }

    /// The unit tests run inside the app bundle, so a test that plays an
    /// episode plays it out of the machine's speakers -- which is what a gate
    /// run's unexplained tone was for days. This is the guard against it
    /// returning. Starting silent is not enough on its own: the model pushes
    /// the owner's saved volume into the backend on every load, so the check
    /// that matters is that asking for full volume changes nothing.
    func testTheTestHostNeverDrivesAudioOutput() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("silent-playback")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "a backend built inside the test host starts silent")
        model.setPlaybackVolume(1)
        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "and the owner's saved volume does not bring the sound back")
    }

    func testTheOpenWindowTickerRestartsAfterBeingStopped() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-ticker-restart")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.automationTickerIsRunning, "nothing ticks before a store is loaded")
        model.startAutomationTicker()
        XCTAssertFalse(model.automationTickerIsRunning,
                       "and asking early is a no-op rather than a ticker with nothing to read")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.automationTickerIsRunning, "the ready transition starts it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "a repeated scene callback is harmless")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "hiding the app stops it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "and coming back starts it again")
        model.stopAutomationTicker()
    }

    /// `checkpointForBackground` stops the open-window tick, which used to be
    /// the only thing that re-evaluated an off-peak window opening. The
    /// ticket-drain ticker is the fix, and it has to survive exactly the call
    /// that stops the other one -- a background tick that stops the moment
    /// the window hides is not a fix at all.
    func testTheTicketDrainTickerSurvivesGoingToBackground() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("ticket-drain-ticker-restart")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.ticketDrainTickerIsRunning, "nothing ticks before a store is loaded")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.ticketDrainTickerIsRunning, "the ready transition starts it")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "the open-window tick still stops")
        XCTAssertTrue(model.ticketDrainTickerIsRunning,
                      "the drain ticker is not scene-phase-gated the way the open-window tick is")

        model.pauseForQuit()
        XCTAssertFalse(model.ticketDrainTickerIsRunning, "actual termination is the one moment stopping it is right")
    }

    /// Step 7's done-condition. `checkpointForBackground` used to leave an
    /// off-peak-deferred episode stuck: the only ticker that re-evaluated
    /// `deferredAutomaticPreparations` was the one it stops. The window here
    /// is constructed to be eligible for all but two minutes out of the day
    /// (00:00 and 23:59), so the deliberately-chosen admission date below
    /// (fixed at 00:00) is reliably ineligible while the live ticker's own
    /// real-clock check, moments later, is eligible with overwhelming
    /// probability -- this is a real-clock ticker, so the assertion is
    /// necessarily a poll rather than a single deterministic instant.
    func testAPendingTicketAdvancesWhileTheWindowIsNotFrontmost() async throws {
        let directory = temporaryDirectory("ticket-drain-background-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/ticket-drain.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/ticket-drain.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeItemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "ticket-drain-1", enclosureURL: enclosureURL
        )
        let episodeID = episodeItemID.rawValue
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let storeCapture = StoreCapture()
        let runner = BlockingPodcastPipelineRunner()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                await storeCapture.capture(store)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fixtures", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeItemID, guid: "ticket-drain-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            },
            podcastPipelineRunnerFactory: { runner },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.episodes.map(\.id), [episodeID])

        let almostAllDay = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: try XCTUnwrap(WiltedAutomationLocalTime(hour: 0, minute: 1)),
            end: try XCTUnwrap(WiltedAutomationLocalTime(hour: 23, minute: 59))
        ))
        let reliablyIneligibleNow = try localDate(hour: 0, minute: 0)

        // Mirrors `downloadEpisode`'s own sequence: the place in line is taken
        // before admission is decided, so there is already a durable, pending
        // ticket for this episode's preparation by the time deferral happens.
        let sequence = model.registerPreparationRequest(for: episodeID)
        XCTAssertEqual(sequence, 1)

        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        func fetchedTicket() async throws -> WorkTicket? {
            try await capturedStore.workTicket(kind: .podcastPreparation, subjectID: episodeID)
        }
        var attempts = 0
        var pending = try await fetchedTicket()
        while attempts < 50, pending == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            pending = try await fetchedTicket()
            attempts += 1
        }
        let priorTicket = try XCTUnwrap(pending, "the register call's ticket write must have landed")
        XCTAssertEqual(priorTicket.state, .pending)
        let priorAttemptCount = priorTicket.attemptCount

        // The stored policy travels with the deferred job from admission,
        // not read again from live settings later (`startEligibleAutomaticPreparations`'s
        // own doc comment): it has to be the near-all-day window from the
        // start, so the one `admitAutomaticPreparation` call below both defers
        // (against the deliberately-ineligible fixed date) and leaves the
        // later real-clock re-check eligible.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(almostAllDay),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID }))
        model.admitAutomaticPreparation(for: episode, at: reliablyIneligibleNow)
        XCTAssertTrue(model.isDeferredForOffPeak(episodeID), "the deliberately-ineligible date defers it")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "the window is not frontmost")
        XCTAssertTrue(model.ticketDrainTickerIsRunning, "started automatically at bootstrap and untouched by backgrounding")

        // Bootstrap already started this ticker at its production interval;
        // restart it at a fast one so the poll below does not have to wait
        // out that real interval.
        model.stopTicketDrainTicker()
        model.startTicketDrainTicker(interval: 0.05)

        attempts = 0
        var current = try await fetchedTicket()
        while attempts < 100, (current?.attemptCount ?? priorAttemptCount) <= priorAttemptCount {
            try await Task.sleep(nanoseconds: 20_000_000)
            current = try await fetchedTicket()
            attempts += 1
        }
        let advanced = try XCTUnwrap(current)
        XCTAssertGreaterThan(advanced.attemptCount, priorAttemptCount,
                             "admission ran and the ticket's attempt count -- its progress -- advanced "
                             + "while the window was not frontmost")

        model.stopTicketDrainTicker()
        await runner.resume(throwing: CancellationError())
    }

    /// Hiding the window, minimising it, or closing the last one must not stop
    /// the audio. It did: the scene-phase handler called a method that paused,
    /// because one call was serving both "not frontmost" and "quitting". David
    /// found it with Cmd-H during Mac owner acceptance.
    ///
    /// The assertion has to defeat the fire-and-forget task the checkpoint runs
    /// in. Calling the method and reading the flag immediately passes against
    /// the *old* code too, because the pause has not landed yet.
    func testHidingTheWindowCheckpointsWithoutStoppingTheAudio() async throws {
        let model = try await playingModel("background-keeps-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying, "the fixture has to be playing for this to prove anything")

        model.checkpointForBackground()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(after.isPlaying, "hiding the app must not stop the episode")
        XCTAssertGreaterThan(after.sequence, before.sequence,
                             "and it still has to write the playhead down")
        model.togglePlayback()
    }

    /// The other half of the split. Termination is the one moment stopping is
    /// right: a Now Playing entry that still claims to be playing outlives the
    /// process, which is the failure `WiltedMacApp.init` records against test
    /// runs that left the machine's media keys pointed at a dead process.
    func testQuittingStopsTheAudioAndCheckpoints() async throws {
        let model = try await playingModel("quit-stops-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying)

        model.pauseForQuit()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertFalse(after.isPlaying, "quitting stops the audio")
        XCTAssertGreaterThan(after.sequence, before.sequence, "and writes the playhead down")
    }

    /// A bootstrapped model with one ready episode already playing.
    private func playingModel(_ name: String) async throws -> WiltedMacModel {
        let directory = temporaryDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/\(name).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/\(name).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "\(name)-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Lifecycle", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "\(name)-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        return model
    }

    /// The scheduling timestamp is the only thing standing between an interval
    /// policy and repeating its work on every tick, so it has to outlive the
    /// process. It lives in preferences rather than the store because losing it
    /// costs one extra idempotent refresh; claims, which cannot be
    /// reconstructed, live in the store.
    func testTheLastAutomaticRefreshTimeSurvivesRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-last-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertNil(model.lastAutomationRefreshAt, "a first launch has nothing to space itself from")

        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
        preferences.set(refreshedAt, forKey: WiltedMacModel.lastAutomationRefreshPreferenceKey)
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(relaunched.lastAutomationRefreshAt, refreshedAt)

        // An interval that has not elapsed since that time must not fire again.
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12), downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate, transcriptPolicy: .bestAvailable,
            removeAds: true
        )
        let tooSoon = WiltedAutomationCoordinator.plan(
            settings: settings, trigger: .openWindowTick,
            lastRefreshSuccess: relaunched.lastAutomationRefreshAt,
            now: refreshedAt.addingTimeInterval(11 * 3_600)
        )
        XCTAssertFalse(tooSoon.shouldRefresh)
    }

    func testAutomationSettingsRoundTripThroughInjectedPreferences() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12),
            downloadPolicy: .newestThreePerEnabledFeed,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe,
            removeAds: false
        )

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(settings)

        XCTAssertEqual(model.automationSettings, settings)
        XCTAssertNotNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
        XCTAssertEqual(WiltedAutomationDownloadPolicy.allNewlyAdmittedUpToTwenty.maximumEpisodesPerRefresh, 20)
    }

    func testLegacyReadableTranscriptSettingDecodesButIsNotReencoded() throws {
        let payload = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":false}"#

        let settings = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(payload.utf8))
        XCTAssertEqual(settings, .defaults)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertNil(encoded?["readableTranscriptPass"])
    }

    func testSettingsSavedBeforeTheMenuFilledItselfDecodeWithItEnabled() throws {
        let payload = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true}"#

        let settings = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(payload.utf8))
        XCTAssertTrue(settings.autoAddPreparedToMenu,
                      "a file that predates the preference must not read as a refusal")
        XCTAssertEqual(settings, .defaults)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertEqual(encoded?["autoAddPreparedToMenu"] as? Bool, true,
                       "the preference is written back once it has been read")
    }

    func testTurningTheMenuOffIsKeptAcrossASaveAndLoad() throws {
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable, removeAds: true, autoAddPreparedToMenu: false
        )
        let restored = try JSONDecoder().decode(
            WiltedAutomationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.autoAddPreparedToMenu)
        XCTAssertEqual(restored, settings)
    }

    func testOnlyEpisodesThatBecamePreparedOnThisReloadCountAsMenuArrivals() {
        func episode(_ id: String, prepared: Bool) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: prepared ? .prepared(summary: "Ready") : .notPrepared
            )
        }
        let loaded = [
            episode("just-finished", prepared: true),
            episode("prepared-all-along", prepared: true),
            episode("first-load", prepared: true),
            episode("still-waiting", prepared: false)
        ]

        let arrivals = WiltedMacModel.episodeIDsNewlyPrepared(
            in: loaded,
            preparedBefore: ["prepared-all-along"],
            knownBefore: ["just-finished", "prepared-all-along", "still-waiting"]
        )

        XCTAssertEqual(arrivals, ["just-finished"],
                       "an episode this process has never seen is a first load, not an arrival, "
                       + "or opening the app would empty the Larder into the Menu")
    }

    func testEveryAutomationControlValueMapsAndPersists() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-control-values")
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = try offPeakWindow()

        let refreshPolicies: [WiltedAutomationRefreshPolicy] = [
            .manual, .onLaunch, .whileOpen(everyHours: 6),
            .whileOpen(everyHours: 12), .whileOpen(everyHours: 24)
        ]
        let downloadPolicies: [WiltedAutomationDownloadPolicy] = [
            .manual, .newestOnePerEnabledFeed, .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty
        ]
        let processingPolicies: [WiltedAutomationProcessingPolicy] = [.immediate, .manual, .offPeak(window)]
        let transcriptPolicies: [WiltedAutomationTranscriptPolicy] = [.bestAvailable, .alwaysTranscribe, .noLocalSTT]

        XCTAssertEqual(Set(refreshPolicies.map(\.settingsControlLabel)).count, refreshPolicies.count)
        XCTAssertEqual(Set(downloadPolicies.map(\.settingsControlLabel)).count, downloadPolicies.count)
        XCTAssertEqual(Set(processingPolicies.map(\.settingsControlLabel)).count, processingPolicies.count)
        XCTAssertEqual(Set(transcriptPolicies.map(\.settingsControlLabel)).count, transcriptPolicies.count)
        for policy in refreshPolicies {
            XCTAssertEqual(WiltedAutomationRefreshPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in downloadPolicies {
            XCTAssertEqual(WiltedAutomationDownloadPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in processingPolicies {
            XCTAssertEqual(
                WiltedAutomationProcessingPolicy.fromSettingsControlLabel(policy.settingsControlLabel, window: window),
                policy
            )
        }
        for policy in transcriptPolicies {
            XCTAssertEqual(WiltedAutomationTranscriptPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }

        let settings = refreshPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: $0, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + downloadPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: $0, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + processingPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: $0,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + transcriptPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: $0, removeAds: true
            )
        }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        for candidate in settings {
            model.setAutomationSettings(candidate)
            let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(relaunched.automationSettings, candidate)
        }
    }

    func testAutomationStatusOnlyOffersStopWhileWorkCanBeInterrupted() {
        XCTAssertFalse(WiltedAutomationStatus.idle.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.failed("Network unavailable").isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.cancelled.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.refreshing(feedsRemaining: 2).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.downloading(episode: "Daily Brief", remaining: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.retrying(afterSeconds: 30, attempt: 2).isCancellable)
        XCTAssertEqual(
            WiltedAutomationStatus.refreshing(feedsRemaining: 1).settingsStatusText,
            "Refreshing 1 feed"
        )
        XCTAssertEqual(WiltedAutomationStatus.failed("Network unavailable").settingsStatusText,
                       "Failed: Network unavailable")
        XCTAssertEqual(WiltedAutomationStatus.cancelled.settingsStatusText, "Stopped")
        XCTAssertEqual(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).settingsStatusText,
                       "Finished: 2 refreshed, 1 downloaded")
    }

    func testAutomationSettingsSurviveRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .onLaunch,
            downloadPolicy: .allNewlyAdmittedUpToTwenty,
            processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT,
            removeAds: false
        )

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        first.setAutomationSettings(settings)
        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(second.automationSettings, settings)
    }

    func testCorruptAutomationSettingsFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(Data("not settings data".utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
    }

    func testInvalidAutomationSettingsValuesFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let invalidPayloads = [
            #"{"version":1,"refreshPolicy":{"kind":"whileOpen","everyHours":7},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"offPeak","window":{"start":{"hour":24,"minute":0},"end":{"hour":6,"minute":0}}},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":2,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#
        ]

        XCTAssertNil(WiltedAutomationLocalTime(hour: 24, minute: 0))
        let time = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 0))
        XCTAssertNil(WiltedAutomationOffPeakWindow(start: time, end: time))
        for payload in invalidPayloads {
            preferences.set(Data(payload.utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)
            let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(model.automationSettings, .defaults, "invalid persisted settings must fail closed")
            XCTAssertEqual(model.libraryOrder, .oldest)
            XCTAssertEqual(model.playbackRate, 1.5)
        }
    }

    func testAbsentAutomationSettingsUseCurrentDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-absent")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
        XCTAssertNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
    }

    func testAutomationSettingsDoNotDisturbLegacyPreferenceKeys() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 6),
            downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable,
            removeAds: true
        ))
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.libraryOrder, .oldest)
        XCTAssertEqual(relaunched.playbackRate, 1.5)
        XCTAssertEqual(relaunched.automationSettings.refreshPolicy, .whileOpen(everyHours: 6))
    }

    // MARK: Show notes

    /// The row leads with what the episode is about when the feed says so,
    /// and the fixture carries notes so the pane has something to show.
    func testEpisodeRowSummaryComesFromTheNotesOpeningParagraph() throws {
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: "\n\n  Hosts discuss M6.  \n\nGuest: Ada", fallback: "Leo"),
            "Hosts discuss M6."
        )
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: nil, fallback: "Leo"), "Leo")
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: "   \n ", fallback: "Leo"), "Leo")
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: String(repeating: "x", count: 500), fallback: "Leo").count, 180
        )

        let directory = temporaryDirectory("fixture-notes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(fixture.episodes.first)
        XCTAssertEqual(episode.notes, WiltedMacModel.fixtureEpisodeNotes)
        XCTAssertEqual(episode.summary, "A walk through the machines that keep the field office quiet.")
    }

    func testNotesLinksAreClickable() {
        let notes = "Guest: Ada (https://example.com/ada) and code WILTED at example.com/quiet."
        let linked = WiltedShowNotes.linked(notes)
        let links = linked.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/ada", "http://example.com/quiet"])
        XCTAssertEqual(String(linked.characters), notes, "linking must not alter the words")
    }

    // MARK: Prep page

    /// After a relaunch the row must still answer "were the advertisements
    /// removed?", not just "is there a transcript?".
    func testPreparedSummaryIsRecoveredFromTheJournal() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "6", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "6", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available, text: "Words.", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")], updatedAt: when
        )
        func run(terminal: String, completion: String?, terminalRevisionID: RevisionID) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let completion {
                entries.append(PreparationJournalEntry(
                    id: requestID + "|pipeline.complete", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(stage: .preparing, detail: completion, cancellable: true, emittedAt: when)
                ))
            }
            entries.append(PreparationJournalEntry(
                id: requestID + "|terminal", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .completed, detail: terminal, cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: terminalRevisionID),
                    emittedAt: when
                )
            ))
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: terminal, fraction: nil, isTerminal: true, outcome: .succeeded, failure: nil, entries: entries
            )
        }
        func outcome(for revisionID: RevisionID) -> PodcastPreparationOutcome {
            PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                      pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        }

        // A current build journals the summary itself as the terminal row.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Ready · 5 ads removed (7:22) · transcript synced",
                                                         completion: "5 advertisements, 1307 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 5 ads removed (7:22) · transcript synced")
        )
        // Older builds wrote "Prepared." and counted advertisements one row
        // earlier; zero there is the honest state of an episode the broken
        // detector build marked prepared.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: "0 advertisements, 1345 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · no ads found · transcript synced")
        )
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: "3 advertisements, 900 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )
        // Transcript timing alone cannot prove that preparation completed.
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: transcript),
                       .notPrepared)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: nil,
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · transcript synced")
        )
        let staleRevisionID = try RevisionID(rawValue: "rev-" + String(repeating: "8", count: 64))
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: staleRevisionID),
                run: try run(terminal: "Ready · transcript synced", completion: nil,
                             terminalRevisionID: staleRevisionID),
                readyRevisionID: revisionID,
                transcript: transcript
            ),
            .notPrepared,
            "An outcome proven for an older audio revision cannot label the current download prepared."
        )
    }

    /// Phase 4 gate: relaunch must reconstruct the right state from durable
    /// facts alone for every journal state a preparation run can be in --
    /// queued, running, cancelled, failed, or completed -- plus the case
    /// where a run's own terminal result names a revision the outcome row
    /// has since moved past.
    func testRefreshAcrossEveryPreparationStateReconstructsFromDurableFactsAlone() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "7", count: 64))
        let supersededRevisionID = try RevisionID(rawValue: "rev-" + String(repeating: "9", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        func nonTerminalRun(stage: PreparationStage) -> PreparationRunSummary {
            PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: stage,
                detail: "Working…", fraction: nil, isTerminal: false, outcome: nil, failure: nil, entries: []
            )
        }
        func terminalRun(outcome: PreparationOutcome, terminalRevisionID: RevisionID?) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let terminalRevisionID {
                entries = [PreparationJournalEntry(
                    id: requestID + "|terminal", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(
                        stage: .completed, detail: "Prepared.", cancellable: false,
                        terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: terminalRevisionID),
                        emittedAt: when
                    )
                )]
            }
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: "Prepared.", fraction: nil, isTerminal: true, outcome: outcome, failure: nil, entries: entries
            )
        }
        func outcome(for revisionID: RevisionID) -> PodcastPreparationOutcome {
            PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                      pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        }

        // Queued: not yet terminal, no outcome yet. `PreparationStage` has no
        // dedicated `queued` case; `.preparing` is the stage a freshly
        // admitted, not-yet-started run carries.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: nonTerminalRun(stage: .preparing),
                                            readyRevisionID: revisionID, transcript: nil),
            .preparing(stage: "Preparing…")
        )
        // Running: also not yet terminal, no outcome yet.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: nonTerminalRun(stage: .extracting),
                                            readyRevisionID: revisionID, transcript: nil),
            .preparing(stage: "Preparing…")
        )
        // Cancelled: terminal, but cancellation is not failure and not proof.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: try terminalRun(outcome: .cancelled, terminalRevisionID: nil),
                                            readyRevisionID: revisionID, transcript: nil),
            .notPrepared
        )
        // Failed: terminal, no outcome -- the row says it failed.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: try terminalRun(outcome: .failed, terminalRevisionID: nil),
                                            readyRevisionID: revisionID, transcript: nil),
            .failed(WiltedMacModel.preparationFailedLabel)
        )
        // Completed: terminal, succeeded, outcome present and matching.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: try terminalRun(outcome: .succeeded, terminalRevisionID: revisionID),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable")
        )
        // Completed but superseded: this run's own terminal result names an
        // older revision the ready revision has since moved past, but the
        // outcome row proves the *current* ready revision is prepared. The
        // stale run must not derail that proof.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: try terminalRun(outcome: .succeeded, terminalRevisionID: supersededRevisionID),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable"),
            "A proven outcome for the current ready revision must not be demoted by an older run's own result."
        )
        // Committed, died before the terminal write: the run is still open
        // (its own terminal journal entry never landed), but a matching,
        // non-invalid outcome for the current ready revision proves it
        // finished. The outcome guard must win before `!run.isTerminal` is
        // ever consulted -- pinning this ordering so a refactor that hoists
        // the run-terminal check cannot silently regress it back to
        // "Preparing…" forever over a proven artifact.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: nonTerminalRun(stage: .saving),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable"),
            "A durable outcome for the current ready revision must win even while its own run is still open."
        )
    }

    /// A failed run is retried from Prep, next to the reason it failed.
    func testRetryFromPrepPreparesTheRunsEpisode() throws {
        let directory = temporaryDirectory("retry-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertEqual(episode.preparationState, .notPrepared)
        let failed = WiltedMacProcessorRun(
            id: WiltedMacModel.podcastRequestPrefix + episode.id, itemID: episode.id, isPodcast: true,
            title: episode.title, source: episode.feedTitle, stage: "failed",
            detail: "the model failed 30 of 50 requests", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(failed)
        XCTAssertTrue(model.episodes.first?.preparationState.isRunning == true, "Retry must start a run")

        let article = WiltedMacProcessorRun(
            id: "article-request", itemID: "not-an-episode", isPodcast: false, title: "Article", source: "Web",
            stage: "failed", detail: "Could not fetch", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(article)  // article runs have their own path; nothing to do
    }

    func testFourRapidPrepRetriesPublishOneActiveProjectionAndThreeQueuedRows() async throws {
        let directory = temporaryDirectory("retry-projection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let ids = ["retry-one", "retry-two", "retry-three", "retry-four"]
        let episodes = ids.map { id in
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .notPrepared
            )
        }
        episodes.forEach(model.installEpisodeForTesting)

        for episode in episodes {
            model.retryProcessorRun(WiltedMacProcessorRun(
                id: WiltedMacModel.podcastRequestPrefix + episode.id,
                itemID: episode.id, isPodcast: true, title: episode.title, source: episode.feedTitle,
                stage: "failed", detail: "previous failure", fraction: nil, outcome: .failed, updatedAt: Date()
            ))
        }

        XCTAssertEqual(
            model.processorRuns.filter { $0.outcome == .running }.map(\.itemID),
            [ids[0]],
            "the active retry is visible before the journal's first write"
        )
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), Array(ids.dropFirst()))
        XCTAssertTrue(model.episodes.allSatisfy { $0.preparationState.isRunning })

        await model.waitForPodcastPreparationOperationsForTesting()
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertTrue(model.processorRuns.filter { $0.outcome == .running }.isEmpty)
    }

    // MARK: Task 4.1 — preparation request sequence

    /// The gate admits the eligible set in request order, not in the order the
    /// runs reached it. Downloads finishing in a different order from the
    /// clicks is the defect this orders away.
    func testPreparationGateAdmitsWaitersInRequestSequenceOrder() async throws {
        let gate = WiltedPreparationGate()
        var admitted: [Int] = []
        try await gate.admit(sequence: 0)  // the holder

        let arrivals = [30, 20, 10]
        let tasks = arrivals.map { sequence in
            Task { @MainActor in
                try await gate.admit(sequence: sequence)
                admitted.append(sequence)
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(gate.queueDepth, arrivals.count)

        for _ in 0..<arrivals.count {
            gate.release()
            for _ in 0..<10 { await Task.yield() }
        }
        for task in tasks { try await task.value }
        XCTAssertEqual(admitted, [10, 20, 30],
                       "the request sequence decides, not the order the runs reached the gate")
    }

    /// Eligibility gates admission: a request still downloading is not at the
    /// gate, so a later eligible request takes the free slot; the lower-numbered
    /// request keeps its pending place.
    func testAnIneligibleRequestKeepsItsPendingPlaceWhileALaterEligibleRequestRuns() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let lower = model.registerPreparationRequest(for: "episode-still-downloading")
        let higher = model.consumePreparationRequest(for: "episode-downloaded")
        XCTAssertEqual([lower, higher], [1, 2])

        try await model.preparationGateForTesting.admit(sequence: higher)
        XCTAssertTrue(model.preparationGateForTesting.isBusy)

        XCTAssertEqual(model.preparationRequestSequences, ["episode-still-downloading": lower],
                       "the ineligible request is still pending, in its original place")
        XCTAssertEqual(model.preparationRequestSequence, higher)
    }

    /// The test above drives the gate directly, so it never exercises whether
    /// the *model* itself would hold the higher-numbered run back for the
    /// lower one -- a gate that always admits when free proves nothing about
    /// a model that refuses to ask it to. This one runs the real path: a
    /// still-downloading episode's request is registered and left pending,
    /// then a downloaded, later-numbered episode is sent through
    /// `retryProcessorRun`, the same entry point a reader's click uses. It
    /// must reach the gate and be admitted immediately rather than being
    /// entered into `preparationQueue` to wait for a lower number that has
    /// not arrived.
    func testAModelDrivenLaterEligibleRequestIsAdmittedRatherThanQueuedForALowerNumber() async throws {
        let directory = temporaryDirectory("later-eligible-not-queued-for-lower")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BlockingPodcastPipelineRunner()
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/later-eligible.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/later-eligible.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let higherItemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "later-eligible-1", enclosureURL: enclosureURL
        )
        let higherID = higherItemID.rawValue
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                // A real, downloaded-with-audio-on-disk episode: `prepare`
                // refuses anything less before it ever reaches the runner
                // below, and a fixture row alone (`installEpisodeForTesting`)
                // does not satisfy that -- it fails the pipeline's own
                // "is this actually downloaded" guard before the gate's
                // admission decision is observable.
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fixtures", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    higherItemID, guid: "later-eligible-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            },
            podcastPipelineRunnerFactory: { runner },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.episodes.map(\.id), [higherID])

        let lowerID = "episode-still-downloading"
        let lower = model.registerPreparationRequest(for: lowerID)
        let higher = model.registerPreparationRequest(for: higherID)
        XCTAssertEqual([lower, higher], [1, 2])

        model.retryProcessorRun(WiltedMacProcessorRun(
            id: WiltedMacModel.podcastRequestPrefix + higherID,
            itemID: higherID, isPodcast: true, title: "Downloaded", source: "Fixtures",
            stage: "failed", detail: "previous failure", fraction: nil, outcome: .failed, updatedAt: Date()
        ))

        XCTAssertTrue(model.episodes.first(where: { $0.id == higherID })?.preparationState.isRunning == true,
                      "the later, eligible request starts rather than sitting queued")
        XCTAssertFalse(model.preparationQueue.entries.contains { $0.id == higherID },
                       "a free slot is not held open for the lower number still downloading")
        XCTAssertEqual(model.preparationRequestSequences, [lowerID: lower],
                       "the still-downloading request keeps its original pending place")

        // The decision above is made synchronously, before the run's task body
        // ever reaches `gate.admit` -- that happens one main-actor hop later.
        // The runner blocks once the pipeline actually calls it, so settling
        // here lands the run at a deterministic point: admitted and running
        // if the gate let it through, or still queued if a gate reserved the
        // free slot for the lower, still-outstanding sequence instead.
        try await settle(model, iterations: 20)
        XCTAssertTrue(model.preparationGateForTesting.isBusy,
                      "the later request reached and was admitted by the gate, not left waiting on it")
        XCTAssertEqual(model.preparationGateForTesting.queueDepth, 0)

        // Unstick the run however it actually ended up: released from the
        // pipeline if it was admitted, or cancelled out of the queue if the
        // assertion above already caught it stuck waiting. Either path
        // resolves quickly, so a failing assertion above reports as a clean
        // test failure rather than a hang.
        if model.preparationGateForTesting.isBusy {
            await runner.resume(throwing: CancellationError())
        } else {
            model.cancelEpisodePreparation(model.episodes.first(where: { $0.id == higherID })!)
        }
        await model.waitForPodcastPreparationOperationsForTesting()
    }

    /// Article text-to-speech and podcast preparation share one GPU. The
    /// article path used to start its coordinator without asking the gate, so
    /// both could hold the device at once.
    func testAnArticleAsksTheSameAdmissionGateAsAPodcast() async throws {
        let directory = temporaryDirectory("article-admission")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let gate = model.preparationGateForTesting
        try await gate.admit(sequence: 1)
        XCTAssertTrue(gate.isBusy, "the slot is held before the article asks for it")

        model.urlDraft = "https://example.test/an-article"
        model.addArticle()

        XCTAssertEqual(model.preparation?.phase, .preparing)
        XCTAssertEqual(model.preparation?.detail, WiltedMacModel.articlePreparationQueuedDetail,
                       "a queued article says so rather than sitting on a stale step label")
        XCTAssertTrue(model.preparation?.cancellable ?? false,
                      "a queued article can still be cancelled")
    }

    /// Cancel used to reach only the run, which does not exist yet while the
    /// article is queued -- so it did nothing until the work ahead finished.
    func testCancellingAQueuedArticleLeavesTheLineImmediately() async throws {
        let directory = temporaryDirectory("article-admission-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let gate = model.preparationGateForTesting
        try await gate.admit(sequence: 1)
        model.urlDraft = "https://example.test/an-article"
        model.addArticle()
        XCTAssertEqual(model.preparation?.detail, WiltedMacModel.articlePreparationQueuedDetail)

        model.cancelPreparation()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.preparation?.phase, .cancelled,
                       "the queued article reports its own terminal state; no status stream ever opened")
        gate.release()
        XCTAssertFalse(gate.isBusy, "the cancelled article left no waiter holding the slot")
    }

    /// Step 6's done-condition. An article's ticket is keyed by the draft
    /// URL's `ItemID` -- a stable request key, computed without ever
    /// reaching the network -- from the moment the reader asks for it, the
    /// same way `registerPreparationRequest` keys a podcast's. Holding the
    /// gate busy means this article's run never reaches the coordinator at
    /// all: admission is taken (the ticket becomes `.running`), but nothing
    /// in this process ever finishes the run or records a terminal outcome
    /// -- exactly what "interrupted by relaunch" means here. A second model
    /// opened against the same store must find the ticket table already
    /// resolved by `reconcileWorkTickets(in:)`'s interrupted-run pass:
    /// resumable (`.pending`) or a named terminal state, never stuck at
    /// `.running` forever.
    func testAnArticleInterruptedByRelaunchEmergesResumableOrTerminal() async throws {
        let directory = temporaryDirectory("article-ticket-relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let storeCapture = StoreCapture()
        let draftURL = try XCTUnwrap(URL(string: "https://example.test/an-interrupted-article"))
        let subjectID = try ItemID.derive(from: draftURL).rawValue

        let first = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                await storeCapture.capture(store)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        first.startStoreBootstrap()
        await first.waitForStoreBootstrap()

        let gate = first.preparationGateForTesting
        try await gate.admit(sequence: 1)
        first.urlDraft = draftURL.absoluteString
        first.addArticle()
        XCTAssertEqual(first.preparation?.detail, WiltedMacModel.articlePreparationQueuedDetail,
                       "queued behind the gate -- the run never reaches the coordinator")

        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        func fetchedTicket() async throws -> WorkTicket? {
            try await capturedStore.workTicket(kind: .articlePreparation, subjectID: subjectID)
        }
        var attempts = 0
        var ticket = try await fetchedTicket()
        while attempts < 50, ticket == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            ticket = try await fetchedTicket()
            attempts += 1
        }
        let interruptedTicket = try XCTUnwrap(ticket, "request creation must be durable before any relaunch")
        XCTAssertEqual(interruptedTicket.state, .running,
                       "admission was taken; the run itself never started because the gate is held")
        gate.release()

        // The process ends here, with the ticket stuck at `.running` --
        // nothing in it ever finished the run or recorded a terminal outcome.
        let second = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        second.startStoreBootstrap()
        await second.waitForStoreBootstrap()
        XCTAssertEqual(second.startupState, .ready)

        let reopenedStore = try LocalLibraryStore(url: libraryURL)
        let reopenedTicket = try await reopenedStore.workTicket(kind: .articlePreparation, subjectID: subjectID)
        let resumed = try XCTUnwrap(reopenedTicket)
        XCTAssertTrue(
            resumed.state == .pending || resumed.state.isTerminal,
            "an article interrupted by relaunch emerges resumable (.pending) or in a named terminal state, "
            + "never stuck at .running -- got \(resumed.state)"
        )
    }

    /// A run that consumed its place must not leave one behind: if it did, a
    /// later request for the same episode would inherit the old, too-low
    /// number and jump the queue ahead of everything asked for since.
    func testAskingAgainAfterARunTakesAFreshPlaceInLine() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let first = model.consumePreparationRequest(for: "episode")
        XCTAssertEqual(model.preparationRequestSequences, [:],
                       "a consumed request holds no place")

        let other = model.registerPreparationRequest(for: "other-episode")
        let second = model.registerPreparationRequest(for: "episode")
        XCTAssertGreaterThan(second, other,
                             "asking again queues behind what was asked for in between")
        XCTAssertGreaterThan(second, first)
    }

    /// The counter is persisted, so the click order outlives the process.
    func testPreparationRequestSequenceSurvivesAModelRebuild() throws {
        let suite = "com.zerodelta.wilted.mac.preparation-sequence-tests"
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("preparation-sequence")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(first.preparationRequestSequence, 0)
        let one = first.registerPreparationRequest(for: "episode-one")
        let repeated = first.registerPreparationRequest(for: "episode-one")
        let two = first.registerPreparationRequest(for: "episode-two")
        XCTAssertEqual([one, repeated, two], [1, 1, 2],
                       "a repeated request keeps its original place")

        let rebuilt = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(rebuilt.preparationRequestSequence, 2,
                       "the restored sequence equals the one written")
        XCTAssertTrue(rebuilt.preparationRequestSequences.isEmpty,
                      "in-flight requests do not survive the process that made them")
        XCTAssertEqual(rebuilt.registerPreparationRequest(for: "episode-three"), 3)
    }

    /// Step 4's done-condition: a request pending at relaunch keeps its
    /// number and its place, because the ticket table -- not preferences --
    /// is now the writer of record. Two requests are registered and their
    /// distinct numbers asserted (the in-memory face, live) *before*
    /// teardown, proving the pre-relaunch half is not just assumed; the
    /// rebuilt model's projection and a raw store read afterward both prove
    /// the post-relaunch half.
    func testAPendingRequestKeepsItsPlaceAcrossARelaunch() async throws {
        let directory = temporaryDirectory("ticket-relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let storeCapture = StoreCapture()

        let first = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                await storeCapture.capture(store)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        first.startStoreBootstrap()
        await first.waitForStoreBootstrap()
        XCTAssertEqual(first.startupState, .ready)

        let lowerSequence = first.registerPreparationRequest(for: "episode-alpha")
        let higherSequence = first.registerPreparationRequest(for: "episode-beta")
        XCTAssertNotEqual(lowerSequence, higherSequence, "two distinct requests, two distinct numbers")
        XCTAssertEqual(first.preparationRequestSequences["episode-alpha"], lowerSequence,
                       "live, in-memory, before teardown")
        XCTAssertEqual(first.preparationRequestSequences["episode-beta"], higherSequence,
                       "live, in-memory, before teardown")

        // `registerPreparationRequest`'s ticket write is fire-and-forget from
        // an async context it does not itself await; poll the durable table
        // rather than assume a fixed number of yields is enough.
        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        func pendingTicketCount() async throws -> Int {
            try await capturedStore.workTickets().filter {
                $0.kind == .podcastPreparation && $0.state == .pending
            }.count
        }
        var attempts = 0
        while attempts < 50, try await pendingTicketCount() < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }
        let finalCount = try await pendingTicketCount()
        XCTAssertEqual(finalCount, 2, "both requests must have become durable tickets")

        let second = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        second.startStoreBootstrap()
        await second.waitForStoreBootstrap()
        XCTAssertEqual(second.startupState, .ready)

        XCTAssertEqual(second.preparationRequestSequences["episode-alpha"], lowerSequence,
                       "the still-pending request kept its original number across the relaunch")
        XCTAssertEqual(second.preparationRequestSequences["episode-beta"], higherSequence,
                       "the still-pending request kept its original number across the relaunch")

        let reopenedStore = try LocalLibraryStore(url: libraryURL)
        let alphaTicket = try await reopenedStore.workTicket(kind: .podcastPreparation, subjectID: "episode-alpha")
        XCTAssertEqual(alphaTicket?.requestSequence, lowerSequence)
        XCTAssertEqual(alphaTicket?.state, .pending)
        let betaTicket = try await reopenedStore.workTicket(kind: .podcastPreparation, subjectID: "episode-beta")
        XCTAssertEqual(betaTicket?.requestSequence, higherSequence)
        XCTAssertEqual(betaTicket?.state, .pending)
    }

    /// Regression for a lost-update race: `registerPreparationRequest`
    /// (writes `.pending`) and `consumePreparationRequest` (writes
    /// `.running`) both dispatch detached `Task`s into
    /// `recordWorkTicketTransition`, and Swift gives no ordering guarantee
    /// between them. Calling both back-to-back with no `await` in between --
    /// no quiescence wait, unlike every other test in this file -- is exactly
    /// the shape that let the two writes interleave and the later one
    /// silently clobber the earlier one's `state`/`attemptCount`.
    ///
    /// Whichever of the two `Task`s actually lands first at the store, the
    /// ticket must settle on `.running` with `attemptCount == 1`: consume
    /// logically follows register (it was called second, on the same
    /// actor-isolated caller, and it already removed the sequence from
    /// `preparationRequestSequences`), so `.running` is the only correct
    /// final state -- a `.pending` win would mean the transition that
    /// happened later in real dispatch order got discarded.
    func testInterleavedRegisterAndConsumeSettleOnTheLaterTransition() async throws {
        let directory = temporaryDirectory("ticket-interleave")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let storeCapture = StoreCapture()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                await storeCapture.capture(store)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        // No `await` between these two calls: both fire their transition
        // `Task`s into flight before either has a chance to land.
        let sequence = model.registerPreparationRequest(for: "episode-interleaved")
        let consumedSequence = model.consumePreparationRequest(for: "episode-interleaved")
        XCTAssertEqual(sequence, consumedSequence, "consume claims the exact number register reserved")

        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        func settledTicket() async throws -> WorkTicket? {
            try await capturedStore.workTicket(kind: .podcastPreparation, subjectID: "episode-interleaved")
        }
        var attempts = 0
        var fetched = try await settledTicket()
        while attempts < 50, fetched?.state != .running {
            try await Task.sleep(nanoseconds: 20_000_000)
            fetched = try await settledTicket()
            attempts += 1
        }
        let ticket = try XCTUnwrap(fetched)
        XCTAssertEqual(ticket.state, .running, "the later (running) transition must win, never the earlier pending")
        XCTAssertEqual(ticket.attemptCount, 1, "exactly one attempt recorded, not zero and not double-counted")
        XCTAssertEqual(ticket.requestSequence, sequence)

        // Reopen the store directly, independent of the live model, to prove
        // this is durable and not just an in-memory read.
        let reopenedStore = try LocalLibraryStore(url: libraryURL)
        let reopenedTicket = try await reopenedStore.workTicket(kind: .podcastPreparation, subjectID: "episode-interleaved")
        XCTAssertEqual(reopenedTicket?.state, .running)
        XCTAssertEqual(reopenedTicket?.attemptCount, 1)
    }

    /// Step 5's done-condition: a download that exhausts `withRetries`'
    /// bounded backoff and a preparation that fails outright both settle on
    /// a `.failed` ticket naming a `PodcastDownloadFailureKind`, read back
    /// from the store -- not inferred from in-memory model state.
    func testAFailingDownloadAndAFailingPreparationBothSettleOnANamedTerminalTicket() async throws {
        let directory = temporaryDirectory("ticket-failure-classification")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/ticket-failure.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let downloadEnclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/ticket-failure-download.mp3"))
        let downloadEpisodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "ticket-failure-download", enclosureURL: downloadEnclosureURL
        )
        let prepEnclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/ticket-failure-prep.mp3"))
        let prepEpisodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "ticket-failure-prep", enclosureURL: prepEnclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Ticket failure feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: downloadEpisodeID, feedID: feedID, feedURL: feedURL, rssGUID: "ticket-failure-download",
                    title: "Failing download", publishedTime: created, enclosureURL: downloadEnclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // A stranded claim: automation's reconcile drains it with
                // `alreadyClaimed: true`, exactly as a relaunch after a crash
                // mid-download would, and the transport below always
                // answers 503 -- retryable, and `withRetries` exhausts its
                // bound rather than succeeding.
                try await store.save(download: PodcastDownload(
                    episodeID: downloadEpisodeID, status: .queued, updatedAt: created
                ))
                try await store.addPodcastQueueEpisode(downloadEpisodeID)
                try await store.save(episode: try PodcastEpisode(
                    itemID: prepEpisodeID, feedID: feedID, feedURL: feedURL, rssGUID: "ticket-failure-prep",
                    title: "Failing preparation", publishedTime: created, enclosureURL: prepEnclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // Deliberately no download row for this one: `pipeline.prepare`
                // refuses an episode with nothing downloaded before it ever
                // reaches a worker, which is a real, deterministic failure.
                return store
            },
            podcastDownloadTransportFactory: {
                CountingFailingPodcastDownloadTransport(enclosureURL: downloadEnclosureURL, statusCode: 503, counter: counter)
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        // Drains the stranded claim above through the real bounded retry
        // schedule; by the time this returns the download's ticket write
        // already happened inside the same task `withRetries` awaited.
        await model.waitForAutomation()

        let prepEpisode = WiltedMacEpisode(
            id: prepEpisodeID.rawValue, title: "Failing preparation", feedTitle: "Ticket failure feed",
            summary: "", artworkURL: nil, releasedAt: created.date, durationSeconds: nil,
            playbackSeconds: 0, downloadState: .notDownloaded
        )
        model.installEpisodeForTesting(prepEpisode)
        model.prepareEpisode(prepEpisode)
        await model.waitForPodcastPreparationOperationsForTesting()

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let downloadTicket = try await store.workTicket(kind: .podcastDownload, subjectID: downloadEpisodeID.rawValue)
        XCTAssertEqual(downloadTicket?.state, .failed)
        XCTAssertEqual(downloadTicket?.failureKind, PodcastDownloadFailureKind.retryable.rawValue,
                       "a 503 is `.invalidResponse`, classified retryable")

        let prepTicket = try await store.workTicket(kind: .podcastPreparation, subjectID: prepEpisodeID.rawValue)
        XCTAssertEqual(prepTicket?.state, .failed)
        XCTAssertNotNil(prepTicket?.failureKind, "a failed ticket must name a failure kind")
    }

    /// Step 5's other done-condition: the ticket's `policySnapshot` is the
    /// one captured when the run was admitted, not whatever `automationSettings`
    /// says by the time the run actually starts. The gate is held closed so
    /// the mutation below provably lands in the window between admission and
    /// run start rather than before either.
    func testTheAdmittedPolicyEqualsTheSnapshotCapturedAtRequest() async throws {
        let directory = temporaryDirectory("ticket-admitted-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/ticket-policy.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/ticket-policy.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "ticket-policy", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Ticket policy feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "ticket-policy", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        // Holds the gate closed so `prepareEpisode` below admits, is issued
        // a ticket, and then sits queued rather than starting immediately.
        let gate = model.preparationGateForTesting
        try await gate.admit(sequence: 1)

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable, removeAds: false
        ))
        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))
        model.prepareEpisode(episode)

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        func admittedTicket() async throws -> WorkTicket? {
            try await store.workTicket(kind: .podcastPreparation, subjectID: episodeID.rawValue)
        }
        var pollAttempts = 0
        while pollAttempts < 50, try await admittedTicket()?.policySnapshot == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            pollAttempts += 1
        }
        let fetchedAtAdmission = try await admittedTicket()
        let ticketAtAdmission = try XCTUnwrap(fetchedAtAdmission)
        let snapshotAtAdmission = try XCTUnwrap(ticketAtAdmission.policySnapshot)
        let decodedAtAdmission = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: snapshotAtAdmission)
        XCTAssertEqual(decodedAtAdmission.removeAds, false, "captured from the settings in effect at admission")

        // Mutated only now, after admission -- while the run still sits
        // queued behind the gate held above.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable, removeAds: true
        ))

        let ticketAfterMutation = try await admittedTicket()
        let snapshotAfterMutation = try XCTUnwrap(ticketAfterMutation?.policySnapshot)
        let decodedAfterMutation = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: snapshotAfterMutation)
        XCTAssertEqual(decodedAfterMutation.removeAds, false,
                       "the ticket's policy is immutable once admitted -- a later settings change must not reach it")

        // Unstick the run so the task does not outlive the test.
        gate.release()
        await model.waitForPodcastPreparationOperationsForTesting()
    }

    /// Ordering preparations must not order downloads. Two ordinary downloads
    /// still overlap, and the peak is asserted so this diff cannot silently
    /// serialize transfers.
    func testTwoOrdinaryDownloadsStillOverlapAfterPreparationOrderingLanded() async throws {
        let directory = temporaryDirectory("download-overlap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/overlap.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let downloads = try (0..<2).map { index -> (enclosure: URL, id: ItemID) in
            let enclosure = try XCTUnwrap(
                URL(string: "https://media.example.test/overlap-\(index).mp3")
            )
            return (enclosure, try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "overlap-\(index)", enclosureURL: enclosure
            ))
        }
        let enclosures = downloads.map(\.enclosure)
        let episodeIDs = downloads.map(\.id)
        let eventsByURL = Dictionary(uniqueKeysWithValues: enclosures.map { url in
            (url, [
                PodcastDownloadEvent.response(.init(
                    url: url, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4
                )),
                PodcastDownloadEvent.data(Data("body".utf8))
            ])
        })
        let transport = ConcurrencyTrackingPodcastDownloadTransport(eventsByURL: eventsByURL)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Overlap feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in episodeIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: "overlap-\(index)",
                        title: "Overlap episode \(index)", publishedTime: created,
                        enclosureURL: enclosures[index], enclosureMediaType: "audio/mpeg", createdAt: created
                    ))
                }
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episodes = episodeIDs.compactMap { id in
            model.episodes.first(where: { $0.id == id.rawValue })
        }
        XCTAssertEqual(episodes.count, 2)
        for episode in episodes { model.downloadEpisode(episode) }
        await model.waitForPodcastOperations()

        let peak = await transport.maxObservedInFlight
        XCTAssertEqual(peak, 2,
                       "ordinary downloads overlap; ordering preparations must not serialize them")
    }

    func testMenuAndLarderIndicatorsShareTheCurrentQueueSnapshot() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = try XCTUnwrap(model.episodes.first)
        let queued = WiltedMacEpisode(
            id: "queue-coherence-next", title: "Queued next", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        model.installEpisodeForTesting(queued)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [current.id, queued.id]
        )

        XCTAssertEqual(model.menuUpcomingEpisodeIDs, [current.id, queued.id])
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Playing"])
        XCTAssertEqual(model.episodePlaybackIndicators(for: queued.id), ["In Larder"])
        XCTAssertFalse(model.episodePlaybackIndicators(for: current.id).contains("In Larder"))
    }

    /// The journal stores the coarse stage every pipeline shares; the worker's
    /// own stage name survives only in the entry key, and that is what the
    /// detailed log has to show.
    func testProcessorEventsRecoverTheWorkerStageFromTheJournalKey() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "8", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ id: String, _ stage: PreparationStage, _ detail: String, at offset: TimeInterval) throws -> PreparationJournalEntry {
            PreparationJournalEntry(
                id: id, itemID: itemID, requestID: requestID,
                status: try PreparationStatus(stage: stage, detail: detail, cancellable: true,
                                              emittedAt: Timestamp(when.addingTimeInterval(offset)))
            )
        }
        let run = PreparationRunSummary(
            requestID: requestID, itemID: itemID, startedAt: Timestamp(when), updatedAt: Timestamp(when),
            stage: .assembling, detail: "50 requests, 0 failed", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil,
            entries: [
                try entry(requestID + "|transcript.stt.start#1", .extracting, "transcript.stt.start", at: 0),
                try entry(requestID + "|ads.detect.calls#2", .assembling, "50 requests, 0 failed", at: 60),
                try entry(requestID + "|log.warning.1#3", .assembling, "wilted.ads: FA is not enabled", at: 61),
                try entry("legacy-key-without-prefix", .saving, "Storing", at: 62),
            ]
        )

        let events = WiltedMacModel.processorEvents(for: run)
        XCTAssertEqual(events.map(\.stage), ["transcript.stt.start", "ads.detect.calls", "log.warning.1", "saving"])
        XCTAssertEqual(events[0].line, "transcript.stt.start", "a status with no detail is just its stage")
        XCTAssertEqual(events[1].line, "ads.detect.calls · 50 requests, 0 failed")
        XCTAssertEqual(events[2].at, when.addingTimeInterval(61))

        // A running podcast run is narrated from its latest real stage; a
        // forwarded warning is not a stage.
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: true, outcome: .running, detail: "wilted.ads: FA is not enabled",
                                              events: Array(events.prefix(3))),
            "Finding advertisements…"
        )
        // Finished runs, and article runs, say what the journal recorded.
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: true, outcome: .failed, detail: "the model failed 30 of 50 requests",
                                              events: events),
            "the model failed 30 of 50 requests"
        )
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: false, outcome: .running, detail: "Extracting the article…",
                                              events: events),
            "Extracting the article…"
        )
    }

    // MARK: Preparation presentation

    func testPreparationLabelsSpeakToTheListenerNotTheWorker() {
        let cases: [(String, String)] = [
            ("transcript.published.fetch", "Fetching the published transcript…"),
            ("transcript.stt.start", "Transcribing the audio…"),
            ("transcript.glossary.progress", "Correcting names from the show notes…"),
            ("transcript.glossary.complete", "Correcting names from the show notes…"),
            ("ads.detect.start", "Finding advertisements…"),
            ("ads.cut.refused", "Advertisements left in place."),
            ("audio.publish", "Storing the prepared audio…"),
            ("pipeline.complete", "Prepared."),
        ]
        for (stage, expected) in cases {
            XCTAssertEqual(
                WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: stage)),
                expected, "stage \(stage)"
            )
        }
        // An unrecognised stage still says something rather than going blank.
        XCTAssertEqual(
            WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: "something.new")),
            "Preparing…"
        )
    }

    /// Only a successful terminal journal for the ready revision proves that
    /// an episode is prepared; transcript timing is descriptive, not proof.
    func testPreparationStateComesFromWhatTheLibraryCanProve() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "7", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func transcript(_ timing: TranscriptTiming, _ availability: TranscriptAvailability = .available) throws -> Transcript {
            try Transcript(
                itemID: itemID, revisionID: revisionID, availability: availability,
                text: availability == .available ? "Words." : nil, timing: timing,
                cues: timing == .none ? nil : [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")],
                updatedAt: when
            )
        }

        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: nil), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.published)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.none)), .notPrepared)

        let failed = PreparationRunSummary(
            requestID: "podcast-prepare|" + itemID.rawValue, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .failed, detail: "Wilted could not start the preparation pipeline.",
            fraction: nil, isTerminal: true, outcome: .failed, failure: nil
        )
        // The row says only that it failed; the reason and the log are on Prep.
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: failed, readyRevisionID: revisionID,
                                                       transcript: nil),
                       .failed(WiltedMacModel.preparationFailedLabel))
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: failed, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .failed(WiltedMacModel.preparationFailedLabel))

        let running = PreparationRunSummary(
            requestID: failed.requestID, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .extracting, detail: "Transcribing", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil
        )
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: running, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .preparing(stage: "Preparing…"))

        // A proven outcome is not demoted by a later run's own failure -- a
        // re-preparation that changed nothing must not un-prepare the episode.
        let outcome = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome, run: failed, readyRevisionID: revisionID,
                                            transcript: try transcript(.aligned)),
            .prepared(summary: "\(PodcastPreparationResult.readyLabel) · \(PodcastPreparationResult.transcriptStep(.aligned))")
        )
        // A legacy-invalidated outcome is not proof, even for the ready revision.
        let invalidated = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                    pipelineFingerprint: "f", semanticVersion: "v", producedAt: when,
                                                    eligibility: .invalid)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: invalidated, run: nil, readyRevisionID: revisionID,
                                            transcript: try transcript(.aligned)),
            .notPrepared
        )
    }

    func testEpisodePreparationStateLarderLabelsShowOnlyProvenCompletedSummary() {
        XCTAssertNil(WiltedMacEpisodePreparationState.notPrepared.larderLabel)

        let summary = "Ready · 5 ads removed (7:22) · transcript synced"
        let prepared = WiltedMacEpisodePreparationState.prepared(summary: summary)
        XCTAssertEqual(prepared.label, summary)
        XCTAssertEqual(prepared.larderLabel, summary)

        let preparing = WiltedMacEpisodePreparationState.preparing(stage: "Preparing…")
        XCTAssertEqual(preparing.label, "Preparing…")
        XCTAssertEqual(preparing.larderLabel, "Preparing…")

        let failed = WiltedMacEpisodePreparationState.failed(WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.label, WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.larderLabel, WiltedMacModel.preparationFailedLabel)
    }

    func testEpisodeLifecyclePresentationCoversPrecedenceAndAvailableDetails() {
        let cases: [(
            download: WiltedMacEpisodeDownloadState,
            preparation: WiltedMacEpisodePreparationState,
            expected: String,
            failure: Bool
        )] = [
            (.notDownloaded, .prepared(summary: "Ready \u{00B7} transcript synced"), "Not downloaded", false),
            (.queued, .failed("old failure"), "Download queued", false),
            (.downloading(received: 2, expected: 10), .prepared(summary: "Ready"), "Downloading 20%", false),
            (.downloading(received: 1, expected: nil), .notPrepared, "Downloading 1 byte", false),
            (.downloading(received: 0, expected: nil), .notPrepared, "Downloading", false),
            (.failed, .prepared(summary: "Ready"), "Download failed", true),
            (.cancelled, .preparing(stage: "Finding advertisements\u{2026}"), "Download cancelled", false),
            (.completed, .notPrepared, "Downloaded \u{00B7} Ready to prepare", false),
            (.completed, .preparing(stage: "Queued"), "Preparing \u{00B7} Queued", false),
            (.completed, .preparing(stage: "Preparing\u{2026}"), "Preparing", false),
            (.completed, .prepared(summary: "Ready \u{00B7} 5 ads removed \u{00B7} transcript synced"),
             "Prepared \u{00B7} 5 ads removed \u{00B7} transcript synced", false),
            (.completed, .failed("Preparation failed. See Prep."), "Preparation failed \u{00B7} See Prep.", true),
        ]

        for value in cases {
            let presentation = WiltedMacEpisodeLifecyclePresentation(
                downloadState: value.download,
                preparationState: value.preparation
            )
            XCTAssertEqual(presentation.label, value.expected)
            XCTAssertEqual(presentation.isFailure, value.failure)
        }
    }

    func testArticlePlaybackStateLoadsFromStore() async throws {
        let directory = temporaryDirectory("article-playback-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/article-progress"))
        let itemID = try ItemID.derive(from: articleURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let article = try Article(
            itemID: itemID, canonicalURL: articleURL, title: "Partly heard",
            source: "Example", createdAt: created
        )
        let audioURL = directory.appendingPathComponent("article.m4a")
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * 2)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
            itemID: itemID, destinationURL: audioURL
        )
        let playback = try PlaybackState(
            itemID: itemID, revisionID: assembled.revision.revisionID,
            sessionID: "article-progress", sequence: 1, positionSeconds: 0.75,
            durationSeconds: assembled.revision.durationSeconds, completed: false,
            intent: .progress, deviceID: "test-device", updatedAt: created
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(article: article)
                try await store.save(revision: assembled.revision, mediaURL: audioURL)
                try await store.save(playback: playback)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let loaded = try XCTUnwrap(model.articles.first)
        XCTAssertEqual(loaded.playbackSeconds, 0.75)
        XCTAssertFalse(loaded.isPlayed)
        XCTAssertEqual(try XCTUnwrap(loaded.durationSeconds, "the loaded article did not carry a duration"),
                       try XCTUnwrap(assembled.revision.durationSeconds, "the assembled revision did not carry a duration"), accuracy: 0.001,
                       "the saved position and the assembled audio's duration both survive the store load")
    }

    func testLivePlaybackReadoutTracksScrubbingWithoutStoreReload() async throws {
        let directory = temporaryDirectory("live-playback-readout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = try XCTUnwrap(model.articles.first)
        XCTAssertEqual(article.durationSeconds, 120)

        model.openNowPlaying(for: article)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.playbackPositionSeconds, 60)
    }

    func testSwitchingPlaybackItemsRetainsOutgoingProgress() async throws {
        let directory = temporaryDirectory("switch-playback-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.articles.first)
        let second = WiltedMacArticle(
            id: "second-article", title: "Second", source: "Example",
            url: URL(string: "https://example.test/second")!, isReady: true,
            durationSeconds: 120
        )
        model.installArticleForTesting(second)
        model.openNowPlaying(for: first)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        model.openNowPlaying(for: second)
        await model.waitForPlaybackOperationForTesting()

        // The outgoing article's progress is checkpointed before the overlay
        // moves; the destination does not inherit it.
        XCTAssertEqual(model.articles.first(where: { $0.id == first.id })?.playbackSeconds, 60)
        XCTAssertEqual(model.articles.first(where: { $0.id == second.id })?.playbackSeconds, 0)
    }

    func testFailedArticleSwitchDoesNotCopyOutgoingProgressIntoDestination() async throws {
        let directory = temporaryDirectory("failed-switch-playback-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.articles.first)
        let second = WiltedMacArticle(
            id: "failed-destination", title: "Failed destination", source: "Example",
            url: URL(string: "https://example.test/failed-destination")!, isReady: true,
            durationSeconds: 120
        )
        model.installArticleForTesting(second)
        model.openNowPlaying(for: first)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Selection changes before an asynchronous load completes. Leaving
        // the controller on the first item models the failure boundary.
        model.beginArticlePlaybackTransitionForTesting(second)
        model.refreshPlaybackReadout()

        XCTAssertEqual(model.articles.first(where: { $0.id == first.id })?.playbackSeconds, 60)
        XCTAssertEqual(model.articles.first(where: { $0.id == second.id })?.playbackSeconds, 0)
    }

    func testUnavailableTranscriptProjectsAudioReadyWithoutPreparedPrefix() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "9", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "9", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let run = PreparationRunSummary(
            requestID: WiltedMacModel.podcastRequestPrefix + itemID.rawValue,
            itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
            detail: "Prepared · no ads found · transcript not synced", fraction: nil,
            isTerminal: true, outcome: .succeeded, failure: nil,
            entries: [PreparationJournalEntry(
                id: "terminal", itemID: itemID,
                requestID: WiltedMacModel.podcastRequestPrefix + itemID.rawValue,
                status: try PreparationStatus(
                    stage: .completed, detail: "Prepared · no ads found · transcript not synced",
                    cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                    emittedAt: when
                )
            )]
        )
        let outcome = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        let state = WiltedMacModel.preparationState(outcome: outcome, run: run, readyRevisionID: revisionID,
                                                    transcript: nil)
        XCTAssertEqual(state, .prepared(summary: "Audio ready · Transcript unavailable"))
        XCTAssertEqual(
            WiltedMacEpisodeLifecyclePresentation(downloadState: .completed, preparationState: state).label,
            "Audio ready · Transcript unavailable"
        )
    }

    func testEpisodePlaybackIndicatorsKeepCurrentPlaybackOutOfUpNext() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = try XCTUnwrap(model.episodes.first)
        let queuedID = "queued-episode"

        model.installPlaybackStateForTesting(
            episode: current,
            isPlaying: true,
            position: 1,
            duration: 10,
            queue: [current.id, queuedID]
        )
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Playing"])
        XCTAssertEqual(model.episodePlaybackIndicators(for: queuedID), ["In Larder"])

        model.installPlaybackStateForTesting(
            episode: current,
            isPlaying: false,
            position: 1,
            duration: 10,
            queue: [current.id, queuedID]
        )
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Now Playing"])
        XCTAssertFalse(model.episodePlaybackIndicators(for: current.id).contains("In Larder"))
    }

    func testPreparedLifecycleSeparatesStatusFromExplicitOutcomes() {
        let presentation = WiltedMacEpisodeLifecyclePresentation(
            downloadState: .completed,
            preparationState: .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )

        XCTAssertEqual(presentation.primaryLabel, "Prepared")
        XCTAssertEqual(presentation.detailLabel, "3 ads removed · transcript synced")
        XCTAssertEqual(presentation.label, "Prepared · 3 ads removed · transcript synced")
    }

    func testPlaybackAndMenuActionsRequireCompletedPreparation() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let base = WiltedMacEpisode(
            id: "episode-state-contract", title: "State contract", feedTitle: "Fixtures",
            summary: "Fixture", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .notPrepared
        )

        XCTAssertFalse(model.canPlayEpisode(base))
        XCTAssertFalse(model.canAddEpisodeToMenu(base))
        XCTAssertTrue(WiltedMacModel.isEligibleForPreparation(base))

        var preparing = base
        preparing.preparationState = .preparing(stage: "Transcribing")
        XCTAssertFalse(model.canPlayEpisode(preparing))
        XCTAssertFalse(model.canAddEpisodeToMenu(preparing))
        XCTAssertFalse(WiltedMacModel.isEligibleForPreparation(preparing))

        var prepared = base
        prepared.preparationState = .prepared(summary: "Ready · no ads found · transcript synced")
        XCTAssertTrue(model.canPlayEpisode(prepared))
        XCTAssertTrue(model.canAddEpisodeToMenu(prepared))
        XCTAssertFalse(WiltedMacModel.isEligibleForPreparation(prepared))
    }

    func testMenuUpcomingKeepsEveryDurableEntryAroundThePlayingOne() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        func entry(_ id: String, at published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: published), durationSeconds: 600,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
            )
        }
        let current = entry("menu-current", at: 1_700_000_000)
        let earlier = entry("menu-earlier", at: 1_699_000_000)
        let next = entry("menu-next", at: 1_701_000_000)
        let later = entry("menu-later", at: 1_702_000_000)
        for value in [earlier, next, later] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [earlier.id, current.id, next.id, later.id]
        )

        XCTAssertEqual(model.menuUpcomingEpisodeIDs, [earlier.id, current.id, next.id, later.id],
                       "an entry before the playing one is still a durable Menu entry")
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [earlier.id, current.id, next.id, later.id],
                       "the sort projection keeps the entries around the playing one too")
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Playing"])
        XCTAssertEqual(model.episodePlaybackIndicators(for: next.id), ["In Larder"])
    }

    /// The regression: `retireFinishedEpisode` swallows a failed queue removal
    /// with `try?`, and a failed `podcastQueueState()` read makes
    /// `refreshPodcastQueueState()` return early. Either way the episode that
    /// just finished can still be sitting at the head of `podcastQueueIDs`
    /// when the search runs. Before the fix `nextMenuEpisodeToPlay()` took
    /// `podcastQueueIDs.first` unconditionally and handed back the episode the
    /// listener had just been told was done, restarting it instead of moving on.
    func testNextMenuEpisodeSkipsTheJustFinishedEpisodeStillAtTheHeadOfTheQueue() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let finished = WiltedMacEpisode(
            id: "next-menu-finished", title: "Finished", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            playbackSeconds: 600, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        let next = WiltedMacEpisode(
            id: "next-menu-next", title: "Next", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_060), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        model.installEpisodeForTesting(next)
        model.installPlaybackStateForTesting(
            episode: finished, isPlaying: false, position: 600, duration: 600,
            queue: [finished.id, next.id]
        )

        XCTAssertEqual(model.nextMenuEpisodeToPlay()?.id, next.id,
                       "the episode still marked current must never be handed back as its own successor")
    }

    /// A retired episode left at the head of the queue -- the ordinary case,
    /// not the swallowed-removal one -- is passed over the same way.
    func testNextMenuEpisodeSkipsARetiredEpisodeAtTheHeadOfTheQueue() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        var retired = WiltedMacEpisode(
            id: "next-menu-retired", title: "Retired", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            playbackSeconds: 600, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        retired.retiredAt = Date(timeIntervalSince1970: 1_700_000_500)
        let eligible = WiltedMacEpisode(
            id: "next-menu-eligible", title: "Eligible", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_060), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        let unrelated = WiltedMacEpisode(
            id: "next-menu-unrelated", title: "Unrelated", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_699_999_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        model.installEpisodeForTesting(retired)
        model.installEpisodeForTesting(eligible)
        model.installPlaybackStateForTesting(
            episode: unrelated, isPlaying: false, position: 0, duration: 600,
            queue: [retired.id, eligible.id]
        )

        XCTAssertEqual(model.nextMenuEpisodeToPlay()?.id, eligible.id,
                       "a retired episode is off the shelf and can never be the next thing offered")
    }

    /// A dismissed (hidden) episode left at the head of the queue is skipped
    /// the same way -- dismissal is optimistic and in-memory, ahead of the
    /// durable round trip, so the search has to honor it immediately.
    func testNextMenuEpisodeSkipsAHiddenEpisodeAtTheHeadOfTheQueue() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let hidden = WiltedMacEpisode(
            id: "next-menu-hidden", title: "Hidden", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        let eligible = WiltedMacEpisode(
            id: "next-menu-eligible-2", title: "Eligible", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_060), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        let unrelated = WiltedMacEpisode(
            id: "next-menu-unrelated-2", title: "Unrelated", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_699_999_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
        )
        model.installEpisodeForTesting(hidden)
        model.installEpisodeForTesting(eligible)
        model.installPlaybackStateForTesting(
            episode: unrelated, isPlaying: false, position: 0, duration: 600,
            queue: [hidden.id, eligible.id]
        )
        model.removeEpisode(hidden)

        XCTAssertEqual(model.nextMenuEpisodeToPlay()?.id, eligible.id,
                       "a dismissed episode is hidden immediately and can never be the next thing offered")
    }

    /// An empty queue has nothing to search; the fresh model's queue is empty
    /// before any playback has ever started.
    func testNextMenuEpisodeReturnsNilForAnEmptyQueue() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        XCTAssertNil(model.nextMenuEpisodeToPlay(),
                     "there is nothing to hand back when the queue itself is empty")
    }

    /// Every entry in the queue is ineligible -- neither downloaded nor
    /// prepared -- so the search has to exhaust the queue and come back empty
    /// rather than returning an episode nothing can actually play.
    func testNextMenuEpisodeReturnsNilWhenEveryQueuedEpisodeIsIneligible() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let firstIneligible = WiltedMacEpisode(
            id: "next-menu-ineligible-1", title: "Not ready", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .notDownloaded, preparationState: .notPrepared
        )
        let secondIneligible = WiltedMacEpisode(
            id: "next-menu-ineligible-2", title: "Also not ready", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_060), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed, preparationState: .notPrepared
        )
        model.installEpisodeForTesting(secondIneligible)
        model.installPlaybackStateForTesting(
            episode: firstIneligible, isPlaying: false, position: 0, duration: 600,
            queue: [firstIneligible.id, secondIneligible.id]
        )

        XCTAssertNil(model.nextMenuEpisodeToPlay(),
                     "nothing in the queue can actually play, so the search must not invent a candidate")
    }

    func testPreparedMenuCandidatesFollowLarderOrderAndExcludeCurrentAndQueued() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        func episode(_ id: String, releasedAt: TimeInterval, prepared: Bool = true) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: releasedAt), durationSeconds: 600,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: prepared
                    ? .prepared(summary: "Ready · transcript synced")
                    : .notPrepared
            )
        }

        let current = episode("menu-current", releasedAt: 100)
        let queued = episode("menu-queued", releasedAt: 300)
        let newest = episode("menu-newest", releasedAt: 400)
        let unprepared = episode("menu-unprepared", releasedAt: 500, prepared: false)
        model.installEpisodeForTesting(current)
        model.installEpisodeForTesting(queued)
        model.installEpisodeForTesting(newest)
        model.installEpisodeForTesting(unprepared)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [current.id, queued.id]
        )

        XCTAssertEqual(model.readyToPlayEpisodes.map(\.id), [newest.id, queued.id, current.id])
        XCTAssertEqual(model.preparedEpisodesReadyForMenu.map(\.id), [newest.id])

        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [current.id, queued.id, newest.id]
        )
        XCTAssertTrue(model.preparedEpisodesReadyForMenu.isEmpty)
    }

    func testAddAllPreparedEpisodesAppendsDurableQueueWithoutChangingCurrent() async throws {
        let root = temporaryDirectory("bulk-menu")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentID = "item-" + String(repeating: "1", count: 64)
        let preparedID = "item-" + String(repeating: "2", count: 64)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try await store.addPodcastQueueEpisode(try ItemID(rawValue: currentID))
        try await store.setCurrentPodcastQueueEpisode(try ItemID(rawValue: currentID))
        let current = WiltedMacEpisode(
            id: currentID, title: "Current", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 100), durationSeconds: 600,
            playbackSeconds: 12, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        let prepared = WiltedMacEpisode(
            id: preparedID, title: "Prepared", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 200), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        model.installEpisodeForTesting(current)
        model.installEpisodeForTesting(prepared)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600, queue: [currentID]
        )

        model.addAllPreparedEpisodesToMenu()
        await model.waitForPlaybackOperationForTesting()

        let reopened = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let queue = try await reopened.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [currentID, preparedID])
        XCTAssertEqual(queue.currentEpisodeID?.rawValue, currentID)
        XCTAssertEqual(model.currentPodcastEpisodeID, currentID)
        XCTAssertTrue(model.isPlaying)
    }

    func testBulkMenuAddShowsAQueueWhenNothingIsPlaying() async {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        guard let prepared = model.preparedEpisodesReadyForMenu.first else {
            return XCTFail("prepared fixture must offer one Menu candidate")
        }

        model.addAllPreparedEpisodesToMenu()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.podcastQueueIDs, [prepared.id])
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [prepared.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [prepared.id])
        XCTAssertEqual(model.episodePlaybackIndicators(for: prepared.id), ["In Larder"])
    }

    func testMenuDownwardBeforeMoveUsesPostRemovalIndexAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("library.sqlite")
        var store = try LocalLibraryStore(url: storeURL)
        let first = try ItemID(rawValue: "item-" + String(repeating: "1", count: 64))
        let second = try ItemID(rawValue: "item-" + String(repeating: "2", count: 64))
        let third = try ItemID(rawValue: "item-" + String(repeating: "3", count: 64))
        try await store.addPodcastQueueEpisode(first)
        try await store.addPodcastQueueEpisode(second)
        try await store.addPodcastQueueEpisode(third)

        let insertion = WiltedMacModel.menuInsertionIndex(source: 0, destination: 2)
        try await store.movePodcastQueueEpisode(from: 0, to: insertion)
        store = try LocalLibraryStore(url: storeURL)
        let reopenedState = try await store.podcastQueueState()

        XCTAssertEqual(reopenedState.episodeIDs, [second, first, third])
    }

    /// Larder projects every subscribed episode's preparation evidence, so it
    /// cannot use Prep's display-oriented 200-run cap: this seeds a
    /// non-terminal run for one subscribed episode, then 200 newer terminal
    /// runs for other episodes that push it out of that cap, and requires
    /// the Larder row to still show it while Prep's own capped display list
    /// still excludes it.
    func testLibraryProjectionIncludesPreparationEvidenceBeyondThePrepDisplayLimit() async throws {
        let directory = temporaryDirectory("prep-evidence-beyond-cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/beyond-cap-feed.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/beyond-cap-episode.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "beyond-cap-episode", enclosureURL: enclosureURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_600_000_000))

        let storeCapture = StoreCapture()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Beyond Cap Show", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "beyond-cap-episode",
                    title: "Beyond Cap Episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                // The target run: old, non-terminal, must survive being
                // pushed out of Prep's 200-newest cap.
                try await store.record(preparation: PreparationJournalEntry(
                    id: "beyond-cap|preparing", itemID: episodeID,
                    requestID: WiltedMacModel.podcastRequestPrefix + episodeID.rawValue,
                    status: try PreparationStatus(
                        stage: .preparing, detail: "Preparing…", fraction: 0.1, cancellable: true, emittedAt: created
                    )
                ))
                // 200 newer requests to push the target out of the default 200-run display cap.
                for i in 0..<200 {
                    let fillerID = try ItemID(rawValue: "filler-episode-\(i)")
                    try await store.record(preparation: PreparationJournalEntry(
                        id: "filler-\(i)|terminal", itemID: fillerID, requestID: "podcast-prepare|filler-\(i)",
                        status: try PreparationStatus(
                            stage: .cancelled, detail: "cancelled", fraction: nil, cancellable: false,
                            terminalResult: try PreparationTerminalResult(outcome: .cancelled),
                            emittedAt: Timestamp(created.date.addingTimeInterval(Double(i) + 1))
                        )
                    ))
                }
                await storeCapture.capture(store)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        let projected = model.episodes.first(where: { $0.id == episodeID.rawValue })
        guard case .preparing = projected?.preparationState else {
            return XCTFail("Larder must show preparation evidence even when 200 newer podcast-prepare runs exist to push it out of Prep's display cap")
        }

        let capturedStore = await storeCapture.store
        let store = try XCTUnwrap(capturedStore)
        let displayRuns = try await store.preparationRuns()
        XCTAssertEqual(displayRuns.count, 200, "Prep's own display list keeps its 200-run cap")
        XCTAssertFalse(displayRuns.contains(where: { $0.itemID == episodeID }),
                       "the target run should have been pushed out of Prep's cap by the 200 newer filler runs")
    }

    /// Step 3 done-condition. A model built WITHOUT `storeBootstrap:` never
    /// reaches `performStoreBootstrap` at all -- `addArticle` and friends
    /// return early at the coordinator guard -- so asserting only against
    /// the model's own published state here would pass even if reconcile
    /// were never wired in. Every assertion below instead reads a ticket row
    /// back from the store the bootstrap closure captured, and the
    /// preferences key is checked on the same `UserDefaults` instance the
    /// model was built with, not a fresh one.
    func testBootstrapImportsDeferredPreparationsFromPreferencesIntoTickets() async throws {
        let directory = temporaryDirectory("reconcile-imports-deferrals")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/reconcile-bootstrap/feed.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/reconcile-bootstrap/episode.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "reconcile-bootstrap", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_650_000_000))

        let preferences = WiltedMacTestPreferences.ephemeral()
        let window = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: try XCTUnwrap(WiltedAutomationLocalTime(hour: 1, minute: 0)),
            end: try XCTUnwrap(WiltedAutomationLocalTime(hour: 2, minute: 0))
        ))
        WiltedMacModel.persistDeferredAutomaticPreparations([
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: episodeID.rawValue,
                processingPolicy: .offPeak(window),
                policySnapshot: PodcastPreparationPolicySnapshot(transcriptPolicy: .noLocalSTT, removeAds: false)
            )
        ], to: preferences)
        preferences.set(41, forKey: WiltedMacModel.preparationRequestSequencePreferenceKey)

        let storeCapture = StoreCapture()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Reconcile bootstrap show", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                await storeCapture.capture(store)
                return store
            },
            preferences: preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        let tickets = try await capturedStore.workTickets()
        let imported = try XCTUnwrap(
            tickets.first { $0.kind == .podcastPreparation && $0.subjectID == episodeID.rawValue },
            "the deferral read from preferences at launch must have become a durable work ticket"
        )
        XCTAssertEqual(imported.state, .pending)
        XCTAssertGreaterThan(imported.requestSequence, 41,
                             "a newly imported ticket's sequence must be above the imported pre-V12 floor")
        XCTAssertNotNil(imported.policySnapshot, "the deferral's policy snapshot must have crossed into the ticket")
        XCTAssertNotNil(imported.processingPolicy, "the deferral's processing policy must have crossed into the ticket")

        XCTAssertNil(preferences.data(forKey: WiltedMacModel.deferredAutomaticPreparationsPreferenceKey),
                    "the deferred-preparations preference key must be cleared once the tickets it named are durable")
    }

    // MARK: Transcript synchronisation

    /// The reading position has to track the playback clock exactly, including
    /// before the first cue, across a boundary, and past the last one.
    func testCueLookupFollowsThePlaybackClock() {
        let transcript = WiltedMacTranscript(
            availability: .available, text: "one two three",
            cues: [
                WiltedMacTranscriptCue(id: 0, startSeconds: 2, endSeconds: 4, text: "one"),
                WiltedMacTranscriptCue(id: 1, startSeconds: 4, endSeconds: 6, text: "two"),
                WiltedMacTranscriptCue(id: 2, startSeconds: 6, endSeconds: 9, text: "three"),
            ],
            timingSource: "synced"
        )
        XCTAssertNil(transcript.cueIndex(at: 0), "nothing has been said yet")
        XCTAssertNil(transcript.cueIndex(at: 1.99))
        XCTAssertEqual(transcript.cueIndex(at: 2), 0)
        XCTAssertEqual(transcript.cueIndex(at: 3.9), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4), 1)
        XCTAssertEqual(transcript.cueIndex(at: 8.5), 2)
        XCTAssertEqual(transcript.cueIndex(at: 500), 2, "past the end stays on the last line")
        XCTAssertTrue(transcript.isSynchronized)
        XCTAssertEqual(transcript.disclosureTitle, "Transcript · synced")
    }

    /// Cues arrive in order but may overlap, and a large episode carries
    /// thousands of them: the lookup must stay correct at both ends.
    func testCueLookupHandlesALongEpisode() {
        let cues = (0..<5_000).map {
            WiltedMacTranscriptCue(id: $0, startSeconds: Double($0) * 2,
                                   endSeconds: Double($0) * 2 + 2.5, text: "line \($0)")
        }
        let transcript = WiltedMacTranscript(availability: .available, text: "long",
                                             cues: cues, timingSource: "synced")
        XCTAssertEqual(transcript.cueIndex(at: 0), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4_999), 2_499)
        XCTAssertEqual(transcript.cueIndex(at: 9_998), 4_999)
    }

    /// A plain-text transcript is still readable; it just cannot be followed.
    func testAnUntimedTranscriptIsReadableButNotSynchronized() {
        let transcript = WiltedMacTranscript(availability: .available, text: "Words with no timing.")
        XCTAssertTrue(transcript.isReadable)
        XCTAssertFalse(transcript.isSynchronized)
        XCTAssertNil(transcript.cueIndex(at: 10))
        XCTAssertEqual(transcript.disclosureTitle, "Transcript")
    }

    /// The wiring the feature actually rests on: the player is what reads a
    /// transcript, and until this landed the episode path set `.unavailable`
    /// unconditionally, so a timed transcript in the library was unreachable.
    func testPlayingAnEpisodeSurfacesItsSyncedTranscript() async throws {
        let directory = temporaryDirectory("episode-transcript")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/synced.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/synced.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "synced-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Synced", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "synced-1",
                    title: "Synced episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                try await store.save(transcript: try Transcript(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    availability: .available, text: "First line. Second line.",
                    timing: .published,
                    cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "First line."),
                           try TranscriptCue(startSeconds: 0.5, endSeconds: 1.0, text: "Second line.")],
                    updatedAt: created
                ))
                try await store.record(preparation: PreparationJournalEntry(
                    id: "prep-synced", itemID: episodeID, requestID: "podcast-prepare|synced",
                    status: try PreparationStatus(
                        stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                        terminalResult: try PreparationTerminalResult(
                            outcome: .succeeded, revisionID: assembled.revision.revisionID
                        ),
                        emittedAt: created,
                        timeline: try PreparationStatus.PreparationTimeline(
                            removed: [try .init(originalStartSeconds: 30, originalEndSeconds: 90,
                                                label: "advertisement", confidence: 0.9)],
                            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, outputStartSeconds: 0),
                                   try .init(originalStartSeconds: 90, originalEndSeconds: 200, outputStartSeconds: 30)]
                        )
                    )
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        defer { model.togglePlayback() }

        let transcript = try XCTUnwrap(model.currentTranscript)
        XCTAssertTrue(transcript.isSynchronized, "playing an episode has to surface its timed transcript")
        XCTAssertEqual(transcript.cues.map(\.text), ["First line.", "Second line."])
        XCTAssertEqual(transcript.disclosureTitle, "Transcript \u{00B7} synced from the feed")
        XCTAssertEqual(transcript.cueIndex(at: 0.6), 1)

        // What preparation cut, placed where the listener meets it: the
        // seam is on the prepared clock the cues are stamped in, and the
        // span it names is on the original clock, which is what Prep reports
        // for the same run.
        let spans = model.currentRemovedSpans
        XCTAssertEqual(spans.count, 1, "a prepared episode says what came out of it")
        XCTAssertEqual(spans.first?.preparedSeconds, 30)
        XCTAssertEqual(spans.first?.originalStartSeconds, 30)
        XCTAssertEqual(spans.first?.originalEndSeconds, 90)
        XCTAssertEqual(spans.first?.summary, "Ad removed \u{00B7} 1:00 \u{00B7} original 0:30–1:30")
    }

    /// An episode the listener is finished with early has no other way to
    /// close out: progress is written from where the audio is, so it stays at
    /// the abandoned position for good and the Larder goes on offering it.
    /// The press has to reach the durable record and retire the row, the same
    /// as playing the episode to its end does -- a control whose only effect
    /// is a scrubber jumping to the end is indistinguishable from one that
    /// did nothing.
    func testMarkingTheCurrentEpisodeCompletedRetiresItFromTheLarder() async throws {
        let directory = temporaryDirectory("episode-mark-completed")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/completed.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/completed.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "completed-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Finished", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "completed-1",
                    title: "Finished episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertFalse(episode.isPlayed)
        model.playEpisode(episode)
        try await settle(model)
        XCTAssertFalse(model.playbackCompleted)

        model.markCurrentPlaybackCompleted()
        try await settle(model)
        XCTAssertTrue(model.playbackCompleted, "the player has to stop offering to mark what it just marked")
        XCTAssertFalse(model.isPlaying, "marking an episode finished stops the audio")

        XCTAssertLessThan(model.playbackPositionSeconds, model.playbackDurationSeconds,
                          "the playhead stays where the listener left it; only the completed flag is written")

        let retired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue },
                                    "retirement is not dismissal -- the row survives, just off the shelf")
        XCTAssertNotNil(retired.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episodeID.rawValue },
                       "saying \"I am done with this\" takes it off the shelf, the same as playing it to the end")
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue },
                       "retirement is not a dismissal -- nothing was deleted")
        XCTAssertEqual(model.podcastOperationMessage, "Finished \(episode.title).")
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "both halves are done, so the control has nothing left to offer")
    }

    /// Reported 2026-09-07: an episode marked completed on a build that wrote
    /// the record without retiring the row stayed in the Larder, and the
    /// control that would have retired it read "Completed" and was disabled.
    /// The record and the shelf can still disagree after Phase 5's bootstrap
    /// sweep -- a completion synced from iPhone against a revision this
    /// device has since re-downloaded, for instance, which the sweep
    /// deliberately leaves alone rather than retiring sight unseen -- so the
    /// press has to remain available until the row is actually gone, and it
    /// has to finish the half that was skipped rather than repeat the half
    /// that was not.
    func testAnEpisodeAlreadyMarkedCompletedCanStillBeRetired() async throws {
        let directory = temporaryDirectory("episode-completed-not-retired")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/stranded.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/stranded.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "stranded-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Stranded", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "stranded-1",
                    title: "Stranded episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                // The state a sync from another device can leave behind:
                // finished on the record, with no retirement to take the row
                // off the shelf. The listening fact names a revision this
                // device does not currently have ready -- e.g. synced before
                // a local re-download -- so the bootstrap sweep in
                // `startStoreBootstrap()` must not retire it, leaving the
                // press with real work still to do.
                try await store.save(playback: try PlaybackState(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    sessionID: "stranded-session", sequence: 3,
                    positionSeconds: assembled.revision.durationSeconds,
                    durationSeconds: assembled.revision.durationSeconds,
                    completed: true, intent: .progress, deviceID: "stranded-device",
                    updatedAt: created
                ))
                try await store.saveListening(PodcastListeningState(
                    episodeID: episodeID, completedAt: created,
                    lastRevisionID: try RevisionID(rawValue: "stranded-superseded-revision"),
                    updatedAt: created
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertTrue(episode.isPlayed, "the record survived; only the retirement was missed")
        model.playEpisode(episode)
        try await settle(model)

        XCTAssertTrue(model.playbackCompleted, "the loaded record still says finished")
        XCTAssertFalse(model.playbackCompletionIsSettled,
                       "the row is still on the shelf, so the press still has work to do")

        model.markCurrentPlaybackCompleted()
        try await settle(model)

        let retired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue },
                                    "retirement is not dismissal -- the row survives, just off the shelf")
        XCTAssertNotNil(retired.retiredAt, "pressing it a second time has to retire the row the first press never did")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episodeID.rawValue })
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue })
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "and then stop offering, because there is nothing left to finish")
    }

    /// Placement is the whole point: a cut is meaningless unless it sits where
    /// the audio jumps. The seam is the end of the last kept interval carried
    /// onto the output clock, so the second cut of an episode has to account
    /// for everything removed ahead of it rather than reporting its original
    /// time.
    func testRemovedSpansArePlacedOnThePreparedClock() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 60, originalEndSeconds: 120, label: "advertisement", confidence: 0.9),
                      try .init(originalStartSeconds: 600, originalEndSeconds: 690, label: "sponsor", confidence: 0.8)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 60, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 120, originalEndSeconds: 600, outputStartSeconds: 60),
                   try .init(originalStartSeconds: 690, originalEndSeconds: 1_200, outputStartSeconds: 540)]
        )
        let spans = WiltedMacModel.removedSpans(in: timeline)
        XCTAssertEqual(spans.map(\.preparedSeconds), [60, 540],
                       "the second cut lands a minute earlier than its original time, because the first was removed")
        XCTAssertEqual(spans.map(\.originalStartSeconds), [60, 600])
        XCTAssertEqual(spans.map(\.summary), [
            "Ad removed \u{00B7} 1:00 \u{00B7} original 1:00–2:00",
            "Ad removed \u{00B7} 1:30 \u{00B7} original 10:00–11:30",
        ])
    }

    /// A cut that opens the episode has nothing kept ahead of it, so it sits
    /// at the very start rather than being dropped or placed by a fallback
    /// that happens to also be zero for a different reason.
    func testACutAtTheStartOfAnEpisodeSitsAtZero() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, label: "advertisement", confidence: 0.9)],
            kept: [try .init(originalStartSeconds: 30, originalEndSeconds: 600, outputStartSeconds: 0)]
        )
        XCTAssertEqual(WiltedMacModel.removedSpans(in: timeline).map(\.preparedSeconds), [0])
    }

    /// The transcript pane merges cues and cuts onto one clock. A marker
    /// belongs before the first line that starts at or after it: it describes
    /// audio the listener is about to not hear, so interrupting the line
    /// already in progress would put it a beat too late.
    func testRemovedMarkersAreMergedBeforeTheLineTheyPrecede() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Before."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 60, text: "After."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 90, text: "Later."),
        ]
        let markers = [
            WiltedTranscriptMarkerLine(id: 1, atSeconds: 95, text: "Ad removed"),
            WiltedTranscriptMarkerLine(id: 0, atSeconds: 60, text: "Ad removed"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, markers: markers, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.rows.map(\.id), ["cue-0", "marker-0", "cue-1", "cue-2", "marker-1"],
                       "markers sort into the cues by time, and one past the last line still shows")

        let withoutMarkers = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil, identifier: "test") { _ in }
        XCTAssertEqual(withoutMarkers.rows.map(\.id), ["cue-0", "cue-1", "cue-2"])
    }

    /// Following the audio means handing `ScrollViewReader` the identity the
    /// row actually carries. When markers joined the list, row identity became
    /// a `String` while auto-scroll still passed the cue's `Int`, so the active
    /// line stayed highlighted but was never scrolled into view.
    func testTheScrollTargetMatchesTheRowIdentityOfTheActiveCue() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Before."),
            WiltedTranscriptCueLine(id: 41, startSeconds: 60, text: "After."),
        ]
        let markers = [WiltedTranscriptMarkerLine(id: 0, atSeconds: 30, text: "Ad removed")]
        let view = WiltedSyncedTranscriptView(cues: cues, markers: markers, activeCueID: 41,
                                              identifier: "test") { _ in }
        let target = WiltedSyncedTranscriptView.Row.scrollTarget(forCueID: 41)
        XCTAssertTrue(view.rows.contains { $0.id == target },
                      "the scroll target has to be a row identity, or a lazy list cannot resolve it")
        XCTAssertEqual(view.rows.first { $0.id == target }.map { row -> Int? in
            if case .cue(let cue) = row { return cue.id }
            return nil
        } ?? nil, 41, "and it has to be the active cue's row, not a marker that happens to share a number")
        XCTAssertNotEqual(target, WiltedSyncedTranscriptView.Row.scrollTarget(forCueID: 0))
    }

    /// A name is drawn where the voice changes, not on every line. An
    /// interview alternates two people for an hour, and repeating both names
    /// down the whole transcript is noise the reader reads past to find words.
    func testTheSpeakerIsLabelledOnlyWhereItChanges() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Still me.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Thanks.", speaker: "Chris"),
            WiltedTranscriptCueLine(id: 3, startSeconds: 15, text: "Back again.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0, 2, 3],
                       "the first attributed line always says who is talking, then only changes do")
    }

    /// Publishers attribute the line that changes hands and leave the rest
    /// bare. Treating a bare line as "unknown speaker" would redraw the name
    /// on every line after it.
    func testAnUnattributedLineDoesNotEndTheSpeakersRun() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "No attribution here."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Still Angie.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0])
    }

    func testATranscriptThatNamesNobodyLabelsNothing() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "One."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Two."),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertTrue(view.speakerHeadingCueIDs.isEmpty)
    }

    /// The visual heading is `accessibilityHidden` so the name is not read
    /// twice. That makes the spoken label the only place a reader using
    /// VoiceOver learns the voice changed.
    func testTheSpokenLabelCarriesTheNameExactlyWhereTheHeadingDoes() {
        let named = WiltedTranscriptCueLine(id: 0, startSeconds: 65, text: "Welcome.", speaker: "Angie")
        let view = WiltedSyncedTranscriptView(cues: [named], activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: true), "1:05. Angie. Welcome.")
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: false), "1:05. Welcome.")
    }

    // MARK: - One add box

    /// Builds a store-backed model whose add box classifies against `document`
    /// and whose feed client is fed `feedXML` when a subscription follows.
    private func modelForPastedLink(
        directory: URL, document: String, feedXML: String = ""
    ) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(feedXML.utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: Data(document.utf8))), preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    /// The reported complaint: a podcast address pasted into the article box has
    /// to reach the subscription flow, not the article pipeline. Larder no longer
    /// subscribes on its own -- it moves the address to the page that owns feeds
    /// and shows it there, so the listener sees what they are about to follow.
    func testPastingAFeedAddressHandsItToTheSubscriptionComposer() async throws {
        let directory = temporaryDirectory("pasted-feed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<?xml version=\"1.0\"?><rss><channel><title>Pasted show</title></channel></rss>",
            feedXML: "<rss><channel><title>Pasted show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.subscriptions.isEmpty, "the handoff subscribes to nothing on its own")
        XCTAssertNil(model.preparation, "a feed must never reach the article pipeline")
        XCTAssertEqual(model.selectedNavigation, .feeds, "the listener is taken to the page that owns feeds")
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show")
        XCTAssertEqual(model.urlDraft, "", "the address moved rather than being left in both boxes")
        XCTAssertNil(model.linkDraftStatus)

        // Confirming in the composer it landed in is what subscribes.
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Pasted show"])
        XCTAssertEqual(model.podcastFeedDraft, "", "a completed subscription clears the box")
    }

    /// An address ending in .xml is unmistakable, so neither box may spend a
    /// round trip to learn what it already knows. The classifier here cannot
    /// fetch anything, so a subscription proves the shortcut ran in both.
    func testAnUnmistakableFeedAddressReachesTheComposerWithoutSniffing() async throws {
        let directory = temporaryDirectory("pasted-feed-extension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Direct show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show.xml"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.selectedNavigation, .feeds)
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show.xml")
        XCTAssertTrue(model.subscriptions.isEmpty)

        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Direct show"])
    }

    /// A page that publishes a feed is still the article that was pasted. The
    /// feed is offered, and only subscribes when the offer is accepted.
    func testAPageThatPublishesAFeedOffersItRatherThanSubscribing() async throws {
        let directory = temporaryDirectory("pasted-advertised")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://blog.example.test/posts/one"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// The Feeds composer refuses an incomplete address before it starts any
    /// work, so a typo never reads as a network problem.
    func testTheSubscriptionComposerRefusesAnIncompleteAddressWithoutChecking() async throws {
        let directory = temporaryDirectory("composer-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Unused</title></channel></rss>",
            feedXML: "<rss><channel><title>Unused</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "podcasts.example.test/show"
        model.addPodcastFeedDraft()

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "Enter a complete HTTPS podcast feed or show-page address."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    /// A show page is not a feed. The composer says which feed it found and
    /// waits, because following a site's whole feed is a separate decision from
    /// the address that was pasted.
    func testTheSubscriptionComposerOffersAShowPagesFeedBeforeFollowingIt() async throws {
        let directory = temporaryDirectory("composer-advertised")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://blog.example.test/posts/one"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "This page advertises one podcast feed. Confirm before subscribing."
        )

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// Subscribing to a feed already followed adds nothing, so the answer is the
    /// row that already exists rather than a second subscription or an error the
    /// listener cannot act on.
    func testSubscribingTwiceKeepsOneFeedAndPointsAtTheOneAlreadyFollowed() async throws {
        let directory = temporaryDirectory("composer-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Repeat show</title></channel></rss>",
            feedXML: "<rss><channel><title>Repeat show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://podcasts.example.test/repeat"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Repeat show"])
        XCTAssertNil(model.selectedPodcastFeedID, "a first subscription points at nothing")

        // The same feed through an equivalent spelling of its address.
        model.podcastFeedDraft = "https://Podcasts.Example.test/repeat#latest"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.count, 1, "one feed, however many times it is offered")
        XCTAssertEqual(model.selectedPodcastFeedID, model.subscriptions.first?.id)
        XCTAssertEqual(model.podcastOperationMessage, "Already following this podcast.")
    }

    /// A cancelled check still resumes; by then the listener may have started
    /// another. The cancelled one must write nothing, or it clears the live
    /// check's progress and replaces its answer with a stale one.
    func testACancelledSubscriptionCheckCannotWriteOverTheNextOne() async throws {
        let directory = temporaryDirectory("composer-cancel-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = URL(string: "https://pages.example.test/plain")!
        let feedURL = URL(string: "https://podcasts.example.test/gated")!
        let gate = GatedRoutingLoader(documents: [
            pageURL: Data("<!doctype html><html><body>Just words</body></html>".utf8),
            feedURL: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8),
        ])
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: gate),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = pageURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckInProgressStatus)

        model.cancelPodcastSubscriptionCheck()
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckCancelledStatus)

        model.podcastFeedDraft = feedURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription, "the next check starts on its own terms")

        // Both classifications complete now, the cancelled one first.
        await gate.release()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.map(\.title), ["Gated show"])
        XCTAssertNil(model.podcastFeedDraftStatus,
                     "the cancelled check must not report on the address that replaced it")
        XCTAssertFalse(model.isCheckingPodcastSubscription)
    }

    /// A pasted address that cannot be reached is reported in the box. Guessing
    /// would send it to a pipeline that fails for a reason the reader did not
    /// cause.
    func testAnUnreachableAddressIsReportedInTheBox() async throws {
        let directory = temporaryDirectory("pasted-unreachable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://unreachable.example.test/thing"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(
            model.linkDraftStatus,
            "Wilted could not reach that address. Check it, or retry when online."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertNil(model.preparation)
    }

    func testAnIncompleteAddressIsRefusedWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("pasted-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        for draft in ["", "example.com/thing", "http://example.com/thing"] {
            model.urlDraft = draft
            model.addPastedLink()
            XCTAssertEqual(model.linkDraftStatus, "Enter a complete HTTPS address.", "draft: \(draft)")
        }
    }

    /// The row never left the store under the unified removal column, so
    /// restore needs no feed fetch and no re-matched evidence -- it commits
    /// the old target directly and clears the durable dismissal. (Until this
    /// task, dismissal deleted the row and restore had to re-fetch the known
    /// feed to reconstruct it; that path no longer exists.)
    func testKnownFeedRestoreReappearsInLarderAndClearsRemovedWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("restore-known-feed")
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
        defer { try? FileManager.default.removeItem(at: directory) }
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

    // MARK: Continuing across the Larder when playback runs out

    /// `.oldest` puts the second episode after the first in the Larder's own
    /// displayed order, matching what "next" means to a listener: forward
    /// through the feed, not `.newest`'s reversal of it.
    func testANaturallyFinishedEpisodeStartsTheNextReadyOneAndRemovesItself() async throws {
        let directory = temporaryDirectory("continue-ready")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-ready.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Continuing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-ready-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-ready-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue,
                       "the next ready episode should start once the current one runs out with nothing queued")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue },
                                     "retirement is not dismissal -- the row survives")
        XCTAssertNotNil(finished.retiredAt,
                         "the episode that was listened to all the way through is retired")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == firstID.rawValue },
                        "and off the Larder shelf")
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == firstID.rawValue })
        XCTAssertEqual(model.podcastOperationMessage, "Finished \(first.title).")
    }

    /// Coverage-table row: "Prepared episode's media disappears" (Phase 6).
    func testMediaMissingAfterPreparationDisablesPlaybackAndSurvivesDurableRecords() async throws {
        let directory = temporaryDirectory("media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/media-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/media-missing-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-missing-1", enclosureURL: enclosureURL
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Missing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "media-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let prepared = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertTrue(model.canPlayEpisode(prepared))
        model.playEpisode(prepared)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        let verifyStore = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let readyRevision = try await verifyStore.readyRevision(for: episodeID)
        let revisionID = try XCTUnwrap(readyRevision?.revision.revisionID)
        let outcomeBefore = try await verifyStore.preparationOutcome(for: episodeID, revisionID: revisionID)
        let listeningBefore = try await verifyStore.listeningState(for: episodeID)
        XCTAssertNotNil(listeningBefore?.completedAt)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("media-missing-1.m4a"))

        // A fresh launch is what actually rebuilds the snapshot from the store
        // and the filesystem together; nothing short of relaunch reaches
        // `loadLibrary` again from test code.
        let relaunched = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()

        let afterDeletion = try XCTUnwrap(relaunched.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertFalse(afterDeletion.isReadyMediaAvailable)
        XCTAssertFalse(relaunched.canPlayEpisode(afterDeletion))
        XCTAssertEqual(
            afterDeletion.lifecyclePresentation.label,
            "Prepared \u{00B7} Local audio missing — Download again"
        )
        XCTAssertTrue(afterDeletion.lifecyclePresentation.isFailure)
        XCTAssertTrue(afterDeletion.isPlayed, "the durable listening fact must survive the file's absence")
        XCTAssertNotNil(afterDeletion.retiredAt,
                        "natural completion still retired it before the file went missing")

        let outcomeAfter = try await verifyStore.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(outcomeAfter, outcomeBefore, "a missing file must not touch the durable preparation outcome")
        let listeningAfter = try await verifyStore.listeningState(for: episodeID)
        XCTAssertEqual(listeningAfter, listeningBefore, "a missing file must not touch the durable listening record")
    }

    /// Plan gate: "a test asserting no hashing occurs during snapshot
    /// construction (inject a counting file-manager seam)."
    func testLoadingTheLibraryChecksMediaExistenceOnceExactlyPerReadyRevision() async throws {
        let directory = temporaryDirectory("media-availability-seam")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/media-seam.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/media-seam-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/media-seam-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-seam-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-seam-2", enclosureURL: secondEnclosure
        )
        let checker = CountingMediaAvailabilityChecker()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Seam", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "media-seam-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                // Never downloaded, so there is no ready revision -- proving
                // the seam is not consulted once per episode, only once per
                // ready revision.
                try await store.save(episode: try PodcastEpisode(
                    itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "media-seam-2",
                    title: "Not ready", publishedTime: created, enclosureURL: secondEnclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            mediaAvailabilityChecker: checker,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.episodes.count, 2)
        XCTAssertEqual(checker.fileExistsCallCount, 1,
                       "exactly one stat for the one ready revision, and none for the unprepared episode")
    }

    /// Repeats the Phase 5 HIGH-severity chain (auto-advance skipping the
    /// finished item) for the media-availability gate added on top of it.
    func testNaturalCompletionSkipsASuccessorWhoseMediaWentMissing() async throws {
        let directory = temporaryDirectory("continue-media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-media-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Missing Media", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-media-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-media-missing-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-media-missing-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("continue-media-missing-2.m4a")
        )

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "the successor with missing media must be skipped in favor of the next ready one")
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertFalse(skipped.isReadyMediaAvailable)
        XCTAssertFalse(skipped.isPlayed, "skipping past it must not mark it finished")
        XCTAssertNil(skipped.retiredAt, "skipping past it must not retire it")
    }

    /// The fault names the episode that failed to load, not the one that just
    /// finished -- this is the same pair Phase 5's HIGH bug lived in. Uses two
    /// distinct episodes so a repair keyed on `itemID` instead of the fault's
    /// own associated value would fail this test: the just-finished episode
    /// (`itemID`) must stay untouched while the successor named by `fault`
    /// (`.podcastMediaUnavailable`) is the one that flips.
    func testMediaUnavailableFaultImmediatelyDisablesPlaybackForTheSuccessorNotTheFinishedEpisode() async throws {
        let directory = temporaryDirectory("fault-media-unavailable")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/fault-media.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let finishedEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/fault-media-finished.mp3"))
        let successorEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/fault-media-successor.mp3"))
        let finishedID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "fault-media-finished", enclosureURL: finishedEnclosure
        )
        let successorID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "fault-media-successor", enclosureURL: successorEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fault", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    finishedID, guid: "fault-media-finished", feedID: feedID, feedURL: feedURL,
                    enclosureURL: finishedEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    successorID, guid: "fault-media-successor", feedID: feedID, feedURL: feedURL,
                    enclosureURL: successorEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let finished = try XCTUnwrap(model.episodes.first { $0.id == finishedID.rawValue })
        let successor = try XCTUnwrap(model.episodes.first { $0.id == successorID.rawValue })
        XCTAssertTrue(finished.isReadyMediaAvailable)
        XCTAssertTrue(successor.isReadyMediaAvailable)

        // Mirrors PlaybackController.handleBackendCompletion's successor-load-throws
        // shape: `itemID` is the episode that just finished, `fault`'s associated
        // value is the successor that actually failed to load.
        model.applyPodcastPlaybackObservationForTesting(
            itemID: finishedID, fault: .podcastMediaUnavailable(successorID)
        )

        let repairedSuccessor = try XCTUnwrap(model.episodes.first { $0.id == successorID.rawValue })
        XCTAssertFalse(repairedSuccessor.isReadyMediaAvailable,
                       "a media-unavailable fault must flip the flag immediately, without waiting for a reload")
        XCTAssertFalse(model.canPlayEpisode(repairedSuccessor))

        let untouchedFinished = try XCTUnwrap(model.episodes.first { $0.id == finishedID.rawValue })
        XCTAssertTrue(untouchedFinished.isReadyMediaAvailable,
                      "the episode named by itemID just finished playing fine and must not be flagged")
        XCTAssertTrue(model.canPlayEpisode(untouchedFinished))
    }

    /// A manual "Play" throws out of `loadQueuedEpisode` before
    /// `podcastStateHandler` ever runs, so the auto-advance fault repair never
    /// fires on this path -- it needs its own repair in `playEpisode`'s catch.
    func testManuallyPlayingAnEpisodeWithMissingMediaDisablesItImmediately() async throws {
        let directory = temporaryDirectory("manual-play-media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-play-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/manual-play-missing-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-play-missing-1", enclosureURL: enclosureURL
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Play", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "manual-play-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manual-play-missing-1.m4a")
        )

        let episode = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let repaired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertFalse(repaired.isReadyMediaAvailable,
                       "a manual play that throws podcastMediaUnavailable must flip the flag without a reload")
        XCTAssertFalse(model.canPlayEpisode(repaired))
        XCTAssertNotNil(model.playbackError)
    }

    /// Symmetric to the manual-play test above: pressing Next also throws out of
    /// `loadQueuedEpisode` before `podcastStateHandler` ever runs, so
    /// `navigatePodcastQueue`'s own catch block is the only place that can repair
    /// the flag for this path.
    func testManuallySkippingToAnEpisodeWithMissingMediaDisablesItImmediately() async throws {
        let directory = temporaryDirectory("manual-skip-media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-missing-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-missing-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-missing-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-missing-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "manual-skip-missing-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        // `playEpisode` only enqueues the episode it plays -- the controller's
        // own queue, not the Larder-wide search `simulatePodcastPlaybackReachedEndForTesting`
        // uses -- so `second` must be enqueued explicitly for `nextPlayback` to reach it.
        let second = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        model.addEpisodeToUpNext(second)
        try await settle(model)
        XCTAssertTrue(model.canSelectNextEpisode,
                      "second's media is still on disk and queued, so Next must be enabled going in")

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manual-skip-missing-2.m4a")
        )

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let repaired = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertFalse(repaired.isReadyMediaAvailable,
                       "a manual skip that throws podcastMediaUnavailable must flip the flag without a reload")
        XCTAssertFalse(model.canPlayEpisode(repaired))
        XCTAssertNotNil(model.playbackError)
    }

    /// `canSelectNextEpisode`'s third gate, added alongside the other two media
    /// availability checks in this phase, had no direct coverage: this puts a
    /// missing-media episode at exactly the queue slot the property inspects.
    func testCanSelectNextEpisodeIsFalseWhenTheQueuedSuccessorsMediaIsMissing() {
        let root = temporaryDirectory("can-select-next-media-missing")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentID = "item-" + String(repeating: "1", count: 64)
        let missingID = "item-" + String(repeating: "2", count: 64)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = WiltedMacEpisode(
            id: currentID, title: "Current", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 100), durationSeconds: 600,
            playbackSeconds: 12, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        let missing = WiltedMacEpisode(
            id: missingID, title: "Missing", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 200), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced"),
            isReadyMediaAvailable: false
        )
        model.installEpisodeForTesting(missing)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [currentID, missingID]
        )

        XCTAssertFalse(model.canSelectNextEpisode,
                       "the queued successor's media is missing, so advancing to it must be disallowed")
    }

    /// In production, `PlaybackController`'s own `podcastCompletionHandler`
    /// retires the finished episode before `handlePodcastPlaybackFinished`
    /// ever runs its successor search -- the two fire from separate places in
    /// `handleBackendCompletion`, and the retirement's single store hop wins
    /// the race against the handler's own multi-hop reload. This test forces
    /// that ordering directly (retiring the episode between "reached end" and
    /// "finished") so the successor search has to find its anchor even though
    /// the anchor is already hidden and retired by the time it looks.
    func testFinishedEpisodeAdvancesEvenWhenItIsAlreadyRetiredBeforeTheSearchRuns() async throws {
        let directory = temporaryDirectory("continue-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-race.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-race-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-race-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-race-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-race-2", enclosureURL: secondEnclosure
        )

        let storeCapture = StoreCapture()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Racing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-race-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-race-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                await storeCapture.capture(store)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        let capturedStore = await storeCapture.store
        let store = try XCTUnwrap(capturedStore)
        _ = try await store.retireEpisode(firstID)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue,
                       "the search has to find its own anchor even though retirement already ran first")
    }

    /// The undownloaded middle episode is never a candidate; the search has
    /// to keep going past it rather than stopping at the first row after the
    /// one that finished.
    func testNaturalCompletionSkipsAnUndownloadedEpisodeToReachTheNextReadyOne() async throws {
        let directory = temporaryDirectory("continue-skip")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-skip.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Skipping", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-skip-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addUndownloadedEpisode(
                    secondID, guid: "continue-skip-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-skip-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "an undownloaded episode in between has to be skipped, not offered")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue },
                                     "retirement is not dismissal -- the finished episode's row survives")
        XCTAssertNotNil(finished.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == firstID.rawValue },
                       "the episode that finished is taken off the shelf")
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNil(skipped.retiredAt, "the one merely passed over is not -- it was never listened to")
    }

    /// Nothing else in the Larder is ready, so playback has to stop and the
    /// operation message has to say why -- silence with no explanation reads
    /// as a stall, not as "nothing to play."
    func testNaturalCompletionWithNoReadyEpisodeLeftStopsAndSaysSo() async throws {
        let directory = temporaryDirectory("continue-none")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-none.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let onlyEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-none-1.mp3"))
        let onlyID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-none-1", enclosureURL: onlyEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Alone", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    onlyID, guid: "continue-none-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: onlyEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let only = try XCTUnwrap(model.episodes.first { $0.id == onlyID.rawValue })
        model.playEpisode(only)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        // Retiring what was playing empties the player, the same as taking it off
        // the shelf by hand does; there is no episode left to show.
        XCTAssertNil(model.currentEpisode, "the finished episode was retired and nothing replaced it")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == onlyID.rawValue },
                                     "retirement is not dismissal -- the row survives")
        XCTAssertNotNil(finished.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == onlyID.rawValue })
        XCTAssertEqual(model.podcastOperationMessage,
                       "Finished \(only.title). No other downloaded, prepared episode is ready to play next.")
    }

    /// The handler is podcast-specific; an article running out must not go
    /// looking through the Larder at all.
    func testArticleCompletionDoesNotSearchForANextPodcastEpisode() {
        let directory = temporaryDirectory("continue-article")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = WiltedMacArticle(
            id: "article-1", title: "A Long Read", source: "example.com",
            url: URL(string: "https://example.com/read")!, isReady: true,
            durationSeconds: 300, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        model.installPlaybackStateForTesting(article: article, isPlaying: true, position: 300, duration: 300)

        model.simulatePodcastPlaybackFinishedForTesting()

        XCTAssertNil(model.podcastOperationMessage, "an article finishing has nothing to do with the podcast queue")
    }

    /// `applyPodcastPlaybackObservation` also covers `PlaybackController`'s
    /// own within-queue advance, which already wrote the outgoing episode's
    /// completed record before this fires; the in-memory Larder rows would
    /// otherwise not know until something else happened to reload them.
    func testMovingToAnotherPodcastEpisodeRefreshesTheLibraryRows() async throws {
        let directory = temporaryDirectory("continue-move-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-move.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Moving", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-move-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-move-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        try await settle(model)

        let phantom = WiltedMacEpisode(
            id: "phantom-episode", title: "Not really in the store", feedTitle: "Moving",
            summary: "", artworkURL: nil, releasedAt: created.date, durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed
        )
        model.installEpisodeForTesting(phantom)
        XCTAssertTrue(model.episodes.contains { $0.id == phantom.id })

        model.applyPodcastPlaybackObservationForTesting(itemID: secondID, fault: nil)
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue)
        XCTAssertFalse(model.episodes.contains { $0.id == phantom.id },
                       "moving to another episode has to reload the Larder from the store, not keep stale rows")
    }

    /// Pure enumeration logic, but it is the one line that decides whether an
    /// episode still preparing or one that failed can be handed to
    /// continuous playback, so it earns its own direct check.
    func testEpisodePreparationStateReportsWhetherItIsPrepared() {
        XCTAssertTrue(WiltedMacEpisodePreparationState.prepared(summary: "Ready").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.notPrepared.isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.preparing(stage: "Preparing…").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.failed("Failed").isPrepared)
    }

    // MARK: - Interrupted preparation runs

    /// The bug this covers: an install quit Wilted at 18:59 while an episode
    /// downloaded at 18:56 was still transcribing. The pipeline writes a run's
    /// terminal entry from inside the run, so the journal kept a live entry
    /// with nothing behind it, and the next launch read it back as
    /// "Preparing…" with a Stop that stopped nothing.
    func testBootstrapClosesARunTheJournalStillCallsLive() async throws {
        let directory = temporaryDirectory("interrupted-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://podcasts.example.test/interrupted.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Waveform", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        func episode(_ guid: String) async throws -> ItemID {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            return id
        }
        let interrupted = try await episode("interrupted")
        let finished = try await episode("finished")
        let interruptedRequest = WiltedMacModel.podcastRequestPrefix + interrupted.rawValue
        let finishedRequest = WiltedMacModel.podcastRequestPrefix + finished.rawValue
        // What the journal held when the process died: a start and a stage,
        // no terminal.
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|pipeline.start#1", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .preparing, detail: "Episode interrupted", cancellable: true, emittedAt: created)
        ))
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|transcript.stt.start#2", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .extracting, detail: "rev-abc.mp3", cancellable: true,
                                          emittedAt: Timestamp(created.date.addingTimeInterval(1)))
        ))
        // A run that did finish is not this launch's business.
        try await store.record(preparation: PreparationJournalEntry(
            id: finishedRequest + "|terminal", itemID: finished, requestID: finishedRequest,
            status: try PreparationStatus(stage: .completed, detail: "Prepared.", cancellable: false,
                                          terminalResult: try PreparationTerminalResult(
                                              outcome: .succeeded,
                                              revisionID: try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
                                          ),
                                          emittedAt: created)
        ))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let runs = Dictionary(uniqueKeysWithValues: try await store.preparationRuns().map { ($0.requestID, $0) })
        let closed = try XCTUnwrap(runs[interruptedRequest])
        XCTAssertTrue(closed.isTerminal, "a run no process is running must not stay live across a launch")
        XCTAssertEqual(closed.outcome, .failed)
        XCTAssertEqual(closed.failure?.message, WiltedMacModel.preparationInterruptedMessage)
        XCTAssertEqual(closed.entries.count, 3, "the run's own entries stay; one closing entry is added")
        let untouched = try XCTUnwrap(runs[finishedRequest])
        XCTAssertEqual(untouched.outcome, .succeeded)
        XCTAssertEqual(untouched.entries.count, 1)

        let row = try XCTUnwrap(model.episodes.first { $0.id == interrupted.rawValue })
        XCTAssertEqual(row.preparationState, .failed(WiltedMacModel.preparationFailedLabel),
                       "the row says the run failed and points at Prep, where the retry is")
        XCTAssertEqual(model.episodes.first { $0.id == finished.rawValue }?.preparationState.isRunning, false)
    }

    /// The closing entry is written only for a run that has no terminal
    /// entry, and it is one the journal reader recognises as a failure.
    func testInterruptedEntryIsWrittenOnlyForALiveRun() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "c", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func run(isTerminal: Bool) -> PreparationRunSummary {
            PreparationRunSummary(requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when,
                                  stage: isTerminal ? .completed : .extracting, detail: "x", fraction: nil,
                                  isTerminal: isTerminal, outcome: isTerminal ? .succeeded : nil, failure: nil)
        }
        XCTAssertNil(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: true), at: when))
        let entry = try XCTUnwrap(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: false), at: when))
        XCTAssertEqual(entry.id, requestID + "|interrupted")
        XCTAssertEqual(entry.requestID, requestID)
        XCTAssertTrue(entry.status.terminal)
        XCTAssertEqual(entry.status.terminalResult?.outcome, .failed)
        XCTAssertEqual(entry.status.terminalResult?.error?.retryable, true)
        XCTAssertEqual(entry.status.detail, WiltedMacModel.preparationInterruptedMessage)
    }

    /// Phase 4 gate: `closeInterruptedPreparationRuns` must not stamp a
    /// false `.failed` over a run whose own outcome already proves it
    /// finished before the process died -- only a genuinely stuck run (no
    /// outcome, or one that predates this run) gets closed.
    func testBootstrapDoesNotCloseALiveRunAnOutcomeAlreadyProves() async throws {
        let directory = temporaryDirectory("interrupted-run-proven")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://podcasts.example.test/proven.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Waveform", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))

        func episode(_ guid: String) async throws -> ItemID {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            return id
        }
        func makeReadyRevision(for id: ItemID, suffix: String) async throws -> RevisionID {
            let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: suffix, count: 64))
            let hash = "sha256:" + String(repeating: suffix, count: 64)
            let url = directory.appendingPathComponent("\(suffix).mp3")
            try Data("audio-\(suffix)".utf8).write(to: url)
            try await store.finalizePodcastDownload(
                revision: try AudioRevision(itemID: id, revisionID: revisionID, durationSeconds: 12, byteCount: 12,
                                            contentHash: hash, mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3),
                mediaURL: url,
                download: try PodcastDownload(episodeID: id, status: .completed, bytesReceived: 12,
                                              expectedByteCount: 12, localURL: url, contentHash: hash, updatedAt: created)
            )
            return revisionID
        }
        func nonTerminalEntry(for id: ItemID) throws -> PreparationJournalEntry {
            let requestID = WiltedMacModel.podcastRequestPrefix + id.rawValue
            return try PreparationJournalEntry(
                id: requestID + "|pipeline.start#1", itemID: id, requestID: requestID,
                status: try PreparationStatus(stage: .preparing, detail: "in flight", cancellable: true, emittedAt: created)
            )
        }

        // Proven: this run's own outcome landed (dated at the run's own
        // start) before the process died mid-journal-write.
        let proven = try await episode("proven")
        let provenRevisionID = try await makeReadyRevision(for: proven, suffix: "1")
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: proven, revisionID: provenRevisionID, policyDigest: "d", pipelineFingerprint: "f",
            semanticVersion: "v", producedAt: created
        ))
        try await store.record(preparation: nonTerminalEntry(for: proven))

        // Stuck: no outcome at all -- a genuinely interrupted run.
        let stuck = try await episode("stuck")
        _ = try await makeReadyRevision(for: stuck, suffix: "2")
        try await store.record(preparation: nonTerminalEntry(for: stuck))

        // Stale: an outcome exists, but it predates this run's own start, so
        // it proves nothing about whether *this* run finished.
        let stale = try await episode("stale")
        let staleRevisionID = try await makeReadyRevision(for: stale, suffix: "3")
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: stale, revisionID: staleRevisionID, policyDigest: "d", pipelineFingerprint: "f",
            semanticVersion: "v", producedAt: Timestamp(created.date.addingTimeInterval(-60))
        ))
        try await store.record(preparation: nonTerminalEntry(for: stale))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let runs = Dictionary(uniqueKeysWithValues: try await store.preparationRuns().map { ($0.requestID, $0) })
        let provenRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + proven.rawValue])
        XCTAssertFalse(provenRun.isTerminal,
                       "an outcome the run itself produced must not be overwritten with a false failure")
        XCTAssertEqual(provenRun.entries.count, 1, "no interrupted-closing entry should be added")

        let stuckRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + stuck.rawValue])
        XCTAssertTrue(stuckRun.isTerminal, "a run with no outcome proving it finished is genuinely stuck")
        XCTAssertEqual(stuckRun.outcome, .failed)
        XCTAssertEqual(stuckRun.failure?.message, WiltedMacModel.preparationInterruptedMessage)

        let staleRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + stale.rawValue])
        XCTAssertTrue(staleRun.isTerminal, "an outcome from before this run started proves nothing about it")
        XCTAssertEqual(staleRun.outcome, .failed)

        let provenEpisode = try XCTUnwrap(model.episodes.first { $0.id == proven.rawValue })
        XCTAssertTrue(provenEpisode.preparationState.isPrepared,
                      "the proven episode must read as prepared even though its journal entry is still open")
        let stuckEpisode = try XCTUnwrap(model.episodes.first { $0.id == stuck.rawValue })
        XCTAssertEqual(stuckEpisode.preparationState, .failed(WiltedMacModel.preparationFailedLabel))
    }

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
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("model.larderEpisodeCount(forFeedID: subscription.id)"),
                      "the Feeds row must render that count, not the raw snapshot one")
    }

    func testMenuInProgressIndicatorUsesLiveOrSavedPositionAndExcludesFinishedRows() {
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
        let finished = episode("finished", position: 99)
        XCTAssertTrue(model.isEpisodeInProgress(saved))
        XCTAssertFalse(model.isEpisodeInProgress(fresh))
        XCTAssertFalse(model.isEpisodeInProgress(finished))

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

    func testCurrentPlaybackShareUsesCanonicalOrFeedURLWithTextFallback() {
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
            feedURL: feedURL
        )
        model.installPlaybackStateForTesting(episode: episode, isPlaying: false, position: 12, duration: 100)
        XCTAssertEqual(model.currentPlaybackShareURL, feedURL)

        let fallback = WiltedMacEpisode(
            id: "fallback-episode", title: "An episode", feedTitle: "A show", summary: "",
            artworkURL: nil, releasedAt: Date(), durationSeconds: 100, playbackSeconds: 12,
            downloadState: .completed, preparationState: .prepared(summary: "Ready")
        )
        model.installPlaybackStateForTesting(episode: fallback, isPlaying: false, position: 12, duration: 100)
        XCTAssertNil(model.currentPlaybackShareURL)
        XCTAssertEqual(model.currentPlaybackShareText, "An episode — A show")
    }

    /// The Menu row's Played state asks the model's one finished predicate,
    /// including the boundary cases where surfaces used to disagree.
    func testFinishedHasOneDefinitionForTheMenuRow() throws {
        let cases: [(position: TimeInterval, duration: TimeInterval?, isPlayed: Bool, finished: Bool)] = [
            (0, 100, true, true),       // finished by hand, never reached the end
            (96, 100, false, true),     // stopped seconds short of the end
            (95, 100, false, true),     // the 95% boundary itself
            (94.9, 100, false, false),
            (0, nil, false, false),
            (0, 0, false, false),
            (0, nil, true, true),       // a record with no duration is still finished
        ]
        for (position, duration, isPlayed, expected) in cases {
            XCTAssertEqual(
                WiltedMacModel.isFinished(position: position, duration: duration, isPlayed: isPlayed),
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
        let stoppedShort = episode("finished-short", position: 96, played: false)
        let stillGoing = episode("still-going", position: 50, played: false)
        let notStarted = episode("not-started", position: 0, played: false)
        for value in [handFinished, stoppedShort, stillGoing, notStarted] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        // The Menu row asks the model's one predicate before it offers Play:
        // a finished episode says "Played" rather than waiting to be played
        // again. The threshold itself may not be duplicated in the view.
        XCTAssertTrue(model.isEpisodeFinished(handFinished),
                      "finished by hand never reached the end")
        XCTAssertTrue(model.isEpisodeFinished(stoppedShort))
        XCTAssertFalse(model.isEpisodeFinished(stillGoing))
        XCTAssertFalse(model.isEpisodeFinished(notStarted))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        XCTAssertTrue(modelSource.contains("Self.isFinished("),
                      "the row's Played state reads the model's one definition")
        XCTAssertEqual(modelSource.components(separatedBy: "func isFinished").count - 1, 1,
                       "exactly one implementation of the finished predicate")
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(source.contains("model.isEpisodeFinished(episode)"),
                      "the Menu row must read the model's one definition")
        XCTAssertFalse(source.contains("0.95"), "the threshold must live in one place")
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

        XCTAssertEqual(steps, [
            .openingStore,
            .updatingLibraryFormat,
            .retiringFinishedEpisodes,
            .checkingPreparationFingerprint,
            .closingInterruptedRuns,
            .reconcilingWork,
            .loadingLibrary,
            .restoringPlayback,
        ])
        let labels = steps.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "every awaited step renders one distinct string")
        XCTAssertEqual(model.startupState, .ready)
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
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(source.contains("model.startupStepLabel"),
                      "the loading surface must render the step the model is on")
        XCTAssertFalse(source.contains("Opening and updating your larder"),
                       "the fixed sentence must be gone")
    }

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

        let model = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
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
        let pipeline = try String(
            contentsOf: root.appendingPathComponent("Producer/Sources/WiltedProducer/PodcastPreparationPipeline.swift")
        )
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

        let model = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
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
        XCTAssertEqual(model.podcastOperationMessage, "Untouched was not started, so nothing was skipped.")
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
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
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
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertTrue(fixture.model.feedsEpisodes.contains { $0.id == episode.id })

        fixture.model.skipFeedEpisode(episode)
        try await settle(fixture.model)
        let skipped = try XCTUnwrap(fixture.model.skippedFeedEpisodes.first { $0.id == episode.id })
        XCTAssertNotNil(skipped.retiredAt)
        XCTAssertFalse(fixture.model.feedsEpisodes.contains { $0.id == episode.id })

        fixture.model.restoreSkippedFeedEpisode(skipped)
        try await settle(fixture.model)

        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == episode.id })
        XCTAssertNil(restored.retiredAt, "restore clears the retirement")
        XCTAssertFalse(restored.isPlayed, "restore does not write a completion record")
        XCTAssertTrue(fixture.model.feedsEpisodes.contains { $0.id == episode.id },
                      "the row returns to the set Feeds renders")
        XCTAssertEqual(fixture.model.podcastOperationMessage, "Restored \(restored.title) to Feeds.")
    }

    /// 2.4: Feeds renders a restore control for skipped and removed rows, with
    /// stable identifiers.
    func testFeedsRendersRestoreControlsForSkippedAndRemovedEpisodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
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
        try await settle(model)
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

    // MARK: Phase 0 — the two-destination restructure

    func testNavigationHasExactlyTheThreeSurvivingDestinations() {
        XCTAssertEqual(WiltedMacNavigation.allCases, [.menu, .feeds, .settings])
        XCTAssertEqual(WiltedMacNavigation.allCases.map(\.title), ["Larder", "Feeds", "Settings"])
    }

    func testOnlyKeptEpisodesMayResumeDurableDownloadClaims() {
        let claims: Set<String> = ["kept", "undecided", "skipped"]
        XCTAssertEqual(
            WiltedMacModel.keptDownloadClaims(claims, queueIDs: ["kept", "another-kept"]),
            ["kept"]
        )
    }

    func testARestoredSelectionNamingARetiredDestinationResolvesToTheMenu() {
        XCTAssertEqual(WiltedMacNavigation.restored(from: "library"), .menu)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "processor"), .menu)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "feeds"), .feeds)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "menu"), .menu)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "settings"), .settings)
        XCTAssertEqual(WiltedMacNavigation.restored(from: nil), .menu,
                       "no stored selection lands on the one waiting place")
        XCTAssertEqual(WiltedMacNavigation.restored(from: "sideways"), .menu,
                       "an unreadable selection resolves rather than crashing")
    }

    func testAStoredRetiredDestinationRestoresToTheMenu() {
        let directory = temporaryDirectory("navigation-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "com.zerodelta.wilted.mac.navigation-restore-tests"
        let preferences = UserDefaults(suiteName: suite) ?? UserDefaults()
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        preferences.set("library", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromLibrary = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromLibrary.selectedNavigation, .menu, "the retired Larder resolves to the Menu")

        preferences.set("processor", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromProcessor = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromProcessor.selectedNavigation, .menu, "the retired Prep resolves to the Menu")

        preferences.set("settings", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromSettings = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromSettings.selectedNavigation, .settings, "a live destination still restores")
    }

    func testTheRetiredSurfacesRetainNoRenderer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        for retired in ["WiltedMacLibraryView", "WiltedMacProcessorView", "WiltedMacEpisodeRow",
                        "WiltedMacPreparationView", "WiltedMacQueueControls", "WiltedMacQueueSection",
                        "WiltedMacQueueGrouping", "WiltedMacLibraryKind"] {
            XCTAssertFalse(view.contains(retired), "\(retired) is a retired renderer and must be deleted")
        }
        let model = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        for retired in ["preparationQueueSections", "makeQueueSections", "WiltedMacQueueSection",
                        "WiltedMacLibraryKind", "WiltedMacQueueGrouping", "WiltedMacQueueStatus",
                        "WiltedMacPreparationSort"] {
            XCTAssertFalse(model.contains(retired), "\(retired) is retired model code and must be deleted")
        }
    }

    /// Destination helper: every visible episode is in Feeds until it is kept.
    private func destinationEpisode(
        _ id: String,
        download: WiltedMacEpisodeDownloadState,
        preparation: WiltedMacEpisodePreparationState
    ) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: download,
            preparationState: preparation
        )
    }

    func testEveryEpisodeAppearsOnExactlyOneDestination() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("dest-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("dest-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("dest-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("dest-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
        }

        // Nothing is kept yet: every episode is in Feeds and none is waiting.
        XCTAssertEqual(Set(model.feedsEpisodes.map(\.id)),
                       Set([available.id, downloaded.id, preparing.id, ready.id]))
        XCTAssertTrue(model.menuWaitingEpisodes.isEmpty)
        XCTAssertTrue(
            Set(model.feedsEpisodes.map(\.id))
                .isDisjoint(with: Set(model.menuWaitingEpisodes.map(\.id))),
            "no episode may appear on both destinations"
        )

        // Kept: every episode is waiting, each in exactly one Menu group, and
        // none remains in Feeds.
        for value in [available, downloaded, preparing, ready] {
            model.keepEpisode(value)
        }
        XCTAssertTrue(model.feedsEpisodes.isEmpty)
        XCTAssertEqual(model.menuWaitingEpisodes.count, 4)
        let grouped = WiltedMacMenuGroup.allCases.flatMap { model.menuEpisodes(in: $0) }
        XCTAssertEqual(grouped.count, 4, "each waiting episode appears in exactly one group")
        XCTAssertEqual(Set(grouped.map(\.id)), Set(model.menuWaitingEpisodes.map(\.id)))
    }

    func testAFeedsRowOffersExactlyKeepAndSkip() throws {
        XCTAssertEqual(WiltedMacFeedsAction.allCases.map(\.rawValue), ["Keep", "Skip"],
                       "Feeds asks one question; every other step belongs on the Menu")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("ForEach(WiltedMacFeedsAction.allCases)"),
                      "the inbox row's buttons are that list, not a hand-kept set")
    }

    func testKeepPutsAnEpisodeOnTheMenuWithoutTouchingItsAudio() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let prepared = WiltedMacEpisode(
            id: "keep-prepared", title: "Prepared", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 12, downloadState: .completed,
            preparationState: .prepared(summary: "Ad removed"), isReadyMediaAvailable: true
        )
        model.installEpisodeForTesting(prepared)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == prepared.id })

        model.keepEpisode(prepared)

        XCTAssertTrue(model.podcastQueueIDs.contains(prepared.id), "the kept episode waits on the Menu")
        XCTAssertTrue(model.menuWaitingEpisodes.contains { $0.id == prepared.id })
        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == prepared.id })
        guard let after = model.episodes.first(where: { $0.id == prepared.id }) else {
            return XCTFail("the kept row must still exist")
        }
        XCTAssertEqual(after.downloadState, .completed, "Keep must not change the download")
        XCTAssertEqual(after.preparationState, .prepared(summary: "Ad removed"),
                       "Keep must not change the prepared cut")
        XCTAssertEqual(after.isReadyMediaAvailable, true, "Keep must not change the transcript's audio")
        XCTAssertEqual(after.playbackSeconds, 12, "Keep must not change the saved position")
    }

    func testAnEpisodeAlreadyWaitingIsNotOfferedInFeeds() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let episode = destinationEpisode("feeds-excluded", download: .completed, preparation: .notPrepared)
        model.installEpisodeForTesting(episode)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == episode.id })

        model.keepEpisode(episode)

        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == episode.id },
                       "an episode waiting on the Menu is not a Feeds arrival")
    }

    func testMenuGroupForEachReadinessState() {
        XCTAssertEqual(
            WiltedMacModel.menuGroup(for: destinationEpisode(
                "group-available", download: .notDownloaded, preparation: .notPrepared)),
            .available
        )
        XCTAssertEqual(
            WiltedMacModel.menuGroup(for: destinationEpisode(
                "group-downloaded", download: .completed, preparation: .notPrepared)),
            .downloaded
        )
        XCTAssertEqual(
            WiltedMacModel.menuGroup(for: destinationEpisode(
                "group-failed", download: .completed, preparation: .failed("Preparation failed"))),
            .downloaded,
            "a failed preparation is still a downloaded episode needing the prepare step"
        )
        XCTAssertEqual(
            WiltedMacModel.menuGroup(for: destinationEpisode(
                "group-prepared", download: .completed, preparation: .prepared(summary: "Ready"))),
            .playable
        )
        // Prepared but its media is gone: playable is a claim about the file
        // on disk, so it stays one step away rather than offering Play.
        var missingMedia = destinationEpisode(
            "group-media-missing", download: .completed, preparation: .prepared(summary: "Ready")
        )
        missingMedia.isReadyMediaAvailable = false
        XCTAssertEqual(WiltedMacModel.menuGroup(for: missingMedia), .downloaded)
    }

    func testTheMenuGroupSequenceIsFixed() {
        XCTAssertEqual(WiltedMacMenuGroup.allCases, [.playable, .downloaded, .available],
                       "available can be downloaded, downloaded can be prepared, prepared can be played")
    }

    func testPreparingStaysInDownloadedAndTheRowCarriesTheProgressFigure() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let preparing = destinationEpisode("group-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        model.installEpisodeForTesting(preparing)
        model.keepEpisode(preparing)

        XCTAssertEqual(WiltedMacModel.menuGroup(for: preparing), .downloaded,
                       "preparing is a state, not a group")
        XCTAssertTrue(model.menuEpisodes(in: .downloaded).contains { $0.id == preparing.id })
        XCTAssertFalse(model.menuEpisodes(in: .playable).contains { $0.id == preparing.id })

        // The row renders the one progress accessor, keyed by the episode id.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("model.preparationFraction(forEpisode: episode.id)"))
        XCTAssertTrue(view.contains("wilted-menu-progress-"))
    }

    func testASelectedMenuFilterRendersExactlyThatGroup() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("filter-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("filter-downloaded", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("filter-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.menuFilter = .downloaded
        XCTAssertEqual(Set(model.menuFilteredEpisodes.map(\.id)),
                       Set(model.menuEpisodes(in: .downloaded).map(\.id)))
        XCTAssertEqual(model.menuFilteredEpisodes.map(\.id), [downloaded.id])

        model.menuFilter = nil
        XCTAssertEqual(Set(model.menuFilteredEpisodes.map(\.id)),
                       Set(model.menuWaitingEpisodes.map(\.id)),
                       "the unfiltered selection is every waiting episode")
        XCTAssertEqual(model.menuFilteredEpisodes.count, 3)
    }

    func testEveryMenuCountReadsTheGroupAccessorItLabels() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("count-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("count-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("count-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("count-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        // One group, one set: a heading's count is the size of the rows it
        // labels, and the groups partition the waiting list exactly.
        XCTAssertEqual(model.menuEpisodes(in: .available).map(\.id), [available.id])
        XCTAssertEqual(model.menuEpisodes(in: .downloaded).map(\.id).sorted(),
                       [downloaded.id, preparing.id].sorted())
        XCTAssertEqual(model.menuEpisodes(in: .playable).map(\.id), [ready.id])
        XCTAssertEqual(
            WiltedMacMenuGroup.allCases.reduce(0) { $0 + model.menuEpisodes(in: $1).count },
            model.menuWaitingEpisodes.count
        )

        // And the view draws every heading and chip from that accessor.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("model.menuEpisodes(in: group).count"),
                      "a heading or chip count must come from the group accessor")
        XCTAssertFalse(view.contains("menuQueueSections"),
                       "no parallel filter may rebuild the Menu list")
    }

    // MARK: Menu bulk actions and group clears

    /// The retired upcoming-scoped clear is gone, and every group owns a clear
    /// whose identifier names the group it acts on.
    func testTheRetiredUpcomingClearIsGoneAndEveryGroupClearsItsOwnRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        XCTAssertFalse(modelSource.contains("clearUpcomingMenu"),
                       "the upcoming-scoped clear is retired")
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertFalse(view.contains("wilted-menu-clear-upcoming"),
                       "the retired identifier must not survive in the view")
        for identifier in [
            "wilted-menu-clear-ready",
            "wilted-menu-clear-downloaded",
            "wilted-menu-clear-available",
        ] {
            XCTAssertTrue(view.contains(identifier), "\(identifier) must name its own group")
        }
        XCTAssertTrue(view.contains("model.menuGroupClearLabel(group)"))
    }

    func testAGroupClearRemovesExactlyItsOwnRows() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("clear-available", download: .notDownloaded, preparation: .notPrepared)
        var started = destinationEpisode("clear-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 30
        let untouched = destinationEpisode("clear-untouched", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("clear-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, started, untouched, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.clearMenuGroup(.downloaded)

        XCTAssertEqual(model.menuEpisodes(in: .available).map(\.id), [available.id])
        XCTAssertEqual(model.menuEpisodes(in: .playable).map(\.id), [ready.id])
        XCTAssertTrue(model.menuEpisodes(in: .downloaded).isEmpty)
        XCTAssertEqual(Set(model.menuWaitingEpisodes.map(\.id)), Set([available.id, ready.id]),
                       "only the cleared group's rows leave the Menu")
        // Nothing about the removed rows changed beyond Menu membership: no
        // download was cancelled and no prepared cut was touched.
        XCTAssertEqual(model.episodes.first { $0.id == started.id }?.downloadState, .completed)
        XCTAssertEqual(model.episodes.first { $0.id == started.id }?.preparationState, .notPrepared)
        XCTAssertEqual(model.episodes.first { $0.id == untouched.id }?.downloadState, .completed)
    }

    func testAClearLabelSaysClearWhenAnyRowWasStartedAndSkipOtherwise() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var started = destinationEpisode("label-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 12
        let fresh = destinationEpisode("label-fresh", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("label-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [started, fresh, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertEqual(model.menuGroupClearLabel(.downloaded), "Remove all 2 from Larder")
        XCTAssertEqual(model.menuGroupClearLabel(.playable), "Remove all 1 from Larder")
    }

    func testAGroupRemovalDoesNotMarkStartedRowsCompletedOrSkipped() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var started = destinationEpisode("report-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 12
        let fresh = destinationEpisode("report-fresh", download: .completed, preparation: .notPrepared)
        for value in [started, fresh] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.clearMenuGroup(.downloaded)

        let message = try XCTUnwrap(model.podcastOperationMessage)
        XCTAssertEqual(message,
                       "Removed all 2 in Downloaded from Larder. No download, prepared cut, transcript, or listening history was touched.")
        XCTAssertFalse(model.episodes.first { $0.id == started.id }?.isPlayed == true)
        XCTAssertNil(model.undoableSkip, "a bulk clear leaves nothing single for Undo Skip")

        // The same queue-only contract applies when no row was started.
        let freshModel = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let neverStarted = destinationEpisode("report-never", download: .completed, preparation: .notPrepared)
        freshModel.installEpisodeForTesting(neverStarted)
        freshModel.keepEpisode(neverStarted)
        freshModel.clearMenuGroup(.downloaded)
        XCTAssertEqual(freshModel.podcastOperationMessage,
                       "Removed all 1 in Downloaded from Larder. No download, prepared cut, transcript, or listening history was touched.")
    }

    func testTheToolbarBulkActionsActOnTheSetTheirCountNames() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("bulk-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("bulk-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("bulk-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("bulk-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertEqual(model.menuDownloadableEpisodes.map(\.id), [available.id],
                       "Download all acts on the Available group")
        XCTAssertEqual(model.menuPreparableEpisodes.map(\.id), [downloaded.id],
                       "Prepare all acts on the downloaded rows that have not started preparing")

        // The label's count and the press's set are one accessor, so they
        // cannot promise different work.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        for fragment in [
            "model.menuDownloadableEpisodes.count",
            "model.menuDownloadableEpisodes.isEmpty",
            "model.menuPreparableEpisodes.count",
            "model.menuPreparableEpisodes.isEmpty",
        ] {
            XCTAssertTrue(view.contains(fragment), "\(fragment) must be the toolbar's source")
        }
        for identifier in [
            "wilted-menu-play-first",
            "wilted-menu-group-prepare-all",
            "wilted-menu-group-download-all",
        ] {
            XCTAssertTrue(view.contains(identifier), "\(identifier) must sit on its group's heading")
        }
        let modelSource = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        XCTAssertTrue(modelSource.contains("for episode in menuDownloadableEpisodes"))
        XCTAssertTrue(modelSource.contains("for episode in menuPreparableEpisodes"))
    }

    /// Prepare all starts exactly the Downloaded group's eligible rows and
    /// leaves every other group's rows in their prior state.
    func testPrepareAllStartsOnlyTheDownloadedGroupsEligibleRows() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], preferences: WiltedMacTestPreferences.ephemeral()
        )
        let available = destinationEpisode("start-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("start-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("start-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("start-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.prepareAllDownloadedMenuEpisodes()

        XCTAssertEqual(model.episodes.first { $0.id == downloaded.id }?.preparationState,
                       .preparing(stage: WiltedMacModel.preparingStage),
                       "the eligible downloaded row starts")
        XCTAssertEqual(model.episodes.first { $0.id == preparing.id }?.preparationState,
                       .preparing(stage: "Preparing…"),
                       "an already-running preparation is not restarted")
        XCTAssertEqual(model.episodes.first { $0.id == available.id }?.preparationState, .notPrepared,
                       "an Available row is not prepared")
        XCTAssertEqual(model.episodes.first { $0.id == ready.id }?.preparationState,
                       .prepared(summary: "Ready"), "a Ready row is not touched")
    }

    func testPrepareAllNowOverridesDeferredRowsWithoutDuplicatingRunningWork() throws {
        let (directory, model, deferred) = try automationFixture("prepare-all-now-deferred")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.keepEpisode(deferred)
        model.admitAutomaticPreparation(for: deferred, at: try localDate(hour: 12))
        XCTAssertEqual(model.menuPreparableEpisodes.map(\.id), [deferred.id])

        model.prepareAllDownloadedMenuEpisodes()

        XCTAssertFalse(model.isDeferredForOffPeak(deferred.id))
        XCTAssertTrue(model.episodes.first(where: { $0.id == deferred.id })?.preparationState.isRunning == true)
        XCTAssertTrue(model.menuPreparableEpisodes.isEmpty,
                      "a genuinely running preparation must not be offered or started twice")
    }

    // MARK: Sidebar totals

    /// The sidebar's three waiting times are the playable group's, the
    /// downloaded group's, and the whole Menu's; each is summed from the same
    /// accessor its heading counts, and an unknown duration stays a count.
    func testSidebarTotalsSumTheSameSetsTheirHeadingsCount() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func episode(_ id: String, duration: TimeInterval?, download: WiltedMacEpisodeDownloadState,
                     preparation: WiltedMacEpisodePreparationState) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: duration, playbackSeconds: 0,
                downloadState: download, preparationState: preparation
            )
        }
        let readyKnown = episode("sidebar-ready-known", duration: 600, download: .completed,
                                 preparation: .prepared(summary: "Ready"))
        let readyUnknown = episode("sidebar-ready-unknown", duration: nil, download: .completed,
                                   preparation: .prepared(summary: "Ready"))
        let downloaded = episode("sidebar-downloaded", duration: 300, download: .completed,
                                 preparation: .notPrepared)
        for value in [readyKnown, readyUnknown, downloaded] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertEqual(model.menuGroupAudioSummary(.playable).seconds, 600)
        XCTAssertEqual(model.menuGroupAudioSummary(.playable).unknownCount, 1,
                       "an unknown duration is excluded and counted, not treated as zero")
        XCTAssertEqual(model.menuGroupAudioSummary(.downloaded).seconds, 300)
        XCTAssertEqual(model.menuGroupAudioSummary(.downloaded).unknownCount, 0)
        XCTAssertEqual(model.menuAudioSummary.seconds, 900)
        XCTAssertEqual(model.menuAudioSummary.unknownCount, 1)
        XCTAssertEqual(model.menuAudioSummary, WiltedMacQueueAudioSummary(episodes: model.menuWaitingEpisodes),
                       "the whole-Menu figure sums the waiting set the Menu counts")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        for fragment in [
            "wilted-sidebar-ready-total",
            "wilted-sidebar-downloaded-total",
            "wilted-sidebar-menu-total",
            "model.menuGroupAudioSummary(.playable)",
            "model.menuGroupAudioSummary(.downloaded)",
            "model.menuAudioSummary",
        ] {
            XCTAssertTrue(view.contains(fragment), "\(fragment) must be in the sidebar's totals")
        }
        // The totals are a standing readout, so they sit below the navigation
        // List rather than inside it, where a growing destination list would
        // scroll them out of sight.
        let listEnd = try XCTUnwrap(view.range(of: ".scrollContentBackground(.hidden)"))
        let totals = try XCTUnwrap(view.range(of: "sidebarTotals\n"))
        XCTAssertTrue(totals.lowerBound > listEnd.upperBound,
                      "the totals must be pinned below the navigation List, not scroll with it")
        XCTAssertTrue(view.contains("wilted-sidebar-totals"))
    }

    // MARK: Menu row controls

    /// A preparing row offers Stop and a failed preparation offers Retry, both
    /// on the row that is in the state.
    func testAPreparingRowOffersStopAndAFailedOneOffersRetry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("wilted-menu-stop-"),
                      "a preparing row must offer a way to stop the run")
        XCTAssertTrue(view.contains("model.cancelEpisodePreparation(episode)"))
        XCTAssertTrue(view.contains("wilted-menu-retry-"),
                      "a failed preparation must offer a retry beside it")
        XCTAssertTrue(view.contains("model.prepareEpisode(episode)"))
        XCTAssertTrue(view.contains("episode.preparationState.isRunning"))
        XCTAssertTrue(view.contains("case .failed = episode.preparationState"))
    }

    // MARK: Menu row retirement (Task 0.5)

    /// The row's one retirement control reads the model's label: "Completed"
    /// once an episode was started, "Skip" when pressing it can only pass the
    /// episode on. Both labels press the reversible `skipEpisode`.
    func testMenuRowRetirementLabelIsCompletedOnlyOnceStarted() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let started = retirementEpisode("retire-started", position: 12)
        let unstarted = retirementEpisode("retire-unstarted", position: 0)
        model.installEpisodeForTesting(started)
        model.installEpisodeForTesting(unstarted)

        XCTAssertEqual(model.menuRowRetirementLabel(started), "Completed",
                       "a saved position means the press finishes a record")
        XCTAssertEqual(model.menuRowRetirementLabel(unstarted), "Skip")
        XCTAssertTrue(model.hasStartedEpisode(started))
        XCTAssertFalse(model.hasStartedEpisode(unstarted))

        let playing = retirementEpisode("retire-playing", position: 0)
        model.installEpisodeForTesting(playing)
        model.installPlaybackStateForTesting(episode: playing, isPlaying: true, position: 0, duration: 600)
        XCTAssertEqual(model.menuRowRetirementLabel(playing), "Completed",
                       "the episode playing right now counts as started")
    }

    private func retirementEpisode(_ id: String, position: TimeInterval) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: position,
            downloadState: .completed, preparationState: .notPrepared
        )
    }

    /// The started predicate is declared once, in the model, and the view
    /// reads the model's label rather than restating the comparison.
    func testTheStartedPredicateLivesOnceInTheModelAndTheViewReadsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        XCTAssertEqual(modelSource.components(separatedBy: "playbackSeconds > 0").count - 1, 1,
                       "the started predicate must have one home")
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertEqual(view.components(separatedBy: "playbackSeconds > 0").count - 1, 0,
                       "the view must not restate the predicate")
        XCTAssertTrue(view.contains("model.menuRowRetirementLabel(episode)"))
        XCTAssertTrue(view.contains("model.skipEpisode(episode)"))
        XCTAssertTrue(view.contains("wilted-menu-skip-\\(episode.id)"))
        XCTAssertEqual(view.components(separatedBy: "model.removeEpisode(").count - 1, 0,
                       "the destructive path gets no row surface")
    }

    // MARK: Settings overrides (Task 0.6)

    func testMenuOverridesAreOffByDefaultAndSurviveARebuild() {
        let suite = "com.zerodelta.wilted.mac.menu-overrides-tests"
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertFalse(first.automationSettings.downloadEverythingOnMenu)
        XCTAssertFalse(first.automationSettings.prepareEverythingDownloaded)

        first.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: settings.processingPolicy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToMenu: settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: true, prepareEverythingDownloaded: true
            )
        }

        let rebuilt = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertTrue(rebuilt.automationSettings.downloadEverythingOnMenu,
                      "the download override must survive a model rebuild")
        XCTAssertTrue(rebuilt.automationSettings.prepareEverythingDownloaded,
                      "the prepare override must survive a model rebuild")
    }

    /// Turning an override on takes the same bulk step the Menu's matching
    /// group action takes; the override is not a second enqueue path.
    func testMenuOverridesReuseTheMenuBulkAdmissionFunctions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        let start = try XCTUnwrap(source.range(of: "func setAutomationSettings"))
        let end = try XCTUnwrap(source.range(of: "func updateAutomationSettings",
                                             range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("downloadAllAvailableMenuEpisodes()"),
                      "the download override must reuse the Menu's bulk admission")
        XCTAssertTrue(body.contains("prepareAllDownloadedMenuEpisodes()"),
                      "the prepare override must reuse the Menu's bulk admission")
    }

    /// The download override admits the whole Available group, not just later
    /// arrivals: turning it on against a Menu that already holds episodes
    /// leaves nothing available and disables the bulk action.
    func testDownloadEverythingOverrideAdmitsTheWholeAvailableGroup() async throws {
        let directory = temporaryDirectory("download-everything-override")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/download-everything.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let downloads = try (0..<2).map { index -> (enclosure: URL, id: ItemID) in
            let enclosure = try XCTUnwrap(
                URL(string: "https://media.example.test/download-everything-\(index).mp3")
            )
            return (enclosure, try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "override-\(index)", enclosureURL: enclosure
            ))
        }
        let enclosures = downloads.map(\.enclosure)
        let episodeIDs = downloads.map(\.id)
        let eventsByURL = Dictionary(uniqueKeysWithValues: enclosures.map { url in
            (url, [
                PodcastDownloadEvent.response(.init(
                    url: url, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4
                )),
                PodcastDownloadEvent.data(Data("body".utf8))
            ])
        })
        let transport = ConcurrencyTrackingPodcastDownloadTransport(eventsByURL: eventsByURL)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Override feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in episodeIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: "override-\(index)",
                        title: "Override episode \(index)", publishedTime: created,
                        enclosureURL: enclosures[index], enclosureMediaType: "audio/mpeg", createdAt: created
                    ))
                }
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episodes = episodeIDs.compactMap { id in
            model.episodes.first(where: { $0.id == id.rawValue })
        }
        XCTAssertEqual(episodes.count, 2)
        for episode in episodes { model.keepEpisode(episode) }
        XCTAssertEqual(model.menuDownloadableEpisodes.count, 2, "both rows are Available before the override")

        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToMenu: settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: true, prepareEverythingDownloaded: false
            )
        }
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.menuEpisodes(in: .available).isEmpty,
                      "everything available was admitted, not hidden")
        XCTAssertTrue(model.menuDownloadableEpisodes.isEmpty,
                      "the disabled bulk action has no set left")
        for id in episodeIDs {
            XCTAssertEqual(model.episodes.first { $0.id == id.rawValue }?.downloadState, .completed,
                           "admission goes through the real download path")
        }
    }

    /// The prepare override starts the whole eligible Downloaded group and
    /// leaves the other groups alone.
    func testPrepareEverythingOverridePreparesTheWholeDownloadedGroup() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], preferences: WiltedMacTestPreferences.ephemeral()
        )
        let downloaded = destinationEpisode(
            "override-prepare-downloaded", download: .completed, preparation: .notPrepared
        )
        let available = destinationEpisode(
            "override-prepare-available", download: .notDownloaded, preparation: .notPrepared
        )
        for value in [downloaded, available] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: settings.processingPolicy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToMenu: settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: false, prepareEverythingDownloaded: true
            )
        }

        XCTAssertEqual(model.episodes.first { $0.id == downloaded.id }?.preparationState,
                       .preparing(stage: WiltedMacModel.preparingStage),
                       "the downloaded row starts on the override")
        XCTAssertEqual(model.episodes.first { $0.id == available.id }?.preparationState, .notPrepared,
                       "an Available row is not prepared")
    }

    // MARK: Menu search (Task 0.8)

    /// A query matching an episode's show notes keeps that row on the Menu.
    func testMenuSearchKeepsTheRowWhoseShowNotesMatch() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let matching = searchEpisode("search-matching", notes: "The winter garden survives")
        let other = searchEpisode("search-other", notes: "A different subject")
        for value in [matching, other] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        model.librarySearchQuery = "winter garden"

        XCTAssertEqual(model.menuSearchResults.map(\.id), [matching.id])
        XCTAssertEqual(model.menuEpisodes(in: .downloaded).map(\.id), [matching.id])
    }

    /// A transcript-only match admits exactly the row the store named, and
    /// shows no row the set does not name.
    func testMenuSearchShowsTranscriptNamedRowsAndNothingElse() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let named = searchEpisode("search-transcript-named", notes: "Nothing visible matches")
        let other = searchEpisode("search-transcript-other", notes: "Nothing visible matches")
        for value in [named, other] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }
        model.librarySearchQuery = "cormorant"
        model.installTranscriptSearchMatchesForTesting([named.id])

        XCTAssertEqual(model.menuSearchResults.map(\.id), [named.id],
                       "the transcript set admits the row it names")
        XCTAssertFalse(model.menuSearchResults.contains { $0.id == other.id },
                       "the transcript set does not licence any other row")
    }

    /// A query below the floor never schedules a transcript read at all.
    func testAShortQueryNeverSchedulesATranscriptRead() async throws {
        let directory = temporaryDirectory("short-query")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.librarySearchQuery = "co"
        XCTAssertFalse(model.isSearchingTranscripts)
        XCTAssertTrue(model.transcriptSearchMatches.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isSearchingTranscripts,
                       "a two-character query must not reach the store")
        XCTAssertTrue(model.transcriptSearchMatches.isEmpty)
    }

    /// Clearing the field returns every row even when a transcript answer is
    /// still held from the previous query.
    func testAnEmptyQueryReturnsEveryRowDespiteAStaleTranscriptSet() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let first = searchEpisode("search-clear-first", notes: "One")
        let second = searchEpisode("search-clear-second", notes: "Two")
        for value in [first, second] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }
        model.librarySearchQuery = "cormorant"
        model.installTranscriptSearchMatchesForTesting([first.id])
        XCTAssertEqual(model.menuSearchResults.map(\.id), [first.id])

        model.librarySearchQuery = ""
        XCTAssertFalse(model.isSearchingMenu)
        XCTAssertEqual(Set(model.menuSearchResults.map(\.id)), Set([first.id, second.id]))
    }

    /// While a search is active every group's bulk action is disabled, and
    /// the control says why; with the field clear the sets are non-empty.
    func testSearchDisablesEveryMenuBulkAction() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode(
            "search-bulk-available", download: .notDownloaded, preparation: .notPrepared
        )
        let downloaded = destinationEpisode(
            "search-bulk-downloaded", download: .completed, preparation: .notPrepared
        )
        for value in [available, downloaded] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertFalse(model.isSearchingMenu)
        XCTAssertFalse(model.menuDownloadableEpisodes.isEmpty,
                       "the Available bulk action has work with a clear field")
        XCTAssertFalse(model.menuPreparableEpisodes.isEmpty,
                       "the Prepare bulk action has work with a clear field")

        model.librarySearchQuery = "nothing matches this"
        XCTAssertTrue(model.isSearchingMenu)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("wilted-menu-search-suppresses-bulk"),
                      "the disabled control must say a search is active")
        XCTAssertGreaterThanOrEqual(
            view.components(separatedBy: "|| model.isSearchingMenu").count - 1, 5,
            "every bulk action must be disabled by an active search"
        )
        XCTAssertTrue(view.contains(".disabled(model.isSearchingMenu)"),
                      "the group clear is a bulk action too")
        XCTAssertTrue(view.contains(".searchable(text: $model.librarySearchQuery,"),
                      "the Menu must expose the search field")
    }

    /// The sidebar totals describe the Menu, not the current search.
    func testMenuSearchLeavesTheSidebarTotalsUnchanged() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = destinationEpisode(
            "search-sidebar-ready", download: .completed, preparation: .prepared(summary: "Ready")
        )
        let downloaded = destinationEpisode(
            "search-sidebar-downloaded", download: .completed, preparation: .notPrepared
        )
        for value in [ready, downloaded] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }
        let playableTotal = model.menuGroupAudioSummary(.playable)
        let menuTotal = model.menuAudioSummary

        model.librarySearchQuery = "no episode matches this"

        XCTAssertTrue(model.menuSearchResults.isEmpty)
        XCTAssertEqual(model.menuGroupAudioSummary(.playable), playableTotal)
        XCTAssertEqual(model.menuAudioSummary, menuTotal)
        XCTAssertEqual(model.menuAudioSummary.seconds, 1200)
    }

    private func searchEpisode(_ id: String, notes: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            notes: notes, artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0,
            downloadState: .completed, preparationState: .notPrepared
        )
    }

    // MARK: Phase 1 — Menu admission, removal, ordering, drops

    /// 1.2: an admission that raises is named instead of swallowed.
    func testAFailedAutoAddNamesTheFailureInTheStatusLine() async throws {
        let directory = temporaryDirectory("auto-add-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = preparedAdmissionModel(in: directory, suffix: "failure")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id))

        model.installMenuAdmissionForTesting { _ in throw StartupTestError.expectedFailure }
        await model.performAutoAddPreparedEpisodesToMenu([episode.id])

        XCTAssertTrue(
            model.podcastOperationMessage?.contains("could not be added to Larder") == true,
            "a raised admission must reach the status line: \(model.podcastOperationMessage ?? "nil")"
        )
    }

    /// 1.2: the failed admission is held and retried on the next reload.
    func testAutoAddRetriesAFailedMenuAdmissionOnTheNextReload() async throws {
        let directory = temporaryDirectory("auto-add-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = preparedAdmissionModel(in: directory, suffix: "retry")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id))

        model.installMenuAdmissionForTesting { _ in throw StartupTestError.expectedFailure }
        await model.performAutoAddPreparedEpisodesToMenu([episode.id])
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id),
                       "a write that raised leaves no durable Menu entry")

        model.installMenuAdmissionForTesting(nil)
        await model.reloadLibraryRowsForTesting()

        XCTAssertTrue(model.podcastQueueIDs.contains(episode.id),
                      "the next reload retries the admission")
    }

    private func preparedAdmissionModel(in directory: URL, suffix: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                _ = try await installPreparedMenuEpisode(
                    into: store, directory: url.deletingLastPathComponent(), suffix: suffix
                )
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    /// 1.3: the badge and its label count the same rows the Menu renders.
    func testMenuBadgeAndSidebarTotalsCountTheRowsTheMenuRenders() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = destinationEpisode("count-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        let downloaded = destinationEpisode("count-downloaded", download: .completed,
                                            preparation: .notPrepared)
        let available = destinationEpisode("count-available", download: .notDownloaded,
                                           preparation: .notPrepared)
        for value in [ready, downloaded, available] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }

        XCTAssertEqual(model.menuUpcomingEpisodeIDs.count, model.menuWaitingEpisodes.count,
                       "the badge counts the rows the Menu renders")
        XCTAssertEqual(Set(model.menuUpcomingEpisodeIDs), Set(model.menuWaitingEpisodes.map(\.id)))
        XCTAssertEqual(model.menuAudioSummary,
                       WiltedMacQueueAudioSummary(episodes: model.menuWaitingEpisodes))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"))
        XCTAssertTrue(view.contains("model.menuUpcomingEpisodeIDs.count"))
        XCTAssertTrue(view.contains("Open Larder with \\(model.menuUpcomingEpisodeIDs.count) episodes"))
        XCTAssertTrue(view.contains("model.menuAudioSummary"))
    }

    /// 1.3: queue removal is not retirement. The durable entry leaves the
    /// queue; the episode's row, records, and listening state stay.
    func testRemovingADurableMenuEntryLeavesItsLibraryRowUntouched() async throws {
        let directory = temporaryDirectory("menu-remove-leaves-row")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                        "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        model.keepEpisode(episode)
        // The durable add has to land before the removal, or the two writes
        // race and the later add can put the entry back on the queue.
        await model.waitForPlaybackOperationForTesting()
        for _ in 0..<100 {
            if model.podcastQueueIDs.contains(episode.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.podcastQueueIDs.contains(episode.id))

        model.removeEpisodeFromUpNext(episode.id)
        for _ in 0..<100 {
            if !model.podcastQueueIDs.contains(episode.id), model.playbackOperationStatus == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id),
                       "the durable entry left the queue")
        let retained = try XCTUnwrap(model.episodes.first { $0.id == episode.id },
                                     "removal from the queue is not retirement; the row stays")
        XCTAssertNil(retained.retiredAt)
        XCTAssertFalse(retained.isPlayed)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == episode.id },
                      "an un-kept row is back in Feeds, not destroyed")
    }

    /// 1.3: a durable member is not addable, wherever it sits in the queue.
    func testCanAddEpisodeToMenuRefusesADurableMemberAtAnyIndex() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let earlier = ready("addable-earlier")
        let current = ready("addable-current")
        let later = ready("addable-later")
        for value in [earlier, current, later] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [earlier.id, current.id, later.id]
        )

        XCTAssertFalse(model.canAddEpisodeToMenu(earlier),
                       "an entry before the current index is already durable")
        XCTAssertFalse(model.canAddEpisodeToMenu(current),
                       "the current episode is never added a second time")
        XCTAssertFalse(model.canAddEpisodeToMenu(later),
                       "an entry after the current index is already durable")
    }

    /// 1.4: oldest-first orders every row except the playing one and anchors
    /// the playing one where it was.
    func testOldestMenuSortOrdersAscendingAndAnchorsTheCurrentEpisode() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String, published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: published),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let current = ready("oldest-current", published: 200)
        let oldest = ready("oldest-first", published: 100)
        let middle = ready("oldest-middle", published: 300)
        let newest = ready("oldest-last", published: 400)
        for value in [oldest, middle, newest] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [middle.id, oldest.id, current.id, newest.id]
        )

        model.menuSort = .oldest

        XCTAssertEqual(model.menuDisplayEpisodeIDs, [oldest.id, middle.id, current.id, newest.id],
                       "the non-playing rows sort by ascending publication date")
        XCTAssertEqual(model.menuDisplayEpisodeIDs.firstIndex(of: current.id), 2,
                       "the playing episode keeps its prior position")
    }

    /// 1.4: the selection is written and read back.
    func testOldestMenuSortSurvivesARebuild() throws {
        let suite = "com.zerodelta.wilted.mac.menu-sort-oldest-tests"
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        first.menuSort = .oldest

        let rebuilt = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(rebuilt.menuSort, .oldest)
    }

    /// 1.5: a drop past the last row appends. The index the helper answers
    /// with is the count of the queue the dragged row leaves behind.
    func testTailInsertionIndexAppendsPastTheLastRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("library.sqlite")
        var store = try LocalLibraryStore(url: storeURL)
        let first = try ItemID(rawValue: "item-" + String(repeating: "1", count: 64))
        let second = try ItemID(rawValue: "item-" + String(repeating: "2", count: 64))
        let third = try ItemID(rawValue: "item-" + String(repeating: "3", count: 64))
        try await store.addPodcastQueueEpisode(first)
        try await store.addPodcastQueueEpisode(second)
        try await store.addPodcastQueueEpisode(third)
        let queue = [first, second, third]

        let insertion = WiltedMacModel.menuInsertionIndex(source: 0, destination: queue.count)
        try await store.movePodcastQueueEpisode(from: 0, to: insertion)
        store = try LocalLibraryStore(url: storeURL)
        let reopened = try await store.podcastQueueState()

        XCTAssertEqual(reopened.episodeIDs, [second, third, first],
                       "a drop past the last row lands last")
        XCTAssertEqual(insertion, queue.filter { $0 != first }.count,
                       "the tail index equals the count of the queue it leaves behind")
    }

    /// 1.5: a payload that is not one of the Menu's episodes is refused and
    /// the order is left exactly as it was.
    func testAForeignDropPayloadIsRejectedAndLeavesTheOrderAlone() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let first = destinationEpisode("drop-first", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        let second = destinationEpisode("drop-second", download: .completed,
                                        preparation: .prepared(summary: "Ready"))
        for value in [first, second] {
            model.installEpisodeForTesting(value)
            model.keepEpisode(value)
        }
        let before = model.podcastQueueIDs

        XCTAssertFalse(model.moveMenuEpisode("file:///Users/dave/Downloads/invoice.pdf", before: second.id),
                       "a foreign payload is refused at a row")
        XCTAssertFalse(model.moveMenuEpisodeToEnd("file:///Users/dave/Downloads/invoice.pdf"),
                       "a foreign payload is refused at the tail")
        XCTAssertEqual(model.podcastQueueIDs, before, "the order is left exactly as it was")
    }

    // MARK: Removal kinds (Task 5.5)

    /// A prepared row must say what was removed, not just how much: two
    /// sponsor reads and a show plugging its own newsletter are different
    /// removals, and collapsing them into "3 ads removed" tells a listener
    /// the show ran three adverts when it ran two.
    func testPreparedSummaryReportsASeparateFigureForEachRemovalKind() throws {
        let run = try preparationRun(withRemovalKinds: [
            "paid advertising", "paid advertising", "house promotion", "credits"
        ])
        let summary = WiltedMacModel.preparedSummary(of: run, timing: .aligned)

        XCTAssertTrue(summary.contains("2 paid advertising"), summary)
        XCTAssertTrue(summary.contains("1 house promotion"), summary)
        XCTAssertTrue(summary.contains("1 credits"), summary)
        // The taxonomy's own order, so the removal a listener cares about
        // leads rather than being buried under credits.
        let paid = try XCTUnwrap(summary.range(of: "2 paid advertising"))
        let house = try XCTUnwrap(summary.range(of: "1 house promotion"))
        let credits = try XCTUnwrap(summary.range(of: "1 credits"))
        XCTAssertTrue(paid.lowerBound < house.lowerBound)
        XCTAssertTrue(house.lowerBound < credits.lowerBound)
        XCTAssertFalse(summary.contains("4 ads removed"),
                       "four removals of three kinds must not collapse to one figure")
    }

    /// Every journal written before kinds existed has no kind to report, and
    /// inventing one would claim a breakdown the run never recorded.
    func testPreparedSummaryKeepsItsPreviousWordingWhenNoRemovalCarriesAKind() throws {
        let run = try preparationRun(withRemovalKinds: [])
        XCTAssertNil(WiltedMacModel.removalKindSummary(of: run))
        XCTAssertEqual(WiltedMacModel.preparedSummary(of: run, timing: .aligned),
                       WiltedMacModel.recordedSummary(of: run)
                       ?? "Ready · \(PodcastPreparationResult.transcriptStep(.aligned))")
    }

    /// A run retried inside one request journals its spans twice. The summary
    /// counts the removals the episode has, not the attempts it took.
    func testPreparedSummaryCountsARetriedRunsSpansOnce() throws {
        let run = try preparationRun(withRemovalKinds: ["paid advertising", "house promotion"],
                                     attempts: 3)
        let summary = try XCTUnwrap(WiltedMacModel.removalKindSummary(of: run))
        XCTAssertEqual(summary, "1 paid advertising, 1 house promotion removed")
    }

    /// Builds a succeeded run whose entries journal one `advertisement`
    /// evidence per removal, the shape `adProgress` writes.
    private func preparationRun(
        withRemovalKinds kinds: [String], attempts: Int = 1
    ) throws -> PreparationRunSummary {
        let itemID = try ItemID(rawValue: "kind-summary-episode")
        let requestID = "podcast-prepare|kind-summary-episode"
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        var entries: [PreparationJournalEntry] = []
        var emitted = 0
        for attempt in 0..<max(1, attempts) {
            for (index, kind) in kinds.enumerated() {
                let ordinal = index + 1
                entries.append(PreparationJournalEntry(
                    id: "\(requestID)|ads.detect.span.\(ordinal)#\(attempt)",
                    itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(
                        stage: .assembling, detail: "span \(ordinal)", fraction: 0.5, cancellable: true,
                        emittedAt: Timestamp(origin.addingTimeInterval(Double(emitted))),
                        evidence: try PreparationEvidence(kind: "advertisement", fields: [
                            "ordinal": String(ordinal), "startSeconds": "10.000",
                            "endSeconds": "40.000", "label": "sponsor", "confidence": "0.9000",
                            "removalKind": kind
                        ])
                    )
                ))
                emitted += 1
            }
        }
        let terminal = try PreparationStatus(
            stage: .completed, detail: "Prepared.", fraction: 1, cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .succeeded, revisionID: RevisionID(rawValue: "rev-kind-summary")
            ),
            emittedAt: Timestamp(origin.addingTimeInterval(Double(emitted)))
        )
        entries.append(PreparationJournalEntry(
            id: "\(requestID)|pipeline.complete", itemID: itemID, requestID: requestID, status: terminal
        ))
        return PreparationRunSummary(
            requestID: requestID, itemID: itemID,
            startedAt: Timestamp(origin), updatedAt: terminal.emittedAt,
            stage: .completed, detail: "Prepared.", fraction: 1, isTerminal: true,
            outcome: .succeeded, failure: nil, entries: entries
        )
    }

    // MARK: Measurement (Task 3.2)

    /// Reports what the Prep poll and the queue lists cost on a library the
    /// size of a real one.
    ///
    /// Figures go into `docs/2026-09-17-queue-drawdown-measurements.md`. Two
    /// costs are measured separately because they are paid in different
    /// places: `refreshProcessorRuns` reads the store off the main actor,
    /// while the Feeds and Menu lists are rebuilt on the main actor, where
    /// the cost is a dropped frame. Set `WILTED_MEASURE=1` to print.
    func testMeasureThePrepPollAndTheEagerlyBuiltQueueLists() async throws {
        let directory = temporaryDirectory("measure-queue-lists")
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        let feedCount = 12
        let perFeed = 30
        let queuedCount = 180

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                var queued = 0
                for feedIndex in 0..<feedCount {
                    let feedURL = try XCTUnwrap(
                        URL(string: "https://podcasts.example.test/measure-\(feedIndex)/feed.xml")
                    )
                    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
                    try await store.save(feed: try PodcastFeed(
                        itemID: feedID, canonicalURL: feedURL,
                        title: "Measure Show \(feedIndex)", createdAt: created
                    ))
                    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                    for episodeIndex in 0..<perFeed {
                        let guid = "measure-\(feedIndex)-\(episodeIndex)"
                        let enclosureURL = try XCTUnwrap(
                            URL(string: "https://podcasts.example.test/measure-\(feedIndex)/\(episodeIndex).mp3")
                        )
                        let episodeID = try ItemID.derivePodcastEpisode(
                            feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL
                        )
                        // Titles and dates vary so every Menu sort has real
                        // work to do rather than comparing equal keys.
                        try await store.save(episode: try PodcastEpisode(
                            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
                            title: "Episode \((episodeIndex * 7 + feedIndex) % perFeed) of \(feedIndex)",
                            publishedTime: Timestamp(created.date.addingTimeInterval(
                                Double((episodeIndex * 13 + feedIndex) % 900) * 86_400
                            )),
                            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: created
                        ))
                        if queued < queuedCount {
                            try await store.addPodcastQueueEpisode(episodeID)
                            queued += 1
                        }
                    }
                }
                // 200 preparation runs of four statuses each, the journal the
                // Prep poll reads.
                for run in 0..<200 {
                    let itemID = try ItemID(rawValue: "measure-run-\(run)")
                    for (step, stage) in [PreparationStage.preparing, .fetching, .assembling, .completed].enumerated() {
                        let terminal = stage == .completed
                            ? try PreparationTerminalResult(
                                outcome: .succeeded, revisionID: RevisionID(rawValue: "rev-measure-\(run)")
                              )
                            : nil
                        try await store.record(preparation: PreparationJournalEntry(
                            id: "measure-\(run)-\(step)", itemID: itemID,
                            requestID: "podcast-prepare|measure-\(run)",
                            status: try PreparationStatus(
                                stage: stage, detail: "step-\(step)",
                                fraction: terminal == nil ? 0.5 : 1, cancellable: terminal == nil,
                                terminalResult: terminal,
                                emittedAt: Timestamp(created.date.addingTimeInterval(Double(run * 10 + step)))
                            )
                        ))
                    }
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.episodes.count, feedCount * perFeed)

        let shouldPrint = ProcessInfo.processInfo.environment["WILTED_MEASURE"] == "1"
        func measure(_ label: String, _ body: () -> Int) -> (seconds: Double, rows: Int) {
            _ = body()  // warm the caches; the first call pays for page-in
            let started = DispatchTime.now().uptimeNanoseconds
            var rows = 0
            for _ in 0..<5 { rows = body() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 5e9
            if shouldPrint {
                print("measure.\(label) seconds=\(String(format: "%.4f", elapsed)) rows=\(rows)")
            }
            return (elapsed, rows)
        }

        // Main-actor cost: the lists a queue screen rebuilds on every change.
        let feeds = measure("feedsEpisodes") { model.feedsEpisodes.count }
        XCTAssertEqual(feeds.rows, feedCount * perFeed - queuedCount)
        XCTAssertLessThan(feeds.seconds, 0.5, "the Feeds list got an order of magnitude slower")

        // One Menu view pass: every group's chip count, its rows, and the
        // continue button's check all call `menuEpisodes(in:)`, and each call
        // rebuilds the whole waiting set.
        let menu = measure("menuEpisodesOneViewPass") {
            var total = 0
            for group in WiltedMacMenuGroup.allCases {
                total += model.menuEpisodes(in: group).count   // the chip count
                total += model.menuEpisodes(in: group).count   // the rows
            }
            total += model.menuEpisodes(in: .playable).count   // the continue check
            return total
        }
        XCTAssertEqual(menu.rows, queuedCount * 2 + model.menuEpisodes(in: .playable).count)
        XCTAssertLessThan(menu.seconds, 0.5, "building the Menu's lists got an order of magnitude slower")

        // Off-main cost: the Prep poll's store reads.
        let pollStarted = DispatchTime.now().uptimeNanoseconds
        model.refreshProcessorRuns()
        var polledRuns = 0
        for _ in 0..<600 {
            if !model.processorRuns.isEmpty { polledRuns = model.processorRuns.count; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pollSeconds = Double(DispatchTime.now().uptimeNanoseconds - pollStarted) / 1e9
        XCTAssertEqual(polledRuns, 200, "the poll publishes the journal's capped run list")
        if shouldPrint {
            print("measure.refreshProcessorRuns seconds=\(String(format: "%.4f", pollSeconds)) rows=\(polledRuns)")
            print("measure.fixture feeds=\(feedCount) episodes=\(model.episodes.count) "
                  + "queued=\(queuedCount) preparationRuns=\(polledRuns) journalRows=\(200 * 4)")
        }
    }

    /// Replaces the UI test testMenuBulkActionsAreDisabledWithHonestEmptyState.
    func testAReadyLibraryWithNothingKeptOffersNoBulkLarderWork() throws {
        let directory = temporaryDirectory("ready-no-bulk-work")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        XCTAssertTrue(model.menuDownloadableEpisodes.isEmpty)
        XCTAssertTrue(model.menuPreparableEpisodes.isEmpty)
    }

    /// Replaces the playback half of testSidebarListsDestinationsOnlyAndNotTheArticleList.
    func testAnArticleStillBeingReadCannotOpenThePlayer() throws {
        let directory = temporaryDirectory("preparing-no-player")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-preparing"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        XCTAssertFalse(model.articles.isEmpty)
        XCTAssertFalse(model.articles.contains { $0.isReady })
    }
}

/// Seeds one downloaded, prepared episode -- unplayed and not queued -- so a
/// model that bootstraps this store sees it as a candidate for automatic Menu
/// admission.
private func installPreparedMenuEpisode(
    into store: LocalLibraryStore, directory: URL, suffix: String
) async throws -> ItemID {
    let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/menu-admission-\(suffix).xml"))
    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
    let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/menu-admission-\(suffix).mp3"))
    let episodeID = try ItemID.derivePodcastEpisode(
        feedURL: feedURL, rssGUID: "menu-admission-\(suffix)", enclosureURL: enclosure
    )
    try await store.save(feed: try PodcastFeed(
        itemID: feedID, canonicalURL: feedURL, title: "Menu admission feed", createdAt: created
    ))
    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
    try await store.save(episode: try PodcastEpisode(
        itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "menu-admission-\(suffix)",
        title: "Menu admission episode", publishedTime: created, enclosureURL: enclosure,
        enclosureMediaType: "audio/mpeg", createdAt: created
    ))
    let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
    let mediaURL = directory.appendingPathComponent("menu-admission-\(suffix).mp3")
    try Data("audio".utf8).write(to: mediaURL)
    try await store.finalizePodcastDownload(
        revision: try AudioRevision(
            itemID: episodeID, revisionID: revisionID, durationSeconds: 12, byteCount: 5,
            contentHash: "sha256:" + String(repeating: "a", count: 64),
            mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3
        ),
        mediaURL: mediaURL,
        download: try PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: 5, expectedByteCount: 5,
            localURL: mediaURL, contentHash: "sha256:" + String(repeating: "a", count: 64),
            updatedAt: created
        )
    )
    try await store.savePreparationOutcome(PodcastPreparationOutcome(
        episodeID: episodeID, revisionID: revisionID, policyDigest: "d",
        pipelineFingerprint: "f", semanticVersion: "v", producedAt: created
    ))
    return episodeID
}

private struct FixedBodyLoader: PodcastFeedLoading {
    let body: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

/// Serves a document per URL, but only once released.
///
/// Holding every request open is what lets a test place two classifications in
/// flight at a chosen moment instead of racing them.
private actor GatedRoutingLoader: PodcastFeedLoading {
    private let documents: [URL: Data]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(documents: [URL: Data]) { self.documents = documents }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard let body = documents[url] else { throw URLError(.fileDoesNotExist) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

private struct FailingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

/// Replays a fixed event sequence instead of opening a real network connection.
private struct StubPodcastDownloadTransport: PodcastDownloadTransporting {
    let events: [PodcastDownloadEvent]
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Reports a fixed duration instead of decoding real audio, so a stub
/// transport's placeholder bytes can pass validation.
private struct StubPodcastMediaValidator: PodcastMediaValidating {
    let duration: Double
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("stage=stub-validation")
        return duration
    }
}

private struct CancellingPodcastPipelineRunner: PodcastPipelineRunning {
    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        throw CancellationError()
    }
}

/// Suspends once the pipeline actually invokes it, and stays suspended until
/// `resume` is called. Used where a test needs to observe a run at the exact
/// moment it is admitted -- before it does any work -- without racing a
/// timer against however long the pipeline takes to fail on its own.
private actor BlockingPodcastPipelineRunner: PodcastPipelineRunning {
    private var continuation: CheckedContinuation<Data, Error>?

    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Always answers with a bad HTTP status, which the coordinator turns into
/// `.invalidResponse` -- retryable per the Phase 3 classification -- without
/// needing a real network failure to produce one.
private struct FailingPodcastDownloadTransport: PodcastDownloadTransporting {
    let enclosureURL: URL
    let statusCode: Int
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: enclosureURL, statusCode: statusCode,
                                               mediaType: "audio/mpeg", expectedByteCount: nil)))
            continuation.finish()
        }
    }
}

/// Counts every attempt across the whole download, not just the failing ones,
/// so a test can prove exactly how many times automation's bounded retry
/// actually called into the transport.
final class DownloadAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Counts calls made through the one method the seam exposes. Consulted only
/// from `loadLibrary`, which runs on the model's own main actor, so this
/// needs no locking of its own.
private final class CountingMediaAvailabilityChecker: WiltedMacMediaAvailabilityChecking {
    private(set) var fileExistsCallCount = 0
    func fileExists(atPath path: String) -> Bool {
        fileExistsCallCount += 1
        return FileManager.default.fileExists(atPath: path)
    }
}

private struct CountingFailingPodcastDownloadTransport: PodcastDownloadTransporting {
    let enclosureURL: URL
    let statusCode: Int
    let counter: DownloadAttemptCounter
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: enclosureURL, statusCode: statusCode,
                                               mediaType: "audio/mpeg", expectedByteCount: nil)))
            continuation.finish()
        }
    }
}

/// A fixed successful event sequence that counts how many times it was asked
/// for -- used to prove a terminal (non-retryable) failure downstream of a
/// clean transfer makes exactly one attempt rather than a bounded retry's
/// several.
private struct CountingPodcastDownloadTransport: PodcastDownloadTransporting {
    let counter: DownloadAttemptCounter
    let events: [PodcastDownloadEvent]
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ConcurrencyTracker {
    private var inFlight = 0
    private(set) var peak = 0
    func enter() { inFlight += 1; peak = max(peak, inFlight) }
    func leave() { inFlight -= 1 }
}

/// Delays every response briefly and tracks the peak number of transfers in
/// flight at once, so a test can prove bootstrap recovery serializes
/// downloads instead of firing one task per forced-redownload episode. The
/// delay gives an incorrectly-unbounded caller room to start a second
/// transfer before the first finishes.
private final class ConcurrencyTrackingPodcastDownloadTransport: PodcastDownloadTransporting, Sendable {
    private let tracker = ConcurrencyTracker()
    let eventsByURL: [URL: [PodcastDownloadEvent]]

    init(eventsByURL: [URL: [PodcastDownloadEvent]]) { self.eventsByURL = eventsByURL }

    var maxObservedInFlight: Int {
        get async { await tracker.peak }
    }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.tracker.enter()
                try? await Task.sleep(for: .milliseconds(50))
                for event in self.eventsByURL[url] ?? [] { continuation.yield(event) }
                continuation.finish()
                await self.tracker.leave()
            }
        }
    }
}


/// Holds a resolution open until the test releases it.
private actor FingerprintGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let resumed = waiters
        waiters = []
        for continuation in resumed { continuation.resume() }
    }
}

/// Records every fingerprint invalidation was asked to compare against.
private actor FingerprintRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
