import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
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

}
