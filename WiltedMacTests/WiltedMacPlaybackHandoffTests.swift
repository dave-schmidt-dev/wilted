import Foundation
import SwiftUI
import WiltedDomain
@testable import WiltedMac
import WiltedProducer
import XCTest

@MainActor
private final class RecordingNowPlayingSink: WiltedNowPlayingSink {
    private(set) var published: [WiltedNowPlayingInfo] = []

    func publish(_ info: WiltedNowPlayingInfo) {
        published.append(info)
    }

    func clear() {}
}

@MainActor
final class WiltedMacPlaybackHandoffTests: XCTestCase {
    func testPlayingAnEpisodePublishesItBeforeItsTranscriptLoads() async throws {
        let (model, sink, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let first = try await addReadyEpisode(after: fixture, to: model, in: directory,
                                             suffix: "publication-first", durationSeconds: 10)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()

        let second = try await addReadyEpisode(after: first, to: model, in: directory)
        let publicationCount = sink.published.count
        model.playEpisode(second)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(sink.published.dropFirst(publicationCount).first?.episodeID, second.id)
        XCTAssertTrue(sink.published.dropFirst(publicationCount).first?.isPlaying ?? false)

        // Runtime ordering: publication already names new audio even while presentation is held.
        let gate = WiltedMacCommandGate()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        gate.arm()
        model.playEpisode(first)
        await gate.waitUntilHeld()
        XCTAssertEqual(sink.published.last?.episodeID, first.id)
        XCTAssertTrue(sink.published.last?.isPlaying ?? false)
        gate.release()
        await model.waitForPlaybackPresentationForTesting()
        await model.close()
    }

    func testHeldOldTranscriptDoesNotDelayNewEpisodeAudioOrPublishItsState() async throws {
        let (model, sink, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let first = try await addReadyEpisode(after: fixture, to: model, in: directory,
                                             suffix: "held", durationSeconds: 10)
        let second = try await addReadyEpisode(after: first, to: model, in: directory,
                                              suffix: "new", durationSeconds: 10)
        let gate = WiltedMacCommandGate()
        gate.arm()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.playEpisode(first)
        await gate.waitUntilHeld()
        let firstToken = model.playbackCommands.generation
        model.playEpisode(second)
        let secondToken = model.playbackCommands.generation
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playback?.itemID?.rawValue, second.id)
        XCTAssertTrue(model.playback?.isPlaying ?? false, "new audio starts while old transcript is held")
        XCTAssertEqual(sink.published.last?.episodeID, second.id)
        let wait = try XCTUnwrap(model.playbackCommands.trace.measuredWait(.acknowledgedToPlayCalled, token: secondToken))
        XCTAssertLessThan(Double(wait) / 1_000_000, Double(WiltedMacPlaybackTrace.preAudioTargetMilliseconds))
        await model.waitForPlaybackPresentationForTesting()
        let current = model.currentTranscript
        try await Task.sleep(for: .milliseconds(500))
        gate.release()
        // Close must also join the cancelled old request, which is still in the ledger.
        await model.close()
        XCTAssertEqual(model.currentTranscript, current)
        XCTAssertEqual(model.currentPodcastEpisodeID, second.id)
        let trace = model.playbackCommands.trace
        XCTAssertLessThan(try XCTUnwrap(trace.offsetNanos(.playCalled, token: secondToken)),
                          try XCTUnwrap(trace.offsetNanos(.transcriptTailEnded, token: firstToken)))
        print(trace.report())
        retainTraceReport(trace.report(), name: "Held old presentation and newer audio call boundaries")
    }

    /// Reported 2026-10-26: Pause, then Mark completed, started the next episode.
    /// Paused means "not now", so finishing a paused episode leaves the player stopped.
    func testMarkingAPausedEpisodeCompleteDoesNotStartTheNext() async throws {
        let (model, _, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let first = try await addReadyEpisode(
            after: fixture, to: model, in: directory,
            suffix: "first", durationSeconds: 10
        )
        let second = try await addReadyEpisode(after: first, to: model, in: directory)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, first.id)
        model.addEpisodeToUpNext(second)
        try await waitUntil { model.podcastQueueIDs.contains(second.id) }
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.isPlaying)

        model.markCurrentPlaybackCompleted()
        XCTAssertFalse(model.isAutomaticAdvancing, "no Loading next episode… for a paused finish")
        try await waitUntil { model.episodes.first { $0.id == first.id }?.isPlayed == true }
        await model.waitForPlaybackOperationForTesting()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNotEqual(model.currentPodcastEpisodeID, second.id, "the next episode was not loaded")
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertTrue(model.podcastQueueIDs.contains(second.id), "the next episode is still waiting in the Larder")
    }

