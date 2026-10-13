import AppKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The normal-quit path: `applicationShouldTerminate` → `terminateLater`,
/// a bounded local drain, then exactly one reply.
@MainActor
final class WiltedMacTerminationTests: XCTestCase {
    // MARK: Coordinator, with a scripted owner

    func testDelayedSaveRepliesOnceAfterDrainAndRepeatQuitJoinsIt() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsLocal = true
        var isVisible = true
        var dismissals = 0
        let (coordinator, replies) = makeCoordinator(owner, dismiss: {
            isVisible = false
            dismissals += 1
        })

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertFalse(isVisible, "the app is dismissed synchronously before the drain is awaited")
        XCTAssertEqual(dismissals, 1)
        await owner.waitUntilLocalStarted()
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater, "a repeat quit joins the running drain")
        XCTAssertEqual(dismissals, 1, "a repeated quit does not dismiss or start another drain")
        XCTAssertEqual(owner.localRuns, 1)
        XCTAssertTrue(replies.values.isEmpty, "no reply while the save is still running")

        owner.releaseLocal()
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(owner.events, ["local", "network"], "local work drains before the network step")
        XCTAssertEqual(coordinator.state, .approved)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateNow)
        XCTAssertEqual(replies.values, [true], "still exactly one reply")
        XCTAssertFalse(isVisible, "a successful quit stays dismissed")
    }

    func testFailedSaveCancelsQuitVisiblyAndRetryExitsAfterSaving() async throws {
        let owner = ScriptedTerminationOwner()
        owner.localFailures = 1
        var isVisible = true
        var dismissals = 0
        var restorations = 0
        var presented: [WiltedMacTerminationFailure] = []
        let (coordinator, replies) = makeCoordinator(
            owner,
            dismiss: { isVisible = false; dismissals += 1 },
            restore: { isVisible = true; restorations += 1 }
        ) { presented.append($0) }

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertFalse(isVisible, "the app is dismissed while saving")
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [false], "a failed save keeps the app open")
        XCTAssertTrue(isVisible, "a failed save restores the app before the retry prompt")
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(restorations, 1)
        guard case .failed(.saveFailed) = coordinator.state else {
            return XCTFail("expected a visible save failure, got \(coordinator.state)")
        }
        XCTAssertEqual(presented.count, 1, "the retry state is shown")
        XCTAssertEqual(owner.resumes, 1, "admission and stopped work come back")
        XCTAssertFalse(owner.events.contains("network"), "nothing is closed for a quit that did not happen")

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater, "retry quits again")
        XCTAssertFalse(isVisible, "retry dismisses the app while saving again")
        try await waitFor { replies.values.count == 2 }
        XCTAssertEqual(replies.values, [false, true])
        XCTAssertEqual(owner.savedRuns, 1, "the retry exits only after saving")
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(restorations, 1)
    }

    func testTimedOutSaveCancelsQuitAndItsLateCompletionCannotReply() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsLocal = true
        var isVisible = true
        let (coordinator, replies) = makeCoordinator(
            owner, budget: .milliseconds(80),
            dismiss: { isVisible = false }, restore: { isVisible = true }
        )

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        XCTAssertFalse(isVisible)
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [false])
        XCTAssertTrue(isVisible, "a timed-out drain restores the app")
        XCTAssertEqual(coordinator.state, .failed(.timedOut))
        try await waitFor { owner.localWasCancelled }

        owner.releaseLocal()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies.values, [false], "a late completion cannot answer a cancelled quit")
        XCTAssertEqual(coordinator.state, .failed(.timedOut))
    }

    func testSlowNetworkJoinNeverCancelsAQuitWhoseLocalWorkSaved() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsNetwork = true
        let (coordinator, replies) = makeCoordinator(owner, budget: .milliseconds(120))

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [true], "cloud work is never waited on for success")
        XCTAssertEqual(owner.resumes, 0)
        owner.releaseNetwork()
    }

    // MARK: The model's local drain

    func testQuitDrainPausesNowWritesPlayheadAndTotalsAndStopsAdmission() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        let playback = try XCTUnwrap(model.playback)
        XCTAssertTrue(playback.liveIsPlaying)
        try await playback.seek(to: 42)
        // A start issued just before Quit is fenced by the drain's Stop.
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        gate.arm()
        model.togglePlayback()
        await gate.waitUntilHeld()

        try await model.drainLocalWorkForTermination()
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertFalse(backend.isPlaying, "the pending start never ran")
        XCTAssertFalse(model.isPlaying)
        let store = try XCTUnwrap(model.store)
        let itemID = try XCTUnwrap(playback.itemID)
        let revisionID = try XCTUnwrap(playback.revisionID)
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        XCTAssertEqual(try XCTUnwrap(saved?.positionSeconds), playback.livePositionSeconds, accuracy: 0.001)

        let generation = model.playbackCommands.generation
        model.startPlayback()
        model.playEpisode(episode)
        XCTAssertEqual(model.playbackCommands.generation, generation, "no start is admitted while quitting")
        XCTAssertTrue(model.isClosingTemporaryState)

        model.resumeAfterCancelledTermination()
        XCTAssertFalse(model.isClosingTemporaryState, "a cancelled quit admits work again")
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(backend.isPlaying)
    }

    /// Step 4: an in-flight download is cancelled and joined before the
    /// drain returns, and its received bytes reach the store on that exit.
    func testQuitDrainCancelsAndJoinsInFlightDownloadAndKeepsItsBytes() async throws {
        let transport = HeldPodcastDownloadTransport(chunk: 4_096)
        let (model, episode) = try await makeDownloadModel(transport: transport)
        model.downloadEpisode(episode, alreadyClaimed: true)
        try await waitFor {
            if case let .downloading(received, _) = model.episodes.first(where: { $0.id == episode.id })?.downloadState {
                return received > 0
            }
            return false
        }

        try await model.drainLocalWorkForTermination()

        XCTAssertTrue(model.podcastDownloadTasks.isEmpty, "the drain joined the download before returning")
        let store = try XCTUnwrap(model.store)
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 4_096, "the interrupted transfer's bytes were kept")
        let download = try await store.download(for: ItemID(rawValue: episode.id))
        let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(download?.status, .failed)
        XCTAssertEqual(download?.failureKind, .retryable)
        XCTAssertEqual(ticket?.state, .pending)
        XCTAssertEqual(ticket?.failureKind, WorkTicketFailure.interrupted.rawValue)
    }

    func testFailedDownloadDrainJoinsRemainingCancelledTasksBeforeThrowing() async throws {
        let (model, _) = try await makeDownloadModel(transport: HeldPodcastDownloadTransport(chunk: 0))
        let owner = ScriptedTerminationOwner()
        owner.holdsLocal = true
        let failed = Task<PodcastDownloadResult, Error> { throw CocoaError(.fileWriteUnknown) }
        var heldFinished = false
        let held = Task<PodcastDownloadResult, Error> {
            defer { heldFinished = true }
            try await owner.drainLocalWorkForTermination()
            throw PodcastDownloadCoordinatorError.cancelled
        }
        await owner.waitUntilLocalStarted()
        // Choose the actual dictionary iteration order, so the failing join
        // precedes the held join and cannot accidentally hide this regression.
        model.podcastDownloadTasks = ["first": failed, "second": held]
        let keys = Array(model.podcastDownloadTasks.keys)
        model.podcastDownloadTasks[keys[0]] = failed
        model.podcastDownloadTasks[keys[1]] = held
        var returned = false
        var failure: Error?
        let drain = Task {
            do { try await model.cancelAndAwaitDownloadsForTermination() }
            catch { failure = error }
            returned = true
        }
        try await waitFor { owner.localWasCancelled }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(returned, "durability failure must still join every cancelled writer")
        XCTAssertFalse(heldFinished)
        owner.releaseLocal()
        await drain.value
        XCTAssertTrue(heldFinished)
        XCTAssertNotNil(failure, "the local write failure must cancel quit")
        model.podcastDownloadTasks = [:]
        await model.close()
    }

    func testQuitInterruptedDownloadRelaunchRestartsFromZeroAndCompletes() async throws {
        let transport = RelaunchPodcastDownloadTransport()
        let directory = wiltedTemporaryDirectory("termination-relaunch-download")
        let (model, episode) = try await makeDownloadModel(transport: transport, directory: directory)
        let store = try XCTUnwrap(model.store)
        let id = try ItemID(rawValue: episode.id)
        try await store.addPodcastQueueEpisode(id)
        model.downloadEpisode(episode, alreadyClaimed: true)
        try await waitFor { model.episodes.contains { row in
            if row.id == episode.id, case .downloading(4_096, _) = row.downloadState { return true }; return false
        } }
        try await model.drainLocalWorkForTermination()
        let interrupted = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(interrupted?.state, .pending)
        XCTAssertEqual(interrupted?.failureKind, WorkTicketFailure.interrupted.rawValue)
        let staging = model.mediaDirectory.appendingPathComponent(".podcast-staging")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        await model.close()

        let (relaunched, _) = try await makeDownloadModel(transport: transport, directory: directory, seed: false)
        try await waitFor { transport.requestCount == 2 }
        let reopened = try XCTUnwrap(relaunched.store)
        let restarting = try await reopened.download(for: id)
        XCTAssertEqual(restarting?.status, .downloading)
        XCTAssertEqual(restarting?.bytesReceived, 0, "replay starts from zero after staging cleanup")
        transport.completeCurrentRequest()
        await relaunched.waitForAutomation()
        await relaunched.waitForPodcastOperations()
        let completedRecord = try await reopened.download(for: id)
        let completed = try XCTUnwrap(completedRecord)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.bytesReceived, 8_192)
        if let url = completed.localURL {
            XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0x6B, count: 8_192))
        } else { XCTFail("the replay did not commit its audio file") }
        let ticket = try await reopened.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(ticket?.state, .succeeded)
        let summary = try await reopened.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 12_288, "counts actual bytes from both attempts")
        await relaunched.close()
    }

    func testQuitInterruptedDownloadNeverStartsFourthTransferOnRelaunch() async throws {
        let transport = RelaunchPodcastDownloadTransport()
        let directory = wiltedTemporaryDirectory("termination-three-download-attempts")
        for attempt in 1...3 {
            let (model, episode) = try await makeDownloadModel(
                transport: transport, directory: directory, seed: attempt == 1
            )
            let store = try XCTUnwrap(model.store)
            let id = try ItemID(rawValue: episode.id)
            if attempt == 1 {
                try await store.addPodcastQueueEpisode(id)
                model.downloadEpisode(episode, alreadyClaimed: true)
            }
            // The first request's 4 KB must be counted before the quit, or a
            // loaded host drains first and the lifetime total reads zero.
            try await waitFor { transport.requestCount == attempt && model.episodes.contains { row in
                guard row.id == episode.id, case let .downloading(received, _) = row.downloadState else { return false }
                return attempt > 1 || received == 4_096
            } }
            try await model.drainLocalWorkForTermination()
            let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
            XCTAssertEqual(ticket?.attemptCount, attempt)
            XCTAssertEqual(ticket?.state, attempt < 3 ? .pending : .failed)
            XCTAssertEqual(ticket?.failureKind, WorkTicketFailure.interrupted.rawValue)
            let staging = model.mediaDirectory.appendingPathComponent(".podcast-staging")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
            await model.close()
        }
        let (final, episode) = try await makeDownloadModel(transport: transport, directory: directory, seed: false)
        await final.waitForAutomation()
        XCTAssertEqual(transport.requestCount, 3)
        let store = try XCTUnwrap(final.store)
        let download = try await store.download(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(download?.failureKind, .terminal)
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 4_096)
        await final.close()
    }

    func testUserCancelledDownloadDoesNotRestartOnRelaunch() async throws {
        let transport = RelaunchPodcastDownloadTransport()
        let directory = wiltedTemporaryDirectory("termination-user-cancel-download")
        let (model, episode) = try await makeDownloadModel(transport: transport, directory: directory)
        let store = try XCTUnwrap(model.store)
        let id = try ItemID(rawValue: episode.id)
        try await store.addPodcastQueueEpisode(id)
        model.downloadEpisode(episode, alreadyClaimed: true)
        try await waitFor { model.episodes.contains { row in
            if row.id == episode.id, case .downloading(4_096, _) = row.downloadState { return true }; return false
        } }
        model.cancelEpisodeDownload(episode)
        // A following quit must preserve the explicit cancellation reason.
        try await model.drainLocalWorkForTermination()
        let download = try await store.download(for: id)
        let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(download?.status, .cancelled)
        XCTAssertEqual(ticket?.state, .cancelled)
        await model.close()
        let (relaunched, _) = try await makeDownloadModel(transport: transport, directory: directory, seed: false)
        await relaunched.waitForAutomation()
        XCTAssertEqual(transport.requestCount, 1)
        let summary = try await XCTUnwrap(relaunched.store).lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 4_096)
        await relaunched.close()
    }

    func testManualRedownloadAfterSettledInterruptedRequestAdmitsNewRequest() async throws {
        for state in [WorkTicketState.succeeded, .cancelled] {
            let transport = RelaunchPodcastDownloadTransport()
            let (model, episode) = try await makeDownloadModel(transport: transport)
            let store = try XCTUnwrap(model.store)
            let id = try ItemID(rawValue: episode.id)
            let now = Timestamp(Date())
            var previous = try await store.issueWorkTicket(
                kind: .podcastDownload, subjectID: episode.id, requestedAt: now
            )
            previous.state = state
            previous.attemptCount = 3
            previous.failureKind = WorkTicketFailure.interrupted.rawValue
            try await store.upsertWorkTicket(previous)
            let oldFile = model.mediaDirectory.appendingPathComponent("manual-previous.mp3")
            try FileManager.default.createDirectory(at: model.mediaDirectory, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 4_096).write(to: oldFile)
            try await store.save(download: try PodcastDownload(
                episodeID: id, status: state == .succeeded ? .completed : .cancelled,
                bytesReceived: 4_096, localURL: state == .succeeded ? oldFile : nil,
                contentHash: state == .succeeded ? "sha256:" + String(repeating: "a", count: 64) : nil,
                updatedAt: now
            ))
            model.redownloadEpisode(episode)
            try await waitFor { transport.requestCount == 1 && model.episodes.contains { row in
                if row.id == episode.id, case .downloading = row.downloadState { return true }; return false
            } }
            let current = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
            XCTAssertGreaterThan(try XCTUnwrap(current).requestSequence, previous.requestSequence)
            XCTAssertEqual(current?.state, .running)
            XCTAssertNil(current?.failureKind, "a deliberate new request clears old interruption provenance")
            XCTAssertEqual(current?.attemptCount, 1, "this is the new request's first actual transfer")
            try await model.drainLocalWorkForTermination()
            let interrupted = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
            XCTAssertEqual(interrupted?.requestSequence, current?.requestSequence)
            XCTAssertEqual(interrupted?.state, .pending)
            XCTAssertEqual(interrupted?.attemptCount, 1, "old request attempts cannot exhaust this request")
            await model.close()
        }
    }

    func testLostManualDownloadClaimDoesNotSpendInterruptedAttempt() async throws {
        let transport = RelaunchPodcastDownloadTransport()
        let (model, episode) = try await makeDownloadModel(transport: transport)
        let store = try XCTUnwrap(model.store)
        let id = try ItemID(rawValue: episode.id)
        let now = Timestamp(Date())
        var previous = try await store.issueWorkTicket(
            kind: .podcastDownload, subjectID: episode.id, requestedAt: now
        )
        previous.attemptCount = 1
        previous.failureKind = WorkTicketFailure.interrupted.rawValue
        try await store.upsertWorkTicket(previous)
        try await store.save(download: try PodcastDownload(
            episodeID: id, status: .downloading, bytesReceived: 128, updatedAt: now
        ))
        model.downloadEpisode(episode)
        await model.waitForPodcastOperations()
        XCTAssertEqual(transport.requestCount, 0)
        let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(ticket?.requestSequence, previous.requestSequence)
        XCTAssertEqual(ticket?.attemptCount, 1)
        XCTAssertEqual(ticket?.state, .pending)
        XCTAssertEqual(ticket?.failureKind, WorkTicketFailure.interrupted.rawValue)
        let download = try await store.download(for: id)
        XCTAssertEqual(download?.status, .downloading)
        XCTAssertEqual(download?.bytesReceived, 128)
        await model.close()
    }

    func testAutomaticForcedRecoveryCannotResetExhaustedInterruptedRequest() async throws {
        let transport = RelaunchPodcastDownloadTransport()
        let (model, episode) = try await makeDownloadModel(transport: transport)
        let store = try XCTUnwrap(model.store)
        let id = try ItemID(rawValue: episode.id)
        let now = Timestamp(Date())
        var previous = try await store.issueWorkTicket(
            kind: .podcastDownload, subjectID: episode.id, requestedAt: now
        )
        previous.state = .failed
        previous.attemptCount = 3
        previous.failureKind = WorkTicketFailure.interrupted.rawValue
        try await store.upsertWorkTicket(previous)
        let exhausted = try PodcastDownload(
            episodeID: id, status: .failed, bytesReceived: 128, updatedAt: now, failureKind: .terminal
        )
        try await store.save(download: exhausted)
        model.downloadEpisode(episode, ignoringExisting: true, automaticRecovery: true)
        await model.waitForPodcastOperations()
        XCTAssertEqual(transport.requestCount, 0)
        let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.id)
        XCTAssertEqual(ticket?.requestSequence, previous.requestSequence)
        XCTAssertEqual(ticket?.attemptCount, 3)
        XCTAssertEqual(ticket?.state, .failed)
        let download = try await store.download(for: id)
        XCTAssertEqual(download, exhausted, "rejected recovery must not take a queued-row claim")
        await model.close()
    }

    // MARK: An isolated fixture process, quit for real

    /// A directed quit event to a fixture process this test launched enters
    /// `applicationShouldTerminate`, replies once after the drain and exits,
    /// and the reopened store holds exactly the drained playhead and totals.
    func testFixtureQuitEntersDelegateRepliesOnceExitsAndReopensDrainedState() async throws {
        let fixture = try TerminationFixtureProcess.launch(in: wiltedTemporaryDirectory("termination-quit"))
        addTeardownBlock { fixture.forceStopIfRunning() }
        try await fixture.waitForEvent("ready")

        // Two back-to-back quit events still produce exactly one reply.
        try fixture.sendQuit()
        try fixture.sendQuit()
        try await fixture.waitForExit()

        let events = try fixture.events()
        XCTAssertGreaterThanOrEqual(events.filter { $0["event"] == "should-terminate" }.count, 1,
                                    "the quit entered the delegate")
        XCTAssertEqual(events.filter { $0["event"] == "reply" }.map { $0["detail"] }, ["terminate"])
        let playhead = try XCTUnwrap(events.last { $0["event"] == "playhead" })
        try await fixture.assertReopenedStoreMatches(playhead)
    }

    /// A failed drain keeps the fixture alive with its retry state, and the
    /// retried quit exits after saving.
    func testFixtureFailedDrainStaysOpenAndRetriedQuitExitsAfterSaving() async throws {
        let fixture = try TerminationFixtureProcess.launch(
            in: wiltedTemporaryDirectory("termination-retry"), failingFirstDrain: true
        )
        addTeardownBlock { fixture.forceStopIfRunning() }
        try await fixture.waitForEvent("ready")

        try fixture.sendQuit()
        try await fixture.waitForEvent("failed")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(fixture.isRunning, "a cancelled quit leaves the app open")

        try fixture.sendQuit()
        try await fixture.waitForExit()
        let events = try fixture.events()
        XCTAssertEqual(events.filter { $0["event"] == "reply" }.map { $0["detail"] }, ["cancel", "terminate"])
        let playhead = try XCTUnwrap(events.last { $0["event"] == "playhead" })
        try await fixture.assertReopenedStoreMatches(playhead)
    }

    // MARK: Helpers

    private func makeDownloadModel(
        transport: any PodcastDownloadTransporting,
        directory: URL? = nil,
        seed: Bool = true
    ) async throws -> (WiltedMacModel, WiltedMacEpisode) {
        let directory = directory ?? wiltedTemporaryDirectory("termination-download")
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/termination.xml"))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/termination.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "quit", enclosureURL: enclosure)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                guard seed else { return store }
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Quit feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "quit",
                    title: "Quit episode", publishedTime: created, enclosureURL: enclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            pipelineFingerprint: "termination-download-test",
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.automationSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: false
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue })
        return (model, episode)
    }

    private func makeCoordinator(
        _ owner: ScriptedTerminationOwner,
        budget: Duration = .seconds(5),
        dismiss: @escaping @MainActor () -> Void = {},
        restore: @escaping @MainActor () -> Void = {},
        present: @escaping @MainActor (WiltedMacTerminationFailure) -> Void = { _ in }
    ) -> (WiltedMacTerminationCoordinator, TerminationReplies) {
        let replies = TerminationReplies()
        let coordinator = WiltedMacTerminationCoordinator(
            owner: owner, budget: budget,
            reply: { replies.values.append($0) },
            dismissForPendingTermination: dismiss,
            restoreAfterCancelledTermination: restore,
            presentFailure: present
        )
        return (coordinator, replies)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class TerminationReplies {
    var values: [Bool] = []
}

/// A termination owner whose local save and network join finish, fail or
/// hang when the test says so.
@MainActor
final class ScriptedTerminationOwner: WiltedMacTerminationDraining {
    var holdsLocal = false
    var holdsNetwork = false
    var localFailures = 0
    private(set) var localRuns = 0
    private(set) var savedRuns = 0
    private(set) var resumes = 0
    private(set) var events: [String] = []
    private(set) var localWasCancelled = false
    private var localRelease: CheckedContinuation<Void, Never>?
    private var networkRelease: CheckedContinuation<Void, Never>?
    private var localStarted: CheckedContinuation<Void, Never>?

    func drainLocalWorkForTermination() async throws {
        localRuns += 1
        localStarted?.resume()
        localStarted = nil
        if localFailures > 0 {
            localFailures -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        if holdsLocal {
            await withTaskCancellationHandler {
                await withCheckedContinuation { localRelease = $0 }
            } onCancel: {
                Task { @MainActor in self.localWasCancelled = true }
            }
            if Task.isCancelled { throw CancellationError() }
        }
        savedRuns += 1
        events.append("local")
    }

    func closeNetworkWorkForTermination() async {
        if holdsNetwork { await withCheckedContinuation { networkRelease = $0 } }
        events.append("network")
    }

    func resumeAfterCancelledTermination() { resumes += 1 }

    func waitUntilLocalStarted() async {
        guard localRuns == 0 else { return }
        await withCheckedContinuation { localStarted = $0 }
    }

    func releaseLocal() {
        localRelease?.resume()
        localRelease = nil
    }

    func releaseNetwork() {
        networkRelease?.resume()
        networkRelease = nil
    }
}

/// Delivers a response and one chunk, then holds the transfer open until the
/// consuming task is cancelled.
final class HeldPodcastDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    let chunk: Int
    init(chunk: Int) { self.chunk = chunk }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: url, statusCode: 200, mediaType: "audio/mpeg",
                                               expectedByteCount: Int64(chunk * 4))))
            continuation.yield(.data(Data(repeating: 0x5A, count: chunk)))
        }
    }
}

