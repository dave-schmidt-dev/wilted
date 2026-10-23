import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The Larder's Prepare Again controls: which rows offer them, what they start,
/// and what a failed re-preparation leaves behind. The staged run on a cut
/// episode is in `WiltedMacModelTests+PrepareAgainRun`.
extension WiltedMacModelTests {
    /// A worker that fails the run without touching the store. The pipeline's
    /// own failure path journals the attempt; nothing about the prepared audio
    /// changes.
    private struct FailingRepreparationRunner: PodcastPipelineRunning {
        func run(
            request: Data,
            onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
        ) async throws -> Data {
            throw PodcastPreparationError.workerUnavailable("test worker refused the run")
        }
    }

    /// What the store would offer for `id`: a ready revision and the enclosure
    /// to fetch again. The model only reads which episodes have one.
    func prepareAgainCandidate(_ id: String, isCut: Bool = true) throws -> PodcastPrepareAgainCandidate {
        let itemID = try ItemID(rawValue: id)
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let revision = try AudioRevision(
            itemID: itemID, revisionID: try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64)),
            durationSeconds: 12, byteCount: 5, contentHash: hash, mediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)), schemaVersion: 3
        )
        return PodcastPrepareAgainCandidate(
            episodeID: itemID,
            readyRevision: StoredAudioRevision(revision: revision, mediaURL: URL(fileURLWithPath: "/dev/null")),
            isCut: isCut, keptTimeline: nil, sourceHash: nil,
            enclosureURL: try XCTUnwrap(URL(string: "https://media.example.test/\(id).mp3"))
        )
    }

    /// The journal an older pipeline left when it could not resolve an ad: the
    /// worker's `uncertain` result and the succeeded terminal that kept the
    /// original audio.
    private func seedKeptAdsRun(
        in store: LocalLibraryStore, episodeID: ItemID, revisionID: RevisionID, at date: Date
    ) async throws {
        let requestID = PodcastPreparationPipeline.requestID(for: episodeID)
        let evidence = try PreparationEvidence(kind: "worker-result", fields: ["adRemovalOutcome": "uncertain"])
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|pipeline.result#2", itemID: episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .assembling, detail: "audio unchanged", cancellable: true,
                emittedAt: Timestamp(date), evidence: evidence
            )
        ))
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Prepared.", cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                emittedAt: Timestamp(date.addingTimeInterval(1))
            )
        ))
    }

    private func preparedEpisode(
        _ id: String, download: WiltedMacEpisodeDownloadState = .completed
    ) -> WiltedMacEpisode {
        destinationEpisode(id, download: download, preparation: .prepared(summary: "Ready"))
    }

    // MARK: canPrepareAgain

    func testCanPrepareAgainRequiresAStoreCandidateAndAnIdleRow() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let eligible = preparedEpisode("prepare-again-eligible")
        let ineligible = preparedEpisode("prepare-again-ineligible")
        model.installEpisodeForTesting(eligible)
        model.installEpisodeForTesting(ineligible)
        model.prepareAgainCandidates = [eligible.id: try prepareAgainCandidate(eligible.id)]

        XCTAssertTrue(model.canPrepareAgain(eligible))
        XCTAssertFalse(model.canPrepareAgain(ineligible),
                       "the store's candidate, not the row's appearance, decides")

        // The episode in the player is the audio being heard: its cut stays.
        model.currentPodcastEpisodeID = eligible.id
        XCTAssertFalse(model.canPrepareAgain(eligible), "loaded in the player")
        model.currentPodcastEpisodeID = ineligible.id
        XCTAssertTrue(model.canPrepareAgain(eligible), "another episode loaded does not matter")
        model.currentPodcastEpisodeID = nil

        // A run this process started.
        let running = Task {}
        model.podcastPreparationTasks[eligible.id] = running
        XCTAssertFalse(model.canPrepareAgain(eligible), "a run is already in flight")
        model.podcastPreparationTasks[eligible.id] = nil

        // A run waiting for the one preparation slot.
        model.preparationQueue.enter(WiltedMacWaitingPreparation(
            id: eligible.id, title: eligible.title, source: eligible.feedTitle
        ))
        XCTAssertFalse(model.canPrepareAgain(eligible), "a queued run already owns this episode")
        model.preparationQueue.leave(eligible.id)
        XCTAssertTrue(model.canPrepareAgain(eligible))

        // A download replacing the source the run would read.
        var downloading = eligible
        downloading.downloadState = .downloading(received: 1, expected: 2)
        XCTAssertFalse(model.canPrepareAgain(downloading), "the source is being replaced")
    }

    func testPrepareAgainOnAnIneligibleEpisodeStartsNothing() async throws {
        let directory = temporaryDirectory("prepare-again-ineligible")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = preparedEpisode("prepare-again-not-kept-ads")
        model.installEpisodeForTesting(episode)

        model.prepareAgain(episode)

        XCTAssertTrue(model.podcastPreparationTasks.isEmpty, "nothing may be started for an ineligible row")
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertEqual(model.episodes.first { $0.id == episode.id }?.preparationState,
                       WiltedMacEpisodePreparationState.prepared(summary: "Ready"),
                       "the row is left exactly as it was")
    }

    // MARK: prepareAgainAll

    func testPrepareAgainAllStartsOneRunPerEligibleEpisodeInLarderOrder() async throws {
        let directory = temporaryDirectory("prepare-again-all")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episodes = ["prepare-again-one", "prepare-again-two", "prepare-again-three"].map { preparedEpisode($0) }
        episodes.forEach(model.installEpisodeForTesting)
        // The Larder's order is the queue's order, not the library's.
        for index in [2, 0, 1] { model.seedPodcastQueueMembershipForTesting(episodes[index]) }
        model.prepareAgainCandidates = Dictionary(uniqueKeysWithValues: try episodes.map {
            ($0.id, try prepareAgainCandidate($0.id, isCut: false))
        })
        XCTAssertEqual(model.episodesToPrepareAgain.map(\.id),
                       [episodes[2].id, episodes[0].id, episodes[1].id])

        model.prepareAgainAll()

        XCTAssertEqual(Set(model.podcastPreparationTasks.keys), Set(episodes.map(\.id)),
                       "every eligible episode gets exactly one run")
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episodes[0].id, episodes[1].id],
                       "the slot holds the first Larder row; the rest wait in that order")
        await model.waitForPodcastPreparationOperationsForTesting()
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    // MARK: Wording

    func testTheFileCommandAndItsConfirmationNameTheCountAndTheKeptPlace() {
        XCTAssertEqual(WiltedMacModel.prepareAgainCommandTitle(count: 3),
                       "Prepare Again With Current Engine (3)\u{2026}")
        XCTAssertEqual(WiltedMacModel.prepareAgainConfirmationTitle(count: 3), "Prepare 3 episodes again?")
        XCTAssertEqual(
            WiltedMacModel.prepareAgainConfirmationMessage,
            "Wilted downloads the original audio where needed and removes ads with the current engine. "
                + "Your place in each is kept.")
    }

    // MARK: A failed re-preparation

    /// The episode was already prepared, so a failed second run has to leave the
    /// audio it is playing and its durable outcome alone. The row offers Retry,
    /// and nothing pretends the episode became unprepared.
    func testAFailedRepreparationKeepsThePreparedAudioAndOffersRetry() async throws {
        let directory = temporaryDirectory("prepare-again-failure")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try await installPreparedLarderEpisode(
            into: store, directory: directory, suffix: "prepare-again-failure",
            durationSeconds: 600, playbackSeconds: 90
        )
        let prepared = try await store.readyRevision(for: episodeID)
        let storedRevision = try XCTUnwrap(prepared)
        try await seedKeptAdsRun(
            in: store, episodeID: episodeID, revisionID: storedRevision.revision.revisionID,
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, storeBootstrap: { _ in store },
            podcastPipelineRunnerFactory: { FailingRepreparationRunner() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertNotNil(model.prepareAgainCandidates[episode.id],
                        "the library load reads the candidates from the store")
        XCTAssertTrue(model.canPrepareAgain(episode))

        model.prepareAgain(episode)
        await model.waitForPodcastPreparationOperationsForTesting()

        let row = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        guard case .failed = row.preparationState else {
            return XCTFail("a failed re-preparation must offer Retry, not read as prepared")
        }
        XCTAssertNotNil(model.preparationFailureCauses[episode.id])
        XCTAssertTrue(row.isReadyMediaAvailable, "the prepared audio is still on disk")

        // Nothing durable about the prepared episode changed: the same revision
        // is ready and it is still a current preparation outcome, so the row
        // plays after Retry or a relaunch.
        let readyAfterValue = try await store.readyRevision(for: episodeID)
        let readyAfter = try XCTUnwrap(readyAfterValue)
        XCTAssertEqual(readyAfter.revision.revisionID, storedRevision.revision.revisionID)
        XCTAssertEqual(readyAfter.mediaURL, storedRevision.mediaURL)
        let outcomeAfter = try await store.preparationOutcome(
            for: episodeID, revisionID: storedRevision.revision.revisionID
        )
        XCTAssertEqual(outcomeAfter?.eligibility, PodcastPreparationEligibility.current)
        let playbackAfter = try await store.playbackState(
            for: episodeID, revisionID: storedRevision.revision.revisionID
        )
        XCTAssertEqual(playbackAfter?.positionSeconds, 90)
    }
}