    func testMarkingCompleteAdvancesTheWidgetToTheNextEpisode() async throws {
        let (model, sink, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        // The seeded fixture has a placeholder media file. Use a playable
        // episode so completion exercises the controller's real handoff.
        let first = try await addReadyEpisode(
            after: fixture, to: model, in: directory,
            suffix: "first", durationSeconds: 10
        )
        let second = try await addReadyEpisode(after: first, to: model, in: directory)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, first.id)
        model.addEpisodeToUpNext(second)
        try await waitUntil { model.podcastQueueIDs.contains(second.id) }
        XCTAssertTrue(
            model.podcastQueueIDs.contains(second.id),
            "B was not queued: \(model.playbackOperationStatus ?? "no status")"
        )

        let queueGate = QueueBarrierGate()
        addTeardownBlock { await queueGate.release() }
        model.podcastQueueReadBarrierForTesting = { await queueGate.holdUntilReleased() }
        defer { model.podcastQueueReadBarrierForTesting = nil }

        model.playbackError = "Previous operation failed"
        model.markCurrentPlaybackCompleted()
        try await waitUntilHeld(queueGate)
        try await waitUntil { model.currentPodcastEpisodeID == nil }

        // Deterministically assert old row removed and loading feedback active while held.
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertFalse(model.hasCurrentPlayback)
        let firstEpisode = model.episodes.first(where: { $0.id == first.id })
        XCTAssertTrue(try XCTUnwrap(firstEpisode).isPlayed)
        XCTAssertTrue(model.isAutomaticAdvancing)
        XCTAssertEqual(model.playbackStatusMessage, "Loading next episode…")
        XCTAssertEqual(model.playbackStatusTone, .caution)

        let pane = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
        let paneLines = try WiltedMacHeadless.recognizedText(pane)
        let paneText = paneLines.joined(separator: " ").replacingOccurrences(of: "...", with: "…")
        XCTAssertTrue(paneText.contains("Loading next episode…"), paneText)
        let paneBitmap = try WiltedMacHeadless.render(pane)
        let paneColors = WiltedMacHeadless.distinctColorCount(in: paneBitmap)
        XCTAssertGreaterThan(paneColors, 1)
        let attachment = XCTAttachment(data: try XCTUnwrap(paneBitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "next-episode-loading-pane"
        attachment.lifetime = .keepAlways
        add(attachment)

        let rail = WiltedMacPlayerContent(
            model: model, presentation: .constant(nil), layout: .rail,
            focusRequest: nil, onCollapse: { _ in }
        )
        let railLines = try WiltedMacHeadless.recognizedText(rail)
        let railText = railLines.joined(separator: " ").replacingOccurrences(of: "...", with: "…")
        XCTAssertTrue(railText.contains("Loading next episode…"), railText)

        // Release queue barrier: next starts and loading clears.
        await queueGate.release()
        try await waitUntil { model.currentPodcastEpisodeID == second.id }
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.currentPodcastEpisodeID, second.id)
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertEqual(model.playbackStatusMessage, "Playing")
        XCTAssertEqual(sink.published.last?.episodeID, second.id)
        let isSinkPlaying = sink.published.last?.isPlaying ?? false
        XCTAssertTrue(isSinkPlaying)
    }

    func testPauseDuringAutomaticAdvanceCancelsLoaderAndBlocksRestart() async throws {
        let (model, sink, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let first = try await addReadyEpisode(
            after: fixture, to: model, in: directory,
            suffix: "pause-first", durationSeconds: 10
        )
        let second = try await addReadyEpisode(
            after: first, to: model, in: directory,
            suffix: "pause-second", durationSeconds: 10
        )
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, first.id)
        model.addEpisodeToUpNext(second)
        try await waitUntil { model.podcastQueueIDs.contains(second.id) }

        let queueGate = QueueBarrierGate()
        addTeardownBlock { await queueGate.release() }
        model.podcastQueueReadBarrierForTesting = { await queueGate.holdUntilReleased() }
        defer { model.podcastQueueReadBarrierForTesting = nil }

        model.markCurrentPlaybackCompleted()
        try await waitUntilHeld(queueGate)
        try await waitUntil { model.currentPodcastEpisodeID == nil }

        XCTAssertTrue(model.isAutomaticAdvancing)
        XCTAssertEqual(model.playbackStatusMessage, "Loading next episode…")

        // Pause supersedes advance and cancels loader immediately.
        model.pausePlayback()
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertNil(model.playbackCommands.automaticAdvance)
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")

        await queueGate.release()
        await WiltedMacHeadless.drainDecisions(model)
        await model.waitForPlaybackOperationForTesting()

        // Restart is blocked, settling idle with nothing playing.
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")
        XCTAssertNotEqual(sink.published.last?.episodeID, second.id)
    }

    func testCompletionFailureClearsOwnedAdvanceAndRestoresState() async throws {
        let (model, _, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let first = try await addReadyEpisode(
            after: fixture, to: model, in: directory,
            suffix: "fail-first", durationSeconds: 10
        )
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, first.id)

        struct InjectedFailure: Error {}
        model.subscriptionWriteHookForTesting = { throw InjectedFailure() }
        defer { model.subscriptionWriteHookForTesting = nil }

        model.markCurrentPlaybackCompleted()
        await WiltedMacHeadless.drainDecisions(model)
        await model.waitForPlaybackOperationForTesting()

        // Failed completion cleared the owned advance without leaving marker.
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertNil(model.playbackCommands.automaticAdvance)
        XCTAssertNotEqual(model.playbackStatusMessage, "Loading next episode…")
        let operation = model.podcastOperationMessage ?? ""
        XCTAssertTrue(operation.contains("could not be marked completed"), operation)
    }

    func testMarkingCompleteAtEndOfQueueSettlesIdleWithoutStartingAudio() async throws {
        let (model, _, directory) = makeModel()
        let fixture = try XCTUnwrap(model.episodes.first)
        let only = try await addReadyEpisode(
            after: fixture, to: model, in: directory,
            suffix: "endqueue", durationSeconds: 10
        )
        model.playEpisode(only)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, only.id)

        let queueGate = QueueBarrierGate()
        addTeardownBlock { await queueGate.release() }
        model.podcastQueueReadBarrierForTesting = { await queueGate.holdUntilReleased() }
        defer { model.podcastQueueReadBarrierForTesting = nil }

        model.markCurrentPlaybackCompleted()
        try await waitUntilHeld(queueGate)
        try await waitUntil { model.currentPodcastEpisodeID == nil }

        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertTrue(model.isAutomaticAdvancing)
        XCTAssertEqual(model.playbackStatusMessage, "Loading next episode…")

        await queueGate.release()
        await WiltedMacHeadless.drainDecisions(model)
        await model.waitForPlaybackOperationForTesting()

        // Settles idle because there are no more episodes in queue.
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertFalse(model.isAutomaticAdvancing)
        XCTAssertNil(model.playbackCommands.automaticAdvance)
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")
    }

