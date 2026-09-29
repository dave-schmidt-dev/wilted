import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Records what the applier asked of the model and answers from a scripted state.
@MainActor
private final class FakeDecisionHost: WiltedMacDecisionHost {
    var states: [ItemID: WiltedMacDecisionEntryState] = [:]
    var queue: [ItemID] = []
    var succeeds = true
    private(set) var calls: [String] = []

    func decisionState(of entryID: ItemID) -> WiltedMacDecisionEntryState { states[entryID] ?? .unknown }
    var decisionQueue: [ItemID] { queue }
    func keepEntry(_ entryID: ItemID) async -> Bool { record("keep", entryID) }
    func skipEntry(_ entryID: ItemID) async -> Bool { record("skip", entryID) }
    func markEntryDone(_ entryID: ItemID) async -> Bool { record("markDone", entryID) }
    func restoreEntry(_ entryID: ItemID) async -> Bool { record("restore", entryID) }
    func moveQueueEntry(from source: Int, to destination: Int, resulting: [ItemID]) async -> Bool {
        calls.append("move \(source)->\(destination) \(resulting.map(\.rawValue).joined(separator: ","))")
        return succeeds
    }

    private func record(_ name: String, _ entryID: ItemID) -> Bool {
        calls.append("\(name) \(entryID.rawValue)")
        return succeeds
    }
}

@MainActor
final class WiltedMacIntentApplierTests: XCTestCase {
    private let phone = "iphone"
    private let mac = "mac-test"
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var ids: [ItemID] = []

    override func setUpWithError() throws {
        ids = try ["a", "b", "c", "d"].map { try ItemID(rawValue: "item-\($0)") }
    }

    private struct Rig {
        var host: FakeDecisionHost
        var server: InMemoryLibraryServer
        var applier: WiltedMacIntentApplier
        var appliedCount: Counter
    }

    @MainActor final class Counter { var value = 0 }

    private func rig(
        host: FakeDecisionHost = FakeDecisionHost(), directory: URL? = nil, server: InMemoryLibraryServer? = nil,
        writer: String? = nil
    ) -> Rig {
        let server = server ?? InMemoryLibraryServer(writerDeviceID: mac)
        let counter = Counter()
        let at = clock
        let applier = WiltedMacIntentApplier(
            host: host,
            ledger: WiltedMacIntentLedger(fileURL: directory?.appendingPathComponent("ledger.json"), now: { at }),
            book: WiltedMacIntentOutcomeBook(fileURL: directory?.appendingPathComponent("book.json"), now: { at }),
            transport: InMemoryLibraryTransport(deviceID: writer ?? mac, server: server), now: { at },
            onApplied: { counter.value += 1 }
        )
        return Rig(host: host, server: server, applier: applier, appliedCount: counter)
    }

    private func outcomes(_ rig: Rig) async throws -> [IntentOutcome] {
        try await InMemoryLibraryTransport(deviceID: phone, server: rig.server).intentOutcomes()
    }

