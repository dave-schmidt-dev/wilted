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

/// Thread-safe collector for retry callbacks and backoff waits.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// The CloudKit adapter's error as it reaches the fetcher: same case name and printed form as
/// `CloudKitSyncError.cloudKit(code:message:)`, which this package cannot import.
private enum AdapterError: Error { case cloudKit(code: Int, message: String) }

/// Throws the scripted errors on the first fetches, then delivers through the in-memory transport.
private final class ScriptedFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [any Error]
    private var count = 0
    init(_ failures: [any Error]) { self.failures = failures }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return failures.isEmpty ? nil : failures.removeFirst()
    }
}

private struct FlakyTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let script: ScriptedFetch
    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { fatalError() }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { fatalError() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        if let failure = script.next() { throw failure }
        return try await inner.fetchMedia(offer, progress: progress)
    }
}

/// A clock that moves only when told to; a sleeper wakes once time reaches its deadline.
private final class ManualClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]

    var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
    var minimumResolution: Swift.Duration { .zero }
    var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                let early: Result<Void, Error>?
                if Task.isCancelled {
                    early = .failure(CancellationError())
                } else if current >= deadline {
                    early = .success(())
                } else {
                    sleepers[id] = (deadline, continuation)
                    early = nil
                }
                lock.unlock()
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers[id] = nil }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