    private func makeModel() -> (WiltedMacModel, RecordingNowPlayingSink, URL) {
        let sink = RecordingNowPlayingSink()
        let directory = wiltedTemporaryDirectory("playback-handoff")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            nowPlayingSink: sink,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        return (model, sink, directory)
    }

    /// Adds a second ready episode through the same store the fixture model reads.
    private func addReadyEpisode(
        after first: WiltedMacEpisode, to model: WiltedMacModel, in directory: URL,
        suffix: String = "second", durationSeconds: Int = 1
    ) async throws -> WiltedMacEpisode {
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let deadline = ContinuousClock.now + .seconds(10)
        var maybeStoredFirst: PodcastEpisode?
        while maybeStoredFirst == nil && ContinuousClock.now < deadline {
            let persisted = try await store.podcastEpisodes()
            maybeStoredFirst = persisted.first { $0.itemID.rawValue == first.id }
            if maybeStoredFirst == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let storedFirst = try XCTUnwrap(maybeStoredFirst)
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/playback-handoff-\(suffix).mp3"))
        let itemID = try ItemID.derivePodcastEpisode(
            feedURL: storedFirst.feedURL, rssGUID: "playback-handoff-\(suffix)", enclosureURL: enclosureURL
        )
        try await store.save(episode: PodcastEpisode(
            itemID: itemID,
            feedID: storedFirst.feedID,
            feedURL: storedFirst.feedURL,
            rssGUID: "playback-handoff-\(suffix)",
            title: "\(suffix.capitalized) handoff episode",
            publishedTime: storedFirst.publishedTime,
            enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date())
        ))
        // Real audio: the controller has to load and start this episode, and
        // a placeholder file fails that load and never reaches the widget.
        let mediaURL = directory.appendingPathComponent("playback-handoff-\(suffix).m4a")
        // Revision identity is derived from audio bytes, so distinct items need distinct content.
        let toneHz = 220 + Double(suffix.utf8.reduce(0) { $0 + Int($1) })
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * durationSeconds)).map {
                Float(0.2 * sin(2 * Double.pi * toneHz * Double($0) / 44_100))
            },
            itemID: itemID, destinationURL: mediaURL
        )
        // Downloaded and prepared in the store, not just on the model: marking
        // the first episode complete reloads every row from the store, and a
        // row with no download or outcome comes back unplayable.
        try await store.finalizePodcastDownload(
            revision: assembled.revision, mediaURL: mediaURL,
            download: try PodcastDownload(
                episodeID: itemID, status: .completed,
                bytesReceived: assembled.revision.byteCount,
                expectedByteCount: assembled.revision.byteCount,
                localURL: mediaURL, contentHash: assembled.revision.contentHash,
                updatedAt: Timestamp(Date())
            )
        )
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: itemID, revisionID: assembled.revision.revisionID, policyDigest: "handoff-policy",
            pipelineFingerprint: "handoff-fingerprint", semanticVersion: "handoff-semantic-version",
            producedAt: Timestamp(Date())
        ))
        let episode = WiltedMacEpisode(
            id: itemID.rawValue,
            title: "\(suffix.capitalized) handoff episode",
            feedTitle: first.feedTitle,
            summary: "Playback handoff fixture.",
            artworkURL: nil,
            releasedAt: first.releasedAt,
            durationSeconds: TimeInterval(durationSeconds),
            playbackSeconds: 0,
            downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        model.installEpisodeForTesting(episode)
        return episode
    }

    // TRACE 1.1: catalog-scan timing excludes actor mailbox wait. This records
    // fetch/decode samples; the causal contention fixture belongs to Task 1.2.
    func testScaledCatalogScanTimingReportsFetchAndDecodeSamples() async throws {
        let directory = wiltedTemporaryDirectory("store-scan-trace")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await addScaledCatalog(to: store, in: directory, itemCount: 1)
        let itemID = try ItemID(rawValue: "trace-scale-item-0")
        let revisionID = try RevisionID(rawValue: "trace-scale-revision-0")
        LocalLibraryStoreStageTrace.reset()
        LocalLibraryStoreStageTrace.isEnabled = true
        defer { LocalLibraryStoreStageTrace.isEnabled = false }

        for _ in 0..<6 {
            _ = try await store.readyRevision(for: itemID)
            _ = try await store.transcript(for: itemID, revisionID: revisionID)
        }
        let oneRowReport = "catalog rows=1\n" + LocalLibraryStoreStageTrace.report()
        print(oneRowReport)
        retainTraceReport(oneRowReport, name: "Store playback reads at one row")
        let baseline = LocalLibraryStoreStageTrace.summaries()
        let baselineFetch = try XCTUnwrap(baseline.first { $0.stage == .revisionFetch })
        XCTAssertGreaterThanOrEqual(baselineFetch.sampleCount, 6)

        try await addScaledCatalog(to: store, in: directory, itemCount: 160)

        LocalLibraryStoreStageTrace.reset()
        for _ in 0..<6 {
            _ = try await store.readyRevision(for: itemID)
            _ = try await store.transcript(for: itemID, revisionID: revisionID)
        }
        let scaled = LocalLibraryStoreStageTrace.summaries()
        let scaledFetch = try XCTUnwrap(scaled.first { $0.stage == .revisionFetch })
        XCTAssertGreaterThanOrEqual(scaledFetch.sampleCount, baselineFetch.sampleCount)
        let decode = try XCTUnwrap(scaled.first { $0.stage == .transcriptDecode })
        XCTAssertGreaterThanOrEqual(decode.sampleCount, 6)
        let scaledReport = "catalog rows=160\n" + LocalLibraryStoreStageTrace.report()
        print(scaledReport)
        retainTraceReport(scaledReport, name: "Store playback reads at 160 rows")
    }

    /// Adds synthetic ready revisions and transcripts for higher item IDs, so
    /// the store's whole-table fetches scale without touching real media.
    private func addScaledCatalog(to store: LocalLibraryStore, in directory: URL, itemCount: Int) async throws {
        for offset in 0..<itemCount {
            let itemID = try ItemID(rawValue: "trace-scale-item-\(offset)")
            let revisionID = try RevisionID(rawValue: "trace-scale-revision-\(offset)")
            try await store.saveReadyRevision(
                try AudioRevision(
                    itemID: itemID, revisionID: revisionID,
                    durationSeconds: 600, byteCount: 1_024,
                    contentHash: "sha256:" + String(repeating: "a", count: 64),
                    mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1
                ),
                mediaURL: directory.appendingPathComponent("trace-scale-\(offset).m4a")
            )
            try await store.save(transcript: try Transcript(
                itemID: itemID, revisionID: revisionID, availability: .available,
                text: "Synthetic transcript \(offset) exists only to scale the store fixture.",
                updatedAt: Timestamp(Date())
            ))
        }
    }

    private func waitUntilHeld(_ gate: QueueBarrierGate) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await gate.isHeld()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Completion never reached the held queue refresh")
                throw HandoffWaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Polls until a background task has produced the state under test.
    private func waitUntil(
        timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met within \(timeout)", file: file, line: line)
                throw HandoffWaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func retainTraceReport(_ report: String, name: String) {
        let attachment = XCTAttachment(string: report)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

private struct HandoffWaitTimeout: Error {}

private actor QueueBarrierGate {
    private var held = false
    private var released = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func holdUntilReleased() async {
        guard !released else { return }
        held = true
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func isHeld() -> Bool { held }

    func release() {
        released = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }
}
