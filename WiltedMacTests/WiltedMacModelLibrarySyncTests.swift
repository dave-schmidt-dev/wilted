import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacModelLibrarySyncTests: XCTestCase {
    private let flagOn = ["WILTED_LIBRARY_SYNC": "1"]
    private let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeModel(_ name: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    private func bootstrapped(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore) {
        let model = makeModel(name)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (model, try XCTUnwrap(model.store))
    }

    /// One feed with episodes "a", "b", "c" (none downloaded), returned in that order.
    private func seedEpisodes(_ store: LocalLibraryStore) async throws -> [ItemID] {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        var ids: [ItemID] = []
        for (index, guid) in ["a", "b", "c"].enumerated() {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + Double(index))),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            ids.append(id)
        }
        return ids
    }

    private func source(_ store: LocalLibraryStore, playback: WiltedMacPlaybackSample? = nil) -> WiltedMacLocalLibraryStateSource {
        WiltedMacLocalLibraryStateSource(store: store, deviceID: "mac-test") { playback }
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    // MARK: State source

    func testStateSourceMapsFeedsEpisodesQueueRemovalAndListening() async throws {
        let (_, store) = try await bootstrapped("library-sync-state")
        let ids = try await seedEpisodes(store)
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[2], ids[0], ids[1]]))
        _ = try await store.retireEpisode(ids[1])
        _ = try await store.dismissPodcastEpisode(ids[2])
        try await store.saveListening(PodcastListeningState(
            episodeID: ids[0], completedAt: Timestamp(Date(timeIntervalSince1970: 50)), lastRevisionID: nil,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 60))
        ))

        let state = try await source(store).currentState()

        XCTAssertEqual(state.feeds.map(\.title), ["Show"])
        XCTAssertEqual(state.feeds.first?.kind, .podcastFeed)
        XCTAssertEqual(Set(state.episodes.map(\.id)), Set(ids))
        XCTAssertTrue(state.episodes.allSatisfy { $0.kind == .podcastEpisode })
        let removals = Dictionary(uniqueKeysWithValues: state.episodes.map { ($0.id, $0.removal) })
        XCTAssertEqual(removals[ids[0]], LibraryRemoval.none)
        XCTAssertEqual(removals[ids[1]], .retired)
        XCTAssertEqual(removals[ids[2]], .dismissed)
        let removedAt: [ItemID: Date?] = Dictionary(uniqueKeysWithValues: state.episodes.map { ($0.id, $0.removedAt) })
        XCTAssertNil(removedAt[ids[0]] ?? nil, "a live episode has no removal date")
        XCTAssertNotNil(removedAt[ids[1]] ?? nil, "retired carries the store's retirement date")
        XCTAssertNotNil(removedAt[ids[2]] ?? nil, "dismissed carries the store's removal date")
        XCTAssertEqual(state.queue, [ids[0]], "removed episodes leave the published queue; order is kept")
        XCTAssertEqual(state.listening.map(\.itemID), [ids[0]])
        XCTAssertEqual(state.listening.first?.deviceID, "mac-test")
        XCTAssertNil(state.currentPlayback, "no playback sample")
    }

    func testStateSourcePublishesCurrentPlaybackOnlyWithAPreparedRevision() async throws {
        let directory = wiltedTemporaryDirectory("library-sync-playback-media")
        let (_, store) = try await bootstrapped("library-sync-playback")
        let ids = try await seedEpisodes(store)
        let sample = WiltedMacPlaybackSample(episodeID: ids[0], positionSeconds: 12, rate: 1.5, isPlaying: false)
        let unprepared = try await source(store, playback: sample).currentState()
        XCTAssertNil(unprepared.currentPlayback)

        let enclosure = URL(string: "https://media.example.test/ready.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let readyID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "ready", enclosureURL: enclosure)
        try await WiltedMacModelTests.addReadyEpisode(
            readyID, guid: "ready", feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_100), directory: directory, store: store, created: created
        )
        let ready = WiltedMacPlaybackSample(episodeID: readyID, positionSeconds: 12, rate: 1.5, isPlaying: false)
        let state = try await source(store, playback: ready).currentState()
        let position = try XCTUnwrap(state.currentPlayback)
        XCTAssertEqual(position.entryID, readyID)
        XCTAssertEqual(position.positionSeconds, 12)
        XCTAssertEqual(position.rate, 1.5)
        XCTAssertEqual(position.deviceID, "mac-test")
        XCTAssertFalse(position.isPlaying)
    }

    // MARK: Intents

    func testSinkRecordsMediaRequestsWithoutAConsumerAndDeduplicates() async throws {
        let sink = WiltedMacLibraryIntentSink()
        let intent = try LibraryIntent.requestMedia(entryID: try ItemID(rawValue: "item-a"), deviceID: "iphone", id: "i-1")
        try await sink.receive(intent)
        try await sink.receive(intent)
        let recorded = await sink.recorded
        XCTAssertEqual(recorded, [intent])
    }

    func testSinkRoutesToConsumerAndRetriesAfterAFailure() async throws {
        actor Calls { var ids: [String] = []; var failing = true
            func call(_ intent: LibraryIntent) throws {
                ids.append(intent.id)
                if failing { failing = false; throw NSError(domain: "test", code: 1) }
            }
        }
        let calls = Calls()
        let sink = WiltedMacLibraryIntentSink { intent in try await calls.call(intent) }
        let intent = try LibraryIntent.requestMedia(entryID: try ItemID(rawValue: "item-a"), deviceID: "iphone", id: "i-2")
        do { try await sink.receive(intent); XCTFail("expected failure") } catch {}
        let afterFailure = await sink.recorded
        XCTAssertTrue(afterFailure.isEmpty)
        try await sink.receive(intent)
        let ids = await calls.ids
        let recorded = await sink.recorded
        XCTAssertEqual(ids, ["i-2", "i-2"])
        XCTAssertEqual(recorded.count, 1)
    }

    // MARK: Wiring

    func testFlagOffStartsNothing() async throws {
        let (model, _) = try await bootstrapped("library-sync-off")
        XCTAssertFalse(model.startLibrarySyncIfEnabled(environment: [:]))
        XCTAssertNil(model.librarySyncController)
        XCTAssertFalse(model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "0"]))
    }

    func testPublisherRepublishesOnQueueRemovalAndPlaybackChanges() async throws {
        let (model, store) = try await bootstrapped("library-sync-publish")
        let ids = try await seedEpisodes(store)
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[0], ids[1]]))
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let transport = InMemoryLibraryTransport(deviceID: "mac-test", server: server)

        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(20)
        ))
        try await eventually("first publish") { await server.currentSnapshot.entries.count == 3 }
        var snapshot = await server.currentSnapshot
        XCTAssertEqual(snapshot.queue.map(\.entryID), [ids[0], ids[1]])
        XCTAssertEqual(snapshot.sources.count, 1)

        // Queue reorder: the store changes, then the model's observed queue moves.
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[1], ids[0]]))
        model.podcastQueueIDs = [ids[1].rawValue, ids[0].rawValue]
        try await eventually("queue reorder") { await server.currentSnapshot.queue.first?.entryID == ids[1] }

        // Removal: retiring drops the episode from the observed queue, as the model's reload does.
        _ = try await store.retireEpisode(ids[0])
        model.podcastQueueIDs = [ids[1].rawValue]
        try await eventually("retire") { await server.currentSnapshot.entries[ids[0]]?.removal == .retired }
        snapshot = await server.currentSnapshot
        XCTAssertEqual(snapshot.queue.map(\.entryID), [ids[1]])

        model.stopLibrarySync()
        XCTAssertNil(model.librarySyncController)
    }

    func testMediaRequestFromTheServerIsRecordedThroughTheSink() async throws {
        let (model, store) = try await bootstrapped("library-sync-intent")
        let ids = try await seedEpisodes(store)
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = InMemoryLibraryTransport(deviceID: "iphone", server: server)
        try await phone.send(intent: LibraryIntent.requestMedia(entryID: ids[0], deviceID: "iphone", id: "i-3"))

        model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20)
        )
        let sink = try XCTUnwrap(model.librarySyncController).sink
        try await eventually("intent recorded") { await sink.recorded.count == 1 }
        let recorded = await sink.recorded
        XCTAssertEqual(recorded.first?.action, .requestMedia(entryID: ids[0]))
    }

    func testEnvironmentFlagTurnsLegacyEngineOffAndDefaultLeavesItOn() async throws {
        let (defaultModel, _) = try await bootstrapped("library-sync-legacy-default")
        XCTAssertNotNil(defaultModel.syncLifecycle, "default OFF keeps the legacy engine")

        setenv("WILTED_LIBRARY_SYNC", "1", 1)
        defer { unsetenv("WILTED_LIBRARY_SYNC") }
        let (flagged, _) = try await bootstrapped("library-sync-legacy-flag")
        XCTAssertNil(flagged.syncLifecycle, "each app owns exactly one engine")
        XCTAssertNotNil(flagged.librarySyncController)
        XCTAssertNotNil(flagged.libraryDeviceID().range(of: "mac-"))
        flagged.stopLibrarySync()
    }
    // MARK: Positions adopted from the phone

    func testAPhonePositionOnTheServerBecomesTheStoredPositionThroughTheRealWiring() async throws {
        let (model, store) = try await bootstrapped("library-sync-position-import")
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        let directory = wiltedTemporaryDirectory("library-sync-position-import-audio")
        var ids: [ItemID] = []
        for (index, guid) in ["a", "b"].enumerated() {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await WiltedMacModelTests.addReadyEpisode(
                id, guid: guid, feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), directory: directory,
                store: store, created: created)
            ids.append(id)
        }
        // "b" was finished on the Mac: a phone position must not bring it back.
        try await store.saveListening(PodcastListeningState(
            episodeID: ids[1], completedAt: Timestamp(Date()), lastRevisionID: nil, updatedAt: Timestamp(Date())))
        let snapshot = try await store.podcastLibrarySnapshot()
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: "iphone", server: server), deviceID: "iphone")
        for id in ids {
            let revision = try XCTUnwrap(snapshot.readyRevisions[id]).revision.revisionID
            try await phone.takeover(entryID: id, revision: revision, positionSeconds: 1)
            try await phone.paused(at: 4)
        }

        model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20))
        let revisionA = try XCTUnwrap(snapshot.readyRevisions[ids[0]]).revision.revisionID
        try await eventually("the phone's position is stored") {
            (try? await store.playbackState(for: ids[0], revisionID: revisionA))?.positionSeconds == 4
        }
        let revisionB = try XCTUnwrap(snapshot.readyRevisions[ids[1]]).revision.revisionID
        let finished = try await store.playbackState(for: ids[1], revisionID: revisionB)
        XCTAssertNil(finished, "a finished episode is not resurrected")
        model.stopLibrarySync()
    }
}
