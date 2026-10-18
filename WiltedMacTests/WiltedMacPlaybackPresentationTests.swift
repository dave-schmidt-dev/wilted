import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacPlaybackPresentationTests: XCTestCase {
    func testIdleArticleBackfillPersistsWithoutRequiringLoadedPlayback() async throws {
        let (model, _, _) = makePlaybackCommandModel()
        await model.fixtureInstallTask?.value
        let article = try XCTUnwrap(model.articles.first)
        let store = try XCTUnwrap(model.store)
        let itemID = try ItemID(rawValue: article.id)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)
        model.selectedArticleID = article.id
        XCTAssertNil(model.playback?.itemID)
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: "Idle presentation")
        let presentation = model.currentTranscript
        var extractedURL: URL?
        model.transcriptBackfillBodyForTesting = { url in
            extractedURL = url
            return "Idle article backfill text"
        }
        model.backfillCurrentTranscript()
        await model.waitForPodcastOperations()
        let transcript = try await store.transcript(for: itemID, revisionID: ready.revision.revisionID)
        XCTAssertEqual(extractedURL, article.url)
        XCTAssertEqual(transcript?.text, "Idle article backfill text")
        XCTAssertEqual(model.currentTranscript, presentation, "idle durable backfill has no loaded presentation owner")
        XCTAssertNil(model.transcriptBackfillStatus)
        XCTAssertFalse(model.isBackfillingTranscript)
        await model.close()
    }

    func testArticleBackfillUsesArticleRevisionWhilePodcastIsLoaded() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let loadedRevision = model.playback?.revisionID
        let presentation = model.currentTranscript
        let article = try XCTUnwrap(model.articles.first)
        let itemID = try ItemID(rawValue: article.id)
        let store = try XCTUnwrap(model.store)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)
        model.selectedArticleID = article.id
        model.transcriptBackfillBodyForTesting = { _ in "Article text independent of loaded podcast" }
        model.backfillCurrentTranscript()
        await model.waitForPodcastOperations()
        let transcript = try await store.transcript(for: itemID, revisionID: ready.revision.revisionID)
        XCTAssertEqual(transcript?.text, "Article text independent of loaded podcast")
        XCTAssertEqual(model.playback?.revisionID, loadedRevision)
        XCTAssertEqual(model.currentTranscript, presentation)
        XCTAssertNil(model.transcriptBackfillStatus)
        await model.close()
    }

    func testHeldArticleBackfillPersistsPinnedRevisionWithoutReplacingNewPodcast() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()
        let article = try XCTUnwrap(model.articles.first)
        model.openNowPlaying(for: article)
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        let articleID = try XCTUnwrap(model.playback?.itemID)
        let articleRevision = try XCTUnwrap(model.playback?.revisionID)
        XCTAssertEqual(articleID.rawValue, article.id)
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.transcriptBackfillBodyForTesting = { _ in
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
            return "Late article text pinned before new playback"
        }
        model.backfillCurrentTranscript()
        await gate.waitUntilHeld()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        let current = model.currentTranscript
        XCTAssertEqual(model.transcriptBackfillStatus, "Fetching article text…")
        gate.release()
        await model.waitForPodcastOperations()
        let store = try XCTUnwrap(model.store)
        let transcript = try await store.transcript(for: articleID, revisionID: articleRevision)
        XCTAssertEqual(transcript?.text, "Late article text pinned before new playback")
        XCTAssertEqual(model.playback?.itemID?.rawValue, episode.id)
        XCTAssertEqual(model.currentTranscript, current)
        XCTAssertNil(model.transcriptBackfillStatus, "the old selection must not leave a fetching notice behind")
        XCTAssertFalse(model.isBackfillingTranscript)
        await model.close()
    }

    func testPreparedReloadMissingReadyRevisionReportsFailureAndKeepsLoadedAudio() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let store = try XCTUnwrap(model.store)
        let itemID = try XCTUnwrap(model.playback?.itemID)
        let revision = model.playback?.revisionID
        let loads = backend.loadCount
        _ = try await store.retireEpisode(itemID)
        let missing = try await store.readyRevision(for: itemID)
        XCTAssertNil(missing)
        await model.reloadPreparedPlayback(episode.id, itemID: itemID)
        XCTAssertEqual(model.playbackCommands.failure?.kind, .unavailable)
        XCTAssertEqual(model.playbackError, "This episode's saved audio is unavailable.")
        XCTAssertEqual(model.playback?.revisionID, revision)
        XCTAssertEqual(backend.loadCount, loads)
        await model.close()
    }

    func testHeldImmutableTranscriptCannotReplaceNewLoadedRevisionOrCuts() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let playback = try XCTUnwrap(model.playback)
        let itemID = try XCTUnwrap(playback.itemID)
        let oldRevision = try XCTUnwrap(playback.revisionID)
        let owner = try XCTUnwrap(model.playbackPresentationOwner(itemID: itemID, revisionID: oldRevision))
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackPresentationReadBarrierForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        let oldRead = Task { await model.readPlaybackPresentation(owner, includesCuts: true) }
        await gate.waitUntilHeld()
        let store = try XCTUnwrap(model.store)
        let storedOld = try await store.readyRevision(for: itemID, revisionID: oldRevision)
        let old = try XCTUnwrap(storedOld)
        let revisionID = try RevisionID(rawValue: "presentation-new-revision")
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 600, byteCount: 1024,
            contentHash: "sha256:" + String(repeating: "b", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(Date()), schemaVersion: 1
        )
        try await store.saveReadyRevision(revision, mediaURL: old.mediaURL,
            transcript: Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                   text: "New loaded revision words", updatedAt: Timestamp(Date())))
        try await playback.load(StoredAudioRevision(revision: revision, mediaURL: old.mediaURL))
        model.requestPlaybackPresentation(itemID: itemID, includesCuts: true)
        await model.waitForPlaybackPresentationForTesting()
        XCTAssertEqual(model.currentTranscript?.text, "New loaded revision words")
        let currentCuts = model.removedSpansByEpisode[itemID.rawValue]
        gate.release()
        await oldRead.value
        XCTAssertEqual(model.currentTranscript?.text, "New loaded revision words")
        XCTAssertEqual(model.removedSpansByEpisode[itemID.rawValue], currentCuts)
        XCTAssertFalse(model.ownsPlaybackPresentation(owner))
        await model.close()
    }

    func testSameRevisionReselectionRejectsHeldReadWhilePausePreservesOwner() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let itemID = try XCTUnwrap(model.playback?.itemID)
        let revisionID = try XCTUnwrap(model.playback?.revisionID)
        let owner = try XCTUnwrap(model.playbackPresentationOwner(itemID: itemID, revisionID: revisionID))
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.ownsPlaybackPresentation(owner), "Pause keeps the current transcript request alive")
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackPresentationReadBarrierForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        let read = Task { await model.readPlaybackPresentation(owner, includesCuts: true) }
        await gate.waitUntilHeld()
        model.issuePlaybackCommand(.select, pending: nil, target: episode.id,
                                   failureMessage: "Fixture selection failed") { _ in }
        await model.waitForPlaybackOperationForTesting()
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: "New selection")
        gate.release()
        await read.value
        XCTAssertEqual(model.currentTranscript?.text, "New selection")
        XCTAssertFalse(model.ownsPlaybackPresentation(owner))
        await model.close()
    }

    func testRemovalCheckpointCannotClearSameItemNewSelection() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        backend.onPause = {
            backend.onPause = nil
            model.issuePlaybackCommand(.select, pending: nil, target: episode.id,
                                       failureMessage: "Fixture selection failed") { _ in }
        }
        await model.stopPlaybackForRemovedEpisode()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertTrue(model.isPodcastPlayback)
        await model.close()
    }

    func testBoundaryPreviousReplacesHeldPresentationOwnerWithoutStartingAudio() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.playEpisode(episode)
        await gate.waitUntilHeld()
        await model.waitForPlaybackOperationForTesting()
        let loadedRevision = model.playback?.revisionID
        let playCount = backend.playCount
        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        XCTAssertEqual(backend.playCount, playCount, "a boundary Previous cannot start audio again")
        XCTAssertEqual(model.playback?.revisionID, loadedRevision)
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertEqual(model.podcastQueueIDs, [episode.id], "the replacement owner must hydrate the current queue")
        XCTAssertNil(model.nextEligiblePodcastQueueEpisode(), "a one-item queue has no phantom successor")
        let store = try XCTUnwrap(model.store)
        let itemID = try XCTUnwrap(model.playback?.itemID)
        let revisionID = try XCTUnwrap(loadedRevision)
        let storedExpected = try await store.transcript(for: itemID, revisionID: revisionID)
        let expected = try XCTUnwrap(storedExpected)
        XCTAssertEqual(model.currentTranscript?.text, expected.text)
        XCTAssertEqual(model.currentTranscript?.availability, WiltedMacTranscript(stored: expected).availability)
        let current = model.currentTranscript
        gate.release()
        await model.close()
        XCTAssertEqual(model.currentTranscript, current, "the cancelled older read must stay stale after release")
    }

    func testDurableQueueWriterDoesNotInheritHeldPresentation() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.playEpisode(episode)
        await gate.waitUntilHeld()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForLifetimeStatisticsRefreshForTesting()
        let presentationID = try XCTUnwrap(model.playbackPresentationTaskID)
        XCTAssertNotNil(model.playbackPresentationTasks[presentationID])
        XCTAssertNil(model.subscriptionWriteTasks[presentationID])
        // An absent queue member exercises the real durable queue-only writer without
        // completion effects. Its predecessor drain must finish before releasing presentation.
        model.removeEpisodeFromUpNext("presentation-absent-queue-member")
        let writes = Array(model.subscriptionWriteTasks.values)
        for write in writes { await write.value }
        XCTAssertNil(model.playbackOperationStatus)
        XCTAssertNotNil(model.playbackPresentationTasks[presentationID])
        gate.release()
        await model.waitForPlaybackPresentationForTesting()
        await model.close()
    }

    func testCloseJoinsCancelledPresentationUntilHeldReadFinishes() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.playEpisode(episode)
        await gate.waitUntilHeld()
        var closed = false
        let closing = Task { await model.close(); closed = true }
        await Task.yield()
        XCTAssertFalse(closed)
        gate.release()
        await closing.value
        XCTAssertTrue(closed)
        XCTAssertNil(model.playbackPresentationTaskID)
        XCTAssertTrue(model.subscriptionWriteTasks.isEmpty)
        XCTAssertTrue(model.playbackPresentationTasks.isEmpty)
    }
}
