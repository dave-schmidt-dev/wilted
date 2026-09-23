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
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testPlayingAnEpisodePublishesItBeforeItsTranscriptLoads() async throws {
        let (model, sink, directory) = makeModel()
        let first = try XCTUnwrap(model.episodes.first)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()

        let second = try await addReadyEpisode(after: first, to: model, in: directory)
        let publicationCount = sink.published.count
        model.playEpisode(second)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(sink.published.dropFirst(publicationCount).first?.episodeID, second.id)
        XCTAssertTrue(sink.published.dropFirst(publicationCount).first?.isPlaying ?? false)

        // The fixture's transcript load finishes before anything could observe the
        // gap, so the ordering itself is pinned: the forced publish for the new
        // episode comes before the first await that can take real time.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        let body = try XCTUnwrap(source.range(of: "func playEpisode(_ episode: WiltedMacEpisode)"))
        let rest = source[body.upperBound...]
        let publish = try XCTUnwrap(rest.range(of: "self.publishNowPlaying(force: true)"))
        let queueRefresh = try XCTUnwrap(rest.range(of: "await self.refreshPodcastQueueState()"))
        let transcript = try XCTUnwrap(rest.range(of: "await self.loadEpisodeTranscript(itemID: id)"))
        XCTAssertLessThan(publish.lowerBound, queueRefresh.lowerBound)
        XCTAssertLessThan(publish.lowerBound, transcript.lowerBound)
    }

    func testMarkingCompleteAdvancesTheWidgetToTheNextEpisode() async throws {
        let (model, sink, directory) = makeModel()
        let first = try XCTUnwrap(model.episodes.first)
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()

        let second = try await addReadyEpisode(after: first, to: model, in: directory)
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-playback-handoff-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
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
        after first: WiltedMacEpisode, to model: WiltedMacModel, in directory: URL
    ) async throws -> WiltedMacEpisode {
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let storedEpisodes = try await store.podcastEpisodes()
        let storedFirst = try XCTUnwrap(storedEpisodes.first { $0.itemID.rawValue == first.id })
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/playback-handoff-second.mp3"))
        let itemID = try ItemID.derivePodcastEpisode(
            feedURL: storedFirst.feedURL, rssGUID: "playback-handoff-second", enclosureURL: enclosureURL
        )
        try await store.save(episode: PodcastEpisode(
            itemID: itemID,
            feedID: storedFirst.feedID,
            feedURL: storedFirst.feedURL,
            rssGUID: "playback-handoff-second",
            title: "Second handoff episode",
            publishedTime: storedFirst.publishedTime,
            enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date())
        ))
        // Real audio: the controller has to load and start this episode, and
        // a placeholder file fails that load and never reaches the widget.
        let mediaURL = directory.appendingPathComponent("playback-handoff-second.m4a")
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
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
            title: "Second handoff episode",
            feedTitle: first.feedTitle,
            summary: "Playback handoff fixture.",
            artworkURL: nil,
            releasedAt: first.releasedAt,
            durationSeconds: 1,
            playbackSeconds: 0,
            downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        model.installEpisodeForTesting(episode)
        return episode
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
}