/// One partial transfer, then a separately gated complete transfer on relaunch.
final class RelaunchPodcastDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var pending: AsyncThrowingStream<PodcastDownloadEvent, Error>.Continuation?

    var requestCount: Int { lock.withLock { requests } }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let index = lock.withLock { requests += 1; return requests }
            continuation.yield(.response(.init(url: url, statusCode: 200, mediaType: "audio/mpeg",
                                               expectedByteCount: 8_192)))
            if index == 1 {
                continuation.yield(.data(Data(repeating: 0x5A, count: 4_096)))
            } else {
                lock.withLock { pending = continuation }
            }
        }
    }

    func completeCurrentRequest() {
        let continuation = lock.withLock { let value = pending; pending = nil; return value }
        continuation?.yield(.data(Data(repeating: 0x6B, count: 8_192)))
        continuation?.finish()
    }
}

/// One fixture copy of this app, launched as a child process with an
/// isolated state directory and a clean environment. Every quit or kill is
/// addressed to the child's own PID after checking it is this test's child
/// running this build's bundle, never the installed owner app.
@MainActor
final class TerminationFixtureProcess {
    let process: Process
    let stateDirectory: URL
    let journalURL: URL
    private let bundleURL: URL

    private init(process: Process, stateDirectory: URL, journalURL: URL, bundleURL: URL) {
        self.process = process
        self.stateDirectory = stateDirectory
        self.journalURL = journalURL
        self.bundleURL = bundleURL
    }

