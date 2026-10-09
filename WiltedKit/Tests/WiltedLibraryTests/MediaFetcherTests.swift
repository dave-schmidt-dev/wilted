import CryptoKit
import Darwin
import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// Directory-backed cache used only by these tests.
private actor TempMediaCache: MediaCacheStore {
    let root: URL
    private(set) var adoptCount = 0
    private let ownerEpoch = UUID()
    private let cacheGeneration = UUID()
    private var revocation: UInt64 = 0
    private var offers: [String: LibraryMediaOffer] = [:]
    private var returnGate: FetcherAwaitGate?
    private var adoptGate: FetcherAwaitGate?
    func holdCacheReturn(_ gate: FetcherAwaitGate) { returnGate = gate }
    func holdAdoptReturn(_ gate: FetcherAwaitGate) { adoptGate = gate }
    func admission(for offer: LibraryMediaOffer) -> MediaCacheAdmission {
        MediaCacheAdmission(entryID: offer.entryID, ownerToken: "owner", libraryScope: "scope",
            ownerEpoch: ownerEpoch, entryRevocationEpoch: revocation,
            cacheGeneration: cacheGeneration, transportGeneration: 0)
    }
    func permits(_ token: MediaCacheAdmission, for offer: LibraryMediaOffer) -> Bool {
        offer.isPrepared && token == admission(for: offer)
    }
    func revoke() { revocation += 1 }


    init(root: URL) { self.root = root }

    private func location(_ offer: LibraryMediaOffer) -> URL {
        root.appendingPathComponent("\(offer.entryID.rawValue)-\(offer.revisionID?.rawValue ?? "none")-\(offer.contentHash.dropFirst(7).prefix(16))")
    }

    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
        guard permits(admission, for: offer), offers[location(offer).path] == offer else { return nil }
        let url = location(offer)
        let exists = FileManager.default.fileExists(atPath: url.path)
        await returnGate?.hold()
        return exists ? url : nil
    }

    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        guard permits(admission, for: offer) else { throw CocoaError(.fileWriteUnknown) }
        let destination = location(offer)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: verifiedFile)
            return destination
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: verifiedFile, to: destination)
        offers[destination.path] = offer
        adoptCount += 1
        await adoptGate?.hold()
        return destination
    }

    func remove(entryID: ItemID) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(entryID.rawValue + "-") {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}

/// Never delivers, and reports one early burst of progress; honors cancellation.
private struct StalledTransport: LibraryTransport {
    func verifiedOwnerToken() async -> String? { "owner" }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { fatalError() }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { fatalError() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        progress(10)
        try await Task.sleep(for: .seconds(60))
        fatalError("watchdog should have cancelled this")
    }
}

/// Thread-safe collector for state callbacks.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MediaTransferState] = []
    func append(_ state: MediaTransferState) { lock.lock(); values.append(state); lock.unlock() }
    var states: [MediaTransferState] { lock.lock(); defer { lock.unlock() }; return values }
}

final class MediaFetcherTests: XCTestCase {
    private var scratch: URL!
    private let entry = try! ItemID(rawValue: "item-a")
    private let revision = try! RevisionID(rawValue: "rev-1")

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("media-fetcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func makeFile(_ bytes: [UInt8], name: String = UUID().uuidString) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func offer(for file: URL, hash: String? = nil, byteCount: Int64? = nil) throws -> LibraryMediaOffer {
        let data = try Data(contentsOf: file)
        return try LibraryMediaOffer(
            entryID: entry, revisionID: revision,
            contentHash: hash ?? MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount ?? Int64(data.count), mediaType: "audio/mp4", durationSeconds: 60,
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        )
    }

    private func fixture(_ payload: [UInt8] = Array(repeating: 7, count: 3_000_000)) async throws
        -> (transport: InMemoryLibraryTransport, source: URL, cache: TempMediaCache) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let source = try makeFile(payload)
        let cache = TempMediaCache(root: scratch.appendingPathComponent("cache"))
        return (InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner"), source, cache)
    }

    // MARK: model

