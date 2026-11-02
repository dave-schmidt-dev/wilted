import CryptoKit
import Foundation
import Network
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// The LAN server and client over real sockets on 127.0.0.1 (design M2 tests 1-7). Every server, client
/// connection and raw socket is owned by the test and torn down in `addTeardownBlock` (W-INV-014); all
/// files live in one temp directory the test deletes; every wait is bounded.
final class LANLoopbackTests: XCTestCase {
    private var scratch: URL!
    private let mebibyte = 1 << 20

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lan-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let scratch = scratch!
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Fixtures

    private func peer(_ seed: UInt8) -> LANTLSPeer {
        LANTLSPeer(identity: Data(repeating: seed, count: 16), psk: Data(repeating: seed &+ 100, count: 32))
    }

    private var partialDirectory: URL { scratch.appendingPathComponent("Partial") }

    /// A deterministic file of `bytes` bytes written block by block, with its `sha256:` hash. Each 1 MiB
    /// block is one pseudo-random block with its index stamped in, so no two blocks match.
    private func makeFile(bytes: Int, name: String = UUID().uuidString, corruptAt: Int? = nil) throws -> (URL, String) {
        var block = [UInt8](repeating: 0, count: mebibyte)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: 0, to: block.count, by: 8) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            withUnsafeBytes(of: state) { for k in 0..<8 { block[index + k] = $0[k] } }
        }
        let url = scratch.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var written = 0, index: UInt64 = 0
        while written < bytes {
            withUnsafeBytes(of: index) { for k in 0..<8 { block[k] = $0[k] } }
            let count = min(mebibyte, bytes - written)
            let data = Data(block.prefix(count))
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            written += count
            index += 1
        }
        if let corruptAt {
            // Same size, different byte: the hash above no longer describes the file.
            try handle.seek(toOffset: UInt64(corruptAt))
            try handle.write(contentsOf: Data([0xFF]))
        }
        return (url, MediaHash.prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func offer(
        entry: String = "item-a", revision: String = "rev-1", hash: String, bytes: Int,
        state: LibraryMediaOffer.State = .ready
    ) throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: ItemID(rawValue: entry), revisionID: RevisionID(rawValue: revision), contentHash: hash,
            byteCount: Int64(bytes), mediaType: "audio/mp4", durationSeconds: 60, state: state,
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
    }

    /// What the server's source closure saw, and what it answers.
    private final class SourceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [LANMediaRequest] = []
        var answer: @Sendable (LANMediaRequest) async -> LANSourceAnswer = { _ in .notReady }
        var requests: [LANMediaRequest] { lock.withLock { seen } }
        func call(_ request: LANMediaRequest) async -> LANSourceAnswer {
            lock.withLock { seen.append(request) }
            return await answer(request)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool = false) { self.value = value }
        var isSet: Bool { lock.withLock { value } }
        func set(_ new: Bool) { lock.withLock { value = new } }
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Collector<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        var values: [T] { lock.withLock { items } }
        func add(_ item: T) { lock.withLock { items.append(item) } }
    }

    private struct Rig {
        let server: LANMediaServer
        let port: UInt16
        let source: SourceBox
        let held: Flag
    }

    private func startServer(
        peers: [LANTLSPeer], deadlines: LANDeadlines = .standard, chunkBytes: Int = 1 << 20,
        configure: (LANMediaServer) -> Void = { _ in }
    ) async throws -> Rig {
        let source = SourceBox(), held = Flag()
        let server = LANMediaServer(
            configuration: .init(binding: .loopback, deadlines: deadlines, chunkBytes: chunkBytes),
            isHeld: { held.isSet }, source: { await source.call($0) })
        configure(server)
        addTeardownBlock { await server.stop() }
        let port = try await server.start(peers: peers)
        return Rig(server: server, port: try XCTUnwrap(port), source: source, held: held)
    }

    private func endpoint(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    private func client(
        ports: [UInt16], peer: LANTLSPeer, deadlines: LANDeadlines = .standard,
        onPhase: @escaping @Sendable (LANMediaPhase) -> Void = { _ in }
    ) -> LANMediaClient {
        LANMediaClient(
            endpoints: ports.map(endpoint), peer: peer, partialDirectory: partialDirectory, binding: .loopback,
            deadlines: deadlines, onPhase: onPhase)
    }

    private func waitUntil(
        _ what: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func expect(
        _ expected: LANMediaError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> URL
    ) async {
        do {
            let url = try await body()
            XCTFail("expected \(expected), got a file at \(url.lastPathComponent)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LANMediaError, expected, "\(error)", file: file, line: line)
        }
    }

    private func partialFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: partialDirectory.path)) ?? []
    }

    // MARK: M2 test 1: the full 250 MB file

    func testA250MBFileTransfersVerifiesAndReportsMonotonicProgress() async throws {
        let size = 250 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        rig.source.answer = { _ in .ready(served(file, item)) }
        let progress = Collector<Int64>(), phases = Collector<LANMediaPhase>()

        let url = try await client(ports: [rig.port], peer: phone, onPhase: { phases.add($0) })
            .fetch(item, from: 0) { progress.add($0) }

        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, Int64(size))
        let values = progress.values
        XCTAssertEqual(values.last, Int64(size))
        XCTAssertEqual(values, values.sorted(), "progress never goes backwards")
        XCTAssertTrue(phases.values.contains(.verifying) && phases.values.contains(.downloading), "each wait is announced")
        XCTAssertFalse(phases.values.contains(.resuming))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("item-a-rev-1-\(hash.dropFirst(7).prefix(16))"), url.lastPathComponent)
        try await waitUntil("the server to record the transfer") { rig.server.transferRecords.count == 1 }
        XCTAssertEqual(rig.server.transferRecords.first?.bytesSent, Int64(size))
        XCTAssertEqual(rig.server.transferRecords.first?.request?.offset, 0)
    }

    // MARK: M2 test 2: cut at 40%, resume

    func testACutAt40PercentResumesFromTheBytesOnDiskAndSendsOnlyTheRest() async throws {
        let size = 100 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone]) { server in
            server.shouldCut = { request, sent in request.offset == 0 && sent >= Int64(size) * 4 / 10 }
        }
        rig.source.answer = { _ in .ready(served(file, item)) }
        let phases = Collector<LANMediaPhase>(), progress = Collector<Int64>()

        let url = try await client(ports: [rig.port], peer: phone, onPhase: { phases.add($0) })
            .fetch(item, from: 0) { progress.add($0) }

        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash, "the resumed file is the original")
        XCTAssertTrue(phases.values.contains(.resuming))
        try await waitUntil("both connections to be recorded") { rig.server.transferRecords.count == 2 }
        let records = rig.server.transferRecords
        let first = records[0], second = records[1]
        XCTAssertGreaterThanOrEqual(first.bytesSent, Int64(size) * 4 / 10)
        let resumeOffset = try XCTUnwrap(second.request?.offset)
        XCTAssertGreaterThan(resumeOffset, 0)
        XCTAssertLessThanOrEqual(resumeOffset, first.bytesSent, "never asks for bytes it was not sent")
        XCTAssertEqual(second.bytesSent, Int64(size) - resumeOffset, "the second connection carries only the remaining bytes")
        XCTAssertEqual(progress.values.last, Int64(size))
        XCTAssertEqual(progress.values, progress.values.sorted())
    }

    func testTwoDropsInARowFailAndKeepThePartialFileForALaterTry() async throws {
        let size = 20 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone]) { server in
            server.shouldCut = { _, sent in sent >= Int64(2 * 1_048_576) }
        }
        rig.source.answer = { _ in .ready(served(file, item)) }

        do {
            _ = try await client(ports: [rig.port], peer: phone).fetch(item, from: 0) { _ in }
            XCTFail("a second drop must fail")
        } catch let LANMediaError.connectionDropped(received) {
            XCTAssertEqual(received, Int64(4 * mebibyte), "two cuts of 2 MiB each")
        }
        XCTAssertEqual(partialFiles().count, 1, "the partial stays")
        XCTAssertEqual(LANPartialFile.resumeOffset(in: partialDirectory, for: item), Int64(4 * mebibyte))

        // A later try resumes where the last one stopped.
        rig.server.shouldCut = nil
        let url = try await client(ports: [rig.port], peer: phone).fetch(
            item, from: LANPartialFile.resumeOffset(in: partialDirectory, for: item)) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)
        XCTAssertEqual(rig.source.requests.last?.offset, Int64(4 * mebibyte))
    }

    // MARK: M2 test 3: a neighbour's key, and picking the right advertiser

    func testNeighbourAndUnknownKeysAreRefusedAndTheClientPicksTheRightMac() async throws {
        let size = 3 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let mine = peer(1), neighbour = peer(2)
        let rig = try await startServer(peers: [mine])
        rig.source.answer = { _ in .ready(served(file, item)) }
        let neighbourRig = try await startServer(peers: [neighbour])
        neighbourRig.source.answer = { _ in .ready(served(file, item)) }

        // The neighbour's key and identity on my Mac: unknown identity, then a known identity with the wrong key.
        await expect(.handshakeFailed) { try await client(ports: [rig.port], peer: neighbour).fetch(item, from: 0) { _ in } }
        let wrongKey = LANTLSPeer(identity: mine.identity, psk: neighbour.psk)
        await expect(.handshakeFailed) { try await client(ports: [rig.port], peer: wrongKey).fetch(item, from: 0) { _ in } }
        XCTAssertTrue(rig.source.requests.isEmpty, "nothing was served to a refused key")
        XCTAssertEqual(rig.server.admittedCount, 0)
        XCTAssertTrue(partialFiles().isEmpty, "no stray file: \(partialFiles())")

        // Two advertisers: the neighbour's first, mine second. The handshake picks mine, with no resume used.
        let phases = Collector<LANMediaPhase>()
        let url = try await client(ports: [neighbourRig.port, rig.port], peer: mine, onPhase: { phases.add($0) })
            .fetch(item, from: 0) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)
        XCTAssertTrue(neighbourRig.source.requests.isEmpty)
        XCTAssertEqual(phases.values.filter { if case .connecting = $0 { true } else { false } }.count, 2)
        XCTAssertFalse(phases.values.contains(.resuming))
    }

    // MARK: M2 test 4: unknown key and held gate

    func testAHeldGateRefusesEveryConnectionAndServesNothing() async throws {
        let size = 2 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        rig.source.answer = { _ in .ready(served(file, item)) }

        rig.held.set(true)
        await expect(.handshakeFailed) { try await client(ports: [rig.port], peer: phone).fetch(item, from: 0) { _ in } }
        XCTAssertTrue(rig.source.requests.isEmpty, "the source is never asked while the gate holds")
        XCTAssertEqual(rig.server.admittedCount, 0)

        // The gate closing after the handshake still stops the first audio byte.
        rig.held.set(false)
        let held = rig.held
        rig.source.answer = { _ in
            held.set(true)
            return .ready(served(file, item))
        }
        await expect(.refused) { try await client(ports: [rig.port], peer: phone).fetch(item, from: 0) { _ in } }
        try await waitUntil("the refused connection to be recorded") { !rig.server.transferRecords.isEmpty }
        XCTAssertEqual(rig.server.transferRecords.last?.bytesSent, 0)

        // Reopened, the same phone is served again.
        rig.held.set(false)
        rig.source.answer = { _ in .ready(served(file, item)) }
        let url = try await client(ports: [rig.port], peer: phone).fetch(item, from: 0) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)
    }

    // MARK: M2 test 5: status answers and the connection limit

    func testStatusAnswersAreTypedAndNothingIsKeptForThem() async throws {
        let size = 2 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        let phoneClient = client(ports: [rig.port], peer: phone)

        rig.source.answer = { _ in .notReady }
        await expect(.notReady) { try await phoneClient.fetch(item, from: 0) { _ in } }
        rig.source.answer = { _ in .refused }
        await expect(.refused) { try await phoneClient.fetch(item, from: 0) { _ in } }
        let newer = try offer(revision: "rev-2", hash: hash, bytes: size)
        rig.source.answer = { _ in .ready(served(file, newer)) }
        await expect(.different) { try await phoneClient.fetch(item, from: 0) { _ in } }
        // The Mac's file is not the size its record says: refused, not served.
        let truncated = LANServedFile(fileURL: file, revisionID: item.revisionID!, contentHash: hash, byteCount: Int64(size))
        try FileManager.default.truncateFile(at: file, to: Int64(size - 10))
        rig.source.answer = { _ in .ready(truncated) }
        await expect(.refused) { try await phoneClient.fetch(item, from: 0) { _ in } }
        XCTAssertTrue(partialFiles().isEmpty, "a refused fetch leaves no file: \(partialFiles())")
    }

    func testAThirdConnectionGetsBusyWhileTwoTransfersHoldTheSlots() async throws {
        let size = 2 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        let gate = Gate()
        let items = try ["item-a", "item-b", "item-c"].map { try offer(entry: $0, hash: hash, bytes: size) }
        rig.source.answer = { request in
            if request.entryID.rawValue != "item-c" { await gate.wait() }
            return .ready(served(file, items.first { $0.entryID == request.entryID }!))
        }
        let phoneClient = client(ports: [rig.port], peer: phone)

        let first = Task { try await phoneClient.fetch(items[0], from: 0) { _ in } }
        let second = Task { try await phoneClient.fetch(items[1], from: 0) { _ in } }
        try await waitUntil("two transfers to hold their slots") { rig.server.activeTransferCount == 2 && rig.source.requests.count == 2 }

        await expect(.busy) { try await phoneClient.fetch(items[2], from: 0) { _ in } }
        XCTAssertEqual(rig.server.activeTransferCount, 2, "the busy answer takes no slot")

        await gate.release()
        _ = try await first.value
        _ = try await second.value
        // Slots come back: a new request is served.
        let third = try await phoneClient.fetch(items[2], from: 0) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: third), hash)
    }

    // MARK: M2 test 6: a bad delivery is never adopted

    func testAMismatchedDeliveryIsDeletedAndNeverReturned() async throws {
        let size = 5 * mebibyte
        let (good, hash) = try makeFile(bytes: size)
        let (bad, _) = try makeFile(bytes: size, name: "bad", corruptAt: 12345)
        _ = good
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        rig.source.answer = { _ in .ready(served(bad, item)) }
        let phases = Collector<LANMediaPhase>()

        await expect(.mismatch) {
            try await client(ports: [rig.port], peer: phone, onPhase: { phases.add($0) }).fetch(item, from: 0) { _ in }
        }
        XCTAssertTrue(partialFiles().isEmpty, "the partial file is gone: \(partialFiles())")
        XCTAssertTrue(phases.values.contains(.verifying))
        XCTAssertEqual(LANPartialFile.resumeOffset(in: partialDirectory, for: item), 0)
    }

    func testAnOfferWithoutACertifiedHashIsNeverFetchedDirectly() async throws {
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        let legacy = try offer(hash: "", bytes: 1000, state: .available)
        let unprepared = try LibraryMediaOffer(
            entryID: ItemID(rawValue: "item-a"), revisionID: RevisionID(rawValue: "rev-1"),
            contentHash: MediaHash.prefix + String(repeating: "a", count: 64), byteCount: 10, mediaType: "audio/mp4",
            state: .available)

        await expect(.invalidOffer) { try await client(ports: [rig.port], peer: phone).fetch(legacy, from: 0) { _ in } }
        await expect(.invalidOffer) { try await client(ports: [rig.port], peer: phone).fetch(unprepared, from: 0) { _ in } }
        await expect(.invalidOffer) {
            try await client(ports: [rig.port], peer: phone).fetch(.notReady(entryID: legacy.entryID), from: 0) { _ in }
        }
        XCTAssertEqual(rig.server.connectionCount, 0)
        XCTAssertEqual(rig.server.admittedCount, 0, "no connection was even opened")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialDirectory.path), "nothing was created")
    }

    func testAResumeOffsetIsHonouredAndNeverTrustedBeyondTheBytesOnDisk() async throws {
        let size = 6 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        rig.source.answer = { _ in .ready(served(file, item)) }

        // Seed a partial holding the first 2 MiB of the real file.
        let seed = try LANPartialFile.open(in: partialDirectory, for: item)
        try seed.append(try Data(contentsOf: file).prefix(2 * mebibyte))
        seed.close()

        let url = try await client(ports: [rig.port], peer: phone).fetch(item, from: Int64.max) { _ in }
        XCTAssertEqual(rig.source.requests.first?.offset, Int64(2 * mebibyte), "min(offset, bytes on disk)")
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)

        // Asked to start over, the old prefix is cut away.
        let again = try LANPartialFile.open(in: partialDirectory, for: item)
        again.close()
        _ = try await client(ports: [rig.port], peer: phone).fetch(item, from: 0) { _ in }
        XCTAssertEqual(rig.source.requests.last?.offset, 0)
    }

    // MARK: M2 test 7: quit cancels within 10 seconds

    func testCancelAllEndsAStalledTransferWellInsideTheQuitBudgetAndTheServerKeepsListening() async throws {
        let size = 64 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone])
        rig.source.answer = { _ in .ready(served(file, item)) }
        let raw = try await RawClient.connect(port: rig.port, peer: phone, owner: self)
        try await raw.send(LANMediaRequest(
            entryID: item.entryID, revisionID: item.revisionID!, contentHash: hash, byteCount: Int64(size), offset: 0).encoded())
        try await waitUntil("the server to start sending") { rig.server.activeTransferCount == 1 && !rig.source.requests.isEmpty }
        try await Task.sleep(for: .milliseconds(300))   // the client never reads, so the send stalls on a full buffer
        XCTAssertEqual(rig.server.connectionCount, 1)

        let started = ContinuousClock.now
        await rig.server.cancelAll()
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertEqual(rig.server.connectionCount, 0)
        XCTAssertEqual(rig.server.activeTransferCount, 0)
        let ended = await raw.drainUntilClosed(within: .seconds(10))
        XCTAssertTrue(ended, "the phone's side sees the connection end")
        XCTAssertLessThan(started.duration(to: .now), .seconds(10), "the whole cancel, seen from the phone, fits the quit drain")

        let small = try makeFile(bytes: mebibyte)
        let smallOffer = try offer(entry: "item-s", hash: small.1, bytes: mebibyte)
        rig.source.answer = { _ in .ready(served(small.0, smallOffer)) }
        let url = try await client(ports: [rig.port], peer: phone).fetch(smallOffer, from: 0) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), small.1, "cancelAll leaves the listener running")
    }

    // MARK: Key set changes, deadlines

    func testAChangedKeySetRestartsTheListenerAndCutsEveryOpenConnection() async throws {
        let size = 64 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let (kept, removed) = (peer(1), peer(2))
        let rig = try await startServer(peers: [kept, removed])
        rig.source.answer = { _ in .ready(served(file, item)) }
        let raw = try await RawClient.connect(port: rig.port, peer: removed, owner: self)
        try await raw.send(LANMediaRequest(
            entryID: item.entryID, revisionID: item.revisionID!, contentHash: hash, byteCount: Int64(size), offset: 0).encoded())
        try await waitUntil("the removed phone's transfer to start") { rig.server.activeTransferCount == 1 }

        let same = try await rig.server.updatePeers([kept, removed])
        XCTAssertFalse(same.restarted, "an unchanged set restarts nothing")
        XCTAssertEqual(rig.server.connectionCount, 1)

        let changed = try await rig.server.updatePeers([kept])
        XCTAssertTrue(changed.restarted)
        let port = try XCTUnwrap(changed.port)
        XCTAssertEqual(rig.server.connectionCount, 0, "a removed key stops at once, not at the end of its transfer")
        let ended = await raw.drainUntilClosed(within: .seconds(10))
        XCTAssertTrue(ended)

        await expect(.handshakeFailed) { try await client(ports: [port], peer: removed).fetch(item, from: 0) { _ in } }
        let url = try await client(ports: [port], peer: kept).fetch(item, from: 0) { _ in }
        XCTAssertEqual(try MediaHash.sha256(fileAt: url), hash)

        let none = try await rig.server.updatePeers([])
        XCTAssertNil(none.port, "no phones, no listener")
        XCTAssertNil(rig.server.port)
    }

    func testTheHandshakeAndIdleDeadlinesEndConnectionsThatStall() async throws {
        let size = 64 * mebibyte
        let (file, hash) = try makeFile(bytes: size)
        let item = try offer(hash: hash, bytes: size)
        let phone = peer(1)
        let rig = try await startServer(peers: [phone], deadlines: LANDeadlines(handshake: 1, idle: 1, overall: 30))
        rig.source.answer = { _ in .ready(served(file, item)) }

        // A plain TCP socket that never starts TLS holds nothing past the handshake limit.
        let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!, using: {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            return parameters
        }())
        plain.start(queue: DispatchQueue(label: "lan-loopback.plain"))
        addTeardownBlock { plain.cancel() }
        try await waitUntil("the plain socket to be admitted") { rig.server.connectionCount == 1 }
        try await waitUntil("the handshake deadline", seconds: 6) { rig.server.connectionCount == 0 }

        // A phone that stops reading mid-transfer is cut at the idle limit.
        let raw = try await RawClient.connect(port: rig.port, peer: phone, owner: self)
        try await raw.send(LANMediaRequest(
            entryID: item.entryID, revisionID: item.revisionID!, contentHash: hash, byteCount: Int64(size), offset: 0).encoded())
        try await waitUntil("the idle deadline", seconds: 8) { !rig.server.transferRecords.isEmpty && rig.server.connectionCount == 0 }
        XCTAssertLessThan(rig.server.transferRecords.last?.bytesSent ?? Int64.max, Int64(size))
    }

    // MARK: The partial file

    func testPartialFileNamesAreKeyedByRevisionAndHashAndOnlyOneFetchOwnsThem() throws {
        let hash = MediaHash.prefix + "0123456789abcdef" + String(repeating: "0", count: 48)
        let first = try offer(hash: hash, bytes: 100)
        let second = try offer(revision: "rev-2", hash: hash, bytes: 100)
        let url = try XCTUnwrap(LANPartialFile.url(in: partialDirectory, for: first))
        XCTAssertEqual(url.lastPathComponent, "item-a-rev-1-0123456789abcdef.part")
        XCTAssertNotEqual(url, LANPartialFile.url(in: partialDirectory, for: second), "a newer revision never resumes an older file")

        let owner = try LANPartialFile.open(in: partialDirectory, for: first)
        XCTAssertThrowsError(try LANPartialFile.open(in: partialDirectory, for: first)) {
            XCTAssertEqual($0 as? LANPartialFileError, .inUse)
        }
        try owner.append(Data(repeating: 1, count: 100))
        XCTAssertThrowsError(try owner.append(Data([1]))) { XCTAssertEqual($0 as? LANPartialFileError, .overrun) }
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        owner.close()

        // Closed, it can be reopened and resumes at its size; a file too big to be a prefix is replaced.
        let reopened = try LANPartialFile.open(in: partialDirectory, for: first)
        XCTAssertEqual(reopened.size, 100)
        reopened.close()
        let smaller = try offer(hash: hash, bytes: 50)
        let replaced = try LANPartialFile.open(in: partialDirectory, for: smaller)
        XCTAssertEqual(replaced.size, 0, "100 bytes cannot be the start of a 50-byte file")
        replaced.close()
    }
}

