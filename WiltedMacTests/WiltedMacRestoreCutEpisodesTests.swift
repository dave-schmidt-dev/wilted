import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Restoring cuts on a show marked as having no ads: the Mac passes that set
/// into prepare-again refresh, the feed-settings control, and the wording for
/// a restoring run.
@MainActor
final class WiltedMacRestoreCutEpisodesTests: XCTestCase {
    // MARK: Real store + pipeline

    func testACurrentEngineCutAppearsOnlyWhenTheFeedIsMarkedAdFree() async throws {
        let cut = try await seedCurrentEngineCut(suffix: "restore-load")
        let unmarkedPreferences = WiltedMacTestPreferences.ephemeral()
        let unmarked = WiltedMacModel(
            arguments: [], stateDirectoryOverride: cut.root, storeBootstrap: { _ in cut.store },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: unmarkedPreferences
        )
        addTeardownBlock { await unmarked.close() }
        unmarked.startStoreBootstrap()
        await unmarked.waitForStoreBootstrap()
        XCTAssertNil(unmarked.prepareAgainCandidates[cut.episodeID.rawValue],
                     "without the ad-free mark the current engine's cut is final")
        await unmarked.close()

        let markedPreferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacAdFreeFeedPreference(preferences: markedPreferences).set(
            feedID: cut.feedID.rawValue, adFree: true
        )
        let marked = WiltedMacModel(
            arguments: [], stateDirectoryOverride: cut.root, storeBootstrap: { _ in cut.store },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: markedPreferences
        )
        addTeardownBlock { await marked.close() }
        marked.startStoreBootstrap()
        await marked.waitForStoreBootstrap()
        let candidate = try XCTUnwrap(marked.prepareAgainCandidates[cut.episodeID.rawValue])
        XCTAssertTrue(candidate.isCut)
        let episode = try XCTUnwrap(marked.episodes.first { $0.id == cut.episodeID.rawValue })
        XCTAssertTrue(marked.restoresFullEpisode(episode))
    }

    func testSetAdFreeMakesACurrentEngineCutAppearThenDisappear() async throws {
        let cut = try await seedCurrentEngineCut(suffix: "restore-toggle")
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: cut.root, storeBootstrap: { _ in cut.store },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertNil(model.prepareAgainCandidates[cut.episodeID.rawValue])

        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: cut.feedID.rawValue, isArticleFeed: false, isNews: false)
        XCTAssertTrue(board.setAdFree(true, for: cut.feedID.rawValue))
        try await eventually("the cut to appear after marking ad-free") {
            model.prepareAgainCandidates[cut.episodeID.rawValue] != nil
        }
        XCTAssertEqual(board.restorableCutCount(cut.feedID.rawValue), 1)

