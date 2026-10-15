import Foundation
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

        model.markCurrentPlaybackCompleted()
        // Completion runs outside the playback operation and only then starts
        // the next episode, so wait for the switch rather than a fixed delay.
        try await waitUntil { model.currentPodcastEpisodeID == second.id }
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(sink.published.last?.episodeID, second.id)
        XCTAssertTrue(sink.published.last?.isPlaying ?? false)
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

    /// Polls until a background task has produced the state under test.
    private func waitUntil(
        timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("condition not met within \(timeout)")
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
