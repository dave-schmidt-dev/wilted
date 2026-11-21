import Foundation
import Network
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

final class WiltedMacLANDeviceRemovalTests: XCTestCase {
    private final class FakeServer: LANMediaServing, @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [LANTLSPeer] = []
        private var started = false
        private var activeTransfers = 0
        private var updateCount = 0
        private var stopCount = 0
        private var failNextUpdateValue = false

        func start(peers: [LANTLSPeer]) async throws -> UInt16? {
            lock.withLock {
                self.peers = peers
                started = true
                return 8080
            }
        }

        func updatePeers(_ peers: [LANTLSPeer]) async throws -> (port: UInt16?, restarted: Bool) {
            let shouldFail = lock.withLock { () -> Bool in
                updateCount += 1
                defer { failNextUpdateValue = false }
                return failNextUpdateValue
            }
            if shouldFail { throw CocoaError(.fileWriteUnknown) }
            lock.withLock {
                self.peers = peers
                started = true
            }
            return (8080, true)
        }

        func cancelAll() async { lock.withLock { activeTransfers = 0 } }

        func stop() async {
            lock.withLock {
                stopCount += 1
                started = false
                peers = []
                activeTransfers = 0
            }
        }

        var port: UInt16? { lock.withLock { started ? 8080 : nil } }
        var activeTransferCount: Int { lock.withLock { activeTransfers } }
        var connectionCount: Int { lock.withLock { activeTransfers } }
        var peerUpdateCount: Int { lock.withLock { updateCount } }
        var stopCountValue: Int { lock.withLock { stopCount } }

        func setFailNextUpdate() { lock.withLock { failNextUpdateValue = true } }
        func beginTransfer() { lock.withLock { activeTransfers += 1 } }

