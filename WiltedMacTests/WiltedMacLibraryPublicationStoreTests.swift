import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

actor PublicationBytes {
    var bytes: [String: Data] = [:]
    var writes = 0
    var failingWrite: Int?
    var hook: (@Sendable (Int) async -> Void)?
    func load(_ key: String) -> Data? { bytes[key] }
    func seed(owner: String, data: Data) { bytes[WiltedMacLibraryPublicationStore.key(for: owner)] = data }
    func fail(_ number: Int?) { failingWrite = number }
    func setHook(_ value: (@Sendable (Int) async -> Void)?) { hook = value }
    func save(_ key: String, _ value: Data) async throws {
        writes += 1
        await hook?(writes)
        if writes == failingWrite { throw LibraryTransportError.transport("injected sidecar write failure") }
        bytes[key] = value
    }
    nonisolated var store: WiltedMacLibraryPublicationStore {
        .init(loadBytes: { await self.load($0) }, saveBytes: { try await self.save($0, $1) })
    }
}

actor PublicationBarrier {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrived = true; arrivals.forEach { $0.resume() }; arrivals = []
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}

actor PublicationOwnerBox {
    var value: String? = "owner"
    func set(_ value: String?) { self.value = value }
}

actor PublicationSource: LibraryStateSource {
    var value: LibraryStateSnapshot
    var hook: (@Sendable () async -> Void)?
    init(_ value: LibraryStateSnapshot) { self.value = value }
    func set(_ value: LibraryStateSnapshot) { self.value = value }
    func setHook(_ value: (@Sendable () async -> Void)?) { hook = value }
    func currentState() async throws -> LibraryStateSnapshot {
        let captured = value
        await hook?()
        return captured
    }
}

struct PublicationSink: LibraryIntentSink { func receive(_ intent: LibraryIntent) async throws {} }

