import Foundation
import Network
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

final class WiltedMacLANMediaServerTests: XCTestCase {
    private final class FakeLANMediaServer: LANMediaServing, @unchecked Sendable {
        private let lock = NSLock()
        private var peersValue: [LANTLSPeer] = []
        private var isStartedValue = false
        private var cancelAllCountValue = 0
        private var stopCountValue = 0
        private var activeTransfersValue = 0
        private var connectionsValue = 0
        private var portValue: UInt16? = 8080

        var isHeldCheck: (@Sendable () -> Bool)?
        var onCancelAll: (@Sendable () -> Void)?

        init(isHeld: (@Sendable () -> Bool)? = nil) {
            self.isHeldCheck = isHeld
        }

        func start(peers: [LANTLSPeer]) async throws -> UInt16? {
            lock.withLock {
                peersValue = peers
                isStartedValue = true
                return portValue
            }
        }

        func updatePeers(_ peers: [LANTLSPeer]) async throws -> (port: UInt16?, restarted: Bool) {
            lock.withLock {
                peersValue = peers
                isStartedValue = true
                return (portValue, true)
            }
        }

        func cancelAll() async {
            lock.withLock {
                cancelAllCountValue += 1
                activeTransfersValue = 0
            }
            onCancelAll?()
        }

        func stop() async {
            lock.withLock {
                stopCountValue += 1
                isStartedValue = false
                activeTransfersValue = 0
            }
        }

        var port: UInt16? { lock.withLock { portValue } }
        var activeTransferCount: Int { lock.withLock { activeTransfersValue } }
        var connectionCount: Int { lock.withLock { connectionsValue } }

        var peers: [LANTLSPeer] { lock.withLock { peersValue } }
        var cancelAllCount: Int { lock.withLock { cancelAllCountValue } }
        var isStarted: Bool { lock.withLock { isStartedValue } }

        func beginSimulatedTransfer() {
            lock.withLock {
                activeTransfersValue += 1
                connectionsValue += 1
            }
        }

        enum ConnectionAttemptOutcome: Equatable {
            case admitted
            case rejectedHeldGate
            case rejectedUnknownPeer
        }

        func simulateIncomingConnection(from phonePublicKey: Data) -> ConnectionAttemptOutcome {
            if let isHeldCheck, isHeldCheck() {
                return .rejectedHeldGate
            }
            let identity = LANPairingKey.identity(phonePublicKey: phonePublicKey)
            let matches = lock.withLock {
                peersValue.contains { $0.identity == identity }
            }
            if !matches {
                return .rejectedUnknownPeer
            }
            return .admitted
        }
    }