    static func launch(in root: URL, failingFirstDrain: Bool = false) throws -> TerminationFixtureProcess {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        XCTAssertFalse(bundleURL.path.hasPrefix("/Applications/"), "never launch the installed app")
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("termination.jsonl")
        let process = Process()
        process.executableURL = executable
        var arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-ui-fixture-playing",
            "--wilted-ui-fixture-state-directory", state.path,
            WiltedMacTerminationJournal.argument, journal.path,
        ]
        if failingFirstDrain { arguments.append(WiltedMacTerminationJournal.failFirstDrainArgument) }
        process.arguments = arguments
        // A clean environment: an inherited XCTest configuration or injected
        // library would make the child think it hosts tests.
        process.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return TerminationFixtureProcess(process: process, stateDirectory: state, journalURL: journal, bundleURL: bundleURL)
    }

    var isRunning: Bool { process.isRunning }

    /// Sends the AppKit quit event to the verified child only.
    func sendQuit() throws {
        let app = try verifiedChild()
        XCTAssertTrue(app.terminate(), "the quit event was delivered")
    }

    func forceStopIfRunning() {
        guard process.isRunning, (try? verifiedChild()) != nil else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func verifiedChild() throws -> NSRunningApplication {
        let pid = process.processIdentifier
        guard process.isRunning, pid > 0, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.standardizedFileURL == bundleURL,
              app.bundleURL?.path.hasPrefix("/Applications/") == false else {
            throw XCTSkip("the fixture child could not be verified; refusing to signal it")
        }
        return app
    }

    func events() throws -> [[String: String]] {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    func waitForEvent(_ name: String, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try events().contains(where: { $0["event"] == name }) { return }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("fixture never recorded \(name); events: \(try events())")
        throw CancellationError()
    }

    func waitForExit(timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning, "the fixture exited after its reply")
    }

    /// Reopens the fixture's store after exit and compares what it committed
    /// with what the drain journaled.
    func assertReopenedStoreMatches(_ playhead: [String: String]) async throws {
        let store = try LocalLibraryStore(url: stateDirectory.appendingPathComponent("library.sqlite"))
        let itemID = try ItemID(rawValue: try XCTUnwrap(playhead["item"]))
        let revisionID = try RevisionID(rawValue: try XCTUnwrap(playhead["revision"]))
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        let position = try XCTUnwrap(Double(try XCTUnwrap(playhead["position"])))
        XCTAssertEqual(position, 37, accuracy: 0.001, "the fixture's seek is the drained playhead")

        XCTAssertEqual(try XCTUnwrap(saved?.positionSeconds), position, accuracy: 0.001)
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.state.rawValue, playhead["summaryState"])
        XCTAssertEqual(String(summary.measured.playedMilliseconds), playhead["playedMilliseconds"],
                       "the reopened totals are the drained totals")
        // The fixture plays for 1.5 s after its seek before reporting ready;
        // only the quit drain's pause checkpoint can have committed that time.
        XCTAssertGreaterThanOrEqual(summary.measured.playedMilliseconds, 1_400)
    }
}