    func testCorruptedExactCacheIsNotReturnedAfterOfferWithdrawal() async throws {
        let (transport, source, cache) = try await fixture([1, 2, 3, 4])
        let ready = try offer(for: source)
        try await transport.publishMedia(offer: ready, fileURL: source)
        let fetcher = MediaFetcher(cache: cache)
        guard case let .cached(file) = try await fetcher.fetch(ready, from: transport, admission: await cache.admission(for: ready)) else { return XCTFail("initial cache") }
        try Data([4, 3, 2, 1]).write(to: file)
        try await transport.removeMedia(entryID: entry)
        let result = try await fetcher.fetch(ready, from: transport, admission: await cache.admission(for: ready))
        guard case .failed(.deliveryFailed) = result else { return XCTFail("corrupt cache reused: \(result)") }
    }

    func testSingleTargetVerifierRejectsSymlinkAndSameSizeReplacement() async throws {
        let file = try makeFile([1, 2, 3, 4])
        let expected = try offer(for: file)
        let valid = await MediaFetcher.verifies(file, byteCount: 4, contentHash: expected.contentHash)
        XCTAssertTrue(valid)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = await MediaFetcher.verifies(link, byteCount: 4, contentHash: expected.contentHash)
        XCTAssertFalse(linked)
        try Data([4, 3, 2, 1]).write(to: file)
        let changed = await MediaFetcher.verifies(file, byteCount: 4, contentHash: expected.contentHash)
        XCTAssertFalse(changed)
    }

    func testOfferValidationAndCoding() throws {
        let file = try makeFile([1, 2, 3])
        let ready = try offer(for: file)
        XCTAssertEqual(try JSONDecoder().decode(LibraryMediaOffer.self, from: JSONEncoder().encode(ready)), ready)
        let notReady = LibraryMediaOffer.notReady(entryID: entry)
        XCTAssertEqual(try JSONDecoder().decode(LibraryMediaOffer.self, from: JSONEncoder().encode(notReady)), notReady)
        XCTAssertThrowsError(try LibraryMediaOffer(entryID: entry, revisionID: revision, contentHash: "md5:x", byteCount: 3, mediaType: "audio/mp4"))
        XCTAssertThrowsError(try LibraryMediaOffer(entryID: entry, revisionID: nil, contentHash: ready.contentHash, byteCount: 3, mediaType: "audio/mp4"))
        XCTAssertThrowsError(try LibraryMediaOffer(entryID: entry, revisionID: revision, contentHash: ready.contentHash, byteCount: 0, mediaType: "audio/mp4"))
    }