    private struct FakeReadySource: WiltedMacReadyAudioSource {
        func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? { nil }
        func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] { [:] }
        func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? { nil }
        func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] { [:] }
    }

    private var defaultsSuite: String!
    private var preferences: WiltedMacLANPreferences!

    override func setUp() {
        super.setUp()
        defaultsSuite = "WiltedMacLANMediaServerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        preferences = WiltedMacLANPreferences(defaults: defaults)
    }

    override func tearDown() {
        if let defaultsSuite {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }
        super.tearDown()
    }

    /// Asserts that a held account gate causes connection attempts to be rejected.
    func testHeldGateRejectsConnection() async throws {
        let gate = WiltedMacLibraryAccountGate(open: false)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let transport = makeTransport()
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")
        let keyStore = InMemoryLANKeyStore()

        let server = WiltedMacLANMediaServer(
            readySource: FakeReadySource(),
            accountGate: gate,
            links: links,
            deviceID: "mac-1",
            ownerTokenProvider: { "owner-token" },
            keyStore: keyStore,
            preferences: preferences,
            server: fakeServer
        )
        await server.start()

        let phoneKey = LANKeyAgreementKey()
        let announcement = LibraryDeviceAnnouncement(
            deviceID: "phone-1", kind: "iPhone", announcedAt: Date(), lanPublicKey: phoneKey.publicKey)
        let directory = LibraryDeviceDirectory(devices: [announcement])
        try await server.updateDirectory(directory)

        let outcome = fakeServer.simulateIncomingConnection(from: phoneKey.publicKey)
        XCTAssertEqual(outcome, .rejectedHeldGate)
    }

    /// Asserts that a connection from an unknown phone (not in the device directory) is rejected.
    func testUnknownPhoneIsRejected() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let transport = makeTransport()
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")
        let keyStore = InMemoryLANKeyStore()

        let server = WiltedMacLANMediaServer(
            readySource: FakeReadySource(),
            accountGate: gate,
            links: links,
            deviceID: "mac-1",
            ownerTokenProvider: { "owner-token" },
            keyStore: keyStore,
            preferences: preferences,
            server: fakeServer
        )
        await server.start()

        let knownPhoneKey = LANKeyAgreementKey()
        let announcement = LibraryDeviceAnnouncement(
            deviceID: "phone-1", kind: "iPhone", announcedAt: Date(), lanPublicKey: knownPhoneKey.publicKey)
        let directory = LibraryDeviceDirectory(devices: [announcement])
        try await server.updateDirectory(directory)

        let unknownPhoneKey = LANKeyAgreementKey()
        let unknownOutcome = fakeServer.simulateIncomingConnection(from: unknownPhoneKey.publicKey)
        XCTAssertEqual(unknownOutcome, .rejectedUnknownPeer)

        let knownOutcome = fakeServer.simulateIncomingConnection(from: knownPhoneKey.publicKey)
        XCTAssertEqual(knownOutcome, .admitted)
    }

    /// Asserts that stopping direct downloads for an iPhone drops its key from the allowed peer set
    /// and causes subsequent connection attempts to be rejected.
    func testStoppedPhoneIsRejected() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let transport = makeTransport()
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")
        let keyStore = InMemoryLANKeyStore()

        let server = WiltedMacLANMediaServer(
            readySource: FakeReadySource(),
            accountGate: gate,
            links: links,
            deviceID: "mac-1",
            ownerTokenProvider: { "owner-token" },
            keyStore: keyStore,
            preferences: preferences,
            server: fakeServer
        )
        await server.start()

        let phoneKey = LANKeyAgreementKey()
        let announcement = LibraryDeviceAnnouncement(
            deviceID: "phone-1", kind: "iPhone", announcedAt: Date(), lanPublicKey: phoneKey.publicKey)
        let directory = LibraryDeviceDirectory(devices: [announcement])
        await links.noteDirectory(directory)
        try await server.updateDirectory(directory)

        let beforeStop = fakeServer.simulateIncomingConnection(from: phoneKey.publicKey)
        XCTAssertEqual(beforeStop, .admitted)

        await server.stopDirectDownloads(for: "phone-1")

        let afterStop = fakeServer.simulateIncomingConnection(from: phoneKey.publicKey)
        XCTAssertEqual(afterStop, .rejectedUnknownPeer)

        let isStopped = await links.isDirectDownloadsStopped(for: "phone-1")
        XCTAssertTrue(isStopped)
    }

    /// Asserts that an account gate closing mid-transfer immediately invokes cancelAll() and ends
    /// the active transfer (DS-3).
    func testGateClosingMidTransferEndsConnection() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let transport = makeTransport()
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")
        let keyStore = InMemoryLANKeyStore()

        let server = WiltedMacLANMediaServer(
            readySource: FakeReadySource(),
            accountGate: gate,
            links: links,
            deviceID: "mac-1",
            ownerTokenProvider: { "owner-token" },
            keyStore: keyStore,
            preferences: preferences,
            server: fakeServer
        )
        await server.start()

        let cancelledExpectation = expectation(description: "cancelAll called on gate close")
        fakeServer.onCancelAll = {
            cancelledExpectation.fulfill()
        }

        fakeServer.beginSimulatedTransfer()
        XCTAssertEqual(fakeServer.activeTransferCount, 1)

        gate.close()

        await fulfillment(of: [cancelledExpectation], timeout: 2.0)
        XCTAssertEqual(fakeServer.activeTransferCount, 0)
        XCTAssertGreaterThanOrEqual(fakeServer.cancelAllCount, 1)
    }

    /// Asserts that all required local network and background download Info keys exist in both
    /// generated plists (C-1, PM-4).
    func testInfoKeysExistInBothGeneratedPlists() throws {
        let macPlist = try loadPlist(named: "WiltedMac/Info.plist")
        let macDescription = macPlist["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(macDescription)
        XCTAssertFalse(macDescription?.isEmpty ?? true)
        let macServices = macPlist["NSBonjourServices"] as? [String]
        XCTAssertNotNil(macServices)
        XCTAssertTrue(macServices?.contains("_wilted-media._tcp") ?? false)

        let iosPlist = try loadPlist(named: "WiltediOS/Info.plist")
        let iosDescription = iosPlist["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(iosDescription)
        XCTAssertFalse(iosDescription?.isEmpty ?? true)
        let iosServices = iosPlist["NSBonjourServices"] as? [String]
        XCTAssertNotNil(iosServices)
        XCTAssertTrue(iosServices?.contains("_wilted-media._tcp") ?? false)
        let iosBGIdentifiers = iosPlist["BGTaskSchedulerPermittedIdentifiers"] as? [String]
        XCTAssertNotNil(iosBGIdentifiers)
        XCTAssertTrue(iosBGIdentifiers?.contains("com.zerodelta.wilted.ios.media-download") ?? false)
    }

    /// Asserts that toggling the Mac switch controls whether the server is started or stopped.
    func testMacSwitchControlsServer() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let transport = makeTransport()
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "mac-1")

        preferences.setDirectDownloadsEnabled(false)

        let server = WiltedMacLANMediaServer(
            readySource: FakeReadySource(),
            accountGate: gate,
            links: links,
            deviceID: "mac-1",
            ownerTokenProvider: { "owner-token" },
            keyStore: InMemoryLANKeyStore(),
            preferences: preferences,
            server: fakeServer
        )
        await server.start()
        XCTAssertFalse(fakeServer.isStarted)

        await server.setEnabled(true)
        XCTAssertTrue(fakeServer.isStarted)

        await server.setEnabled(false)
        XCTAssertFalse(fakeServer.isStarted)
    }

    /// A new library owner rotates the Mac's key and clears stopped phones; the first owner keeps it.
    func testAnOwnerChangeRotatesTheKeyAndTheFirstOwnerKeepsIt() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let fakeServer = FakeLANMediaServer(isHeld: { !gate.isOpen })
        let links = WiltedMacDeviceLinks(transport: makeTransport(), macDeviceID: "mac-1")
        let keyStore = InMemoryLANKeyStore()
        let initialKey = try keyStore.currentKey()
        let owner = OwnerBox("owner-a")
        let server = makeServer(gate: gate, links: links, keyStore: keyStore, server: fakeServer, owner: owner)
        await server.start()
        let phoneKey = LANKeyAgreementKey()
        let directory = LibraryDeviceDirectory(devices: [LibraryDeviceAnnouncement(
            deviceID: "phone-1", kind: "iPhone", announcedAt: Date(), lanPublicKey: phoneKey.publicKey)])
        try await server.updateDirectory(directory)
        XCTAssertEqual(try keyStore.currentKey().publicKey, initialKey.publicKey, "the first owner keeps the key")
        await server.stopDirectDownloads(for: "phone-1")

        owner.value = "owner-b"
        try await server.updateDirectory(directory)
        XCTAssertNotEqual(try keyStore.currentKey().publicKey, initialKey.publicKey)
        XCTAssertEqual(preferences.stoppedPhones, [], "the previous library's stops do not carry over")
        XCTAssertEqual(fakeServer.simulateIncomingConnection(from: phoneKey.publicKey), .admitted)
    }

    /// "Stop direct downloads for this iPhone" survives a relaunch.
    func testAStoppedPhoneStaysStoppedAfterRelaunch() async throws {
        let gate = WiltedMacLibraryAccountGate(open: true)
        let keyStore = InMemoryLANKeyStore()
        let phoneKey = LANKeyAgreementKey()
        let directory = LibraryDeviceDirectory(devices: [LibraryDeviceAnnouncement(
            deviceID: "phone-1", kind: "iPhone", announcedAt: Date(), lanPublicKey: phoneKey.publicKey)])
        let first = makeServer(gate: gate, links: WiltedMacDeviceLinks(transport: makeTransport(), macDeviceID: "mac-1"),
                               keyStore: keyStore, server: FakeLANMediaServer(), owner: OwnerBox("owner-a"))
        await first.start()
        try await first.updateDirectory(directory)
        await first.stopDirectDownloads(for: "phone-1")

        let relaunched = FakeLANMediaServer()
        let links = WiltedMacDeviceLinks(transport: makeTransport(), macDeviceID: "mac-1")
        let second = makeServer(gate: gate, links: links, keyStore: keyStore, server: relaunched, owner: OwnerBox("owner-a"))
        await second.start()
        try await second.updateDirectory(directory)
        XCTAssertEqual(relaunched.simulateIncomingConnection(from: phoneKey.publicKey), .rejectedUnknownPeer)
        let stopped = await links.isDirectDownloadsStopped(for: "phone-1")
        XCTAssertTrue(stopped)
    }

    /// Asserts the Bonjour service configuration matches the required specification.
    func testBonjourConfiguration() {
        let service = WiltedMacLANMediaServer.makeBonjourService()
        XCTAssertEqual(service.name, "Wilted")
        XCTAssertEqual(service.type, "_wilted-media._tcp")
        XCTAssertEqual(service.txtRecord, NetService.data(fromTXTRecord: ["v": Data("1".utf8)]))
    }

    // MARK: - Helpers

    private final class OwnerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String
        init(_ value: String) { stored = value }
        var value: String {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func makeServer(
        gate: WiltedMacLibraryAccountGate, links: WiltedMacDeviceLinks, keyStore: InMemoryLANKeyStore,
        server: FakeLANMediaServer, owner: OwnerBox
    ) -> WiltedMacLANMediaServer {
        WiltedMacLANMediaServer(
            readySource: FakeReadySource(), accountGate: gate, links: links, deviceID: "mac-1",
            ownerTokenProvider: { owner.value }, keyStore: keyStore, preferences: preferences, server: server)
    }

    private func makeTransport(deviceID: String = "mac-1") -> InMemoryLibraryTransport {
        let server = InMemoryLibraryServer(writerDeviceID: deviceID)
        return InMemoryLibraryTransport(deviceID: deviceID, server: server)
    }

    private func loadPlist(named relativePath: String) throws -> [String: Any] {
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let repoRootFromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            currentDir.appendingPathComponent(relativePath),
            repoRootFromSource.appendingPathComponent(relativePath),
        ]

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        XCTFail("Could not locate or parse plist at \(relativePath)")
        return [:]
    }
}
