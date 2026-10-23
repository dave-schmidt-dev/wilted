import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Preparing a cut episode again from a staged copy of its original: what the
/// Larder row shows while it runs, and what a run that changes nothing leaves.
/// The commit itself is covered where the pipeline is (`WiltedProducerTests`).
extension WiltedMacModelTests {
    private struct CutFixture {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let episodeID: ItemID
        let directory: URL
        let enclosure: URL
    }

    /// A model over a store holding one ready, never-journalled episode: the
    /// store offers it as a cut, because nothing proves it is the original.
    private func cutFixture(
        _ suffix: String, playbackSeconds: TimeInterval = 0,
        transport: @escaping @Sendable (URL) -> any PodcastDownloadTransporting,
        runner: any PodcastPipelineRunning
    ) async throws -> CutFixture {
        let directory = temporaryDirectory("prepare-again-run-\(suffix)")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try await installPreparedLarderEpisode(
            into: store, directory: directory, suffix: suffix, durationSeconds: 12, playbackSeconds: playbackSeconds
        )
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/larder-admission-\(suffix).mp3"))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, storeBootstrap: { _ in store },
            podcastDownloadTransportFactory: { transport(enclosure) },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            podcastPipelineRunnerFactory: { runner },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return CutFixture(model: model, store: store, episodeID: episodeID, directory: directory, enclosure: enclosure)
    }

    private func stagedFiles(under directory: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? [])
            .filter { $0.deletingLastPathComponent().lastPathComponent == ".podcast-staging" }
            .map(\.lastPathComponent)
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testAStagedRunKeepsTheCutReadyAndShowsItsStageOnTheRow() async throws {
        let runner = BlockingPodcastPipelineRunner()
        let body = Data("a different original".utf8)
        let fixture = try await cutFixture("staged", transport: { enclosure in
            StubPodcastDownloadTransport(events: [
                .response(.init(url: enclosure, statusCode: 200, mediaType: "audio/mpeg",
                                expectedByteCount: Int64(body.count))),
                .data(body),
            ])
        }, runner: runner)
        let model = fixture.model
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertEqual(model.prepareAgainCandidates[episode.id]?.isCut, true)
        let readyBefore = try await fixture.store.readyRevision(for: fixture.episodeID)
        let ready = try XCTUnwrap(readyBefore)

        model.prepareAgain(episode)
        try await eventually("the original to be staged and the engine to start") {
            model.prepareAgainRows[episode.id]?.phase == .preparing
        }

        // The old cut is still the episode: playable, in the group that has Play.
        let during = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertFalse(during.preparationState.isRunning, "the cut is not taken out of Ready for the run")
        XCTAssertEqual(WiltedMacModel.larderGroup(for: during), .playable)
        XCTAssertEqual(model.prepareAgainRows[episode.id]?.label, "Removing ads with the current engine")
        XCTAssertEqual(stagedFiles(under: fixture.directory).count, 1, "the original is held while the engine runs")
        XCTAssertFalse(model.canPrepareAgain(during), "a second press cannot start a second run")

        await runner.resume(throwing: PodcastPreparationError.workerUnavailable("test worker refused the run"))
        await model.waitForPodcastPreparationOperationsForTesting()

        let after = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        if case .failed = after.preparationState { XCTFail("a failed cut is not a failed episode: Retry would prepare over it") }
        XCTAssertEqual(model.prepareAgainRows[episode.id]?.phase, .note("Preparing again failed, so nothing changed"))
        XCTAssertEqual(model.prepareAgainRows[episode.id]?.isRunning, false)
        XCTAssertNil(model.preparationFailureCauses[episode.id])
        let readyAfter = try await fixture.store.readyRevision(for: fixture.episodeID)
        XCTAssertEqual(readyAfter, ready, "the old cut is the ready revision, untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.mediaURL.path))
        XCTAssertTrue(stagedFiles(under: fixture.directory).isEmpty, "the staged original is deleted")
        XCTAssertNil(model.prepareAgainCandidates[episode.id], "the engine ran, so it is not offered again")
    }

    func testAnOriginalThatCannotBeDownloadedLeavesTheCutAndStaysOffered() async throws {
        let fixture = try await cutFixture(
            "download-fails",
            transport: { FailingPodcastDownloadTransport(enclosureURL: $0, statusCode: 503) },
            runner: CancellingPodcastPipelineRunner()
        )
        let model = fixture.model
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID.rawValue })

        model.prepareAgain(episode)
        await model.waitForPodcastPreparationOperationsForTesting()