actor PublicationTransport: LibraryTransport {
    enum Failure: Equatable { case missing, conflict, retryable, terminal, deletion, unrelated }
    let inner: InMemoryLibraryTransport
    var failure: Failure?
    var tokenFails = false
    var receiptFails = false
    var tokenHook: (@Sendable () async -> Void)?
    var pushes = 0
    var receipts: [LibraryPublication] = []
    init(_ inner: InMemoryLibraryTransport) { self.inner = inner }
    func setFailure(_ value: Failure?) { failure = value }
    func failToken(_ value: Bool) { tokenFails = value }
    func failReceipt(_ value: Bool) { receiptFails = value }
    func setTokenHook(_ value: (@Sendable () async -> Void)?) { tokenHook = value }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await inner.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws {
        await tokenHook?()
        if tokenFails { throw LibraryTransportError.transport("injected token failure") }
        try await inner.commitSentState(token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        pushes += 1
        let result = try await inner.push(changes: changes)
        guard let failure, let rejected = changes.first(where: { failure != .deletion || $0.key.kind == .slot }) else { return result }
        if failure == .unrelated {
            return LibraryPushResult(token: result.token, acknowledged: result.acknowledged,
                failures: [.init(key: .init(kind: .entry, id: try ItemID(rawValue: "unrelated")), disposition: .terminal)])
        }
        let accepted = result.acknowledged.filter { $0.key != rejected.key }
        let disposition: LibraryFailureDisposition?
        switch failure {
        case .missing, .deletion: disposition = nil
        case .conflict: disposition = .conflict
        case .retryable: disposition = .retryable
        case .terminal, .unrelated: disposition = .terminal
        }
        let failures = disposition.map { [LibraryPushFailure(key: rejected.key, disposition: $0)] } ?? []
        return LibraryPushResult(token: result.token, acknowledged: accepted, failures: failures)
    }
    func publishPublication(_ value: LibraryPublication) async throws {
        receipts.append(value)
        if receiptFails { throw LibraryTransportError.transport("injected receipt failure") }
        try await inner.publishPublication(value)
    }
    func readPublication() async throws -> LibraryPublication? { try await inner.readPublication() }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { .init() }
}

struct PublicationScenario: Sendable {
    let bytes = PublicationBytes()
    let server = InMemoryLibraryServer(writerDeviceID: "mac")
    let source: PublicationSource
    let inner: InMemoryLibraryTransport
    let transport: PublicationTransport
    init() throws {
        source = PublicationSource(try Self.state())
        inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        transport = PublicationTransport(inner)
    }
    static func state(title: String = "Captured", queued: Bool = true) throws -> LibraryStateSnapshot {
        let feed = try ItemID(rawValue: "feed-publication")
        let entry = try ItemID(rawValue: "entry-publication")
        return LibraryStateSnapshot(feeds: [LibrarySource(id: feed, kind: .podcastFeed, title: "Feed")],
            episodes: [try LibraryEntry(id: entry, kind: .podcastEpisode, sourceID: feed, title: title,
                                       summary: "", publishedAt: Date(timeIntervalSince1970: 1))],
            queue: queued ? [entry] : [])
    }
    func publisher(owner: String = "owner", date: Date = Date(timeIntervalSince1970: 100),
                   ownerProvider: (@Sendable () async -> String?)? = nil) -> WiltedMacLibraryPublisher {
        WiltedMacLibraryPublisher(source: source, transport: transport, sink: PublicationSink(), relaysIntents: false,
            clock: { date }, publicationStore: bytes.store, deviceID: "mac", approvedOwner: ownerProvider ?? { owner })
    }
}

@MainActor
final class WiltedMacLibraryPublicationStoreTests: XCTestCase {
    private func pending() throws -> WiltedMacLibraryPublicationEnvelope {
        let change = LibraryChange.source(LibrarySource(id: try ItemID(rawValue: "feed-sidecar"), kind: .podcastFeed, title: "Feed"))
        return .init(ownerToken: "owner", pending: .init(id: "operation", writerDeviceID: "mac", captured: [change], remaining: [change]))
    }
    private func receipt() throws -> LibraryPublication { try .init(id: "operation", publishedAt: Date(timeIntervalSince1970: 42), writerDeviceID: "mac") }

    func testAbsentSidecarHasUnknownDateAndNoPendingObligation() async throws {
        let value = try await PublicationBytes().store.load(owner: "owner")
        XCTAssertNil(value.fulfilled); XCTAssertNil(value.pending)
    }
    func testPendingOperationRoundTripsWithoutInventingPublicationDate() async throws {
        let bytes = PublicationBytes(); let original = try pending()
        try await bytes.store.save(original)
        let loaded = try await bytes.store.load(owner: "owner")
        XCTAssertEqual(loaded, original); XCTAssertNil(loaded.pending?.publishedAt)
    }
    func testFulfilledEvidenceRoundTripsItsOriginalIdentityAndDate() async throws {
        let bytes = PublicationBytes(); let value = try receipt()
        try await bytes.store.save(.init(ownerToken: "owner", fulfilled: value))
        let loaded = try await bytes.store.load(owner: "owner")
        XCTAssertEqual(loaded.fulfilled, value)
    }
    func testDifferentOwnerRetainsHistoricalBytesWithoutPresentingThem() async throws {
        let bytes = PublicationBytes(); let value = try receipt()
        try await bytes.store.save(.init(ownerToken: "owner", fulfilled: value))
        let other = try await bytes.store.load(owner: "other")
        let historical = try await bytes.store.load(owner: "owner")
        XCTAssertNil(other.fulfilled); XCTAssertEqual(historical.fulfilled, value)
    }
    func testDamagedSidecarIsAnErrorRatherThanNow() async {
        let bytes = PublicationBytes(); await bytes.seed(owner: "owner", data: Data("damaged".utf8))
        do { _ = try await bytes.store.load(owner: "owner"); XCTFail("damaged evidence accepted") } catch {}
    }
    func testForgedAccountAssociationIsRejected() async throws {
        let bytes = PublicationBytes(); var value = try pending(); value.ownerToken = "other"
        await bytes.seed(owner: "owner", data: try JSONEncoder().encode(value))
        do { _ = try await bytes.store.load(owner: "owner"); XCTFail("wrong account accepted") } catch {}
    }
    func testDuplicateRemainingKeysAreRejectedAsDamagedEvidence() async throws {
        let bytes = PublicationBytes(); var value = try pending()
        let duplicate = value.pending!.remaining[0]
        value.pending?.remaining.append(duplicate)
        await bytes.seed(owner: "owner", data: try JSONEncoder().encode(value))
        do { _ = try await bytes.store.load(owner: "owner"); XCTFail("duplicate obligation accepted") } catch {}
    }
    func testChangedRemainingPayloadUnderCapturedKeyIsRejected() async throws {
        let bytes = PublicationBytes(); var value = try pending()
        value.pending?.remaining = [.source(LibrarySource(id: try ItemID(rawValue: "feed-sidecar"), kind: .podcastFeed, title: "Forged"))]
        await bytes.seed(owner: "owner", data: try JSONEncoder().encode(value))
        do { _ = try await bytes.store.load(owner: "owner"); XCTFail("changed captured value accepted") } catch {}
    }
    func testEmptyUnfulfilledObligationIsRejectedInsteadOfStallingForever() async throws {
        let bytes = PublicationBytes(); var value = try pending(); value.pending?.remaining = []
        await bytes.seed(owner: "owner", data: try JSONEncoder().encode(value))
        do { _ = try await bytes.store.load(owner: "owner"); XCTFail("impossible retry state accepted") } catch {}
    }
    func testFailedSaveKeepsPriorDurableEvidence() async throws {
        let bytes = PublicationBytes(); let old = try receipt()
        try await bytes.store.save(.init(ownerToken: "owner", fulfilled: old)); await bytes.fail(2)
        do { try await bytes.store.save(pending()); XCTFail("failure hidden") } catch {}
        let loaded = try await bytes.store.load(owner: "owner")
        XCTAssertEqual(loaded.fulfilled, old); XCTAssertNil(loaded.pending)
    }
    func testExistingProducerSQLiteSidecarHydratesAcrossHelperReopen() async throws {
        let root = wiltedTemporaryDirectory("publication-sidecar-sqlite")
        let local = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let value = try receipt()
        try await WiltedMacLibraryPublicationStore.store(local).save(.init(ownerToken: "owner", fulfilled: value))
        let reopened = WiltedMacLibraryPublicationStore.store(local)
        let loaded = try await reopened.load(owner: "owner")
        let raw = try await local.syncState(for: WiltedMacLibraryPublicationStore.key(for: "owner"))
        XCTAssertEqual(loaded.fulfilled, value); XCTAssertFalse(try XCTUnwrap(raw).engineState.isEmpty)
    }
}
