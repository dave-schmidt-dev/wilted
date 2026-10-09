import CryptoKit
import Foundation
import WiltedDomain
import WiltedCloudKit
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryOwnerCacheTests: XCTestCase {
    private var scratch: URL!
    private var recoveryAudioURL: URL?
    private var url: URL { scratch.appendingPathComponent("library-state.json") }
    private let date = Date(timeIntervalSince1970: 1_000)
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func entry(_ raw: String) throws -> LibraryEntry {
        try LibraryEntry(id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: raw,
                         summary: "", publishedAt: date)
    }
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("owner-cache-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }
    private struct Legacy: Encodable {
        struct Version: Encodable { let key: LibraryRecordKey; let version: UInt64 }
        let sources: [LibrarySource] = []
        let entries: [LibraryEntry]
        let slots: [QueueSlot]
        let listening: [ListeningRecord] = []
        let versions: [Version]
        let cursor = LibraryChangeToken(rawValue: "legacy-cursor")
    }
    private func legacy() throws -> Data {
        let saved = Legacy(entries: [try entry("old")], slots: [try QueueSlot(entryID: id("old"), sortKey: 0)],
            versions: [Legacy.Version(key: .init(kind: .entry, id: id("old")), version: 9)])
        let bytes = try JSONEncoder().encode(saved)
        try bytes.write(to: url)
        return bytes
    }
    func testLegacyCursorCannotBootstrapTheCurrentAccount() async throws {
        _ = try legacy()
        let store = FileLibraryStore(url: url)
        let state = await store.state()
        XCTAssertEqual(state.cursor?.rawValue, "legacy-cursor", "saved bytes stay intact")
        XCTAssertNil(store.initialCursor, "unbound legacy engine must start without the old cursor")
        XCTAssertEqual(state.content.queue.map(\.entryID), [id("old")])
    }
    func testUnverifiedBatchCannotReplaceLegacyBytes() async throws {
        let bytes = try legacy()
        let store = FileLibraryStore(url: url)
        let prior = await store.state()
        let batch = LibraryChangeBatch(generationID: "partial", changes: [
            .init(version: 1, change: .entry(try entry("new")))], token: .init(rawValue: "new"))
        do {
            try await store.commit(.init(batch: batch, priorState: prior,
                nextState: LibraryReconciler.reconcile(prior, with: batch)))
            XCTFail("unverified data must not commit")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testForgedNextStateCannotBypassActualBatchAdmission() async throws {
        let bytes = try legacy()
        let store = FileLibraryStore(url: url)
        let prior = await store.state()
        var forged = LibraryStoreState()
        forged.content = LibrarySnapshot(entries: [try entry("forged")])
        do {
            try await store.commit(.init(batch: .init(generationID: "empty", changes: [], token: nil),
                priorState: prior, nextState: forged))
            XCTFail("a supplied nextState cannot replace the durable mirror")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testForegroundRefreshDisplaysLegacyBeforeSuspendedNetwork() async throws {
        _ = try legacy()
        let gate = OwnerCacheTransport(batch: .init(generationID: "empty", changes: [], token: nil), suspend: true, failFetch: true)
        let model = LibraryAppModel(transport: gate, store: FileLibraryStore(url: url), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")))
        let refresh = Task { await model.refresh() }
        await gate.waitForFetch()
        XCTAssertEqual(model.queued.map(\.id), [id("old")], "retained mirror is visible during network wait")
        await gate.release()
        await refresh.value
    }
    private func batch(_ names: [String] = ["new"], owner: String = "owner", full: Bool = true,
                       publication: LibraryPublication? = nil, token: String? = "new-cursor") throws -> LibraryChangeBatch {
        let changes = try names.flatMap { name in [
            VersionedLibraryChange(version: 1, change: .entry(try entry(name))),
            VersionedLibraryChange(version: 1, change: .slot(try QueueSlot(entryID: id(name), sortKey: 0)))] }
        return .init(generationID: "complete", changes: changes, token: token.map(LibraryChangeToken.init(rawValue:)),
            provenance: .init(ownerToken: owner, operationGeneration: 0, isFullBootstrap: full), observedPublication: publication)
    }
    private func commit(_ batch: LibraryChangeBatch, to store: FileLibraryStore, failAck: Bool = false) async throws {
        let transport = OwnerCacheTransport(batch: batch, owner: batch.provenance?.ownerToken, failAck: failAck)
        _ = try await LibraryReconciler(transport: transport, store: store).synchronize().get()
    }
    private func bound(publication: LibraryPublication? = nil) async throws -> FileLibraryStore {
        let store = FileLibraryStore(url: url, clock: { Date(timeIntervalSince1970: 2_000) })
        try await commit(batch(["old"], publication: publication), to: store)
        return store
    }
    private func publication(_ id: String, _ time: TimeInterval) throws -> LibraryPublication {
        try .init(id: id, publishedAt: Date(timeIntervalSince1970: time), writerDeviceID: "mac")
    }
    private func defaults() throws -> UserDefaults {
        let suite = "owner-cache-\(UUID())"
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    func testVerifiedFullBootstrapReplacesLegacyRatherThanMergingAndPersistsOwner() async throws {
        _ = try legacy()
        let store = FileLibraryStore(url: url, clock: { Date(timeIntervalSince1970: 2_000) })
        let receipt = try publication("p1", 1_000)
        try await commit(batch(publication: receipt), to: store)
        let saved = await FileLibraryStore(url: url).state()
        XCTAssertEqual(Set(saved.content.entries.keys), [id("new")])
        XCTAssertNil(saved.versions[.init(kind: .entry, id: id("old"))])
        XCTAssertEqual(saved.ownerToken, "owner")
        XCTAssertEqual(saved.observedPublication, receipt)
        XCTAssertEqual(saved.cacheCommittedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(saved.cursor?.rawValue, "new-cursor")
    }
    func testVerifiedEmptyZoneReplacesLegacyAndRemovesOldCursor() async throws {
        _ = try legacy()
        let store = FileLibraryStore(url: url)
        try await commit(batch([], token: nil), to: store)
        let saved = await FileLibraryStore(url: url).state()
        XCTAssertTrue(saved.content.entries.isEmpty && saved.content.slots.isEmpty && saved.versions.isEmpty)
        XCTAssertEqual(saved.ownerToken, "owner")
        XCTAssertNil(saved.cursor)
    }
    func testIncrementalProofCannotAdoptLegacyCache() async throws {
        let bytes = try legacy()
        let store = FileLibraryStore(url: url)
        do { try await commit(batch(full: false), to: store); XCTFail("legacy incremental adopted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let state = await store.state()
        XCTAssertNil(state.ownerToken)
        XCTAssertEqual(state.cursor?.rawValue, "legacy-cursor")
    }
    func testMatchingBoundOwnerIncrementalMergesAndRetainsMissingPublication() async throws {
        let receipt = try publication("p1", 1_000)
        let store = try await bound(publication: receipt)
        try await commit(batch(full: false), to: store)
        let state = await store.state()
        XCTAssertEqual(Set(state.content.entries.keys), [id("old"), id("new")])
        XCTAssertEqual(state.observedPublication, receipt)
        XCTAssertEqual(state.ownerToken, "owner")
        XCTAssertEqual(store.initialCursor, nil, "initial snapshot remains the original constructor context")
        let cursor = await store.fetchCursor()
        XCTAssertEqual(cursor?.rawValue, "new-cursor")
    }
    func testMismatchedBoundOwnerPreservesEveryPriorByte() async throws {
        let store = try await bound(publication: publication("p1", 1_000))
        let bytes = try Data(contentsOf: url)
        do { try await commit(batch(owner: "other"), to: store); XCTFail("different owner admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let state = await store.state()
        XCTAssertEqual(state.ownerToken, "owner")
    }
    func testPartialOrMalformedFetchKeepsLegacyRowsAndBytes() async throws {
        let bytes = try legacy()
        let transport = OwnerCacheTransport(batch: try batch(), failFetch: true)
        let model = LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDurableHoldReopensBeforeFetchAndBlocksPendingSend() async throws {
        let store = try await bound()
        try await store.quarantine()
        let reopened = FileLibraryStore(url: url)
        let transport = OwnerCacheTransport(batch: try batch())
        let reconciler = LibraryReconciler(transport: transport, store: reopened)
        guard case .failure = await reconciler.synchronize() else { return XCTFail("held fetch succeeded") }
        guard case .failure = await reconciler.sendPending() else { return XCTFail("held send succeeded") }
        let calls = await transport.fetchCount
        XCTAssertEqual(calls, 0)
        let model = LibraryAppModel(transport: transport, store: reopened, deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.loadLocalState()
        XCTAssertTrue(model.accountQuarantined)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
    }
    func testInvalidationAfterStageFencesForgedHoldClearingNextState() async throws {
        let store = try await bound()
        let prior = await store.state()
        let incoming = try batch()
        var forged = LibraryReconciler.reconcile(prior, with: incoming)
        forged.reviewHold = false
        try await store.quarantine()
        let bytes = try Data(contentsOf: url)
        do {
            try await store.commit(.init(batch: incoming, priorState: prior, nextState: forged),
                transport: OwnerCacheTransport(batch: incoming), expectedGeneration: 0)
            XCTFail("staged commit cleared an observed hold")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reopened = await FileLibraryStore(url: url).state()
        XCTAssertTrue(reopened.reviewHold)
        XCTAssertGreaterThan(reopened.revision, prior.revision)
    }
    func testGenerationInvalidationDuringStoreVerificationCannotInstall() async throws {
        let store = try await bound()
        let bytes = try Data(contentsOf: url)
        let incoming = try batch()
        let prior = await store.state()
        let transport = OwnerCacheTransport(batch: incoming, invalidateDuringVerification: true)
        do {
            try await store.commit(.init(batch: incoming, priorState: prior, nextState: prior), transport: transport, expectedGeneration: 0)
            XCTFail("invalidated operation installed")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testFailedHoldPersistenceLatchesLocallyAndReportsUndurableFence() async throws {
        _ = try await bound()
        let bytes = try Data(contentsOf: url)
        let store = FileLibraryStore(url: url, writeData: { _, _ in throw LibraryTransportError.transport("disk full") })
        do { try await store.quarantine(); XCTFail("hold write failure hidden") } catch {}
        let state = await store.state()
        XCTAssertTrue(state.reviewHold && state.reviewHoldPersistenceFailed)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reopened = await FileLibraryStore(url: url).state()
        XCTAssertFalse(reopened.reviewHold, "failed save must not claim durable restart protection")
        do { try await commit(batch(), to: store); XCTFail("failed hold became open") } catch {}
    }
    func testFileWriteFailureKeepsAllAtomicFieldsAndBytes() async throws {
        _ = try await bound(publication: publication("old", 1_000))
        let bytes = try Data(contentsOf: url)
        let store = FileLibraryStore(url: url, writeData: { _, _ in throw LibraryTransportError.transport("disk full") })
        let prior = await store.state()
        do { try await commit(batch(publication: publication("new", 3_000)), to: store); XCTFail("write failure hidden") } catch {}
        let after = await store.state()
        XCTAssertEqual(after, prior)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testTokenAcknowledgementFailureExposesNewDurableRowsAndAuthorMetadata() async throws {
        _ = try legacy()
        let receipt = try publication("p1", 1_000)
        let store = FileLibraryStore(url: url, clock: { Date(timeIntervalSince1970: 2_000) })
        let transport = OwnerCacheTransport(batch: try batch(publication: receipt), failAck: true)
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id), [id("new")])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.lastObservedPublication, receipt)
        XCTAssertEqual(model.lastCacheCommittedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(model.lastSynchronizedAt)
        let reopened = await FileLibraryStore(url: url).state()
        XCTAssertEqual(reopened.observedPublication, receipt)
        XCTAssertEqual(reopened.ownerToken, "owner")
    }
    func testNilOlderDuplicateAndFuturePublicationRemainTruthful() async throws {
        let original = try publication("p1", 1_000)
        let store = try await bound(publication: original)
        for incoming in [nil, try publication("older", 500), try publication("p1", 5_000)] {
            try await commit(batch(full: false, publication: incoming), to: store)
            let state = await store.state()
            XCTAssertEqual(state.observedPublication, original)
        }
        let future = try publication("future", 9_000_000_000)
        try await commit(batch(full: false, publication: future), to: store)
        let reopened = await FileLibraryStore(url: url).state()
        XCTAssertEqual(reopened.observedPublication, future)
        XCTAssertEqual(reopened.cacheCommittedAt, Date(timeIntervalSince1970: 2_000))
    }
    func testMalformedOptionalSavedPublicationDoesNotHideValidRows() async throws {
        _ = try await bound(publication: publication("p1", 1_000))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["observedPublication"] = ["id": "", "publishedAt": "bad"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let state = await FileLibraryStore(url: url).state()
        XCTAssertEqual(state.content.queue.map(\.entryID), [id("old")])
        XCTAssertEqual(state.ownerToken, "owner")
        XCTAssertNil(state.observedPublication)
    }
    func testConstructorFailureUsesOneOwnedAttemptAndKeepsTheSameSavedLibrary() async throws {
        let bytes = try legacy()
        let preferences = try defaults()
        preferences.set("historical-owner", forKey: LibraryEnvironment.ownerTokenKey)
        var attempts = 0
        let model = LibraryEnvironment.makeModel(defaults: preferences, directory: scratch, isLiveAllowed: false,
            transportFactory: { _, cursor, owner, _, held in
                attempts += 1
                XCTAssertNil(cursor)
                XCTAssertEqual(owner, "historical-owner")
                XCTAssertFalse(held)
                throw LibraryTransportError.transport("constructor failure")
            })
        await model.loadLocalState()
        await model.refresh()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(preferences.string(forKey: LibraryEnvironment.ownerTokenKey), "historical-owner")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    private func assertDamagedBindingRetainsRowsHeld(_ field: String, value: Any) async throws {
        _ = try legacy()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object[field] = value
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: url)
        let store = FileLibraryStore(url: url)
        let state = await store.state()
        XCTAssertEqual(state.content.queue.map(\.entryID), [id("old")])
        XCTAssertEqual(state.versions[.init(kind: .entry, id: id("old"))], 9)
        XCTAssertNil(state.ownerToken)
        XCTAssertTrue(state.reviewHold && store.initialReviewHold)
        XCTAssertNil(store.initialCursor)
        let model = LibraryAppModel(transport: OwnerCacheTransport(batch: try batch()), store: store,
            deviceID: "phone", mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.refresh()
        XCTAssertTrue(model.accountQuarantined)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testMalformedOwnerKeepsOldLarderButCannotBindOrFetch() async throws {
        try await assertDamagedBindingRetainsRowsHeld("ownerToken", value: 23)
    }
    func testBlankOwnerKeepsOldLarderButCannotBindOrFetch() async throws {
        try await assertDamagedBindingRetainsRowsHeld("ownerToken", value: "  ")
    }
    func testMalformedHoldKeepsOldLarderAndFailsClosed() async throws {
        try await assertDamagedBindingRetainsRowsHeld("reviewHold", value: "false")
    }
    func testMalformedRevisionKeepsOldLarderAndFailsClosed() async throws {
        try await assertDamagedBindingRetainsRowsHeld("revision", value: -1)
    }

    func testEnvironmentInjectsPersistedHoldBeforeTransportConstruction() async throws {
        let store = try await bound()
        try await store.quarantine()
        var constructed = false
        let model = LibraryEnvironment.makeModel(defaults: try defaults(), directory: scratch, isLiveAllowed: false,
            transportFactory: { _, cursor, owner, _, held in
                constructed = true
                XCTAssertTrue(held)
                XCTAssertNil(cursor)
                XCTAssertEqual(owner, "owner")
                return (UnavailableLibraryTransport(reason: "held"), {}, nil)
            })
        await model.loadLocalState()
        XCTAssertTrue(constructed && model.accountQuarantined)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
    }

    func testEnvironmentPersistsAccountSignalBeforeReviewAndConfirmationCannotReleaseIt() async throws {
        _ = try await bound()
        let (signals, continuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream()
        defer { continuation.finish() }
        let model = LibraryEnvironment.makeModel(defaults: try defaults(), directory: scratch, isLiveAllowed: false,
            transportFactory: { _, _, _, _, _ in (UnavailableLibraryTransport(reason: "held"), {}, signals) })
        continuation.yield(.quarantineRequired(.signOut))
        for _ in 0..<200 {
            if await FileLibraryStore(url: url).state().reviewHold { break }
            await Task.yield()
        }
        let held = await FileLibraryStore(url: url).state()
        XCTAssertTrue(held.reviewHold)
        continuation.yield(.ownershipConfirmed)
        await model.loadLocalState()
        await model.refresh()
        XCTAssertTrue(model.accountQuarantined)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
        let reopened = await FileLibraryStore(url: url).state()
        XCTAssertTrue(reopened.reviewHold)
    }

    private func certifiedCache() async throws -> FileMediaCache {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("certified-audio"))
        let data = Data("owner-bound prepared audio".utf8)
        let file = scratch.appendingPathComponent("owner-fixture")
        try data.write(to: file)
        let offer = try LibraryMediaOffer(entryID: id("old"), revisionID: RevisionID(rawValue: "prepared-r1"),
            contentHash: MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count), mediaType: "audio/mpeg",
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(date)))
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let token = await cache.admission(entryID: id("old"), ownerToken: "owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        _ = try await cache.adopt(verifiedFile: file, for: offer, admission: XCTUnwrap(token))
        return cache
    }

    func testDurableSameOwnerPreparationReopensAndVerifiesWithOfflineTransport() async throws {
        _ = try await bound()
        _ = try await certifiedCache()
        let reopenedCache = FileMediaCache(rootURL: scratch.appendingPathComponent("certified-audio"))
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "offline"),
            store: FileLibraryStore(url: url), deviceID: "phone", mediaCache: reopenedCache, preferences: try defaults())
        await model.loadLocalState()
        XCTAssertEqual(model.mediaState(for: id("old")), .onPhone)
        let admitted = await model.verifiedCachedMedia(id("old"), token: model.beginExternalStart())
        XCTAssertNotNil(admitted)
        await model.refresh()
        XCTAssertEqual(model.mediaState(for: id("old")), .onPhone, "failed refresh preserves certified offline bytes")
    }

    func testHeldAndUnboundMirrorCannotPromotePreviouslyCertifiedBytes() async throws {
        let store = try await bound()
        let cache = try await certifiedCache()
        try await store.quarantine()
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "offline"), store: store,
            deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await model.loadLocalState()
        XCTAssertNotEqual(model.mediaState(for: id("old")), .onPhone)
        let admitted = await model.verifiedCachedMedia(id("old"), token: model.beginExternalStart())
        XCTAssertNil(admitted)
        _ = try legacy()
        let legacyModel = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "offline"),
            store: FileLibraryStore(url: url), deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await legacyModel.loadLocalState()
        XCTAssertNotEqual(legacyModel.mediaState(for: id("old")), .onPhone)
    }

    func testObservedNotReadyRevokesRetainedPreparationAcrossCacheReopen() async throws {
        let store = try await bound()
        let cache = try await certifiedCache()
        let transport = OwnerCacheTransport(batch: try batch(["old"], full: false), offers: [.notReady(entryID: id("old"))])
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await model.loadLocalState()
        XCTAssertEqual(model.mediaState(for: id("old")), .onPhone)
        await model.refresh()
        XCTAssertNotEqual(model.mediaState(for: id("old")), .onPhone)
        let reopened = FileMediaCache(rootURL: scratch.appendingPathComponent("certified-audio"))
        try await reopened.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let inventory = await reopened.cachedEntries()
        XCTAssertNil(inventory[id("old")])
    }

    func testCommittedQueueRemovalRevokesPreparationButEmptyOfferListDoesNot() async throws {
        let store = try await bound()
        let cache = try await certifiedCache()
        let transport = OwnerCacheTransport(batch: try batch(["old"], full: false))
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await model.loadLocalState()
        await model.refresh()
        XCTAssertEqual(model.mediaState(for: id("old")), .onPhone, "successful absent offers are not a semantic withdrawal")
        XCTAssertEqual(model.visibleRows.map(\.id), [id("old")], "an empty offer response keeps prepared queued audio listed")
        let removal = OwnerCacheTransport(batch: try batch([]))
        let removedModel = LibraryAppModel(transport: removal, store: store, deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await removedModel.loadLocalState()
        await removedModel.refresh()
        XCTAssertTrue(removedModel.queued.isEmpty)
        XCTAssertTrue(removedModel.visibleRows.isEmpty, "a committed queue removal removes the row")
        let inventory = await cache.cachedEntries()
        XCTAssertNil(inventory[id("old")])
    }

    func testDifferentDurableOwnerCannotUsePriorOwnersProof() async throws {
        _ = try await bound()
        let cache = try await certifiedCache()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["ownerToken"] = "different-owner"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "offline"),
            store: FileLibraryStore(url: url), deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await model.loadLocalState()
        XCTAssertNotEqual(model.mediaState(for: id("old")), .onPhone)
        let admitted = await model.verifiedCachedMedia(id("old"), token: model.beginExternalStart())
        XCTAssertNil(admitted)
    }

    func testChangedCertifiedPreparationRevokesPriorSameRevisionProof() async throws {
        let store = try await bound()
        let cache = try await certifiedCache()
        let inventory = await cache.cachedEntries()
        let old = try XCTUnwrap(inventory[id("old")]?.preparation?.offer)
        let changed = try LibraryMediaOffer(entryID: old.entryID, revisionID: old.revisionID,
            contentHash: old.contentHash, byteCount: old.byteCount, mediaType: old.mediaType, state: .available,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(date.addingTimeInterval(60))))
        let transport = OwnerCacheTransport(batch: try batch(["old"], full: false), offers: [changed])
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone", mediaCache: cache, preferences: try defaults())
        await model.loadLocalState()
        XCTAssertEqual(model.mediaState(for: id("old")), .onPhone)
        await model.refresh()
        XCTAssertNotEqual(model.mediaState(for: id("old")), .onPhone)
        let after = await cache.cachedEntries()
        XCTAssertNil(after[id("old")])
        let admitted = await model.verifiedCachedMedia(id("old"), token: model.beginExternalStart())
        XCTAssertNil(admitted)
    }

    private func seedRecoveryConsequences(_ model: LibraryAppModel) async throws {
        let entryID = id("old")
        let bytes = Data("verified episode audio".utf8)
        let file = scratch.appendingPathComponent("fixture-audio")
        try bytes.write(to: file)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try RevisionID(rawValue: "r1")
        let offer = try LibraryMediaOffer(entryID: entryID, revisionID: revision,
            contentHash: hash, byteCount: Int64(bytes.count), mediaType: "audio/mpeg", durationSeconds: 30,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(date)))
        // Seed already-certified retained bytes before applying the held startup binding.
        try await model.mediaCache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let token = await model.mediaCache.admission(entryID: entryID, ownerToken: "owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        let admission = try XCTUnwrap(token)
        recoveryAudioURL = try await model.mediaCache.adopt(verifiedFile: file, for: offer, admission: admission)
        let transcript = try LibraryTranscript(entryID: entryID, revisionID: revision, plainText: "saved transcript")
        await model.mediaCache.storeTranscript(transcript)
        model.transcripts[entryID] = transcript
        let intent = try LibraryIntent.requestMedia(entryID: entryID, deviceID: "phone", createdAt: date)
        model.decisions = [PendingDecision(intent: intent, baseline: try XCTUnwrap(EntryPlacement(of: entryID, in: model.decisionContent)))]
        try await model.mediaCache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: true)
        model.handoffState.ownPositions[entryID] = ObservedPlayback(record: try DevicePlaybackPosition(
            deviceID: "phone", entryID: entryID, revision: revision,
            positionSeconds: 20, isPlaying: false, epoch: 1), serverModifiedAt: date)
    }

    func testFailedExplicitRecoveryKeepsHeldRowsPositionsAndDecisions() async throws {
        let store = try await bound()
        try await store.quarantine()
        let bytes = try Data(contentsOf: url)
        let recovery = LibraryAccountRecovery(quarantineEvents: AsyncStream { $0.finish() }) {
            throw LibraryTransportError.transport("reset failure")
        }
        let model = LibraryAppModel(transport: OwnerCacheTransport(batch: try batch()), store: store, deviceID: "phone",
            recovery: recovery, mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.loadLocalState()
        try await seedRecoveryConsequences(model)
        model.playedOut[id("old")] = date
        await model.recoverFromAccountChange()
        XCTAssertTrue(model.accountQuarantined)
        XCTAssertEqual(model.queued.map(\.id), [id("old")])
        XCTAssertEqual(model.playedOut[id("old")], date)
        XCTAssertEqual(model.decisions.count, 1)
        XCTAssertNotNil(model.handoffState.ownPositions[id("old")])
        XCTAssertNotNil(model.transcripts[id("old")])
        let cached = await model.mediaCache.cachedEntries()
        XCTAssertNil(cached[id("old")], "held proof stays inventory-inert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recoveryAudioURL).path), "failed recovery retains the bytes")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testExplicitRecoveryAloneDiscardsHeldMirrorAndPlaybackPositions() async throws {
        let store = try await bound()
        try await store.quarantine()
        let storeURL = url
        let recovery = LibraryAccountRecovery(quarantineEvents: AsyncStream { $0.finish() }) {
            try await store.discard()
            return FileLibraryStore(url: storeURL)
        }
        let model = LibraryAppModel(transport: OwnerCacheTransport(batch: try batch(), failFetch: true), store: store,
            deviceID: "phone", recovery: recovery, mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("audio")), preferences: try defaults())
        await model.loadLocalState()
        try await seedRecoveryConsequences(model)
        let retainedAudio = try XCTUnwrap(recoveryAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedAudio.path), "recovery begins with real retained audio")
        await model.recoverFromAccountChange()
        XCTAssertFalse(model.accountQuarantined)
        XCTAssertTrue(model.queued.isEmpty && model.handoffState.ownPositions.isEmpty && model.checkpoints.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(model.decisions.isEmpty && model.transcripts.isEmpty)
        let cached = await model.mediaCache.cachedEntries()
        XCTAssertTrue(cached.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedAudio.path), "confirmed recovery physically discards old audio, not just admission")
    }

}

actor OwnerCacheTransport: LibraryTransport {
    let batch: LibraryChangeBatch
    private let suspend: Bool
    private let owner: String?
    private let failFetch: Bool
    private let ownerProbe: (@Sendable () async -> String?)?
    private var offers: [LibraryMediaOffer]
    private let failAck: Bool
    private let invalidateDuringVerification: Bool
    private var generation: UInt64 = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var fetchCount = 0
    init(batch: LibraryChangeBatch, suspend: Bool = false, owner: String? = "owner", failFetch: Bool = false,
         failAck: Bool = false, invalidateDuringVerification: Bool = false, offers: [LibraryMediaOffer] = [], ownerProbe: (@Sendable () async -> String?)? = nil) {
        self.batch = batch; self.suspend = suspend; self.owner = owner; self.failFetch = failFetch
        self.ownerProbe = ownerProbe
        self.offers = offers
        self.failAck = failAck; self.invalidateDuringVerification = invalidateDuringVerification
    }
    func operationGeneration() -> UInt64 { generation }
    func verifiedOwnerToken() async -> String? {
        if let ownerProbe { return await ownerProbe() }
        if invalidateDuringVerification { generation &+= 1 }
        return owner
    }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        fetchCount += 1
        if suspend { await withCheckedContinuation { waiter = $0 } }
        if failFetch { throw LibraryTransportError.transport("partial or malformed fetch") }
        return batch
    }
    func commitFetchedState(_ token: LibraryChangeToken?) throws {
        if failAck { throw LibraryTransportError.transport("token acknowledgement failed") }
    }
    func waitForFetch() async { while fetchCount == 0 { await Task.yield() } }
    func release() { waiter?.resume(); waiter = nil }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { .init() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func replaceOffers(_ value: [LibraryMediaOffer]) { offers = value }
    func mediaOffers() async throws -> [LibraryMediaOffer] {
        if failFetch { throw LibraryTransportError.transport("offers unavailable") }
        return offers
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { .init() }
}