/// Reports a little progress every `step` of clock time for `steps` steps, then delivers.
private struct SlowTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let clock: ManualClock
    let step: Duration
    let steps: Int
    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { fatalError() }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { fatalError() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        for index in 1...steps {
            clock.advance(by: step)
            progress(Int64(index))
            await Task.yield()
        }
        return try await inner.fetchMedia(offer, progress: progress)
    }
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

    // MARK: automatic retry

    func testTwoTransientFailuresThenSuccessCacheWithoutAManualRetry() async throws {
        let (inner, source, cache) = try await fixture()
        let ready = try offer(for: source)
        try await inner.publishMedia(offer: ready, fileURL: source)
        let script = ScriptedFetch([
            AdapterError.cloudKit(code: 4, message: "Network failure"),
            NSError(domain: "CKErrorDomain", code: 23),
        ])
        let sleeps = Recorder<Duration>(), retries = Recorder<MediaFetchRetry>(), log = StateLog()
        let fetcher = MediaFetcher(cache: cache, sleep: { sleeps.append($0) })

        let outcome = try await fetcher.fetch(
            ready, from: FlakyTransport(inner: inner, script: script), admission: await cache.admission(for: ready),
            onState: { log.append($0) }, onRetry: { retries.append($0) })

        guard case let .cached(url) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
        XCTAssertEqual(script.attempts, 3)
        XCTAssertEqual(sleeps.values, [.seconds(2), .seconds(8)])
        XCTAssertEqual(retries.values, [
            MediaFetchRetry(attempt: 2, attempts: 3, delay: .seconds(2), cause: .offline),
            MediaFetchRetry(attempt: 3, attempts: 3, delay: .seconds(8), cause: .other),
        ])
        XCTAssertFalse(log.states.contains { if case .failed = $0 { true } else { false } })
        XCTAssertEqual(log.states.filter { $0 == .awaiting }.count, 3, "each attempt starts over")
        XCTAssertEqual(log.states.last, .cached)
    }

    func testTransientFailureOnEveryAttemptEndsOfflineAfterThree() async throws {
        let (inner, source, cache) = try await fixture([1, 2, 3])
        let ready = try offer(for: source)
        try await inner.publishMedia(offer: ready, fileURL: source)
        let script = ScriptedFetch(Array(repeating: URLError(.notConnectedToInternet), count: 5))
        let sleeps = Recorder<Duration>()

        let outcome = try await MediaFetcher(cache: cache, sleep: { sleeps.append($0) })
            .fetch(ready, from: FlakyTransport(inner: inner, script: script), admission: await cache.admission(for: ready))

        XCTAssertEqual(outcome, .failed(.deliveryFailed(MediaFetchFailure.offline.rawValue)))
        guard case let .failed(reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason.fetchFailure, .offline)
        XCTAssertEqual(script.attempts, 3)
        XCTAssertEqual(sleeps.values.count, 2)
    }

    func testTerminalFailuresEndAtOnceWithoutRetrying() async throws {
        let cases: [(any Error, MediaFetchFailure)] = [
            (AdapterError.cloudKit(code: 11, message: "Record not found"), .macNotAnswering),
            (LibraryTransportError.transport("the offer for item-a exceeds the size limit"), .tooLarge),
            (AdapterError.cloudKit(code: -1, message: "Raw CloudKit operations are unavailable"), .other),
            (URLError(.badServerResponse), .other),
        ]
        for (error, expected) in cases {
            let (inner, source, cache) = try await fixture([1, 2, 3])
            let ready = try offer(for: source)
            try await inner.publishMedia(offer: ready, fileURL: source)
            let script = ScriptedFetch([error, error, error])
            let sleeps = Recorder<Duration>(), retries = Recorder<MediaFetchRetry>()

            let outcome = try await MediaFetcher(cache: cache, sleep: { sleeps.append($0) }).fetch(
                ready, from: FlakyTransport(inner: inner, script: script), admission: await cache.admission(for: ready),
                onRetry: { retries.append($0) })

            XCTAssertEqual(outcome, .failed(.deliveryFailed(expected.rawValue)), "\(error)")
            XCTAssertEqual(script.attempts, 1, "\(error)")
            XCTAssertTrue(sleeps.values.isEmpty, "\(error)")
            XCTAssertTrue(retries.values.isEmpty, "\(error)")
        }
    }

    func testHashMismatchIsTerminalAndNotRetried() async throws {
        let (inner, source, cache) = try await fixture([1, 2, 3, 4])
        let other = MediaHash.prefix + SHA256.hash(data: Data([9])).map { String(format: "%02x", $0) }.joined()
        let wrong = try offer(for: source, hash: other)
        try await inner.publishMedia(offer: wrong, fileURL: source)
        let script = ScriptedFetch([])
        let sleeps = Recorder<Duration>()

        let outcome = try await MediaFetcher(cache: cache, sleep: { sleeps.append($0) })
            .fetch(wrong, from: FlakyTransport(inner: inner, script: script), admission: await cache.admission(for: wrong))

        XCTAssertEqual(outcome, .failed(.hashMismatch))
        XCTAssertEqual(script.attempts, 1)
        XCTAssertTrue(sleeps.values.isEmpty)
    }

    func testAClosedGateStretchesTheBackoffUpToItsCap() {
        XCTAssertEqual(MediaFetcher.backoff(.seconds(2), after: URLError(.timedOut)), .seconds(2))
        let soon = MediaFetcher.backoff(.seconds(2), after: TransportThrottled(retryAt: Date().addingTimeInterval(30)))
        XCTAssertTrue(soon > .seconds(29) && soon <= .seconds(30), "\(soon)")
        let late = MediaFetcher.backoff(.seconds(8), after: TransportThrottled(retryAt: Date().addingTimeInterval(3_600)))
        XCTAssertEqual(late, .seconds(MediaFetcher.maximumThrottleWait))
        XCTAssertTrue(MediaFetchErrorClassifier.isTransient(TransportThrottled(retryAt: Date())))
    }

    // MARK: stall by progress, not elapsed time

    func testSteadySlowProgressPastTheOldLimitIsNotAStall() async throws {
        let (inner, source, cache) = try await fixture()
        let ready = try offer(for: source)
        try await inner.publishMedia(offer: ready, fileURL: source)
        let clock = ManualClock()
        // A byte every minute for ten minutes: twice the watchdog, never a minute without progress.
        let slow = SlowTransport(inner: inner, clock: clock, step: .seconds(60), steps: 10)
        let sleeps = Recorder<Duration>()

        let outcome = try await MediaFetcher(cache: cache, clock: clock, sleep: { sleeps.append($0) })
            .fetch(ready, from: slow, admission: await cache.admission(for: ready))

        guard case .cached = outcome else { return XCTFail("slow progress was treated as a stall: \(outcome)") }
        XCTAssertGreaterThan(clock.now.offset, MediaFetcher.defaultWatchdog)
        XCTAssertTrue(sleeps.values.isEmpty)
    }

    func testNoProgressForTheWatchdogIntervalIsAStall() async throws {
        let cache = TempMediaCache(root: scratch.appendingPathComponent("cache"))
        let source = try makeFile([1, 2, 3])
        let ready = try offer(for: source)
        let clock = ManualClock()
        let log = StateLog(), sleeps = Recorder<Duration>()
        let admission = await cache.admission(for: ready)
        let fetcher = MediaFetcher(cache: cache, clock: clock, sleep: { sleeps.append($0) })
        let pending = Task { try await fetcher.fetch(ready, from: StalledTransport(), admission: admission) { log.append($0) } }

        try await waitUntil("the early progress and a sleeping watchdog") {
            log.states.contains(.downloading(bytes: 10, total: 3)) && clock.sleeperCount == 1
        }
        clock.advance(by: .seconds(299))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(log.states.contains(.failed(.timedOut)), "one second short of the watchdog is not a stall")

        clock.advance(by: .seconds(1))
        let outcome = try await pending.value
        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertTrue(sleeps.values.isEmpty, "a stall is not retried")
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(1))
        }
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
