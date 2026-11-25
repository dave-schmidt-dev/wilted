import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    func testMacCapturePersistsExactRevisionCuesAndReplaysThatRevisionOutsideLarder() async throws {
        let directory = temporaryDirectory("notebook-mac-capture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/notebook.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/notebook.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "notebook-episode", enclosureURL: enclosureURL
        )
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let firstAudioURL = directory.appendingPathComponent("notebook-first.m4a")
        let secondAudioURL = directory.appendingPathComponent("notebook-second.m4a")
        let originalCueText = "Original first cue. Original second cue."
        let playbackSamples = (0..<(44_100 * 60)).map {
            Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100))
        }

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Notebook feed",
                    createdAt: Timestamp(created)
                ))
                try await store.save(subscription: PodcastSubscription(
                    feedID: feedID, subscribedAt: Timestamp(created)
                ))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "notebook-episode",
                    title: "Notebook episode", publishedTime: Timestamp(created),
                    enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: Timestamp(created)
                ))
                let first = try AudioAssembler().assemble(
                    pcm: playbackSamples,
                    itemID: episodeID, destinationURL: firstAudioURL, createdAt: created
                )
                try await store.finalizePodcastDownload(
                    revision: first.revision, mediaURL: firstAudioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: first.revision.byteCount, expectedByteCount: first.revision.byteCount,
                        localURL: firstAudioURL, contentHash: first.revision.contentHash,
                        updatedAt: Timestamp(created)
                    )
                )
                try await store.savePreparationOutcome(PodcastPreparationOutcome(
                    episodeID: episodeID, revisionID: first.revision.revisionID,
                    policyDigest: "notebook-fixture-policy", pipelineFingerprint: "notebook-fixture-pipeline",
                    semanticVersion: "notebook-fixture-1", producedAt: Timestamp(created), eligibility: .current
                ))
                try await store.save(transcript: try Transcript(
                    itemID: episodeID, revisionID: first.revision.revisionID,
                    availability: .available, text: originalCueText, timing: .published,
                    cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "Original first cue."),
                           try TranscriptCue(startSeconds: 0.5, endSeconds: 1, text: "Original second cue.")],
                    updatedAt: Timestamp(created)
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 0.75)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertNil(model.playbackError, "the source podcast must load before the Larder removal")
        XCTAssertEqual(model.playback?.itemID, episodeID, "the player must still identify the source episode")
        XCTAssertNotNil(model.playback?.revisionID, "the player must still identify the exact loaded revision")
        let playingRevision = try XCTUnwrap(model.playback?.revisionID)
        let store = try XCTUnwrap(model.store)
        try await store.removePodcastQueueEpisode(episodeID)
        await model.refreshPodcastQueueState()
        XCTAssertFalse(model.podcastQueueIDs.contains(episodeID.rawValue), "the episode has left the durable Larder queue")
        XCTAssertEqual(model.playback?.itemID, episodeID)
        XCTAssertTrue(model.isPodcastPlayback)
        model.episodes.removeAll { $0.id == episodeID.rawValue }
        XCTAssertNil(model.currentEpisode, "capture must not depend on a Larder row")
        let captured = try await model.captureNotebookClip(now: created.addingTimeInterval(10))

        XCTAssertEqual(captured.sourceItemID, episodeID)
        XCTAssertEqual(captured.sourceRevision, playingRevision)
        XCTAssertEqual(captured.sourceTitle, "Notebook episode")
        XCTAssertEqual(captured.sourceName, "Notebook feed")
        XCTAssertEqual(captured.sourceURL, enclosureURL)
        XCTAssertEqual(captured.textExcerpt, originalCueText)
        XCTAssertEqual(captured.capturedOn, .mac)
        XCTAssertEqual(captured.startSeconds, 0)
        XCTAssertEqual(captured.endSeconds, 1)
        let notebookEntries = try await model.loadNotebookEntries()
        XCTAssertEqual(notebookEntries.map(\.id), [captured.id], "Notebook is local state outside the Larder queue")
        XCTAssertFalse(model.podcastQueueIDs.contains(captured.id.rawValue))

        let second = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * 60)).map { Float(0.15 * sin(2 * Double.pi * 330 * Double($0) / 44_100)) },
            itemID: episodeID, destinationURL: secondAudioURL, createdAt: created.addingTimeInterval(100)
        )
        let replacementTranscript = try Transcript(
            itemID: episodeID, revisionID: second.revision.revisionID,
            availability: .available, text: "Replacement transcript.", timing: .published,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Replacement transcript.")],
            updatedAt: Timestamp(created.addingTimeInterval(100))
        )
        try await store.saveReadyRevision(second.revision, mediaURL: secondAudioURL, transcript: replacementTranscript)
        let latestReady = try await store.readyRevision(for: episodeID)
        XCTAssertEqual(latestReady?.revision.revisionID, second.revision.revisionID)

        model.playNotebookClip(captured)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playback?.revisionID, captured.sourceRevision,
                       "Notebook replay must load the saved revision even after Ready advances")
        XCTAssertEqual(model.playbackError, nil)
        XCTAssertEqual(model.currentPodcastEpisodeID, episodeID.rawValue)
        XCTAssertNil(model.currentEpisode, "replay remains valid after the Larder row is gone")
    }
}