// MARK: - Helpers

private func served(_ url: URL, _ offer: LibraryMediaOffer) -> LANServedFile {
    LANServedFile(fileURL: url, revisionID: offer.revisionID!, contentHash: offer.contentHash, byteCount: offer.byteCount)
}

private extension FileManager {
    func truncateFile(at url: URL, to length: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }
}

/// A phone-side socket with the right key that sends bytes and reads nothing until told to, so a test can
/// hold a transfer open.
private final class RawClient: @unchecked Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(port: UInt16, peer: LANTLSPeer, owner: XCTestCase) async throws -> RawClient {
        let parameters = try LANTLSProfile.clientParameters(psk: peer.psk, identity: peer.identity)
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        owner.addTeardownBlock { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .waiting, .failed, .cancelled: if once.take() { continuation.resume(throwing: LANMediaError.handshakeFailed) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "lan-loopback.raw"))
        }
        return RawClient(connection)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Reads and discards until the connection ends, or `limit` passes. True when it ended.
    func drainUntilClosed(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            let ended: Bool? = await withCheckedContinuation { continuation in
                let once = Once()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if once.take() { continuation.resume(returning: error != nil || (isComplete && (data ?? Data()).isEmpty)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if once.take() { continuation.resume(returning: nil) }
                }
            }
            if ended == true { return true }
        }
        return false
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
    }
}
