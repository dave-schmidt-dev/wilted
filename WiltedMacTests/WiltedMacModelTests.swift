import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacModelTests: XCTestCase {
    func testBootstrapPublishesOnlyDeviceLocalLedgerTotals() async throws {
        let directory = temporaryDirectory("lifetime-statistics")

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
        await model.waitForLifetimeStatisticsForTesting()

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

}
