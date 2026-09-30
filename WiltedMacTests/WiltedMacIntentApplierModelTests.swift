import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac


// MARK: - Through the real model

private struct ModelRig {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let episodes: [ItemID]
}

extension WiltedMacIntentApplierTests {
    /// Four episodes on one feed; the first two are in the Larder, in order.
    private func modelRig(_ name: String) async throws -> ModelRig {
        let feedURL = URL(string: "https://feeds.example.test/applier.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let episodeIDs = try (0..<4).map { index in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "episode-\(index)",
                enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!
            )
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Applier feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, itemID) in episodeIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-\(index)",
                        title: "Episode \(index)", publishedTime: created,
                        enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!,
                        enclosureMediaType: "audio/mpeg", createdAt: created
                    ))
                }
                try await store.replacePodcastQueue(try PodcastQueueState(
                    episodeIDs: [episodeIDs[0], episodeIDs[1]], currentEpisodeID: episodeIDs[0]
                ))
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await MainActor.run { model.stopLibrarySync() }; await model.close() }
        return ModelRig(model: model, store: try XCTUnwrap(model.store), episodes: episodeIDs)
    }

    func testModelHostKeepsSkipsAndRestoresThroughTheExistingMethods() async throws {
        let rig = try await modelRig("applier-model-decisions")
        let model = rig.model
        let e = rig.episodes
        XCTAssertEqual(model.decisionState(of: e[2]), .live(queued: false, started: false))
        // The Larder's current episode counts as started; the second slot does not.
        XCTAssertEqual(model.decisionState(of: e[0]), .live(queued: true, started: true))
        XCTAssertEqual(model.decisionState(of: e[1]), .live(queued: true, started: false))
        XCTAssertEqual(model.decisionState(of: try ItemID(rawValue: "nope")), .unknown)

        let kept = await model.keepEntry(e[2])
        XCTAssertTrue(kept)
        let durableQueue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(durableQueue, [e[0], e[1], e[2]])
        XCTAssertEqual(model.decisionState(of: e[2]), .live(queued: true, started: false))

        let skipped = await model.skipEntry(e[3])
        XCTAssertTrue(skipped)
        XCTAssertEqual(model.decisionState(of: e[3]), .retired)
        let skippedKind = try await rig.store.removalKind(for: e[3])
        XCTAssertEqual(skippedKind, .retired)

        let restored = await model.restoreEntry(e[3])
        XCTAssertTrue(restored)
        XCTAssertEqual(model.decisionState(of: e[3]), .live(queued: false, started: false))
        let restoredKind = try await rig.store.removalKind(for: e[3])
        XCTAssertNil(restoredKind)
    }

    func testModelHostRestoresADismissedEntry() async throws {
        let rig = try await modelRig("applier-model-dismissed")
        let target = rig.episodes[3]
        let episode = try XCTUnwrap(rig.model.episodes.first { $0.id == target.rawValue })
        rig.model.removeEpisode(episode)
        await rig.model.waitForPodcastOperations()
        XCTAssertEqual(rig.model.decisionState(of: target), .dismissed)

        let restored = await rig.model.restoreEntry(target)

        XCTAssertTrue(restored)
        XCTAssertEqual(rig.model.decisionState(of: target), .live(queued: false, started: false))
    }

    func testModelHostMarksAStartedEpisodeDoneAndRetiresIt() async throws {
        let rig = try await modelRig("applier-model-done")
        let started = try XCTUnwrap(rig.model.episodes.first { $0.id == rig.episodes[1].rawValue })
        rig.model.installPlaybackStateForTesting(
            episode: started, isPlaying: false, position: 120, duration: 600,
            queue: [rig.episodes[0].rawValue, rig.episodes[1].rawValue]
        )
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .live(queued: true, started: true))

        let done = await rig.model.markEntryDone(rig.episodes[1])

        XCTAssertTrue(done)
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .retired)
        let listening = try await rig.store.listeningState(for: rig.episodes[1])
        XCTAssertNotNil(listening?.completedAt)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertFalse(queue.contains(rig.episodes[1]), "a finished episode leaves the Larder")
    }

    func testModelHostRemovesAQueuedEntryFromTheLarderAndKeepsItLive() async throws {
        let rig = try await modelRig("applier-model-remove")
        let target = rig.episodes[1]
        XCTAssertEqual(rig.model.decisionState(of: target), .live(queued: true, started: false))

        let removed = await rig.model.removeEntryFromLarder(target)

        XCTAssertTrue(removed)
        XCTAssertEqual(rig.model.decisionState(of: target), .live(queued: false, started: false))
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [rig.episodes[0]])
        let kind = try await rig.store.removalKind(for: target)
        XCTAssertNil(kind, "Remove from Larder does not retire the episode")
    }

    func testModelHostMovesTheQueueByIndex() async throws {
        let rig = try await modelRig("applier-model-move")
        let e = rig.episodes
        let move = try XCTUnwrap(WiltedMacIntentApplier.queueMove(of: e[1], after: nil, in: rig.model.decisionQueue)?.change)

        let moved = await rig.model.moveQueueEntry(from: move.from, to: move.to, resulting: move.resulting)

        XCTAssertTrue(moved)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [e[1], e[0]])
    }

    /// Phone intents arrive over the transport, reach the applier through the sink, and are answered.
    func testIntentsFromTheServerAreAppliedAndAnswered() async throws {
        let rig = try await modelRig("applier-model-e2e")
        let e = rig.episodes
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = InMemoryLibraryTransport(deviceID: "iphone", server: server)
        try await phone.send(intent: LibraryIntent.keep(entryID: e[2], deviceID: "iphone", id: "e2e-keep"))
        try await phone.send(intent: LibraryIntent.reorder(entryID: e[2], afterEntryID: nil, deviceID: "iphone", id: "e2e-move"))
        try await phone.send(intent: LibraryIntent.skip(entryID: e[3], deviceID: "iphone", id: "e2e-skip"))
        try await phone.send(intent: LibraryIntent.keep(
            entryID: try ItemID(rawValue: "not-an-entry"), deviceID: "iphone", id: "e2e-unknown"
        ))

        XCTAssertTrue(rig.model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20), retryDelay: .milliseconds(50)
        ))
        var published: [String: IntentOutcome] = [:]
        for _ in 0..<200 where published.count < 4 {
            try await Task.sleep(for: .milliseconds(50))
            published = Dictionary(uniqueKeysWithValues: try await phone.intentOutcomes().map { ($0.intentID, $0) })
        }

        XCTAssertEqual(published.count, 4)
        XCTAssertEqual(published["e2e-keep"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-move"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-skip"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-unknown"]?.reason, IntentOutcome.reasonUnknownEntry)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [e[2], e[0], e[1]])
        let skippedKind = try await rig.store.removalKind(for: e[3])
        XCTAssertEqual(skippedKind, .retired)
        // The change reaches the phone's snapshot through the publisher.
        var snapshotQueue: [ItemID] = []
        for _ in 0..<200 where snapshotQueue != [e[2], e[0], e[1]] {
            try await Task.sleep(for: .milliseconds(50))
            snapshotQueue = await server.currentSnapshot.queue.map(\.entryID)
        }
        XCTAssertEqual(snapshotQueue, [e[2], e[0], e[1]])
    }
}
