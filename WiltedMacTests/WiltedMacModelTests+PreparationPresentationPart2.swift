import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
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

}
