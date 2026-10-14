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
                       "Marked \(episode.title) completed. Undo completion restores it.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path),
                      "completion keeps the media Undo needs")
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
        let other = WiltedMacEpisode(
            id: "completion-other", title: "Other", feedTitle: "Completion Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 5, downloadState: .completed
        )
        fixture.model.installEpisodeForTesting(other)
        fixture.model.installPlaybackStateForTesting(episode: other, isPlaying: true, position: 5, duration: 600)
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

    func testDurableCompletionWithdrawsItsPreparationRequest() async throws {
        let fixture = try await fixture("preparation-success")
        let episode = try XCTUnwrap(fixture.model.episodes.first { $0.id == fixture.episodeID })
        _ = fixture.model.registerPreparationRequest(for: fixture.episodeID)

        fixture.model.skipEpisode(episode)
        await WiltedMacHeadless.drainDecisions(fixture.model)

        XCTAssertNil(fixture.model.preparationRequestSequences[fixture.episodeID])
    }
}