        XCTAssertTrue(board.setAdFree(false, for: cut.feedID.rawValue))
        try await eventually("the cut to leave after clearing the mark") {
            model.prepareAgainCandidates[cut.episodeID.rawValue] == nil
        }
        XCTAssertEqual(board.restorableCutCount(cut.feedID.rawValue), 0)
    }

    /// A read that began while the show was marked must not land over the read
    /// made after the mark was cleared, whichever finishes first.
    func testAReadFromBeforeTheSwitchChangedDoesNotWin() async throws {
        let cut = try await seedCurrentEngineCut(suffix: "restore-order")
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: cut.root, storeBootstrap: { _ in cut.store },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let epoch = model.libraryReadEpoch
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)

        for _ in 0..<20 {
            preference.set(feedID: cut.feedID.rawValue, adFree: true)
            let marked = Task { await model.refreshEpisodesToPrepareAgain(from: store, readEpoch: epoch) }
            // Let the marked read start and park on the store before the mark is cleared.
            await Task.yield()
            preference.set(feedID: cut.feedID.rawValue, adFree: false)
            await model.refreshEpisodesToPrepareAgain(from: store, readEpoch: epoch)
            await marked.value
            XCTAssertNil(model.prepareAgainCandidates[cut.episodeID.rawValue],
                         "the show is not marked, so the current engine's cut is final")
        }
    }

    // MARK: Model selection

    func testEpisodesToRestoreIsOnlyThatFeedsOfferableCuts() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-a", adFree: true)
        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-b", adFree: true)
        let model = WiltedMacModel(arguments: [], preferences: preferences)

        let restore = prepared("restore-me", feedID: "feed-a")
        let playing = prepared("playing", feedID: "feed-a")
        let running = prepared("running", feedID: "feed-a")
        let queued = prepared("queued", feedID: "feed-a")
        let otherFeed = prepared("other-feed", feedID: "feed-b")
        let notCut = prepared("not-cut", feedID: "feed-a")
        for episode in [restore, playing, running, queued, otherFeed, notCut] {
            model.installEpisodeForTesting(episode)
        }
        model.prepareAgainCandidates = [
            restore.id: try candidate(restore.id, isCut: true),
            playing.id: try candidate(playing.id, isCut: true),
            running.id: try candidate(running.id, isCut: true),
            queued.id: try candidate(queued.id, isCut: true),
            otherFeed.id: try candidate(otherFeed.id, isCut: true),
            notCut.id: try candidate(notCut.id, isCut: false),
        ]
        model.currentPodcastEpisodeID = playing.id
        model.podcastPreparationTasks[running.id] = Task {}
        model.preparationQueue.enter(WiltedMacWaitingPreparation(
            id: queued.id, title: queued.title, source: queued.feedTitle
        ))

        XCTAssertEqual(model.episodesToRestore(feedID: "feed-a").map(\.id), [restore.id])
        XCTAssertEqual(model.episodesToRestore(feedID: "feed-b").map(\.id), [otherFeed.id])
        XCTAssertTrue(model.restoresFullEpisode(restore))
        XCTAssertFalse(model.restoresFullEpisode(notCut), "an uncut candidate is not a restore")
        XCTAssertEqual(model.prepareAgainMenuTitle(for: restore), "Restore Full Episode")
        XCTAssertEqual(model.prepareAgainMenuTitle(for: notCut), "Prepare Again")

        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-a", adFree: false)
        XCTAssertFalse(model.restoresFullEpisode(restore), "a feed that is not marked is not a restore")
        XCTAssertEqual(model.prepareAgainMenuTitle(for: restore), "Prepare Again")
        XCTAssertTrue(model.episodesToRestore(feedID: "feed-a").isEmpty)
    }

    func testRestoreCutEpisodesAdmitsEachWithAdRemovalOff() async throws {
        let directory = wiltedTemporaryDirectory("restore-admit")
        let preferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-a", adFree: true)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = prepared("restore-admit-1", feedID: "feed-a")
        let second = prepared("restore-admit-2", feedID: "feed-a")
        model.installEpisodeForTesting(first)
        model.installEpisodeForTesting(second)
        model.prepareAgainCandidates = [
            first.id: try candidate(first.id, isCut: true),
            second.id: try candidate(second.id, isCut: true),
        ]

        let gate = model.preparationGateForTesting
        var ownsGate = false
        defer { if ownsGate { gate.release() } }
        try await gate.admit(sequence: 1)
        ownsGate = true

        model.restoreCutEpisodes(feedID: "feed-a")
        XCTAssertEqual(Set(model.podcastPreparationTasks.keys), [first.id, second.id])

        let store = try XCTUnwrap(model.store)
        for episodeID in [first.id, second.id] {
            let ticket = try await eventuallyTicket(in: store, subjectID: episodeID)
            let data = try XCTUnwrap(ticket.policySnapshot)
            let policy = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: data)
            XCTAssertFalse(policy.removeAds, "a restore run is admitted with ad removal off")
        }

        ownsGate = false
        gate.release()
        await model.waitForPodcastPreparationOperationsForTesting()
    }

    // MARK: Wording

    func testRestoreButtonTitlesRowLineMenuAndConfirmationWording() {
        XCTAssertEqual(WiltedMacFeedPolicyContent.restoreCutEpisodesTitle(count: 1), "Restore 1 Cut Episode")
        XCTAssertEqual(WiltedMacFeedPolicyContent.restoreCutEpisodesTitle(count: 3), "Restore 3 Cut Episodes")
        XCTAssertEqual(
            WiltedMacPrepareAgainRow(phase: .preparing, restoringFullEpisode: true).label,
            "Restoring the full episode"
        )
        XCTAssertEqual(
            WiltedMacPrepareAgainRow(phase: .preparing, restoringFullEpisode: false).label,
            "Removing ads with the current engine"
        )
        XCTAssertEqual(
            WiltedMacModel.prepareAgainConfirmationMessage,
            "Wilted downloads the original audio where needed and prepares each episode with the current engine. "
                + "Shows marked as having no ads get their full episodes back. Your place in each is kept."
        )
    }

    // MARK: Fixtures

    private struct CutSeed {
        let root: URL
        let store: LocalLibraryStore
        let episodeID: ItemID
        let feedID: ItemID
    }

    /// One downloaded episode the current engine cut, left in a store the Mac
    /// can bootstrap. Uses the real pipeline with a stub worker.
    private func seedCurrentEngineCut(suffix: String) async throws -> CutSeed {
        let root = wiltedTemporaryDirectory("restore-cut-\(suffix)")
        let work = root.appendingPathComponent("Work", isDirectory: true)
        let audioDir = root.appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/restore-\(suffix).xml"))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/restore-\(suffix).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "restore-\(suffix)", enclosureURL: enclosure
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let body = Data("original-audio-bytes".utf8)
        let contentHash = "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let revisionID = try RevisionID.derive(downloadedAudioContentHash: contentHash)
        let episodeAudio = audioDir.appendingPathComponent(episodeID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: episodeAudio, withIntermediateDirectories: true)
        let audioURL = episodeAudio.appendingPathComponent(revisionID.rawValue + ".mp3")
        try body.write(to: audioURL)

        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Restore feed", createdAt: created
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "restore-\(suffix)",
            title: "Restore episode", publishedTime: created, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", enclosureByteCount: Int64(body.count), createdAt: created
        ))
        try await store.finalizePodcastDownload(
            revision: try AudioRevision(
                itemID: episodeID, revisionID: revisionID, durationSeconds: 12,
                byteCount: Int64(body.count), contentHash: contentHash, mediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)), schemaVersion: 3
            ),
            mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
                expectedByteCount: Int64(body.count), localURL: audioURL, contentHash: contentHash,
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
            )
        )

        let pipeline = PodcastPreparationPipeline(
            store: store, workDirectory: work, runner: CuttingPipelineRunner(),
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )
        _ = try await pipeline.prepare(episodeID: episodeID)
        return CutSeed(root: root, store: store, episodeID: episodeID, feedID: feedID)
    }

    private func prepared(_ id: String, feedID: String) -> WiltedMacEpisode {
        var episode = WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        episode.feedID = feedID
        return episode
    }

    private func candidate(_ id: String, isCut: Bool) throws -> PodcastPrepareAgainCandidate {
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

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func eventuallyTicket(
        in store: LocalLibraryStore, subjectID: String
    ) async throws -> WorkTicket {
        for _ in 0..<100 {
            if let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: subjectID),
               ticket.policySnapshot != nil {
                return ticket
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: subjectID)
        return try XCTUnwrap(ticket, "expected a preparation ticket for \(subjectID)")
    }
}

/// Stands in for the Python worker and removes 3.0–7.5 from a twelve-second episode.
private actor CuttingPipelineRunner: PodcastPipelineRunning {
    private static let cutAudio = Data("shorter-audio-bytes".utf8)

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        var answer: [String: Any] = [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.",
            "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [
                ["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0],
            ],
            "protocolVersion": decoded["protocolVersion"] as? Int ?? 2,
            "report": [
                "outcome": "cut",
                "rawNominations": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
                "audit": [
                    "classifierRequests": 3, "classifierValidRequests": 3, "classifierInvalidRequests": 0,
                    "exhaustedSingletonLineages": 0, "modelRequests": 3, "modelFailures": 0,
                    "experimentalRequests": 0, "unresolvedIds": [Int](), "candidates": [[String: Any]](),
                    "incompleteError": NSNull(),
                ],
            ],
        ]
        if let outputPath = decoded["outputPath"] as? String {
            try Self.cutAudio.write(to: URL(fileURLWithPath: outputPath))
            answer["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}
