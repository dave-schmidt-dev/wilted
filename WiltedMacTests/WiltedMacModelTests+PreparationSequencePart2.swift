import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
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

    /// A Retry is a fresh admission, not a forbidden terminal-to-running
    /// transition. The model must send the current Remove ads choice through
    /// that admission so the run's later ticket read sees the retry policy.
    func testRetryPreparationReplacesAFailedTicketsRemoveAdsPolicy() async throws {
        let directory = temporaryDirectory("ticket-retry-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(1, forKey: WiltedMacModel.preparationRequestSequencePreferenceKey)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let oldPolicy = try JSONEncoder().encode(PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: false
        ))
        _ = try await store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: "retry-policy-episode", requestSequence: 1,
            policySnapshot: oldPolicy, to: .running, at: Timestamp(Date())
        )
        _ = try await store.applyWorkTicketTransition(
            kind: .podcastPreparation, subjectID: "retry-policy-episode", requestSequence: 1,
            to: .failed, failureKind: PodcastDownloadFailureKind.retryable.rawValue,
            lastFailureMessage: "old failure", at: Timestamp(Date())
        )

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let retryPolicy = try JSONEncoder().encode(PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let sequence = model.consumePreparationRequest(
            for: "retry-policy-episode", policySnapshot: retryPolicy
        )
        XCTAssertGreaterThan(sequence, 1)

        var attempts = 0
        var ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: "retry-policy-episode")
        while attempts < 50, ticket?.requestSequence != sequence {
            try await Task.sleep(nanoseconds: 20_000_000)
            ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: "retry-policy-episode")
            attempts += 1
        }
        let retried = try XCTUnwrap(ticket)
        let storedPolicy = try XCTUnwrap(retried.policySnapshot)
        let decodedPolicy = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: storedPolicy)
        XCTAssertEqual(retried.state, .running)
        XCTAssertEqual(retried.attemptCount, 2)
        XCTAssertTrue(decodedPolicy.removeAds, "the retry reads its new admission policy, not the failed attempt's")
        XCTAssertNil(retried.failureKind)
        XCTAssertNil(retried.lastFailureMessage)
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

        XCTAssertEqual(model.menuUpcomingEpisodeIDs, [queued.id])
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

}