    func testMediaCachedIntentRoundTripsAndDedupesByID() async throws {
        let intent = try LibraryIntent.mediaCached(entryID: entry, revisionID: revision, deviceID: "phone", id: "ack-1")
        XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: JSONEncoder().encode(intent)), intent)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        try await phone.send(intent: intent)
        try await phone.send(intent: intent)
        let listed = try await phone.listIntents()
        XCTAssertEqual(listed.count, 1)
    }

    func testDefaultTransportExtensionsCompileForExistingConformers() async throws {
        let stalled = StalledTransport()
        let offers = try await stalled.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
        try await stalled.removeMedia(entryID: entry)
        let source = try makeFile([1])
        do {
            try await stalled.publishMedia(offer: offer(for: source), fileURL: source)
            XCTFail("default publish must throw")
        } catch { XCTAssertTrue(error is LibraryTransportError) }
    }

    // MARK: streaming hash

    func testStreamingHashMatchesOneShotAcrossChunkBoundaries() throws {
        let bytes = (0..<10_007).map { UInt8($0 % 251) }
        let file = try makeFile(bytes)
        let expected = MediaHash.prefix + SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        for chunk in [1, 7, 4096, 10_007, 1 << 20] {
            XCTAssertEqual(try MediaHash.sha256(fileAt: file, chunkSize: chunk), expected, "chunk \(chunk)")
        }
        XCTAssertEqual(try MediaHash.sha256(fileAt: makeFile([])), MediaHash.prefix + SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
    }

    func testHashing250MBStaysUnderMemoryBound() throws {
        let file = scratch.appendingPathComponent("big.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let chunk = Data((0..<(1 << 20)).map { UInt8($0 & 0xFF) })
        var expected = SHA256()
        let writer = try FileHandle(forWritingTo: file)
        for _ in 0..<250 {
            try writer.write(contentsOf: chunk)
            expected.update(data: chunk)
        }
        try writer.close()
        let expectedHash = MediaHash.prefix + expected.finalize().map { String(format: "%02x", $0) }.joined()

        let baseline = Self.footprint()
        let peak = PeakSampler(baseline: baseline)
        peak.start()
        let actual = try MediaHash.sha256(fileAt: file)
        peak.stop()
        XCTAssertEqual(actual, expectedHash)
        XCTAssertLessThan(peak.growth, 64 * 1024 * 1024, "hash of a 250 MB file grew footprint by \(peak.growth) bytes")
    }

    // MARK: fetcher

    func testFetchVerifiesAndCaches() async throws {
        let (transport, source, cache) = try await fixture()
        let ready = try offer(for: source)
        try await transport.publishMedia(offer: ready, fileURL: source)
        let log = StateLog()
        let outcome = try await MediaFetcher(cache: cache).fetch(ready, from: transport, admission: await cache.admission(for: ready)) { log.append($0) }
        guard case let .cached(url) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
        let states = log.states
        XCTAssertEqual(states.first, .awaiting)
        XCTAssertEqual(states.last, .cached)
        XCTAssertTrue(states.contains(.verifying))
        let byteSteps = states.compactMap { state -> Int64? in
            if case let .downloading(bytes, total) = state { XCTAssertEqual(total, ready.byteCount); return bytes }
            return nil
        }
        XCTAssertFalse(byteSteps.isEmpty)
        XCTAssertEqual(byteSteps, byteSteps.sorted())
        XCTAssertEqual(byteSteps.last, ready.byteCount)
    }

    func testHashMismatchIsDiscardedNotCached() async throws {
        let (_, source, cache) = try await fixture()
        let delivered = try makeFile(Array(repeating: 9, count: 100), name: "delivered")
        let wrong = try offer(for: source, byteCount: 100)
        let log = StateLog()
        let outcome = try await MediaFetcher(cache: cache).accept(deliveredFile: delivered, for: wrong, admission: await cache.admission(for: wrong)) { log.append($0) }
        XCTAssertEqual(outcome, .failed(.hashMismatch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivered.path), "bad file must be deleted")
        let cached = await cache.cachedFile(for: wrong, admission: await cache.admission(for: wrong))
        XCTAssertNil(cached)
        XCTAssertEqual(log.states.last, .failed(.hashMismatch))
    }

    func testByteCountMismatchIsDiscardedBeforeHashing() async throws {
        let (_, source, cache) = try await fixture()
        let delivered = try makeFile(Array(repeating: 9, count: 50), name: "short")
        let claimed = try offer(for: source, byteCount: 51)
        let outcome = try await MediaFetcher(cache: cache).accept(deliveredFile: delivered, for: claimed, admission: await cache.admission(for: claimed))
        XCTAssertEqual(outcome, .failed(.byteCountMismatch(expected: 51, actual: 50)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivered.path))
        let adopted = await cache.adoptCount
        XCTAssertEqual(adopted, 0)
    }

    func testWatchdogTimesOutAfterNoProgress() async throws {
        let cache = TempMediaCache(root: scratch.appendingPathComponent("cache"))
        let source = try makeFile([1, 2, 3])
        let ready = try offer(for: source)
        let log = StateLog()
        let started = ContinuousClock.now
        let outcome = try await MediaFetcher(cache: cache, watchdog: .milliseconds(300))
            .fetch(ready, from: StalledTransport(), admission: await cache.admission(for: ready)) { log.append($0) }
        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertEqual(log.states.last, .failed(.timedOut))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertEqual(MediaFetcher.defaultWatchdog, .seconds(300))
    }

    func testNotReadyOfferNeverFetches() async throws {
        let cache = TempMediaCache(root: scratch.appendingPathComponent("cache"))
        let log = StateLog()
        let outcome = try await MediaFetcher(cache: cache).fetch(.notReady(entryID: entry), from: StalledTransport(), admission: await cache.admission(for: .notReady(entryID: entry))) { log.append($0) }
        XCTAssertEqual(outcome, .notReady)
        XCTAssertEqual(log.states, [.notReady])
    }

    func testFetchOfWithdrawnOfferFailsAsDelivery() async throws {
        let (transport, source, cache) = try await fixture()
        let ready = try offer(for: source)
        let outcome = try await MediaFetcher(cache: cache).fetch(ready, from: transport, admission: await cache.admission(for: ready))
        guard case .failed(.deliveryFailed) = outcome else { return XCTFail("\(outcome)") }
    }

    func testRedeliveryIsIdempotent() async throws {
        let (transport, source, cache) = try await fixture()
        let ready = try offer(for: source)
        try await transport.publishMedia(offer: ready, fileURL: source)
        let fetcher = MediaFetcher(cache: cache)
        guard case let .cached(first) = try await fetcher.fetch(ready, from: transport, admission: await cache.admission(for: ready)) else { return XCTFail("first") }
        guard case let .cached(second) = try await fetcher.fetch(ready, from: transport, admission: await cache.admission(for: ready)) else { return XCTFail("second") }
        XCTAssertEqual(first, second)
        // A duplicate delivery of already-cached bytes is discarded, not re-adopted.
        let duplicate = try makeFile(try Data(contentsOf: source).map { $0 }, name: "duplicate")
        guard case let .cached(third) = try await fetcher.accept(deliveredFile: duplicate, for: ready, admission: await cache.admission(for: ready)) else { return XCTFail("third") }
        XCTAssertEqual(third, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        let adopted = await cache.adoptCount
        XCTAssertEqual(adopted, 1)
    }

    func testOnlyWriterPublishesAndRemovalWithdrawsOffer() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let source = try makeFile([1, 2, 3, 4])
        let ready = try offer(for: source)
        do {
            try await phone.publishMedia(offer: ready, fileURL: source)
            XCTFail("follower must not publish")
        } catch { XCTAssertEqual(error as? LibraryTransportError, .ownershipViolation("phone may not publish media")) }
        try await mac.publishMedia(offer: ready, fileURL: source)
        try await mac.publishMedia(offer: .notReady(entryID: try ItemID(rawValue: "item-b")), fileURL: source)
        let offers = try await phone.mediaOffers()
        XCTAssertEqual(offers.map(\.entryID.rawValue), ["item-a", "item-b"])
        try await mac.removeMedia(entryID: entry)
        let remaining = try await phone.mediaOffers()
        XCTAssertEqual(remaining.map(\.entryID.rawValue), ["item-b"])
    }

    func testFetcherRejectsRevocationWhileCachedFileReturnIsAwaited() async throws {
        let (transport, source, cache) = try await fixture([1, 2, 3, 4])
        let ready = try offer(for: source)
        let token = await cache.admission(for: ready)
        let initial = try await MediaFetcher(cache: cache).accept(deliveredFile: source, for: ready, admission: token)
        guard case .cached = initial else { return XCTFail("initial certified cache") }
        let gate = FetcherAwaitGate()
        await cache.holdCacheReturn(gate)
        let log = StateLog()
        let pending = Task { try await MediaFetcher(cache: cache).fetch(ready, from: transport, admission: token) { log.append($0) } }
        await gate.waitUntilHeld()
        await cache.revoke()
        await gate.release()
        let outcome = try await pending.value
        guard case .failed(.cacheFailed) = outcome else { return XCTFail("Stale cache return: \(outcome)") }
        XCTAssertFalse(log.states.contains(.cached))
    }

    func testAcceptRejectsRevocationBeforeAwaitedAdoptionReturns() async throws {
        let (_, source, cache) = try await fixture([1, 2, 3, 4])
        let ready = try offer(for: source)
        let token = await cache.admission(for: ready)
        let gate = FetcherAwaitGate()
        await cache.holdAdoptReturn(gate)
        let log = StateLog()
        let pending = Task { try await MediaFetcher(cache: cache).accept(deliveredFile: source, for: ready, admission: token) { log.append($0) } }
        await gate.waitUntilHeld()
        await cache.revoke()
        await gate.release()
        let outcome = try await pending.value
        guard case .failed(.cacheFailed) = outcome else { return XCTFail("Stale adoption return: \(outcome)") }
        XCTAssertFalse(log.states.contains(.cached))
    }

    // MARK: memory sampling

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Polls this process's physical footprint on a background thread to catch the peak.
    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private let baseline: UInt64
        private var peak: UInt64
        private var running = false

        init(baseline: UInt64) { self.baseline = baseline; peak = baseline }

        func start() {
            lock.lock(); running = true; lock.unlock()
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let keepGoing = running
                    peak = max(peak, MediaFetcherTests.footprint())
                    lock.unlock()
                    if !keepGoing { break }
                    usleep(2_000)
                }
            }
        }

        func stop() { lock.lock(); running = false; lock.unlock(); usleep(10_000) }

        var growth: UInt64 { lock.lock(); defer { lock.unlock() }; return peak - baseline }
    }
}

private actor FetcherAwaitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false
    func hold() async { await withCheckedContinuation { continuation = $0; held = true } }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !held, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(held)
    }
    func release() { continuation?.resume(); continuation = nil }
}