    private func intent(_ action: LibraryIntent.Action, id: String = UUID().uuidString, age: TimeInterval = 0) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: phone, createdAt: clock.addingTimeInterval(-age), action: action)
    }

    // MARK: Each intent

    func testKeepOfANewEntryCallsTheModelAndPublishesApplied() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: false, started: false)
        let keep = try intent(.keep(entryID: ids[0]), id: "k-1")

        try await r.applier.apply(keep)

        XCTAssertEqual(r.host.calls, ["keep item-a"])
        let published = try await outcomes(r)
        XCTAssertEqual(published.map(\.intentID), ["k-1"])
        XCTAssertEqual(published.first?.disposition, .applied)
        XCTAssertEqual(published.first?.deviceID, phone, "the phone finds its outcomes by its own name")
        XCTAssertEqual(r.appliedCount.value, 1, "an applied decision triggers a republish")
    }

    func testKeepOfAnAlreadyQueuedEntryIsAppliedWithoutTouchingTheModel() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: true, started: false)
        try await r.applier.apply(intent(.keep(entryID: ids[0])))
        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.disposition, .applied)
    }

    func testKeepOfARetiredEntryIsNotApplicable() async throws {
        let r = rig()
        r.host.states[ids[0]] = .retired
        try await r.applier.apply(intent(.keep(entryID: ids[0])))
        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonNotApplicable)
        XCTAssertEqual(r.appliedCount.value, 0)
    }

    func testSkipAppliesToNewEntriesOnlyNeverToAKeptOne() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: false, started: false)
        r.host.states[ids[1]] = .live(queued: true, started: false)
        try await r.applier.apply(intent(.skip(entryID: ids[0]), id: "s-a"))
        try await r.applier.apply(intent(.skip(entryID: ids[1]), id: "s-b"))
        XCTAssertEqual(r.host.calls, ["skip item-a"])
        let published = Dictionary(uniqueKeysWithValues: try await outcomes(r).map { ($0.intentID, $0) })
        XCTAssertEqual(published["s-a"]?.disposition, .applied)
        XCTAssertEqual(published["s-b"]?.reason, IntentOutcome.reasonNotApplicable)
    }

    func testMarkDoneNeedsAStartedEpisode() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: true, started: true)
        r.host.states[ids[1]] = .live(queued: true, started: false)
        try await r.applier.apply(intent(.markDone(entryID: ids[0]), id: "m-a"))
        try await r.applier.apply(intent(.markDone(entryID: ids[1]), id: "m-b"))
        XCTAssertEqual(r.host.calls, ["markDone item-a"])
        let published = Dictionary(uniqueKeysWithValues: try await outcomes(r).map { ($0.intentID, $0) })
        XCTAssertEqual(published["m-a"]?.disposition, .applied)
        XCTAssertEqual(published["m-b"]?.reason, IntentOutcome.reasonNotApplicable)
    }

    func testRestoreBringsBackRetiredAndDismissedEntries() async throws {
        let r = rig()
        r.host.states[ids[0]] = .retired
        r.host.states[ids[1]] = .dismissed
        r.host.states[ids[2]] = .live(queued: false, started: false)
        for (index, id) in ids.prefix(3).enumerated() {
            try await r.applier.apply(intent(.restore(entryID: id), id: "r-\(index)"))
        }
        XCTAssertEqual(r.host.calls, ["restore item-a", "restore item-b"], "a live entry is already restored")
        let published = try await outcomes(r)
        XCTAssertTrue(published.allSatisfy(\.isApplied))
        XCTAssertEqual(published.count, 3)
    }

    func testReorderConvertsTheEntryRelativeRequestToTheIndexMove() async throws {
        let r = rig()
        r.host.queue = ids
        ids.forEach { r.host.states[$0] = .live(queued: true, started: false) }

        try await r.applier.apply(intent(.reorder(entryID: ids[3], afterEntryID: ids[0]), id: "o-1"))
        XCTAssertEqual(r.host.calls, ["move 3->1 item-a,item-d,item-b,item-c"])

        try await r.applier.apply(intent(.reorder(entryID: ids[0], afterEntryID: nil), id: "o-2"))
        XCTAssertEqual(r.host.calls.count, 1, "already at the front: nothing to move")

        try await r.applier.apply(intent(.reorder(entryID: ids[0], afterEntryID: ids[2]), id: "o-3"))
        XCTAssertEqual(r.host.calls.last, "move 0->2 item-b,item-c,item-a,item-d")

        let published = try await outcomes(r)
        XCTAssertEqual(published.count, 3)
        XCTAssertTrue(published.allSatisfy(\.isApplied))
    }

    func testQueueMoveMath() throws {
        let queue = ids
        XCTAssertEqual(WiltedMacIntentApplier.queueMove(of: ids[1], after: nil, in: queue)?.change,
                       .init(from: 1, to: 0, resulting: [ids[1], ids[0], ids[2], ids[3]]))
        XCTAssertEqual(WiltedMacIntentApplier.queueMove(of: ids[0], after: ids[3], in: queue)?.change,
                       .init(from: 0, to: 3, resulting: [ids[1], ids[2], ids[3], ids[0]]))
        XCTAssertNil(WiltedMacIntentApplier.queueMove(of: ids[1], after: ids[0], in: queue)?.change,
                     "b already follows a")
        XCTAssertNotNil(WiltedMacIntentApplier.queueMove(of: ids[1], after: ids[0], in: queue))
        XCTAssertNil(WiltedMacIntentApplier.queueMove(of: ids[1], after: try ItemID(rawValue: "gone"), in: queue))
        XCTAssertNil(WiltedMacIntentApplier.queueMove(of: try ItemID(rawValue: "gone"), after: nil, in: queue))
    }

    func testReorderOfAnEntryOutsideTheQueueIsNotApplicable() async throws {
        let r = rig()
        r.host.queue = [ids[0], ids[1]]
        r.host.states[ids[2]] = .live(queued: false, started: false)
        try await r.applier.apply(intent(.reorder(entryID: ids[2], afterEntryID: ids[0])))
        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonNotApplicable)
    }

    // MARK: Rejections

    func testUnknownEntryIsRejectedAndNothingIsApplied() async throws {
        let r = rig()
        try await r.applier.apply(intent(.keep(entryID: ids[0]), id: "u-1"))
        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.disposition, .rejected)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonUnknownEntry)
        XCTAssertEqual(r.appliedCount.value, 0)
    }

    func testAModelCallThatDoesNotTakeIsRejectedAsFailed() async throws {
        let r = rig()
        r.host.succeeds = false
        r.host.states[ids[0]] = .live(queued: false, started: false)
        try await r.applier.apply(intent(.keep(entryID: ids[0])))
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonFailed)
        XCTAssertEqual(r.appliedCount.value, 0)
    }

    func testAnExpiredIntentIsRejectedWithoutBeingApplied() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: false, started: false)
        let stale = try intent(.keep(entryID: ids[0]), id: "e-1", age: IntentRetention.maximumAge + 60)
        try await r.applier.apply(stale)
        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonExpired)
    }

    func testMediaIntentsAreLeftToTheMediaService() async throws {
        let r = rig()
        try await r.applier.apply(intent(.requestMedia(entryID: ids[0])))
        let published = try await outcomes(r)
        XCTAssertTrue(published.isEmpty)
    }

    // MARK: At most once, replay, restart

    func testAReplayedIntentIsAppliedAndPublishedOnce() async throws {
        let r = rig()
        r.host.states[ids[0]] = .live(queued: false, started: false)
        let keep = try intent(.keep(entryID: ids[0]), id: "k-2")
        try await r.applier.apply(keep)
        try await r.applier.apply(keep)
        XCTAssertEqual(r.host.calls, ["keep item-a"])
        let published = try await outcomes(r)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(r.appliedCount.value, 1)
    }

    func testARestartDoesNotApplyAgainAndKeepsTheFirstOutcome() async throws {
        let directory = wiltedTemporaryDirectory("intent-applier-restart")
        let server = InMemoryLibraryServer(writerDeviceID: mac)
        let first = rig(directory: directory, server: server)
        first.host.states[ids[0]] = .live(queued: false, started: false)
        let keep = try intent(.keep(entryID: ids[0]), id: "k-3")
        try await first.applier.apply(keep)

        // A fresh process: new host, applier, ledger and book over the same files and server.
        let second = rig(directory: directory, server: server)
        second.host.states[ids[0]] = .live(queued: false, started: false)
        try await second.applier.apply(keep)

        XCTAssertEqual(second.host.calls, [], "the ledger keeps a restarted Mac from applying twice")
        XCTAssertEqual(second.appliedCount.value, 0)
        let published = try await outcomes(first)
        XCTAssertEqual(published.map(\.intentID), ["k-3"])
        XCTAssertEqual(published.first?.disposition, .applied)
    }

    func testAFailedPublishIsRetriedFromTheSavedOutcomeWithoutApplyingAgain() async throws {
        let directory = wiltedTemporaryDirectory("intent-applier-publish")
        let server = InMemoryLibraryServer(writerDeviceID: mac)
        // A transport that is not the writer cannot publish outcomes, standing in for an outage.
        let offline = rig(directory: directory, server: server, writer: "not-the-writer")
        offline.host.states[ids[0]] = .live(queued: false, started: false)
        let keep = try intent(.keep(entryID: ids[0]), id: "k-4")
        do {
            try await offline.applier.apply(keep)
            XCTFail("a failed publish must surface so the sink retries")
        } catch {}
        XCTAssertEqual(offline.host.calls, ["keep item-a"])
        let before = try await outcomes(offline)
        XCTAssertTrue(before.isEmpty)

        let online = rig(directory: directory, server: server)
        try await online.applier.apply(keep)

        XCTAssertEqual(online.host.calls, [], "the retry republishes; it does not apply again")
        let published = try await outcomes(online)
        XCTAssertEqual(published.map(\.intentID), ["k-4"])
        XCTAssertEqual(published.first?.disposition, .applied)
    }

    func testAnIntentBegunButNeverAnsweredIsRejectedNotReapplied() async throws {
        let directory = wiltedTemporaryDirectory("intent-applier-crash")
        let at = clock
        let ledger = WiltedMacIntentLedger(fileURL: directory.appendingPathComponent("ledger.json"), now: { at })
        _ = try await ledger.recordIfNew("k-5")
        let r = rig(directory: directory)
        r.host.states[ids[0]] = .live(queued: false, started: false)

        try await r.applier.apply(intent(.keep(entryID: ids[0]), id: "k-5"))

        XCTAssertEqual(r.host.calls, [])
        let published = try await outcomes(r)
        XCTAssertEqual(published.first?.reason, IntentOutcome.reasonFailed)
    }
}

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