        XCTAssertEqual(model.prepareAgainRows[episode.id]?.phase,
                       .note("Could not download the original, so nothing changed"))
        let after = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertEqual(WiltedMacModel.larderGroup(for: after), .playable)
        XCTAssertTrue(stagedFiles(under: fixture.directory).isEmpty)
        XCTAssertTrue(model.canPrepareAgain(after), "nothing was decided, so the offer stands")
    }

    func testARunThatCannotCarryThePlaceShowsItsReasonAndNoRetry() async throws {
        let attempts = DownloadAttemptCounter()
        let fixture = try await cutFixture(
            "refused", playbackSeconds: 90,
            transport: { CountingFailingPodcastDownloadTransport(enclosureURL: $0, statusCode: 503, counter: attempts) },
            runner: CancellingPodcastPipelineRunner()
        )
        let model = fixture.model
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID.rawValue })
        XCTAssertEqual(episode.playbackSeconds, 90)

        model.prepareAgain(episode)
        await model.waitForPodcastPreparationOperationsForTesting()

        // Nothing records what the cut removed, so the place cannot be walked
        // back to the original: refused before spending the download.
        XCTAssertEqual(attempts.count, 0)
        XCTAssertEqual(model.prepareAgainRows[episode.id]?.label,
                       "This episode's old cut has no record of what was removed")
        let after = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        if case .failed = after.preparationState { XCTFail("a refusal is not a failure: the row would offer Retry") }
        XCTAssertEqual(WiltedMacModel.larderGroup(for: after), .playable)
        XCTAssertNil(model.preparationFailureCauses[episode.id])
        XCTAssertEqual(after.playbackSeconds, 90, "the listener's place is where it was")
        XCTAssertNil(model.prepareAgainCandidates[episode.id], "tried by the current engine, so not offered again")
        XCTAssertFalse(model.canPrepareAgain(after))
    }

    /// A bulk run can wait for the slot while the listener loads the episode.
    func testAnEpisodeLoadedInThePlayerBeforeItsTurnIsLeftAsItIs() async throws {
        let attempts = DownloadAttemptCounter()
        let fixture = try await cutFixture(
            "loaded-first",
            transport: { CountingFailingPodcastDownloadTransport(enclosureURL: $0, statusCode: 503, counter: attempts) },
            runner: CancellingPodcastPipelineRunner()
        )
        let model = fixture.model
        let episode = try XCTUnwrap(model.episodes.first { $0.id == fixture.episodeID.rawValue })

        model.prepareAgain(episode)
        // The run's task has not started; the listener loads the episode first.
        model.currentPodcastEpisodeID = episode.id
        await model.waitForPodcastPreparationOperationsForTesting()

        XCTAssertEqual(attempts.count, 0, "nothing was downloaded for an episode being heard")
        XCTAssertEqual(model.prepareAgainRows[episode.id]?.label, "Playing now, so it was left as it is")
        let after = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertEqual(WiltedMacModel.larderGroup(for: after), .playable)
        XCTAssertTrue(stagedFiles(under: fixture.directory).isEmpty)
    }

    func testDownloadProgressShowsOnTheRowUntilTheOriginalIsHere() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let id = "prepare-again-progress"
        model.showPreparationAdmitted(id, queued: true, again: true)
        XCTAssertEqual(model.prepareAgainRows[id]?.label, "Waiting for the preparation in flight")

        model.showPrepareAgainDownload(id, PodcastDownloadProgress(
            stage: .transferring, bytesReceived: 25, expectedByteCount: 100))
        XCTAssertEqual(model.prepareAgainRows[id]?.fraction, 0.25)
        XCTAssertEqual(model.prepareAgainRows[id]?.label, "Downloading the original · 25%")

        model.showPrepareAgainDownload(id, PodcastDownloadProgress(
            stage: .transferring, bytesReceived: 40, expectedByteCount: nil))
        XCTAssertNil(model.prepareAgainRows[id]?.fraction, "no declared size, no percentage")
        XCTAssertEqual(model.prepareAgainRows[id]?.label, "Downloading the original")

        model.showPrepareAgainDownload(id, PodcastDownloadProgress(
            stage: .completed, bytesReceived: 100, expectedByteCount: 100))
        XCTAssertEqual(model.prepareAgainRows[id]?.phase, .preparing)

        // A report that was already on its way cannot pull the row back.
        model.showPrepareAgainDownload(id, PodcastDownloadProgress(
            stage: .transferring, bytesReceived: 90, expectedByteCount: 100))
        XCTAssertEqual(model.prepareAgainRows[id]?.phase, .preparing)

        model.finishPrepareAgainRow(id)
        XCTAssertNil(model.prepareAgainRows[id], "a live line ends with the run")
        model.prepareAgainRows[id] = WiltedMacPrepareAgainRow(phase: .note("why"))
        model.finishPrepareAgainRow(id)
        XCTAssertEqual(model.prepareAgainRows[id]?.label, "why", "a note stays for the listener")
    }
}
