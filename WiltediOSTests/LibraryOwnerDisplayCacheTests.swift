import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryOwnerDisplayCacheTests: XCTestCase {
    private var scratch: URL!
    private var seededTransport: OwnerCacheTransport?
    private var url: URL { scratch.appendingPathComponent("library-state.json") }
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("owner-display-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }
    private func defaults() -> UserDefaults {
        let name = "owner-display-\(UUID())"
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    private func batch(_ names: [String] = ["old"], full: Bool = true, owner: String = "owner") throws -> LibraryChangeBatch {
        let changes = try names.flatMap { name in [
            VersionedLibraryChange(version: 1, change: .entry(try LibraryEntry(id: id(name), kind: .podcastEpisode,
                sourceID: id("show"), title: name, summary: "", publishedAt: Date(timeIntervalSince1970: 1_000)))),
            VersionedLibraryChange(version: 1, change: .slot(try QueueSlot(entryID: id(name), sortKey: 0)))] }
        return .init(generationID: "complete", changes: changes, token: .init(rawValue: "cursor"),
            provenance: .init(ownerToken: owner, operationGeneration: 0, isFullBootstrap: full))
    }
    private func offer(_ raw: String = "old") throws -> LibraryMediaOffer {
        try .init(entryID: id(raw), revisionID: RevisionID(rawValue: "r1"), contentHash: PreparedMediaFixture.hash(Data(repeating: 7, count: 10)), byteCount: 10, mediaType: "audio/mpeg", durationSeconds: 30, state: .available, preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))))
    }
    private func model(_ transport: OwnerCacheTransport, store: FileLibraryStore? = nil) -> LibraryAppModel {
        LibraryAppModel(transport: transport, store: store ?? FileLibraryStore(url: url), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: defaults())
    }
    private func seed() async throws -> (FileLibraryStore, LibraryAppModel) {
        let store = FileLibraryStore(url: url)
        let transport = OwnerCacheTransport(batch: try batch(), offers: [try offer()])
        seededTransport = transport
        let online = model(transport, store: store)
        await online.refresh()
        XCTAssertEqual(online.visibleRows.map(\.id), [id("old")])
        return (store, online)
    }
    func testPreviouslyOfferedUndownloadedRowStaysVisibleAtColdSuspendedAndFailedRefresh() async throws {
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(entryID: id("old"), revisionID: RevisionID(rawValue: "r1"),
            contentHash: PreparedMediaFixture.hash(Data(repeating: 7, count: 10)), byteCount: 10, mediaType: "audio/mpeg", durationSeconds: 30, state: .available))
        let store = FileLibraryStore(url: url)
        let online = LibraryAppModel(transport: OwnerCacheTransport(batch: try batch(["old"]), offers: [offer]),
            store: store, deviceID: "phone", mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: defaults())
        await online.refresh()
        XCTAssertEqual(online.visibleRows.map(\.id), [id("old")])
        let gate = OwnerCacheTransport(batch: try batch(["old"]), suspend: true, failFetch: true)
        let cold = LibraryAppModel(transport: gate, store: FileLibraryStore(url: url), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("empty-audio")), preferences: defaults())
        await cold.loadLocalState()
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
        let refresh = Task { await cold.refresh() }
        await gate.waitForFetch()
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
        await gate.release()
        await refresh.value
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
        XCTAssertTrue(cold.preparedIDs.offered.isEmpty && cold.preparedIDs.onPhone.isEmpty)
    }

    func testSuccessfulEmptyOffersClearDisplayAcrossReopenWithoutDeletingLibraryRows() async throws {
        let (store, _) = try await seed()
        let reader = model(OwnerCacheTransport(batch: try batch(), offers: []), store: store)
        await reader.refresh()
        XCTAssertTrue(reader.visibleRows.isEmpty)
        XCTAssertEqual(reader.queued.map(\.id), [id("old")])
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertTrue(cold.visibleRows.isEmpty)
        let state = await FileLibraryStore(url: url).state()
        XCTAssertEqual(state.displayPreparedIDs, [])
    }

    func testCachedDisplayNeverBecomesLiveOfferDownloadedOrPlaybackAuthority() async throws {
        _ = try await seed()
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
        XCTAssertEqual(cold.preparedCount, 1)
        XCTAssertTrue(cold.readyOffers.isEmpty && cold.preparedIDs.offered.isEmpty && cold.preparedIDs.onPhone.isEmpty)
        XCTAssertTrue(cold.playOrderRows.isEmpty)
        XCTAssertTrue(cold.tickState.offers.isEmpty && cold.media.isEmpty)
    }

    func testOnlyPreparedOffersInCurrentQueueBecomeDurableDisplayEvidence() async throws {
        let store = FileLibraryStore(url: url)
        let notReady = try LibraryMediaOffer(entryID: id("new"), revisionID: nil, contentHash: "",
            byteCount: 0, mediaType: "", state: .notReady)
        let online = model(OwnerCacheTransport(batch: try batch(["old", "new"]),
            offers: [try offer(), notReady, try offer("outside")]), store: store)
        await online.refresh()
        let state = await store.state()
        XCTAssertEqual(state.displayPreparedIDs, [id("old")])
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
    }

    func testSuccessfulBodyReplacementClipsPriorDisplayWithoutInventingEligibility() async throws {
        let (store, _) = try await seed()
        let transport = OwnerCacheTransport(batch: try batch(["new"]))
        _ = try await LibraryReconciler(transport: transport, store: store).synchronize().get()
        let state = await store.state()
        XCTAssertEqual(state.content.queue.map(\.entryID), [id("new")])
        XCTAssertEqual(state.displayPreparedIDs, [])
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertTrue(cold.visibleRows.isEmpty)
    }

    func testNegativeOfferHidesImmediatelyAndDurablyAcrossReopen() async throws {
        let (store, online) = try await seed()
        let transport = try XCTUnwrap(seededTransport)
        let negative = try LibraryMediaOffer(entryID: id("old"), revisionID: nil,
            contentHash: "", byteCount: 0, mediaType: "", state: .notReady)
        await transport.replaceOffers([negative])
        online.startMediaRequest(entryID: id("old"))
        for _ in 0..<200 where online.mediaState(for: id("old")) != .notPrepared { await Task.yield() }
        XCTAssertEqual(online.mediaState(for: id("old")), .notPrepared)
        XCTAssertTrue(online.visibleRows.isEmpty)
        for _ in 0..<200 {
            if await store.state().displayPreparedIDs?.isEmpty == true { break }
            await Task.yield()
        }
        let state = await FileLibraryStore(url: url).state()
        XCTAssertEqual(state.displayPreparedIDs, [])
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertTrue(cold.visibleRows.isEmpty)
    }

    func testHoldRejectsOfferReplacementAndNegativeRemovalWithoutChangingBytes() async throws {
        let (store, _) = try await seed()
        try await store.quarantine()
        let state = await store.state()
        let bytes = try Data(contentsOf: url)
        let transport = OwnerCacheTransport(batch: try batch())
        do { try await store.recordDisplayOffers([], transport: transport, expectedGeneration: 0, expectedRevision: state.revision); XCTFail("held display changed") } catch {}
        do { try await store.removeDisplayOffer(id("old"), transport: transport, expectedGeneration: 0, expectedDisplayRevision: state.displayAdmissionRevision); XCTFail("held negative admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let cold = model(transport)
        await cold.loadLocalState()
        XCTAssertTrue(cold.accountQuarantined)
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
    }

    func testGenerationChangeDuringVerificationCannotReplaceDisplayEvidence() async throws {
        let (store, _) = try await seed()
        let state = await store.state()
        let bytes = try Data(contentsOf: url)
        let transport = OwnerCacheTransport(batch: try batch(), invalidateDuringVerification: true)
        do { try await store.recordDisplayOffers([], transport: transport, expectedGeneration: 0, expectedRevision: state.revision); XCTFail("old generation admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testStaleRevisionCannotClearNewerDisplayEvidence() async throws {
        let (store, _) = try await seed()
        let prior = await store.state()
        let transport = OwnerCacheTransport(batch: try batch(["new"], full: false))
        _ = try await LibraryReconciler(transport: transport, store: store).synchronize().get()
        let bytes = try Data(contentsOf: url)
        do { try await store.recordDisplayOffers([], transport: transport, expectedGeneration: 0, expectedRevision: prior.revision); XCTFail("stale revision admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testDifferentOwnerCannotClearSavedEligibility() async throws {
        let (store, _) = try await seed()
        let state = await store.state()
        let bytes = try Data(contentsOf: url)
        let transport = OwnerCacheTransport(batch: try batch(), owner: "other-owner")
        do { try await store.recordDisplayOffers([], transport: transport, expectedGeneration: 0, expectedRevision: state.revision); XCTFail("other owner admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFailedDisplayWriteKeepsAllMirrorFieldsAndFileBytes() async throws {
        _ = try await seed()
        let bytes = try Data(contentsOf: url)
        let store = FileLibraryStore(url: url, writeData: { _, _ in throw LibraryTransportError.transport("disk full") })
        let prior = await store.state()
        let transport = OwnerCacheTransport(batch: try batch())
        do { try await store.recordDisplayOffers([], transport: transport, expectedGeneration: 0, expectedRevision: prior.revision); XCTFail("write failure succeeded") } catch {}
        let after = await store.state()
        XCTAssertEqual(after, prior)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let cold = model(transport, store: store)
        await cold.loadLocalState()
        XCTAssertEqual(cold.visibleRows.map(\.id), [id("old")])
    }

    func testMissingLegacyEligibilityDoesNotInventPreparedRowsOrAdoptOwner() async throws {
        _ = try await seed()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "ownerToken")
        object.removeValue(forKey: "displayPreparedIDs")
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: url)
        let store = FileLibraryStore(url: url)
        let state = await store.state()
        let transport = OwnerCacheTransport(batch: try batch())
        do { try await store.recordDisplayOffers([try offer()], transport: transport, expectedGeneration: 0, expectedRevision: state.revision); XCTFail("unbound eligibility admitted") } catch {}
        let cold = model(transport, store: store)
        await cold.loadLocalState()
        XCTAssertEqual(cold.queued.map(\.id), [id("old")])
        XCTAssertTrue(cold.visibleRows.isEmpty && cold.readyOffers.isEmpty && cold.preparedIDs.offered.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testOwnerReplacementWhileDisplayVerificationWaitsCannotCrossAccountBoundary() async throws {
        let (store, _) = try await seed()
        let prior = await store.state()
        let barrier = DisplayProbeBarrier()
        let old = OwnerCacheTransport(batch: try batch(), ownerProbe: { await barrier.hold() })
        let task = Task { try await store.recordDisplayOffers([], transport: old,
            expectedGeneration: 0, expectedRevision: prior.revision) }
        await barrier.waitUntilHeld()
        try await store.discard()
        let replacement = OwnerCacheTransport(batch: try batch(owner: "new-owner"), owner: "new-owner")
        _ = try await LibraryReconciler(transport: replacement, store: store).synchronize().get()
        let fresh = await store.state()
        try await store.recordDisplayOffers([try offer()], transport: replacement,
            expectedGeneration: 0, expectedRevision: fresh.revision)
        let bytes = try Data(contentsOf: url)
        await barrier.release()
        do { try await task.value; XCTFail("old owner changed replacement display") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let final = await store.state()
        XCTAssertEqual(final.ownerToken, "new-owner")
        XCTAssertEqual(final.displayPreparedIDs, [id("old")])
    }

    func testTwoActualNegativeResponsesPersistBothRemovalsAcrossReopen() async throws {
        let store = FileLibraryStore(url: url)
        let transport = OwnerCacheTransport(batch: try batch(["old", "new"]), offers: [try offer(), try offer("new")])
        let online = model(transport, store: store)
        await online.refresh()
        let negatives = try ["old", "new"].map { try LibraryMediaOffer(entryID: id($0), revisionID: nil,
            contentHash: "", byteCount: 0, mediaType: "", state: .notReady) }
        await transport.replaceOffers(negatives)
        online.startMediaRequest(entryID: id("old"))
        online.startMediaRequest(entryID: id("new"))
        for _ in 0..<400 {
            if online.mediaState(for: id("old")) == .notPrepared && online.mediaState(for: id("new")) == .notPrepared { break }
            await Task.yield()
        }
        XCTAssertEqual(online.mediaState(for: id("old")), .notPrepared)
        XCTAssertEqual(online.mediaState(for: id("new")), .notPrepared)
        for _ in 0..<400 {
            if await store.state().displayPreparedIDs?.isEmpty == true { break }
            await Task.yield()
        }
        let saved = await store.state()
        XCTAssertEqual(saved.displayPreparedIDs, [])
        let cold = model(OwnerCacheTransport(batch: try batch(), failFetch: true))
        await cold.loadLocalState()
        XCTAssertTrue(cold.visibleRows.isEmpty)
    }

    func testSuccessfulOldStoreCallbackCannotRemoveRecoveredSameRevisionDisplay() async throws {
        let (old, _) = try await seed()
        let nextURL = scratch.appendingPathComponent("next-state.json")
        let next = FileLibraryStore(url: nextURL)
        let current = OwnerCacheTransport(batch: try batch())
        _ = try await LibraryReconciler(transport: current, store: next).synchronize().get()
        let fresh = await next.state()
        try await next.recordDisplayOffers([try offer()], transport: current, expectedGeneration: 0, expectedRevision: fresh.revision)
        let barrier = DisplayProbeBarrier()
        let delayed = DelayedDisplayStore(base: old, barrier: barrier)
        let recovery = LibraryAccountRecovery(quarantineEvents: AsyncStream { $0.finish() }) {
            try await old.discard()
            return next
        }
        let online = LibraryAppModel(transport: OwnerCacheTransport(batch: try batch(), failFetch: true), store: delayed,
            deviceID: "phone", recovery: recovery, mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: defaults())
        await online.loadLocalState()
        online.dropOffer(id("old"))
        await barrier.waitUntilHeld()
        await online.recoverFromAccountChange()
        XCTAssertEqual(online.visibleRows.map(\.id), [id("old")])
        await barrier.release()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(online.visibleRows.map(\.id), [id("old")])
        let saved = await next.state()
        XCTAssertEqual(saved.displayPreparedIDs, [id("old")])
    }

    func testNewPositiveAdmissionFencesOlderNegativeEvenWhenIDsAreIdentical() async throws {
        let (store, _) = try await seed()
        let prior = await store.state()
        let transport = OwnerCacheTransport(batch: try batch())
        try await store.recordDisplayOffers([try offer()], transport: transport,
            expectedGeneration: 0, expectedRevision: prior.revision)
        let bytes = try Data(contentsOf: url)
        do { try await store.removeDisplayOffer(id("old"), transport: transport,
            expectedGeneration: 0, expectedDisplayRevision: prior.displayAdmissionRevision)
            XCTFail("old negative removed newly confirmed offer") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let state = await store.state()
        XCTAssertEqual(state.displayPreparedIDs, [id("old")])
    }

}

private actor DisplayProbeBarrier {
    private var held = false
    private var waiter: CheckedContinuation<String?, Never>?
    func hold() async -> String? {
        held = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilHeld() async { while !held { await Task.yield() } }
    func release() { waiter?.resume(returning: "owner"); waiter = nil }
}

private actor DelayedDisplayStore: LibraryStore {
    let base: FileLibraryStore
    let barrier: DisplayProbeBarrier
    init(base: FileLibraryStore, barrier: DisplayProbeBarrier) { self.base = base; self.barrier = barrier }
    func state() async -> LibraryStoreState { await base.state() }
    func fetchCursor() async -> LibraryChangeToken? { await base.fetchCursor() }
    func commit(_ staged: StagedLibraryBatch) async throws { try await base.commit(staged) }
    func commit(_ staged: StagedLibraryBatch, transport: any LibraryTransport, expectedGeneration: UInt64) async throws {
        try await base.commit(staged, transport: transport, expectedGeneration: expectedGeneration)
    }
    func recordDisplayOffers(_ offers: [LibraryMediaOffer], transport: any LibraryTransport, expectedGeneration: UInt64, expectedRevision: UInt64) async throws {
        try await base.recordDisplayOffers(offers, transport: transport, expectedGeneration: expectedGeneration, expectedRevision: expectedRevision)
    }
    func removeDisplayOffer(_ entryID: ItemID, transport: any LibraryTransport, expectedGeneration: UInt64, expectedDisplayRevision: UInt64) async throws {
        try await base.removeDisplayOffer(entryID, transport: transport, expectedGeneration: expectedGeneration, expectedDisplayRevision: expectedDisplayRevision)
        _ = await barrier.hold()
    }
    func enqueue(_ change: LibraryChange) async throws { try await base.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) async throws { try await base.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) async throws { try await base.resolveConflict(key, keepLocal: keepLocal) }
}