        func admits(_ publicKey: Data) -> Bool {
            let identity = LANPairingKey.identity(phonePublicKey: publicKey)
            return lock.withLock { started && peers.contains { $0.identity == identity } }
        }
    }

    private struct ReadySource: WiltedMacReadyAudioSource {
        func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? { nil }
        func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] { [:] }
        func preparedQueued() async throws -> WiltedMacPreparedQueue { WiltedMacPreparedQueue() }
        func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? { nil }
        func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] { [:] }
    }

    private final class CountingKeyStore: LANKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private let store = InMemoryLANKeyStore()
        private var currentCount = 0
        private var rotateCount = 0

        func currentKey() throws -> LANKeyAgreementKey {
            lock.withLock { currentCount += 1 }
            return try store.currentKey()
        }

        func rotate() throws -> LANKeyAgreementKey {
            lock.withLock { rotateCount += 1 }
            return try store.rotate()
        }

        func delete() throws { try store.delete() }
        var counts: (current: Int, rotate: Int) { lock.withLock { (currentCount, rotateCount) } }
    }

    private actor OwnerTokenGate {
        private var blocksNextRead = false
        private var result: CheckedContinuation<String?, Never>?
        private var waiting: XCTestExpectation?

        func blockNextRead() { blocksNextRead = true }

        func read() async -> String? {
            guard blocksNextRead else { return "synthetic-owner" }
            blocksNextRead = false
            return await withCheckedContinuation { continuation in
                result = continuation
                waiting?.fulfill()
                waiting = nil
            }
        }

        func signalWhenBlocked(_ expectation: XCTestExpectation) {
            if result != nil { expectation.fulfill() } else { waiting = expectation }
        }

        func resume() {
            blocksNextRead = false
            result?.resume(returning: "synthetic-owner")
            result = nil
        }
    }

    private var preferences: WiltedMacLANPreferences!
    override func setUp() {
        super.setUp()
        preferences = WiltedMacLANPreferences(defaults: WiltedMacTestPreferences.ephemeral())
    }

    func testRemovingOneDevicePreservesOtherDeviceAccess() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fake = FakeServer()
        let keyStore = CountingKeyStore()
        let server = makeServer(gate: gate, fake: fake, keyStore: keyStore)
        await server.start()
        let removedKey = LANKeyAgreementKey()
        let retainedKey = LANKeyAgreementKey()
        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "fixture-removed", kind: "iPhone",
                                      announcedAt: Date(), lanPublicKey: removedKey.publicKey),
            LibraryDeviceAnnouncement(deviceID: "fixture-retained", kind: "iPad",
                                      announcedAt: Date(), lanPublicKey: retainedKey.publicKey),
        ])
        try await server.updateDirectory(directory)
        let keyCountsBeforeRemove = keyStore.counts

        await server.removeDevice("fixture-removed")
        try await server.updateDirectory(directory)

        XCTAssertFalse(fake.admits(removedKey.publicKey))
        XCTAssertTrue(fake.admits(retainedKey.publicKey))
        XCTAssertEqual(preferences.stoppedPhones, ["fixture-removed"])
        XCTAssertEqual(keyStore.counts.current, keyCountsBeforeRemove.current)
        XCTAssertEqual(keyStore.counts.rotate, keyCountsBeforeRemove.rotate)
    }

    func testReportsAnActiveLANTransferForRemovalWarning() async {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fake = FakeServer()
        let server = makeServer(gate: gate, fake: fake)

        XCTAssertFalse(server.hasActiveTransfers)
        fake.beginTransfer()
        XCTAssertTrue(server.hasActiveTransfers)
    }

    func testRemovingADeviceThatWasNeverAnAllowedPeerDoesNotTouchTheListener() async {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fake = FakeServer()
        let server = makeServer(gate: gate, fake: fake)
        await server.start()
        let updatesBefore = fake.peerUpdateCount

        await server.removeDevice("fixture-never-linked")

        XCTAssertEqual(fake.peerUpdateCount, updatesBefore)
        XCTAssertEqual(fake.stopCountValue, 0)
    }

    func testFailedPeerRefreshStopsTheListenerToFailClosed() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fake = FakeServer()
        let server = makeServer(gate: gate, fake: fake)
        await server.start()
        let key = LANKeyAgreementKey()
        try await server.updateDirectory(LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "fixture-removed", kind: "iPhone",
                                      announcedAt: Date(), lanPublicKey: key.publicKey),
        ]))
        fake.setFailNextUpdate()

        await server.removeDevice("fixture-removed")

        XCTAssertGreaterThan(fake.stopCountValue, 0)
        XCTAssertFalse(fake.admits(key.publicKey))
    }

    func testRemovalDuringAnUnfinishedRefreshKeepsOtherDevicesEligible() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fake = FakeServer()
        let owner = OwnerTokenGate()
        let server = makeServer(gate: gate, fake: fake, ownerTokenProvider: { await owner.read() })
        await server.start()
        let removedKey = LANKeyAgreementKey()
        let retainedKey = LANKeyAgreementKey()
        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "fixture-removed", kind: "iPhone",
                                      announcedAt: Date(), lanPublicKey: removedKey.publicKey),
            LibraryDeviceAnnouncement(deviceID: "fixture-retained", kind: "iPad",
                                      announcedAt: Date(), lanPublicKey: retainedKey.publicKey),
        ])
        await owner.blockNextRead()
        let refresh = Task { try await server.updateDirectory(directory) }
        let blocked = expectation(description: "refresh is reading its owner")
        await owner.signalWhenBlocked(blocked)
        await fulfillment(of: [blocked], timeout: 2)

        await server.removeDevice("fixture-removed")
        await owner.resume()
        try await refresh.value

        XCTAssertFalse(fake.admits(removedKey.publicKey))
        XCTAssertTrue(fake.admits(retainedKey.publicKey))
    }

    private func makeServer(
        gate: WiltedMacLibraryAccountGate, fake: FakeServer,
        keyStore: any LANKeyStore = InMemoryLANKeyStore(),
        ownerTokenProvider: @escaping @Sendable () async -> String? = { "synthetic-owner" }
    ) -> WiltedMacLANMediaServer {
        let transport = InMemoryLibraryTransport(
            deviceID: "mac-1", server: InMemoryLibraryServer(writerDeviceID: "mac-1"))
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")
        return WiltedMacLANMediaServer(
            readySource: ReadySource(), accountGate: gate, links: links, deviceID: "mac-1",
            ownerTokenProvider: ownerTokenProvider, keyStore: keyStore,
            preferences: preferences, server: fake)
    }
}
