import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

private actor FakeStateSource: LibraryStateSource {
    private(set) var reads = 0
    private var state: LibraryStateSnapshot

    init(_ state: LibraryStateSnapshot = LibraryStateSnapshot()) { self.state = state }

    func set(_ state: LibraryStateSnapshot) { self.state = state }

    func currentState() async throws -> LibraryStateSnapshot {
        reads += 1
        return state
    }
}

private actor FakeIntentSink: LibraryIntentSink {
    struct Rejected: Error {}
    private(set) var received: [String] = []
    private var failing = false

    func setFailing(_ failing: Bool) { self.failing = failing }

    func receive(_ intent: LibraryIntent) async throws {
        if failing { throw Rejected() }
        received.append(intent.id)
    }
}

final class WiltedMacLibraryPublisherTests: XCTestCase {
    private func id(_ name: String) -> ItemID { try! ItemID(rawValue: "item-\(name)") }

    private func episode(_ name: String, title: String? = nil, removal: LibraryRemoval = .none) -> LibraryEntry {
        try! LibraryEntry(
            id: id(name), kind: .podcastEpisode, sourceID: id("feed"), title: title ?? "Episode \(name)",
            summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), removal: removal
        )
    }

    private func state(
        _ episodes: [LibraryEntry], queue: [String] = [], listening: [ListeningRecord] = [],
        playback: DevicePlaybackPosition? = nil
    ) -> LibraryStateSnapshot {
        LibraryStateSnapshot(
            feeds: [LibrarySource(id: id("feed"), kind: .podcastFeed, title: "Feed")],
            episodes: episodes, queue: queue.map(id), listening: listening, currentPlayback: playback
        )
    }

    private func position(_ name: String, seconds: Double = 42) -> DevicePlaybackPosition {
        try! DevicePlaybackPosition(
            deviceID: "mac", entryID: id(name), revision: try! RevisionID(rawValue: "rev-\(name)"),
            positionSeconds: seconds, isPlaying: false, epoch: 1
        )
    }

    private func makeServer() -> InMemoryLibraryServer { InMemoryLibraryServer(writerDeviceID: "mac") }

    private func publisher(
        _ source: FakeStateSource, server: InMemoryLibraryServer, sink: FakeIntentSink = FakeIntentSink(),
        enabled: Bool = true
    ) -> WiltedMacLibraryPublisher {
        WiltedMacLibraryPublisher(
            source: source, transport: InMemoryLibraryTransport(deviceID: "mac", server: server),
            sink: sink, isEnabled: enabled
        )
    }

    func testCapturedFullPublicationProducesAuthorReceipt() async throws {
        let fixture = try PublicationScenario()
        let report = try await fixture.publisher().sync()
        XCTAssertTrue(report.publicationCompleted)
        let receipt = try await fixture.transport.readPublication()
        XCTAssertNotNil(receipt, "complete captured library publication must produce author evidence")
    }

    private func assertIncomplete(_ failure: PublicationTransport.Failure) async throws {
        let fixture = try PublicationScenario(); await fixture.transport.setFailure(failure)
        let pub = fixture.publisher(); let report = try await pub.sync()
        let observed = try await fixture.transport.readPublication()
        let sidecar = try await fixture.bytes.store.load(owner: "owner")
        XCTAssertNil(observed); XCTAssertNil(sidecar.fulfilled)
        XCTAssertNotNil(sidecar.pending); XCTAssertNil(sidecar.pending?.publishedAt)
        XCTAssertLessThan(report.acknowledged, report.pushed)
        XCTAssertFalse(report.publicationCompleted, "an incomplete obligation cannot report completion")
    }
    func testMissingAcknowledgementRetainsAnUndatedObligation() async throws { try await assertIncomplete(.missing) }
    func testConflictCannotFulfillCapturedPublication() async throws { try await assertIncomplete(.conflict) }
    func testRetryableFailureCannotFulfillCapturedPublication() async throws { try await assertIncomplete(.retryable) }
    func testTerminalFailureCannotFulfillCapturedPublication() async throws { try await assertIncomplete(.terminal) }

    func testRequiredSlotDeletionMustBeAcknowledgedBeforeNewReceipt() async throws {
        let fixture = try PublicationScenario(); let pub = fixture.publisher()
        _ = try await pub.sync(); let first = try await fixture.transport.readPublication()
        await fixture.source.set(try PublicationScenario.state(queued: false))
        await fixture.transport.setFailure(.deletion)
        let report = try await pub.sync(); let after = try await fixture.transport.readPublication()
        XCTAssertEqual(report.pushed, 1); XCTAssertEqual(report.acknowledged, 0); XCTAssertEqual(after, first)
        let pending = try await fixture.bytes.store.load(owner: "owner").pending
        XCTAssertEqual(pending?.remaining.first?.key.kind, .slot)
    }
    func testSentTokenFailureRetriesEvenAfterBaselineAdoptionWithoutEarlyDate() async throws {
        let fixture = try PublicationScenario(); let pub = fixture.publisher()
        await fixture.transport.failToken(true)
        do { _ = try await pub.sync(); XCTFail("token failure hidden") } catch {}
        let before = try await fixture.bytes.store.load(owner: "owner")
        XCTAssertTrue(before.pending?.contentAcknowledged == true); XCTAssertNil(before.pending?.publishedAt)
        await fixture.transport.failToken(false)
        let retried = try await pub.sync(); let pushes = await fixture.transport.pushes
        XCTAssertEqual(retried.pushed, 0); XCTAssertEqual(pushes, 1)
        XCTAssertEqual(retried.acknowledged, 0); XCTAssertTrue(retried.publicationCompleted)
        XCTAssertEqual(retried.publication?.publishedAt, Date(timeIntervalSince1970: 100))
    }
    func testRemoteReceiptFailureReopensAndRetriesSameIdentityAndCompletionDate() async throws {
        let fixture = try PublicationScenario(); await fixture.transport.failReceipt(true)
        do { _ = try await fixture.publisher().sync(); XCTFail("receipt failure hidden") } catch {}
        let retained = try await fixture.bytes.store.load(owner: "owner")
        XCTAssertNil(retained.fulfilled); XCTAssertEqual(retained.pending?.publishedAt, Date(timeIntervalSince1970: 100))
        await fixture.transport.failReceipt(false)
        let retried = try await fixture.publisher(date: Date(timeIntervalSince1970: 999)).sync()
        XCTAssertTrue(retried.publicationCompleted)
        XCTAssertEqual(retried.pushed, 0); XCTAssertEqual(retried.acknowledged, 0)
        let receipts = await fixture.transport.receipts
        XCTAssertEqual(receipts.count, 2); XCTAssertEqual(receipts[0], receipts[1])
    }
    func testRemoteSuccessLocalCompletionFailureReopensSameReceipt() async throws {
        let fixture = try PublicationScenario(); await fixture.bytes.fail(4)
        do { _ = try await fixture.publisher().sync(); XCTFail("local completion failure hidden") } catch {}
        let retained = try await fixture.bytes.store.load(owner: "owner")
        XCTAssertNil(retained.fulfilled); XCTAssertNotNil(retained.pending?.publishedAt)
        let remote = try await fixture.transport.readPublication(); XCTAssertNotNil(remote)
        await fixture.bytes.fail(nil)
        let report = try await fixture.publisher(date: Date(timeIntervalSince1970: 999)).sync()
        XCTAssertEqual(report.publication, remote)
        XCTAssertTrue(report.publicationCompleted); XCTAssertEqual(report.acknowledged, 0)
        let receipts = await fixture.transport.receipts; XCTAssertEqual(receipts.count, 2); XCTAssertEqual(receipts[0], receipts[1])
    }
    func testHealthyNoopNeverCreatesOrRestampsAuthorReceipt() async throws {
        let fixture = try PublicationScenario(); let pub = fixture.publisher()
        let first = try await pub.sync(); let second = try await pub.sync()
        let receipts = await fixture.transport.receipts
        XCTAssertEqual(second.pushed, 0); XCTAssertEqual(first.publication, second.publication); XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(first.publicationCompleted); XCTAssertFalse(second.publicationCompleted)
    }
    func testSameApprovedOwnerHydratesFulfilledEvidenceWithoutCloudReadsOrWrites() async throws {
        let fixture = try PublicationScenario(); let first = try await fixture.publisher().sync()
        await fixture.transport.failReceipt(true)
        let reopened = fixture.publisher(date: Date(timeIntervalSince1970: 999))
        let hydrated = try await reopened.fulfilledPublication()
        XCTAssertEqual(hydrated, first.publication)
        let report = try await reopened.sync()
        XCTAssertEqual(report.publication, hydrated)
        XCTAssertFalse(report.publicationCompleted, "hydrated history is not a receipt sent by this pass")
        XCTAssertEqual(report.acknowledged, 0)
        let receipts = await fixture.transport.receipts; XCTAssertEqual(receipts.count, 1)
    }
    func testUnapprovedOwnerCannotSendOrHydrateAnotherAccountReceipt() async throws {
        let fixture = try PublicationScenario(); let owner = PublicationOwnerBox(); await owner.set(nil)
        let pub = fixture.publisher(ownerProvider: { await owner.value })
        do { _ = try await pub.sync(); XCTFail("unapproved owner sent") } catch {}
        let pushes = await fixture.transport.pushes; XCTAssertEqual(pushes, 0)
    }
    func testMutatedSourceDuringPushDoesNotEnlargeCapturedPublication() async throws {
        let fixture = try PublicationScenario(); let barrier = PublicationBarrier(); let pub = fixture.publisher()
        await fixture.inner.setAfterPushHook { await barrier.hold() }
        let pass = Task { try await pub.sync() }; await barrier.wait()
        await fixture.source.set(try PublicationScenario.state(title: "Later")); await barrier.release()
        let first = try await pass.value; let captured = await fixture.server.currentSnapshot
        XCTAssertEqual(captured.entries.values.first?.title, "Captured"); XCTAssertNotNil(first.publication)
        await fixture.inner.setAfterPushHook(nil)
        let later = try await pub.sync(); XCTAssertEqual(later.pushed, 1); XCTAssertNotEqual(later.publication?.id, first.publication?.id)
    }
    private func assertReset(at boundary: String) async throws {
        let fixture = try PublicationScenario(); let barrier = PublicationBarrier(); let owner = PublicationOwnerBox()
        let pub = fixture.publisher(ownerProvider: { await owner.value })
        switch boundary {
        case "source": await fixture.source.setHook { await barrier.hold() }
        case "seed": await fixture.inner.setAfterFetchHook { await barrier.hold() }
        case "push": await fixture.inner.setAfterPushHook { await barrier.hold() }
        case "token": await fixture.transport.setTokenHook { await barrier.hold() }
        case "receipt": await fixture.inner.setAfterPublicationHook { await barrier.hold() }
        default: await fixture.bytes.setHook { if $0 == 4 { await barrier.hold() } }
        }
        let task = Task { try await pub.sync() }; await barrier.wait()
        await owner.set("new-owner"); await pub.resetForAccount(); await barrier.release()
        do { _ = try await task.value; XCTFail("old account operation succeeded") }
        catch { XCTAssertEqual(error as? LibraryTransportError, .superseded) }
        let current = try await pub.fulfilledPublication(); XCTAssertNil(current)
    }
    func testResetDuringSourceCaptureSupersedesWholePass() async throws { try await assertReset(at: "source") }
    func testResetDuringSeedSupersedesWholePass() async throws { try await assertReset(at: "seed") }
    func testResetDuringPushSupersedesWholePass() async throws { try await assertReset(at: "push") }
    func testResetDuringSentTokenSupersedesWholePass() async throws { try await assertReset(at: "token") }
    func testResetDuringReceiptSupersedesWholePass() async throws { try await assertReset(at: "receipt") }
    func testResetDuringLocalCompletionPersistenceCannotExposeOldOwnerReceipt() async throws { try await assertReset(at: "persist") }

    func testUnrelatedFailureCannotDiscardOtherwiseAcknowledgedCapturedObligation() async throws {
        let fixture = try PublicationScenario(); let pub = fixture.publisher()
        await fixture.transport.setFailure(.unrelated); _ = try await pub.sync()
        let pending = try await fixture.bytes.store.load(owner: "owner").pending
        XCTAssertFalse(pending?.remaining.isEmpty ?? true); XCTAssertNil(pending?.publishedAt)
        await fixture.transport.setFailure(nil); let retry = try await pub.sync()
        XCTAssertGreaterThan(retry.pushed, 0); XCTAssertNotNil(retry.publication)
    }

    func testFlagIsOffUnlessExactlyOne() {
        // The flag only forces the publisher on; whether it runs without one is the runtime
        // selection's decision (the live-build default), not the flag's.
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: [:]))
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "0"]))
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "true"]))
        XCTAssertTrue(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "1"]))
    }

    func testAPublisherBuiltWithoutAFlagIsEnabledByDefault() {
        let publisher = WiltedMacLibraryPublisher(
            source: FakeStateSource(), transport: InMemoryLibraryTransport(deviceID: "mac", server: makeServer()),
            sink: FakeIntentSink())
        XCTAssertTrue(publisher.isEnabled, "a constructed publisher runs; the runtime selection decides construction")
        XCTAssertEqual(WiltedMacLibraryPublisher.environmentKey, WiltedMacLibraryRuntimeSelection.environmentKey)
    }

        func testDisabledPublisherTouchesNothing() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], queue: ["a"], playback: position("a")))
        let report = try await publisher(source, server: server, enabled: false).sync()
        let reads = await source.reads
        let published = await server.currentSnapshot
        XCTAssertEqual(report, .disabled)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(published, LibrarySnapshot())
    }

    func testFirstSyncPublishesStateInQueueOrder() async throws {
        let server = makeServer()
        let done = ListeningRecord(itemID: id("c"), completedAt: Date(timeIntervalSince1970: 5), updatedAt: Date(timeIntervalSince1970: 5), deviceID: "mac")
        let source = FakeStateSource(state(
            [episode("a"), episode("b"), episode("c")], queue: ["b", "a", "ghost", "b"], listening: [done]
        ))
        let report = try await publisher(source, server: server).sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(report.acknowledged, report.pushed)
        XCTAssertEqual(snapshot.queue.map(\.entryID), [id("b"), id("a")])
        XCTAssertEqual(Set(snapshot.entries.keys), [id("a"), id("b"), id("c")])
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.listening[id("c")], done)
    }

    func testUnchangedStateSendsNothingAndChangesSendOnlyTheDelta() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a"), episode("b")], queue: ["a", "b"]))
        let pub = publisher(source, server: server)
        _ = try await pub.sync()
        let unchanged = try await pub.sync()
        XCTAssertEqual(unchanged.pushed, 0)

        await source.set(state([episode("a", removal: .retired), episode("b")], queue: ["b"]))
        let delta = try await pub.sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(delta.pushed, 3, "retire removal, slot removal for a, slot key move for b")
        XCTAssertEqual(snapshot.entries[id("a")]?.removal, .retired)
        XCTAssertEqual(snapshot.queue.map(\.entryID), [id("b")])
    }

    func testRestartedPublisherResumesFromServerStateWithoutConflicts() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], queue: ["a"]))
        _ = try await publisher(source, server: server).sync()

        let restarted = try await publisher(source, server: server).sync()
        XCTAssertEqual(restarted.pushed, 0)
        XCTAssertEqual(restarted.conflicts, 0)

        await source.set(state([episode("a", title: "Renamed")], queue: ["a"]))
        let edited = try await publisher(source, server: server).sync()
        XCTAssertEqual(edited.acknowledged, 1)
        XCTAssertEqual(edited.conflicts, 0)
    }

    func testConflictAdoptsServerVersionAndSucceedsOnNextPass() async throws {
        let server = makeServer()
        let sourceA = FakeStateSource(state([episode("a")]))
        let first = publisher(sourceA, server: server)
        _ = try await first.sync()

        let sourceB = FakeStateSource(state([episode("a", title: "From B")]))
        _ = try await publisher(sourceB, server: server).sync()

        await sourceA.set(state([episode("a", title: "From A")]))
        let conflicted = try await first.sync()
        XCTAssertEqual(conflicted.conflicts, 1)
        XCTAssertEqual(conflicted.acknowledged, 0)

        let retried = try await first.sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(retried.acknowledged, 1)
        XCTAssertEqual(snapshot.entries[id("a")]?.title, "From A")
    }

    func testPublisherNeverWritesPlaybackRecords() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], playback: position("a")))
        let pub = publisher(source, server: server)
        _ = try await pub.sync()
        await source.set(state([episode("a")], playback: position("a", seconds: 90)))
        _ = try await pub.sync()
        let records = try await InMemoryLibraryTransport(deviceID: "phone", server: server).fetchDeviceRecords()
        XCTAssertTrue(records.nowPlaying.isEmpty, "the handoff coordinator is the only writer of NowPlaying")
        XCTAssertTrue(records.progress.isEmpty, "the handoff coordinator is the only writer of Progress")
    }

    func testIntentsReachTheSinkOnceAndAFailedDeliveryIsRetried() async throws {
        let server = makeServer()
        let sink = FakeIntentSink()
        let source = FakeStateSource(state([episode("a")]))
        let pub = publisher(source, server: server, sink: sink)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        try await phone.send(intent: LibraryIntent.requestMedia(entryID: id("a"), deviceID: "phone", id: "intent-1"))

        await sink.setFailing(true)
        let failed = try await pub.sync()
        XCTAssertEqual(failed.intentFailures, 1)
        XCTAssertEqual(failed.intentsDelivered, 0)

        await sink.setFailing(false)
        let delivered = try await pub.sync()
        let redelivered = try await pub.sync()
        let received = await sink.received
        XCTAssertEqual(delivered.intentsDelivered, 1)
        XCTAssertEqual(redelivered.intentsDelivered, 0)
        XCTAssertEqual(received, ["intent-1"])
    }
    /// The link lives in a store table beside the episode row, so this goes
    /// through a real store: refresh writes it, the state source reads it, and
    /// the payload the differ sends carries it.
    func testPublishedPayloadCarriesTheEpisodeLinkWrittenByARefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-publisher-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://podcasts.example.test/publisher/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        func parsed(link: URL?) throws -> PodcastEpisode {
            let enclosure = URL(string: "https://cdn.example.test/publisher/one.mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "one", enclosureURL: enclosure),
                feedID: feedID, feedURL: feedURL, rssGUID: "one", title: "One", publishedTime: created,
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", episodeLink: link, createdAt: created
            )
        }
        let existing = try parsed(link: nil)
        _ = try await store.savePodcastEpisodes([existing], admission: .backfill)

        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: "mac", playback: { nil })
        let before = try await source.currentState()
        XCTAssertNil(try before.episodes[0].podcastEpisodePayload().episodeLink)

        let page = try XCTUnwrap(URL(string: "https://show.example.test/episodes/one"))
        _ = try await store.savePodcastEpisodes([try parsed(link: page)], admission: .incremental)
        let after = try await source.currentState()
        XCTAssertEqual(try after.episodes[0].podcastEpisodePayload().episodeLink, page)
        XCTAssertNotEqual(before.episodes[0].payload, after.episodes[0].payload, "the changed payload is re-sent")

        let server = makeServer()
        _ = try await publisher(FakeStateSource(after), server: server).sync()
        let published = await server.currentSnapshot
        XCTAssertEqual(try published.entries[existing.itemID]?.podcastEpisodePayload().episodeLink, page)
    }
}
