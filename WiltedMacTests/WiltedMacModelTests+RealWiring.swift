import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
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

}
