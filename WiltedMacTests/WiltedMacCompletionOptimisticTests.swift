import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// The Larder's Mark completed answers the tap before the store does: the row
/// leaves the Larder at once, the message says it is still saving, duplicate
/// taps make one write, Undo waits for the durable completion, and a failure
/// puts back only what this operation projected.
@MainActor
final class WiltedMacCompletionOptimisticTests: XCTestCase {
    private actor WriteGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var writes = 0

        func arrive() async {
            writes += 1
            guard writes == 1, !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private struct Fixture {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let episodeID: String
        let mediaURL: URL
    }

    /// One feed with a downloaded, prepared episode whose row reads as started,
    /// with its media really on disk.
    private func fixture(_ suffix: String) async throws -> Fixture {
        let directory = wiltedTemporaryDirectory("completion-\(suffix)")
        let feedURL = URL(string: "https://feeds.example.test/completion-\(suffix).xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = URL(string: "https://media.example.test/completion-\(suffix).mp3")!
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "completion-\(suffix)", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { root in
                let store = try LocalLibraryStore(url: root)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Completion Show", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await WiltedMacModelTests.addReadyEpisode(
                    episodeID, guid: "completion-\(suffix)", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: Date(timeIntervalSince1970: 1_600_000_000),
                    directory: directory, store: store, created: created
                )
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.reloadLibraryRowsForTesting()
        let store = try XCTUnwrap(model.store)
        let index = try XCTUnwrap(model.episodes.firstIndex { $0.id == episodeID.rawValue })
        model.episodes[index].playbackSeconds = 120
        return Fixture(
            model: model, store: store, episodeID: episodeID.rawValue,
            mediaURL: directory.appendingPathComponent("completion-\(suffix).m4a")
        )
    }

    func testCompletionLeavesTheLarderBeforeTheWriteAndOffersUndoOnlyAfterItCommits() async throws {
        let fixture = try await fixture("projected")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let gate = WriteGate()
        fixture.model.subscriptionWriteHookForTesting = { await gate.arrive() }

        fixture.model.skipEpisode(episode)

        XCTAssertNil(fixture.model.undoableSkip, "Undo is not offered before the completion is durable")
        XCTAssertEqual(fixture.model.podcastOperationMessage, "Saving \(episode.title) as completed…",
                       "a queued write must not claim success")
        XCTAssertFalse(fixture.model.larderVisibleEpisodes.contains { $0.id == fixture.episodeID },
                       "the row leaves the Larder with the tap")
        XCTAssertFalse(fixture.model.feedsEpisodes.contains { $0.id == fixture.episodeID },
                       "Feeds cannot call the completed row new")
        let projected = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        XCTAssertTrue(projected.isPlayed)
        XCTAssertNotNil(projected.retiredAt)

        await gate.open()
        await WiltedMacHeadless.drainDecisions(fixture.model)
        XCTAssertEqual(fixture.model.undoableSkip?.id, fixture.episodeID)
        XCTAssertEqual(fixture.model.podcastOperationMessage,
                       "Marked \(episode.title) completed. Undo completion is available for 10 seconds.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path),
                      "completion keeps the media Undo needs")
    }

    func testVirtualUndoWindowSealsAtTenSecondsAndNeverCancelsStartedTransfers() async throws {
        let fixture = try await fixture("virtual-window")
        let model = fixture.model
        let clock = CompletionClock()
        model.manualCompletionNow = { clock.now }
        model.manualCompletionSleep = { try await clock.sleep($0) }
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID })
        let id = try ItemID(rawValue: fixture.episodeID)
        _ = try await fixture.store.admitEpisode(.init(episodeID: id, decision: .keep, source: .manual,
            decidedAt: Timestamp(clock.now)), workTicketKinds: [.podcastDownload])
        let tickets = try await fixture.store.workTickets()
        let ticket = try XCTUnwrap(tickets.first { $0.kind == .podcastDownload })
        _ = try await fixture.store.applyWorkTicketTransition(kind: ticket.kind, subjectID: ticket.subjectID,
            requestSequence: ticket.requestSequence, to: .running, at: Timestamp(clock.now))
        model.skipEpisode(episode)
        await WiltedMacHeadless.drainDecisions(model)
        let first = try XCTUnwrap(model.undoableSkip)
        clock.advance(9)
        model.undoSkipEpisode(first)
        await WiltedMacHeadless.drainDecisions(model)
        let restored = try await fixture.store.removalKind(for: id)
        XCTAssertNil(restored)
        let running = try await fixture.store.workTickets().first { $0.id == ticket.id }
        XCTAssertEqual(running?.state, .running)
        let refreshed = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID })
        model.skipEpisode(refreshed)
        await WiltedMacHeadless.drainDecisions(model)
        let second = try XCTUnwrap(model.undoableSkip)
        XCTAssertEqual(model.podcastOperationMessage,
                       "Marked \(episode.title) completed. Undo completion is available for 10 seconds.")
        clock.advance(10)
        await WiltedMacHeadless.eventually("the expiry task commits the durable seal") {
            model.manualCompletionExpiryTask == nil && model.undoableSkip == nil
        }
        XCTAssertNil(model.podcastOperationMessage, "the Undo notice leaves the header when its window closes")
        model.undoSkipEpisode(second)
        await WiltedMacHeadless.drainDecisions(model)
        let retired = try await fixture.store.removalKind(for: id)
        XCTAssertEqual(retired, .retired)
        let reservations = try await fixture.store.manualCompletionCapacityReservations(at: clock.now)
        XCTAssertTrue(reservations.isEmpty)
        let retainedTransfer = try await fixture.store.workTickets().first { $0.id == ticket.id }
        XCTAssertEqual(retainedTransfer?.state, .running)
    }

    func testAFailedCompletionRestoresOnlyItsRowAndKeepsMedia() async throws {
        struct Failure: Error {}
        let fixture = try await fixture("failed")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        fixture.model.subscriptionWriteHookForTesting = { throw Failure() }

        fixture.model.skipEpisode(episode)
        XCTAssertFalse(fixture.model.larderVisibleEpisodes.contains { $0.id == fixture.episodeID })

        await WiltedMacHeadless.eventually("the failed completion settles") {
            fixture.model.episodeCompletionProjections.isEmpty
        }
        XCTAssertEqual(fixture.model.podcastOperationMessage,
                       "\(episode.title) could not be marked completed.")
        XCTAssertNil(fixture.model.undoableSkip)
        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        XCTAssertFalse(restored.isPlayed)
        XCTAssertNil(restored.retiredAt)
        XCTAssertNil(restored.removalKind)
        XCTAssertTrue(fixture.model.larderVisibleEpisodes.contains { $0.id == fixture.episodeID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path),
                      "a failed completion may not erase media")
        let durableKind = try await fixture.store.removalKind(for: ItemID(rawValue: fixture.episodeID))
        XCTAssertNil(durableKind)
    }

    func testDuplicateCompletionTapsMakeOneWrite() async throws {
        let fixture = try await fixture("duplicate")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let gate = WriteGate()
        fixture.model.subscriptionWriteHookForTesting = { await gate.arrive() }

        fixture.model.skipEpisode(episode)
        fixture.model.skipEpisode(episode)
        fixture.model.skipEpisode(episode)

        await gate.open()
        await WiltedMacHeadless.drainDecisions(fixture.model)
        let writes = await gate.writes
        XCTAssertEqual(writes, 1, "three taps make one completion write")
        XCTAssertEqual(fixture.model.undoableSkip?.id, fixture.episodeID)
    }

    func testUndoDoesNotRaceAnInFlightCompletion() async throws {
        let fixture = try await fixture("undo-race")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let gate = WriteGate()
        fixture.model.subscriptionWriteHookForTesting = { await gate.arrive() }

        fixture.model.skipEpisode(episode)
        fixture.model.undoSkipEpisode(episode)

        XCTAssertNil(fixture.model.undoableSkip, "Undo did not run against the queued completion")
        XCTAssertEqual(fixture.model.podcastOperationMessage, "Saving \(episode.title) as completed…")
        XCTAssertFalse(fixture.model.larderVisibleEpisodes.contains { $0.id == fixture.episodeID })

        await gate.open()
        await WiltedMacHeadless.drainDecisions(fixture.model)
        let writes = await gate.writes
        XCTAssertEqual(writes, 1, "Undo must not write while the completion is in flight")
        XCTAssertEqual(fixture.model.undoableSkip?.id, fixture.episodeID)
        let durableKind = try await fixture.store.removalKind(for: ItemID(rawValue: fixture.episodeID))
        XCTAssertEqual(durableKind, .retired)
    }

    func testUndoAfterADurableCompletionRestoresTheEpisodeAndKeepsItsMedia() async throws {
        let fixture = try await fixture("undo-durable")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        fixture.model.skipEpisode(episode)
        await WiltedMacHeadless.drainDecisions(fixture.model)
        XCTAssertEqual(fixture.model.undoableSkip?.id, fixture.episodeID)
        let durableKind = try await fixture.store.removalKind(for: ItemID(rawValue: fixture.episodeID))
        XCTAssertEqual(durableKind, .retired)

        let skipped = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        fixture.model.undoSkipEpisode(skipped)
        await WiltedMacHeadless.drainDecisions(fixture.model)
        await fixture.model.waitForPodcastOperations()
        await fixture.model.waitForPlaybackOperationForTesting()

        XCTAssertNil(fixture.model.undoableSkip)
        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        XCTAssertFalse(restored.isPlayed)
        XCTAssertNil(restored.retiredAt)
        let restoredKind = try await fixture.store.removalKind(for: ItemID(rawValue: fixture.episodeID))
        XCTAssertNil(restoredKind)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path),
                      "Undo restores from the media completion never deleted")
    }

    func testAFailedCompletionLeavesUnrelatedHidesAndPlaybackAlone() async throws {
        struct Failure: Error {}
        let fixture = try await fixture("failure-isolation")
        let storedEpisode = try await fixture.store.podcastEpisode(for: ItemID(rawValue: fixture.episodeID))
        let stored = try XCTUnwrap(storedEpisode)
        let otherEnclosureURL = URL(string: "https://media.example.test/completion-other.mp3")!
        let otherID = try ItemID.derivePodcastEpisode(
            feedURL: stored.feedURL, rssGUID: "completion-other", enclosureURL: otherEnclosureURL)
        try await WiltedMacModelTests.addReadyEpisode(
            otherID, guid: "completion-other", feedID: stored.feedID, feedURL: stored.feedURL,
            enclosureURL: otherEnclosureURL,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            directory: fixture.mediaURL.deletingLastPathComponent(), store: fixture.store,
            created: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        // This episode is added after bootstrap's legacy journal reconciliation.
        // Persist preparation's actual outcome rather than relying on its journal.
        let ready = try await fixture.store.readyRevision(for: otherID)
        let readyRevisionID = try XCTUnwrap(ready?.revision.revisionID)
        try await fixture.store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: otherID, revisionID: readyRevisionID, policyDigest: "fixture-policy",
            pipelineFingerprint: "fixture-fingerprint", semanticVersion: "fixture-semantic-version",
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
        await fixture.model.reloadLibraryRowsForTesting()
        let other = try XCTUnwrap(fixture.model.episodes.first { $0.id == otherID.rawValue })
        XCTAssertTrue(other.preparationState.isPrepared)
        XCTAssertTrue(fixture.model.canPlayEpisode(other), "the durable second episode must be eligible before Play")
        fixture.model.installPlaybackBackendForTesting(WiltedMacScriptedBackend())
        fixture.model.playEpisode(other)
        await fixture.model.waitForPlaybackOperationForTesting()
        await fixture.model.waitForPlaybackPresentationForTesting()
        XCTAssertEqual(fixture.model.playback?.itemID, otherID)
        XCTAssertTrue(fixture.model.isPlaying, "the unrelated controller session must exist before completion fails")
        fixture.model.hiddenEpisodeIDs.insert(other.id)
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        fixture.model.subscriptionWriteHookForTesting = { throw Failure() }

        fixture.model.skipEpisode(episode)
        await WiltedMacHeadless.eventually("the failed completion settles") {
            fixture.model.episodeCompletionProjections.isEmpty
        }

        XCTAssertTrue(fixture.model.hiddenEpisodeIDs.contains(other.id),
                      "an unrelated projection is not removed")
        XCTAssertFalse(fixture.model.hiddenEpisodeIDs.contains(fixture.episodeID),
                       "a failed completion adds no hide of its own")
        XCTAssertEqual(fixture.model.currentPodcastEpisodeID, other.id,
                       "playback another command started is left alone")
        XCTAssertTrue(fixture.model.isPlaying)
    }

    func testInvalidCompletionIDChangesNeitherProjectionNorUndoOrPreparation() async throws {
        let fixture = try await fixture("invalid-id")
        let previousUndo = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let invalid = WiltedMacEpisode(
            id: "invalid episode id", title: "Invalid", feedTitle: "Completion Show", summary: "",
            artworkURL: nil, releasedAt: Date(), durationSeconds: 30, playbackSeconds: 0, downloadState: .completed)
        fixture.model.undoableSkip = previousUndo

        fixture.model.skipEpisode(invalid, requireStarted: false)

        XCTAssertTrue(fixture.model.episodeCompletionProjections.isEmpty)
        XCTAssertEqual(fixture.model.undoableSkip?.id, previousUndo.id)
        XCTAssertNil(fixture.model.preparationRequestSequences[invalid.id])
        XCTAssertEqual(fixture.model.podcastOperationMessage, "Invalid could not be marked completed.")
    }

    func testUnstartedRemoveCompletesAndUndoDoesNotStartAudio() async throws {
        let fixture = try await fixture("unstarted-remove")
        let index = try XCTUnwrap(fixture.model.episodes.firstIndex { $0.id == fixture.episodeID })
        fixture.model.episodes[index].playbackSeconds = 0
        let episode = fixture.model.episodes[index]
        fixture.model.removeEpisodeFromUpNext(episode.id)
        await WiltedMacHeadless.drainDecisions(fixture.model)
        let id = try ItemID(rawValue: episode.id)
        let completed = try await fixture.store.listeningState(for: id)
        XCTAssertNotNil(completed?.completedAt)
        XCTAssertEqual(fixture.model.episodes.first { $0.id == episode.id }?.playbackSeconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path))
        fixture.model.undoSkipEpisode(try XCTUnwrap(fixture.model.undoableSkip))
        await WiltedMacHeadless.drainDecisions(fixture.model)
        XCTAssertFalse(fixture.model.isPlaying)
        XCTAssertNil(fixture.model.currentPodcastEpisodeID)
        let restored = try await fixture.store.listeningState(for: id)
        XCTAssertNil(restored)
    }

    func testFailedCompletionKeepsItsPreparationRequest() async throws {
        struct Failure: Error {}
        let fixture = try await fixture("preparation-failure")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let sequence = fixture.model.registerPreparationRequest(for: fixture.episodeID)
        fixture.model.subscriptionWriteHookForTesting = { throw Failure() }

        fixture.model.skipEpisode(episode)
        await WiltedMacHeadless.eventually("the failed completion settles") {
            fixture.model.episodeCompletionProjections.isEmpty
        }

        XCTAssertEqual(fixture.model.preparationRequestSequences[fixture.episodeID], sequence)
    }

    func testDurableCompletionPreservesItsPreexistingPreparationRequest() async throws {
        let fixture = try await fixture("preparation-success")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        let sequence = fixture.model.registerPreparationRequest(for: fixture.episodeID)

        fixture.model.skipEpisode(episode)
        await WiltedMacHeadless.drainDecisions(fixture.model)

        XCTAssertEqual(fixture.model.preparationRequestSequences[fixture.episodeID], sequence,
                       "Completion creates no preparation request and cannot withdraw another request's ownership")
    }
    func testDatedPhoneCompletionOffersTheFullLocalUndoWindow() async throws {
        let fixture = try await fixture("dated-phone")
        let model = fixture.model
        let clock = CompletionClock()
        model.manualCompletionNow = { clock.now }
        model.manualCompletionSleep = { try await clock.sleep($0) }
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID })
        let dated = Timestamp(clock.now.addingTimeInterval(-86_400))
        model.finishEpisodes([episode], at: dated)
        await WiltedMacHeadless.drainDecisions(model)
        let undo = try XCTUnwrap(model.undoableSkip)
        let windows = try await fixture.store.pendingManualCompletionWindows()
        XCTAssertEqual(windows[try XCTUnwrap(undo.manualCompletionOperationID)], clock.now.addingTimeInterval(10))
        let decision = try await fixture.store.episodeDecision(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(decision?.decidedAt, dated)
        XCTAssertEqual(model.podcastOperationMessage,
            "Marked \(episode.title) completed. Undo completion is available for 10 seconds.")
        clock.advance(9)
        model.undoSkipEpisode(undo)
        await WiltedMacHeadless.drainDecisions(model)
        let removal = try await fixture.store.removalKind(for: ItemID(rawValue: episode.id))
        XCTAssertNil(removal)
    }

    func testPartialCompletionSuccessNamesTheCommittedMemberRatherThanRejectedFirstCandidate() async throws {
        let fixture = try await fixture("partial-title")
        let model = fixture.model
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID })
        let missing = WiltedMacEpisode(id: "missing-completion-member", title: "Rejected member",
            feedTitle: "Completion Show", summary: "", artworkURL: nil, releasedAt: Date(),
            durationSeconds: 60, playbackSeconds: 0, downloadState: .completed)
        model.installEpisodeForTesting(missing)
        // finishEpisodes preserves the library order when expanding the request.
        model.episodes.removeAll { $0.id == missing.id }
        model.episodes.insert(missing, at: 0)
        model.finishEpisodes([missing, episode])
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.undoableSkip?.id, episode.id)
        XCTAssertEqual(model.podcastOperationMessage,
            "Marked \(episode.title) completed. Undo completion is available for 10 seconds.")
    }
}

/// Deterministic wall clock and cancellable sleeper for the model-owned task.
@MainActor
private final class CompletionClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        let deadline = now.addingTimeInterval(seconds)
        try await withTaskCancellationHandler { () async throws -> Void in
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if now >= deadline { continuation.resume(returning: ()) }
                else { sleepers[id] = (deadline, continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for (id, value) in sleepers where value.0 <= now {
            sleepers.removeValue(forKey: id)?.1.resume()
        }
    }
}
