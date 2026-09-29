import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Phase 1 — Menu admission, removal, ordering, drops

    /// 1.2: an admission that raises is named instead of swallowed.
    func testAFailedAutoAddNamesTheFailureInTheStatusLine() async throws {
        let directory = temporaryDirectory("auto-add-failure")

        let model = preparedAdmissionModel(in: directory, suffix: "failure")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id))

        model.installMenuAdmissionForTesting { _ in throw StartupTestError.expectedFailure }
        await model.performAutoAddPreparedEpisodesToMenu([episode.id])

        XCTAssertTrue(
            model.podcastOperationMessage?.contains("could not be added to Larder") == true,
            "a raised admission must reach the status line: \(model.podcastOperationMessage ?? "nil")"
        )
    }

    /// 1.2: the failed admission is held and retried on the next reload.
    func testAutoAddRetriesAFailedMenuAdmissionOnTheNextReload() async throws {
        let directory = temporaryDirectory("auto-add-retry")

        let model = preparedAdmissionModel(in: directory, suffix: "retry")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id))

        model.installMenuAdmissionForTesting { _ in throw StartupTestError.expectedFailure }
        await model.performAutoAddPreparedEpisodesToMenu([episode.id])
        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id),
                       "a write that raised leaves no durable Menu entry")

        model.installMenuAdmissionForTesting(nil)
        await model.reloadLibraryRowsForTesting()

        XCTAssertTrue(model.podcastQueueIDs.contains(episode.id),
                      "the next reload retries the admission")
    }

    private func preparedAdmissionModel(in directory: URL, suffix: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                _ = try await installPreparedMenuEpisode(
                    into: store, directory: url.deletingLastPathComponent(), suffix: suffix
                )
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    /// 1.3: the badge and its label count the same rows the Menu renders.
    func testMenuBadgeAndSidebarTotalsCountTheRowsTheMenuRenders() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = destinationEpisode("count-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        let downloaded = destinationEpisode("count-downloaded", download: .completed,
                                            preparation: .notPrepared)
        let available = destinationEpisode("count-available", download: .notDownloaded,
                                           preparation: .notPrepared)
        for value in [ready, downloaded, available] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertEqual(model.menuUpcomingEpisodeIDs.count, model.menuWaitingEpisodes.count,
                       "the badge counts the rows the Menu renders")
        XCTAssertEqual(Set(model.menuUpcomingEpisodeIDs), Set(model.menuWaitingEpisodes.map(\.id)))
        XCTAssertEqual(model.menuAudioSummary,
                       WiltedMacQueueAudioSummary(episodes: model.menuWaitingEpisodes))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("model.menuUpcomingEpisodeIDs.count"))
        XCTAssertTrue(view.contains("Open Larder with \\(model.menuUpcomingEpisodeIDs.count) episodes"))
        XCTAssertTrue(view.contains("model.menuAudioSummary"))
    }

    /// A podcast in playback belongs to Now Playing rather than the lower
    /// waiting list. Its durable queue position is intentionally untouched;
    /// only the Larder projection changes. A remembered marker while an
    /// article is active is not podcast playback and must remain visible.
    func testActivePodcastIsExcludedFromLarderPresentationWhilePlayingOrPaused() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = destinationEpisode(
            "presentation-current", download: .completed, preparation: .prepared(summary: "Ready")
        )
        let waiting = destinationEpisode(
            "presentation-waiting", download: .completed, preparation: .prepared(summary: "Ready")
        )
        model.installEpisodeForTesting(waiting)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [current.id, waiting.id]
        )

        XCTAssertEqual(model.larderPresentationEpisodes.map(\.id), [waiting.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [waiting.id])
        XCTAssertEqual(model.menuUpcomingEpisodeIDs, [waiting.id], "the badge counts only waiting rows")
        XCTAssertEqual(model.menuAudioSummary, WiltedMacQueueAudioSummary(episodes: [waiting]))
        model.menuFilter = .playable
        XCTAssertEqual(model.menuFilteredEpisodes.map(\.id), [waiting.id])
        XCTAssertEqual(model.menuSections().flatMap(\.episodes).map(\.id), [waiting.id])

        model.installPlaybackStateForTesting(
            episode: current, isPlaying: false, position: 12, duration: 600,
            queue: [current.id, waiting.id]
        )
        XCTAssertEqual(model.larderPresentationEpisodes.map(\.id), [waiting.id],
                       "a paused podcast remains in Now Playing")

        model.menuFilter = nil
        model.installArticlePlaybackWithPodcastMarkerForTesting(
            episodeID: current.id, position: 12, duration: 600
        )
        XCTAssertEqual(model.larderPresentationEpisodes.map(\.id), [waiting.id, current.id],
                       "article playback must not hide a merely remembered podcast")
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [current.id, waiting.id])
    }

    /// 1.3: queue removal is not retirement. The durable entry leaves the
    /// queue; the episode's row, records, and listening state stay.
    func testRemovingADurableMenuEntryLeavesItsLibraryRowUntouched() async throws {
        let directory = temporaryDirectory("menu-remove-leaves-row")

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                        "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first { $0.preparationState.isPrepared })
        let store = try XCTUnwrap(model.store)
        let episodeID = try ItemID(rawValue: episode.id)
        model.keepEpisode(episode)
        // The durable add has to land before the removal, or the two writes
        // race and the later add can put the entry back on the queue.
        await waitForFeedDecisionWriters(model)
        XCTAssertTrue(model.podcastQueueIDs.contains(episode.id))
        let beforeQueue = try await store.podcastQueueState()
        let beforeRows = try await store.podcastEpisodes()
        let beforeRow = try XCTUnwrap(beforeRows.first { $0.itemID == episodeID })
        let beforeReady = try await store.readyRevision(for: episodeID)
        let beforeAudio = try XCTUnwrap(beforeReady)
        let beforePreparation = try await store.preparationOutcome(
            for: episodeID, revisionID: beforeAudio.revision.revisionID
        )
        let beforeListening = try await store.listeningState(for: episodeID)
        let beforeAudioData = try Data(contentsOf: beforeAudio.mediaURL)
        XCTAssertEqual(beforeQueue.episodeIDs, [episodeID])

        model.removeEpisodeFromUpNext(episode.id)
        await model.waitForPodcastOperations()

        XCTAssertFalse(model.podcastQueueIDs.contains(episode.id),
                       "the durable entry left the queue")
        let afterQueue = try await store.podcastQueueState()
        let afterRow = try await store.podcastEpisodes().first { $0.itemID == episodeID }
        let afterAudio = try await store.readyRevision(for: episodeID)
        let afterPreparation = try await store.preparationOutcome(
            for: episodeID, revisionID: beforeAudio.revision.revisionID
        )
        let afterListening = try await store.listeningState(for: episodeID)
        let afterAudioData = try afterAudio.map { try Data(contentsOf: $0.mediaURL) }
        XCTAssertTrue(afterQueue.episodeIDs.isEmpty, "the durable queue is empty")
        XCTAssertEqual(afterRow, beforeRow)
        XCTAssertEqual(afterAudio?.revision, beforeAudio.revision)
        XCTAssertEqual(afterAudio?.mediaURL, beforeAudio.mediaURL)
        XCTAssertEqual(afterAudioData, beforeAudioData)
        XCTAssertEqual(afterPreparation, beforePreparation)
        XCTAssertEqual(afterListening, beforeListening)
        let retained = try XCTUnwrap(model.episodes.first { $0.id == episode.id },
                                     "removal from the queue is not retirement; the row stays")
        XCTAssertNil(retained.retiredAt)
        XCTAssertFalse(retained.isPlayed)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == episode.id },
                      "an un-kept row is back in Feeds, not destroyed")
    }

    /// 1.3: a durable member is not addable, wherever it sits in the queue.
    func testCanAddEpisodeToMenuRefusesADurableMemberAtAnyIndex() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let earlier = ready("addable-earlier")
        let current = ready("addable-current")
        let later = ready("addable-later")
        for value in [earlier, current, later] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [earlier.id, current.id, later.id]
        )

        XCTAssertFalse(model.canAddEpisodeToMenu(earlier),
                       "an entry before the current index is already durable")
        XCTAssertFalse(model.canAddEpisodeToMenu(current),
                       "the current episode is never added a second time")
        XCTAssertFalse(model.canAddEpisodeToMenu(later),
                       "an entry after the current index is already durable")
    }

    /// 1.4: oldest-first orders every row except the playing one and anchors
    /// the playing one where it was.
    func testOldestMenuSortOrdersAscendingAndAnchorsTheCurrentEpisode() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String, published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: published),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let current = ready("oldest-current", published: 200)
        let oldest = ready("oldest-first", published: 100)
        let middle = ready("oldest-middle", published: 300)
        let newest = ready("oldest-last", published: 400)
        for value in [oldest, middle, newest] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [middle.id, oldest.id, current.id, newest.id]
        )

        model.menuSort = .oldest

        XCTAssertEqual(model.menuDisplayEpisodeIDs, [oldest.id, middle.id, current.id, newest.id],
                       "the non-playing rows sort by ascending publication date")
        XCTAssertEqual(model.menuDisplayEpisodeIDs.firstIndex(of: current.id), 2,
                       "the playing episode keeps its prior position")
    }

    /// 1.4: the selection is written and read back.
    func testOldestMenuSortSurvivesARebuild() throws {
        let suite = "com.zerodelta.wilted.mac.menu-sort-oldest-tests"
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        first.menuSort = .oldest

        let rebuilt = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(rebuilt.menuSort, .oldest)
    }

    /// 1.5: a drop past the last row appends. The index the helper answers
    /// with is the count of the queue the dragged row leaves behind.
    func testTailInsertionIndexAppendsPastTheLastRow() async throws {
        let root = wiltedTemporaryDirectory("model-state")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("library.sqlite")
        var store = try LocalLibraryStore(url: storeURL)
        let first = try ItemID(rawValue: "item-" + String(repeating: "1", count: 64))
        let second = try ItemID(rawValue: "item-" + String(repeating: "2", count: 64))
        let third = try ItemID(rawValue: "item-" + String(repeating: "3", count: 64))
        try await store.addPodcastQueueEpisode(first)
        try await store.addPodcastQueueEpisode(second)
        try await store.addPodcastQueueEpisode(third)
        let queue = [first, second, third]

        let insertion = WiltedMacModel.menuInsertionIndex(source: 0, destination: queue.count)
        try await store.movePodcastQueueEpisode(from: 0, to: insertion)
        store = try LocalLibraryStore(url: storeURL)
        let reopened = try await store.podcastQueueState()

        XCTAssertEqual(reopened.episodeIDs, [second, third, first],
                       "a drop past the last row lands last")
        XCTAssertEqual(insertion, queue.filter { $0 != first }.count,
                       "the tail index equals the count of the queue it leaves behind")
    }

    /// 1.5: a payload that is not one of the Menu's episodes is refused and
    /// the order is left exactly as it was.
    func testAForeignDropPayloadIsRejectedAndLeavesTheOrderAlone() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let first = destinationEpisode("drop-first", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        let second = destinationEpisode("drop-second", download: .completed,
                                        preparation: .prepared(summary: "Ready"))
        for value in [first, second] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        let before = model.podcastQueueIDs

        XCTAssertFalse(model.moveMenuEpisode("file:///Users/dave/Downloads/invoice.pdf", before: second.id),
                       "a foreign payload is refused at a row")
        XCTAssertFalse(model.moveMenuEpisodeToEnd("file:///Users/dave/Downloads/invoice.pdf"),
                       "a foreign payload is refused at the tail")
        XCTAssertEqual(model.podcastQueueIDs, before, "the order is left exactly as it was")
    }

    // MARK: Removal kinds (Task 5.5)

    /// A prepared row must say what was removed, not just how much: two
    /// sponsor reads and a show plugging its own newsletter are different
    /// removals, and collapsing them into "3 ads removed" tells a listener
    /// the show ran three adverts when it ran two.
    func testPreparedSummaryReportsASeparateFigureForEachRemovalKind() throws {
        let run = try preparationRun(withRemovalKinds: [
            "paid advertising", "paid advertising", "house promotion", "credits"
        ])
        let summary = WiltedMacModel.preparedSummary(of: run, timing: .aligned)

        XCTAssertTrue(summary.contains("2 paid advertising"), summary)
        XCTAssertTrue(summary.contains("1 house promotion"), summary)
        XCTAssertTrue(summary.contains("1 credits"), summary)
        // The taxonomy's own order, so the removal a listener cares about
        // leads rather than being buried under credits.
        let paid = try XCTUnwrap(summary.range(of: "2 paid advertising"))
        let house = try XCTUnwrap(summary.range(of: "1 house promotion"))
        let credits = try XCTUnwrap(summary.range(of: "1 credits"))
        XCTAssertTrue(paid.lowerBound < house.lowerBound)
        XCTAssertTrue(house.lowerBound < credits.lowerBound)
        XCTAssertFalse(summary.contains("4 ads removed"),
                       "four removals of three kinds must not collapse to one figure")
    }

    /// Every journal written before kinds existed has no kind to report, and
    /// inventing one would claim a breakdown the run never recorded.
    func testPreparedSummaryKeepsItsPreviousWordingWhenNoRemovalCarriesAKind() throws {
        let run = try preparationRun(withRemovalKinds: [])
        XCTAssertNil(WiltedMacModel.removalKindSummary(of: run))
        XCTAssertEqual(WiltedMacModel.preparedSummary(of: run, timing: .aligned),
                       WiltedMacModel.recordedSummary(of: run)
                       ?? "Ready · \(PodcastPreparationResult.transcriptStep(.aligned))")
    }

    /// A run retried inside one request journals its spans twice. The summary
    /// counts the removals the episode has, not the attempts it took.
    func testPreparedSummaryCountsARetriedRunsSpansOnce() throws {
        let run = try preparationRun(withRemovalKinds: ["paid advertising", "house promotion"],
                                     attempts: 3)
        let summary = try XCTUnwrap(WiltedMacModel.removalKindSummary(of: run))
        XCTAssertEqual(summary, "1 paid advertising, 1 house promotion removed")
    }

    /// Builds a succeeded run whose entries journal one `advertisement`
    /// evidence per removal, the shape `adProgress` writes.
    private func preparationRun(
        withRemovalKinds kinds: [String], attempts: Int = 1
    ) throws -> PreparationRunSummary {
        let itemID = try ItemID(rawValue: "kind-summary-episode")
        let requestID = "podcast-prepare|kind-summary-episode"
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        var entries: [PreparationJournalEntry] = []
        var emitted = 0
        for attempt in 0..<max(1, attempts) {
            for (index, kind) in kinds.enumerated() {
                let ordinal = index + 1
                entries.append(PreparationJournalEntry(
                    id: "\(requestID)|ads.detect.span.\(ordinal)#\(attempt)",
                    itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(
                        stage: .assembling, detail: "span \(ordinal)", fraction: 0.5, cancellable: true,
                        emittedAt: Timestamp(origin.addingTimeInterval(Double(emitted))),
                        evidence: try PreparationEvidence(kind: "advertisement", fields: [
                            "ordinal": String(ordinal), "startSeconds": "10.000",
                            "endSeconds": "40.000", "label": "sponsor", "confidence": "0.9000",
                            "removalKind": kind
                        ])
                    )
                ))
                emitted += 1
            }
        }
        let terminal = try PreparationStatus(
            stage: .completed, detail: "Prepared.", fraction: 1, cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .succeeded, revisionID: RevisionID(rawValue: "rev-kind-summary")
            ),
            emittedAt: Timestamp(origin.addingTimeInterval(Double(emitted)))
        )
        entries.append(PreparationJournalEntry(
            id: "\(requestID)|pipeline.complete", itemID: itemID, requestID: requestID, status: terminal
        ))
        return PreparationRunSummary(
            requestID: requestID, itemID: itemID,
            startedAt: Timestamp(origin), updatedAt: terminal.emittedAt,
            stage: .completed, detail: "Prepared.", fraction: 1, isTerminal: true,
            outcome: .succeeded, failure: nil, entries: entries
        )
    }

}
