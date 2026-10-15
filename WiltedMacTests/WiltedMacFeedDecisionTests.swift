import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacFeedDecisionTests: XCTestCase {
    func testLocalFeedChoicesAdvancePastFutureChoiceAndSameClockKeepWhileDatedIntentLoses() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let episode = fixture.episodes[0]
        let id = fixture.itemIDs[0]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = Timestamp(now.addingTimeInterval(1_000))
        fixture.model.manualCompletionNow = { now }
        try await fixture.store.save(episodeDecision: .init(episodeID: id, decision: .skip,
            source: .manual, decidedAt: future))
        fixture.model.decideFeedEpisodes(.keep, episodes: [episode])
        XCTAssertTrue(fixture.model.pendingFeedDecisionIDs.contains(episode.id))
        await drainDecisionWriters(fixture.model)
        let keptValue = try await fixture.store.episodeDecision(for: id)
        let kept = try XCTUnwrap(keptValue)
        XCTAssertEqual(kept.decision, .keep)
        XCTAssertGreaterThan(kept.decidedAt.date, future.date)
        fixture.model.decideFeedEpisodes(.skip, episodes: [episode])
        await drainDecisionWriters(fixture.model)
        let skippedValue = try await fixture.store.episodeDecision(for: id)
        let skipped = try XCTUnwrap(skippedValue)
        XCTAssertEqual(skipped.decision, .skip)
        XCTAssertGreaterThan(skipped.decidedAt.date, kept.decidedAt.date)
        let old = await fixture.model.applyOwnerIntent(try LibraryIntent.keep(entryID: id,
            deviceID: "iphone", createdAt: future.date, id: "old-feed-keep"))
        if case .superseded? = old {} else { XCTFail("Explicit old intent must retain its original chronology") }
        let retained = try await fixture.store.episodeDecision(for: id)
        XCTAssertEqual(retained, skipped)
    }

    func testKeepPublishesPendingBeforeCommitAndRejectsRepeatedClick() async throws {
        let gate = BootstrapGate()
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await gate.release() }
        let first = fixture.episodes[0]
        let second = fixture.episodes[1]
        fixture.model.feedDecisionBeforeCommitForTesting = { await gate.hold() }

        fixture.model.keepEpisode(first)
        XCTAssertEqual(fixture.model.feedsEpisodes.map(\.id), [second.id], "Keep answers before its writer starts")
        XCTAssertEqual(fixture.model.episodes.map(\.id).sorted(), [first.id, second.id].sorted())
        XCTAssertEqual(fixture.model.podcastQueueIDs, [], "presentation does not claim durable queue admission")
        fixture.model.keepEpisode(first)
        await gate.waitUntilHeld()
        XCTAssertEqual(fixture.model.feedsEpisodes.map(\.id), [second.id])

        XCTAssertEqual(fixture.model.pendingFeedDecisionIDs, Set([first.id]))
        XCTAssertFalse(fixture.model.pendingFeedDecisionIDs.contains(second.id))
        XCTAssertEqual(fixture.model.subscriptionWriteTasks.count, 1)
        let queueBeforeRelease = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queueBeforeRelease.episodeIDs, [])

        await gate.release()
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [first.id])
        let queueAfterRelease = try await fixture.store.podcastQueueState()
        XCTAssertEqual(
            queueAfterRelease.episodeIDs.map(\.rawValue), [first.id],
            "A repeated click must not duplicate a durable queue entry."
        )
    }

    func testBulkKeepCapturesVisibleOrderAndPreservesExistingCurrentQueueIdentity() async throws {
        let durable = BootstrapGate()
        let fixture = try await makeFixture(count: 3, queueIndexes: [0])
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await durable.release() }
        let existing = fixture.episodes[0]
        let firstVisible = fixture.episodes[1]
        let secondVisible = fixture.episodes[2]
        fixture.model.feedDecisionAfterDurableCommitForTesting = { await durable.hold() }

        fixture.model.decideFeedEpisodes(.keep, episodes: [secondVisible, firstVisible, secondVisible])
        XCTAssertTrue(fixture.model.feedsEpisodes.isEmpty, "bulk Keep projects every captured row immediately")
        XCTAssertEqual(fixture.model.podcastQueueIDs, [existing.id])
        await durable.waitUntilHeld()
        XCTAssertTrue(fixture.model.feedsEpisodes.isEmpty)

        let persisted = try await fixture.store.podcastQueueState()
        XCTAssertEqual(persisted.episodeIDs.map(\.rawValue), [existing.id, secondVisible.id, firstVisible.id])
        XCTAssertEqual(persisted.currentEpisodeID?.rawValue, existing.id)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [existing.id],
                       "The UI cannot claim the write until the durable boundary releases.")

        await durable.release()
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [existing.id, secondVisible.id, firstVisible.id])
    }

    func testKeepStartsInjectedDownloadOnlyAfterDurableCommitAndNeverForAlreadyQueued() async throws {
        let beforeCommit = BootstrapGate()
        let afterCommit = BootstrapGate()
        let transport = FeedDecisionDownloadTransport()
        let fixture = try await makeFixture(
            count: 1, queueIndexes: [], transportFactory: { transport },
            validatorFactory: { StubPodcastMediaValidator(duration: 12) }
        )
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await beforeCommit.release() }
        addTeardownBlock { await afterCommit.release() }
        let episode = fixture.episodes[0]
        fixture.model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: true, prepareEverythingDownloaded: false
            )
        }
        fixture.model.feedDecisionBeforeCommitForTesting = { await beforeCommit.hold() }
        fixture.model.feedDecisionAfterDurableCommitForTesting = { await afterCommit.hold() }

        fixture.model.keepEpisode(episode)
        await beforeCommit.waitUntilHeld()
        XCTAssertEqual(transport.startCount, 0)

        await beforeCommit.release()
        await afterCommit.waitUntilHeld()
        let durableQueue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(durableQueue.episodeIDs.map(\.rawValue), [episode.id])
        XCTAssertEqual(transport.startCount, 0)
        await afterCommit.release()
        await drainDecisionWriters(fixture.model)
        await fixture.model.waitForPodcastOperations()
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(fixture.model.episodes.first { $0.id == episode.id }?.downloadState, .completed)

        fixture.model.feedDecisionBeforeCommitForTesting = nil
        fixture.model.feedDecisionAfterDurableCommitForTesting = nil
        fixture.model.keepEpisode(episode)
        await drainDecisionWriters(fixture.model)
        await fixture.model.waitForPodcastOperations()
        XCTAssertEqual(transport.startCount, 1)
    }

    func testDisjointKeepsStayPendingAndPublishTheirCapturedOrderAfterFirstDurableBoundary() async throws {
        let firstDurable = FirstDurableGate()
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await firstDurable.release() }
        let first = fixture.episodes[0]
        let second = fixture.episodes[1]
        fixture.model.feedDecisionAfterDurableCommitForTesting = { await firstDurable.holdFirstOnly() }

        fixture.model.keepEpisode(first)
        fixture.model.keepEpisode(second)
        await firstDurable.waitUntilHeld()

        XCTAssertEqual(fixture.model.pendingFeedDecisionIDs, Set([first.id, second.id]))
        let whileFirstHeld = try await fixture.store.podcastQueueState()
        XCTAssertEqual(whileFirstHeld.episodeIDs.map(\.rawValue), [first.id])

        await firstDurable.release()
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [first.id, second.id])
        let finalQueue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(finalQueue.episodeIDs.map(\.rawValue), [first.id, second.id])
    }

    func testPartialSkipFailureLeavesOnlyUnresolvedIDRetryable() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let present = fixture.episodes[0]
        let missingURL = URL(string: "https://media.example.test/missing.mp3")!
        let missingID = try ItemID.derivePodcastEpisode(
            feedURL: fixture.feedURL, rssGUID: "missing", enclosureURL: missingURL
        )
        let missing = episode(id: missingID.rawValue)
        fixture.model.episodes.append(missing)

        fixture.model.decideFeedEpisodes(.skip, episodes: [present, missing])
        XCTAssertTrue(fixture.model.feedsEpisodes.isEmpty, "both captured rows leave before a partial commit")
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.feedsEpisodes.map(\.id), [missing.id], "only the unresolved row returns")
        XCTAssertTrue(fixture.model.pendingFeedDecisionIDs.isEmpty)

        let presentRemoval = try await fixture.store.removalKind(for: fixture.itemIDs[0])
        XCTAssertEqual(presentRemoval, .retired)
        XCTAssertEqual(fixture.model.failedFeedDecisionIDs, Set([missing.id]))
        XCTAssertFalse(fixture.model.failedFeedDecisionIDs.contains(present.id))

        try await fixture.store.save(episode: try PodcastEpisode(
            itemID: missingID, feedID: fixture.feedID, feedURL: fixture.feedURL, rssGUID: "missing",
            title: "Missing", publishedTime: fixture.createdAt, enclosureURL: missingURL,
            enclosureMediaType: "audio/mpeg", createdAt: fixture.createdAt
        ))
        fixture.model.decideFeedEpisodes(.skip, episodes: [missing])
        await drainDecisionWriters(fixture.model)

        let retriedRemoval = try await fixture.store.removalKind(for: missingID)
        XCTAssertEqual(retriedRemoval, .retired)
        XCTAssertTrue(fixture.model.failedFeedDecisionIDs.isEmpty)
    }

    func testWriterFailureLeavesQueueUnchangedAndExactIDRetryable() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let episode = fixture.episodes[0]
        fixture.model.feedDecisionBeforeCommitForTesting = { throw FeedDecisionTestError.injected }

        fixture.model.keepEpisode(episode)
        XCTAssertTrue(fixture.model.feedsEpisodes.isEmpty)
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.feedsEpisodes.map(\.id), [episode.id], "failed Keep returns its row for retry")
        XCTAssertTrue(fixture.model.pendingFeedDecisionIDs.isEmpty)
        let failedQueue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(failedQueue.episodeIDs, [])
        XCTAssertEqual(fixture.model.podcastQueueIDs, [])
        XCTAssertEqual(fixture.model.failedFeedDecisionIDs, Set([episode.id]))

        fixture.model.feedDecisionBeforeCommitForTesting = nil
        fixture.model.keepEpisode(episode)
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [episode.id])
    }

    func testQueueActorRejectsMissingRetiredAndDismissedIDsButAcceptsCanonicalAlreadyQueued() async throws {
        let fixture = try await makeFixture(count: 3, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let active = fixture.itemIDs[0]
        let retired = fixture.itemIDs[1]
        let dismissed = fixture.itemIDs[2]
        let missing = try ItemID.derivePodcastEpisode(
            feedURL: fixture.feedURL, rssGUID: "missing-queue",
            enclosureURL: URL(string: "https://media.example.test/missing-queue.mp3")!
        )
        _ = try await fixture.store.retireEpisodes([retired], at: fixture.createdAt)
        try await fixture.store.dismissPodcastEpisode(dismissed)

        let first = try await fixture.store.appendPodcastQueueEpisodes([active, missing, retired, dismissed])
        XCTAssertEqual(first.newlyAdded, [active])
        XCTAssertEqual(Set(first.unresolved), Set([missing, retired, dismissed]))
        let repeated = try await fixture.store.appendPodcastQueueEpisodes([active])
        XCTAssertEqual(repeated.newlyAdded, [])
        XCTAssertEqual(repeated.alreadyQueued, [active])
    }

    func testSkipDeletesAudioAndRestoreBringsTheEpisodeBackNotDownloadedKeepingCompletedListeningState() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]
        let mediaURL = fixture.directory.appendingPathComponent("episode.m4a")
        let contentHash = "sha256:" + String(repeating: "a", count: 64)
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
        try Data("audio".utf8).write(to: mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 12,
                                        byteCount: 5, contentHash: contentHash, mediaType: "audio/mpeg",
                                        createdAt: fixture.createdAt, schemaVersion: 3),
            mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: itemID, status: .completed, bytesReceived: 5,
                                          expectedByteCount: 5, localURL: mediaURL, contentHash: contentHash,
                                          updatedAt: fixture.createdAt)
        )
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: itemID, completedAt: fixture.createdAt, lastRevisionID: revisionID,
            updatedAt: fixture.createdAt
        ))

        fixture.model.skipFeedEpisode(fixture.episodes[0])
        await drainDecisionWriters(fixture.model)
        let skippedListening = try await fixture.store.listeningState(for: itemID)
        XCTAssertEqual(skippedListening?.completedAt, fixture.createdAt)
        XCTAssertEqual(skippedListening?.lastRevisionID, revisionID)
        // W-INV-025: skipping deletes the audio and the records that named it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        let skippedRevisions = try await fixture.store.revisions(for: itemID)
        XCTAssertEqual(skippedRevisions.count, 0)
        let skippedDownload = try await fixture.store.download(for: itemID)
        XCTAssertNil(skippedDownload)

        let skipped = try XCTUnwrap(fixture.model.skippedFeedEpisodes.first)
        fixture.model.restoreSkippedFeedEpisode(skipped)
        await drainDecisionWriters(fixture.model)
        let restoredListening = try await fixture.store.listeningState(for: itemID)
        XCTAssertEqual(restoredListening?.completedAt, fixture.createdAt)
        XCTAssertEqual(restoredListening?.lastRevisionID, revisionID)
        XCTAssertEqual(restoredListening?.updatedAt, fixture.createdAt)
        let restoredDecision = try await fixture.store.episodeDecision(for: itemID)
        XCTAssertEqual(restoredDecision?.decision, .keep)
        XCTAssertEqual(restoredDecision?.source, .manual)
        // Restore brings the episode back as not downloaded; the audio is not
        // resurrected.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        let restoredRevisions = try await fixture.store.revisions(for: itemID)
        XCTAssertEqual(restoredRevisions.count, 0)
        let restoredDownload = try await fixture.store.download(for: itemID)
        XCTAssertNil(restoredDownload)
    }

    func testOldQueueReadCannotReplaceCommittedKeepAndFreshReadStillPublishes() async throws {
        let queueRead = FirstDurableGate()
        let durable = BootstrapGate()
        let fixture = try await makeFixture(count: 2, queueIndexes: [0])
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await durable.release() }
        addTeardownBlock { await queueRead.release() }
        let old = fixture.episodes[0]
        let kept = fixture.episodes[1]
        // Hold exactly the first actor-read snapshot. Other refreshes must
        // proceed while Keep commits, without replacing its continuation.
        fixture.model.podcastQueueReadBarrierForTesting = { await queueRead.holdFirstOnly() }
        let staleRefresh = Task { @MainActor in await fixture.model.refreshPodcastQueueState() }
        await queueRead.waitUntilHeld()
        await fixture.model.refreshPodcastQueueState()
        fixture.model.feedDecisionAfterDurableCommitForTesting = { await durable.hold() }

        fixture.model.keepEpisode(kept)
        await durable.waitUntilHeld()
        let queueAfterCommit = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queueAfterCommit.episodeIDs.map(\.rawValue), [old.id, kept.id])
        await durable.release()
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [old.id, kept.id])

        await queueRead.release()
        await staleRefresh.value
        XCTAssertEqual(fixture.model.podcastQueueIDs, [old.id, kept.id])

        fixture.model.podcastQueueReadBarrierForTesting = nil
        await fixture.model.refreshPodcastQueueState()
        XCTAssertEqual(fixture.model.podcastQueueIDs, [old.id, kept.id])
    }

    func testCloseBeforeWriteCancelsButRelaunchAfterDurableCommitReadsExactQueue() async throws {
        let beforeWrite = BootstrapGate()
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await beforeWrite.release() }
        let cancelled = fixture.episodes[0]
        let committed = fixture.episodes[1]
        fixture.model.feedDecisionBeforeCommitForTesting = { await beforeWrite.hold() }

        fixture.model.keepEpisode(cancelled)
        await beforeWrite.waitUntilHeld()
        let close = Task { @MainActor in await fixture.model.close() }
        for _ in 0..<50 where !fixture.model.isClosingTemporaryState { await Task.yield() }
        XCTAssertTrue(fixture.model.isClosingTemporaryState)
        await beforeWrite.release()
        await close.value
        let cancelledQueue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(cancelledQueue.episodeIDs, [])

        let afterCommit = BootstrapGate()
        let writer = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await writer.close() }
        addTeardownBlock { await afterCommit.release() }
        writer.startStoreBootstrap()
        await writer.waitForStoreBootstrap()
        let durableEpisode = try XCTUnwrap(writer.episodes.first { $0.id == committed.id })
        writer.feedDecisionAfterDurableCommitForTesting = { await afterCommit.hold() }

        writer.keepEpisode(durableEpisode)
        await afterCommit.waitUntilHeld()
        let durableQueue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(durableQueue.episodeIDs.map(\.rawValue), [committed.id])
        await afterCommit.release()
        await writer.close()

        let relaunched = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await relaunched.close() }
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        XCTAssertEqual(relaunched.podcastQueueIDs, [committed.id])
    }

    func testOlderTaggedProjectionCannotReplaceACommittedDecisionBoundary() async throws {
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let skipped = fixture.episodes[0]
        let unrelated = fixture.episodes[1]
        let old = try await fixture.model.loadLibrary(from: fixture.store)

        fixture.model.skipFeedEpisode(skipped)
        await drainDecisionWriters(fixture.model)
        XCTAssertFalse(fixture.model.applyEpisodes(old.episodes))
        XCTAssertEqual(fixture.model.episodes.first { $0.id == skipped.id }?.removalKind, .retired)

        let fresh = try await fixture.model.loadLibrary(from: fixture.store)
        XCTAssertTrue(fixture.model.applyEpisodes(fresh.episodes))
        XCTAssertEqual(fixture.model.episodes.first { $0.id == unrelated.id }?.id, unrelated.id)
    }

    func testDurableSkipSurvivesFeedRefreshLatePreparationAndColdReopenUntilExplicitRestore() async throws {
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]
        let episode = fixture.episodes[0]
        let storedEpisode = try await fixture.store.podcastEpisode(for: itemID)
        let refreshedEpisode = try XCTUnwrap(storedEpisode)
        fixture.model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: true,
                downloadEverythingOnLarder: false, prepareEverythingDownloaded: false
            )
        }

        fixture.model.skipFeedEpisode(episode)
        await drainDecisionWriters(fixture.model)
        let afterSkip = try await fixture.store.podcastLibrarySnapshot()
        let retirement = try XCTUnwrap(afterSkip.retiredAtByEpisode[itemID])
        try await assertRetiredDecision(fixture.model, store: fixture.store, itemID: itemID, at: retirement)

        _ = try await fixture.store.savePodcastEpisodes([refreshedEpisode], admission: .incremental)
        await fixture.model.reloadLibraryRowsForTesting()
        try await assertRetiredDecision(fixture.model, store: fixture.store, itemID: itemID, at: retirement)

        // The durable output of a preparation finishing after Skip must not restore its episode.
        let mediaURL = fixture.directory.appendingPathComponent("late-prepared.m4a")
        try Data("late prepared audio".utf8).write(to: mediaURL)
        let contentHash = try MediaHash.sha256(fileAt: mediaURL)
        let revisionID = try RevisionID(rawValue: "rev-" + String(contentHash.dropFirst(MediaHash.prefix.count)))
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 12, byteCount: 19,
            contentHash: contentHash, mediaType: "audio/mpeg", createdAt: fixture.createdAt, schemaVersion: 3)
        try await fixture.store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: itemID, status: .completed, bytesReceived: 19,
                expectedByteCount: 19, localURL: mediaURL, contentHash: contentHash, updatedAt: fixture.createdAt))
        try await fixture.store.saveReadyRevision(
            revision, mediaURL: mediaURL,
            transcript: Transcript(itemID: itemID, revisionID: revisionID, availability: .absent, updatedAt: fixture.createdAt),
            outcome: PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID,
                policyDigest: "fixture-policy", pipelineFingerprint: "fixture-pipeline", semanticVersion: "fixture-1",
                producedAt: fixture.createdAt, eligibility: .current))
        await fixture.model.reloadLibraryRowsForTesting()
        await fixture.model.larderAdditionTask?.value
        XCTAssertEqual(fixture.model.episodes.first { $0.id == episode.id }?.downloadState, .completed)
        XCTAssertTrue(fixture.model.episodes.first { $0.id == episode.id }?.preparationState.isPrepared == true)
        await fixture.model.performAutoAddPreparedEpisodesToLarder([episode.id])
        try await assertRetiredDecision(fixture.model, store: fixture.store, itemID: itemID, at: retirement)

        await fixture.model.close()
        let reopened = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory,
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await reopened.close() }
        reopened.startStoreBootstrap()
        await reopened.waitForStoreBootstrap()
        let coldStore = try XCTUnwrap(reopened.store)
        try await assertRetiredDecision(reopened, store: coldStore, itemID: itemID, at: retirement)

        let retired = try XCTUnwrap(reopened.skippedFeedEpisodes.first { $0.id == episode.id })
        reopened.restoreSkippedFeedEpisode(retired)
        await drainDecisionWriters(reopened)
        let restoredSnapshot = try await coldStore.podcastLibrarySnapshot()
        let restoredDecision = try await coldStore.episodeDecision(for: itemID)
        XCTAssertNil(restoredSnapshot.retiredAtByEpisode[itemID])
        XCTAssertNil(restoredSnapshot.removalKindByEpisode[itemID])
        XCTAssertEqual(restoredDecision?.decision, .keep)
        XCTAssertEqual(restoredDecision?.source, .manual)
        XCTAssertTrue(reopened.feedsEpisodes.contains { $0.id == episode.id }, "explicit Restore returns the row")
    }

    private func assertRetiredDecision(
        _ model: WiltedMacModel, store: LocalLibraryStore, itemID: ItemID, at retirement: Timestamp
    ) async throws {
        let snapshot = try await store.podcastLibrarySnapshot()
        let decision = try await store.episodeDecision(for: itemID)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(snapshot.retiredAtByEpisode[itemID], retirement)
        XCTAssertEqual(snapshot.removalKindByEpisode[itemID], .retired)
        XCTAssertEqual(decision?.decision, .skip)
        XCTAssertEqual(decision?.source, .manual)
        XCTAssertEqual(model.episodes.first { $0.id == itemID.rawValue }?.retiredAt, retirement.date)
        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == itemID.rawValue })
        XCTAssertFalse(model.podcastQueueIDs.contains(itemID.rawValue))
        XCTAssertFalse(queue.episodeIDs.contains(itemID))
    }

    func testLargeBatchReportsBoundedActorOperationDiagnostics() async throws {
        let fixture = try await makeFixture(count: 48, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }

        let result = try await fixture.store.appendPodcastQueueEpisodes(fixture.itemIDs)

        XCTAssertEqual(result.state.episodeIDs, fixture.itemIDs)
        XCTAssertEqual(result.newlyAdded, fixture.itemIDs)
        XCTAssertEqual(result.queueReadCount, 1)
        XCTAssertEqual(result.queueWriteCount, 1)
        XCTAssertEqual(result.episodeRecordFetchCount, 1)
    }

    private func drainDecisionWriters(_ model: WiltedMacModel) async {
        let writers = Array(model.subscriptionWriteTasks.values)
        for writer in writers { await writer.value }
    }

    private func makeFixture(
        count: Int, queueIndexes: [Int],
        transportFactory: WiltedMacPodcastDownloadTransportFactory? = nil,
        validatorFactory: WiltedMacPodcastMediaValidatorFactory? = nil
    ) async throws -> FeedDecisionFixture {
        let directory = wiltedTemporaryDirectory("feed-decision")
        let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://feeds.example.test/feed-decision.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemIDs = try (0..<count).map { index in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "episode-\(index)",
                enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!
            )
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Decision feed", createdAt: createdAt
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: createdAt))
                for (index, itemID) in itemIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-\(index)",
                        title: "Episode \(index)", publishedTime: createdAt,
                        enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!,
                        enclosureMediaType: "audio/mpeg", createdAt: createdAt
                    ))
                }
                let queued = queueIndexes.map { itemIDs[$0] }
                if !queued.isEmpty {
                    try await store.replacePodcastQueue(try PodcastQueueState(
                        episodeIDs: queued, currentEpisodeID: queued.first
                    ))
                }
                return store
            },
            podcastDownloadTransportFactory: transportFactory,
            podcastMediaValidatorFactory: validatorFactory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.manualCompletionRecoveryTask?.value
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodes = itemIDs.compactMap { id in model.episodes.first { $0.id == id.rawValue } }
        XCTAssertEqual(episodes.count, count, "Fixture bootstrap must publish every seeded episode.")
        return FeedDecisionFixture(
            model: model, store: store, directory: directory, episodes: episodes, itemIDs: itemIDs,
            feedID: feedID, feedURL: feedURL, createdAt: createdAt
        )
    }

    private func episode(id: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Feed", summary: "", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), publishedAt: nil,
            sourceDurationSeconds: nil, durationSeconds: nil, playbackSeconds: 0,
            downloadState: .notDownloaded
        )
    }
}

private struct FeedDecisionFixture {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let directory: URL
    let episodes: [WiltedMacEpisode]
    let itemIDs: [ItemID]
    let feedID: ItemID
    let feedURL: URL
    let createdAt: Timestamp
}

private final class FeedDecisionDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        lock.lock(); starts += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: url, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4)))
            continuation.yield(.data(Data("body".utf8)))
            continuation.finish()
        }
    }
}

private actor FirstDurableGate {
    private var held = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func holdFirstOnly() async {
        guard !held else { return }
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum FeedDecisionTestError: Error { case injected }
