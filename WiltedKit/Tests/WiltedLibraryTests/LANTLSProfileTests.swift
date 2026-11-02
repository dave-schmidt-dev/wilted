import Foundation
import Network
import XCTest
@testable import WiltedLibrary

/// The TLS profile over a real loopback handshake. Every listener and connection is cancelled by the
/// test (W-INV-014) and every wait is bounded.
final class LANTLSProfileTests: XCTestCase {
    private var cleanups: [@Sendable () -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    private func peer(_ seed: UInt8) -> LANTLSPeer {
        LANTLSPeer(identity: Data(repeating: seed, count: 16), psk: Data(repeating: seed &+ 100, count: 32))
    }

    // MARK: loopback harness

    /// What a connection reached, as the test sees it.
    private enum Outcome: Equatable, Sendable {
        case pending
        /// Ready, with the negotiated version and cipher, and whether `validate(metadata:)` accepted them.
        case ready(version: UInt16, cipher: UInt16, validated: Bool)
        case waiting
        case failed
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome = Outcome.pending
        private var serverOutcomes: [Outcome] = []
        var value: Outcome { lock.withLock { outcome } }
        var servers: [Outcome] { lock.withLock { serverOutcomes } }
        func set(_ new: Outcome) { lock.withLock { if outcome == .pending { outcome = new } } }
        func addServer(_ new: Outcome) { lock.withLock { serverOutcomes.append(new) } }
    }

    private static func outcome(of connection: NWConnection, state: NWConnection.State) -> Outcome? {
        switch state {
        case .ready:
            let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
            let security = metadata?.securityProtocolMetadata
            let version = security.map { sec_protocol_metadata_get_negotiated_tls_protocol_version($0).rawValue } ?? 0
            let cipher = security.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0).rawValue } ?? 0
            return .ready(version: version, cipher: cipher, validated: (try? LANTLSProfile.validate(metadata: metadata)) != nil)
        case .waiting: return .waiting
        case .failed: return .failed
        default: return nil
        }
    }

    /// Starts a loopback listener holding `peers`; returns its port.
    private func startListener(peers: [LANTLSPeer], recorder: Recorder) async throws -> NWEndpoint.Port {
        let parameters = try LANTLSProfile.serverParameters(peers: peers)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "lan-tls-test.server")
        let connections = ConnectionBox()
        listener.newConnectionHandler = { connection in
            connections.add(connection)
            connection.stateUpdateHandler = { state in
                if let outcome = Self.outcome(of: connection, state: state) { recorder.addServer(outcome) }
            }
            connection.start(queue: queue)
        }
        let ready = StateBox()
        listener.stateUpdateHandler = { ready.set($0) }
        listener.start(queue: queue)
        cleanups.append { listener.cancel(); connections.cancelAll() }
        try await wait("the listener to be ready") { if case .ready = ready.value { return true } else { return false } }
        guard let port = listener.port else { throw XCTSkip("the listener has no port") }
        return port
    }

    /// Connects a client with `psk` and `identity`, waits for it to reach ready, waiting or failed, and cancels it.
    private func connect(port: NWEndpoint.Port, psk: Data, identity: Data) async throws -> Outcome {
        let parameters = try LANTLSProfile.clientParameters(psk: psk, identity: identity)
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let recorder = Recorder()
        connection.stateUpdateHandler = { state in
            if let outcome = Self.outcome(of: connection, state: state) { recorder.set(outcome) }
        }
        cleanups.append { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "lan-tls-test.client"))
        defer { connection.cancel() }
        try await wait("the client to settle") { recorder.value != .pending }
        return recorder.value
    }

    private final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NWConnection] = []
        func add(_ item: NWConnection) { lock.withLock { items.append(item) } }
        func cancelAll() { lock.withLock { items }.forEach { $0.cancel() } }
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = NWListener.State.setup
        var value: NWListener.State { lock.withLock { state } }
        func set(_ new: NWListener.State) { lock.withLock { state = new } }
    }

    private func wait(
        _ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool
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

    // MARK: handshakes

    func testTwoPhonesEachCompleteAHandshakeWithOneListener() async throws {
        let (a, b) = (peer(1), peer(2))
        let recorder = Recorder()
        let port = try await startListener(peers: [a, b], recorder: recorder)

        let first = try await connect(port: port, psk: a.psk, identity: a.identity)
        let second = try await connect(port: port, psk: b.psk, identity: b.identity)

        let expected = Outcome.ready(version: 0x0303, cipher: 0xCCAC, validated: true)
        XCTAssertEqual(first, expected, "client A")
        XCTAssertEqual(second, expected, "client B")
        try await wait("both server sides") { recorder.servers.count >= 2 }
        XCTAssertTrue(recorder.servers.allSatisfy { $0 == expected }, "the server side negotiated the same profile")
    }

    func testTheRightIdentityWithTheWrongKeyDoesNotConnect() async throws {
        let (a, b) = (peer(1), peer(2))
        let port = try await startListener(peers: [a, b], recorder: Recorder())
        let outcome = try await connect(port: port, psk: Data(repeating: 9, count: 32), identity: a.identity)
        XCTAssertTrue(outcome == .waiting || outcome == .failed, "a handshake failure shows as waiting or failed, got \(outcome)")
    }

    func testAnIdentityTheListenerDoesNotHoldDoesNotConnect() async throws {
        let port = try await startListener(peers: [peer(1)], recorder: Recorder())
        let stranger = peer(3)
        let outcome = try await connect(port: port, psk: stranger.psk, identity: stranger.identity)
        XCTAssertTrue(outcome == .waiting || outcome == .failed, "got \(outcome)")
    }

    // MARK: pure checks

    func testValidateRefusesAnyOtherVersionOrCipher() {
        XCTAssertNoThrow(try LANTLSProfile.validate(version: 0x0303, cipher: 0xCCAC))
        let versions: [UInt16] = [0x0301, 0x0302, 0x0304, 0]
        let ciphers: [UInt16] = [0xCCA8, 0xC02F, 0x1301, 0]
        for version in versions {
            XCTAssertThrowsError(try LANTLSProfile.validate(version: version, cipher: 0xCCAC), "version \(version)") {
                XCTAssertEqual($0 as? LANTLSError, .unexpectedNegotiation)
            }
        }
        for cipher in ciphers {
            XCTAssertThrowsError(try LANTLSProfile.validate(version: 0x0303, cipher: cipher), "cipher \(cipher)")
        }
        XCTAssertThrowsError(try LANTLSProfile.validate(metadata: nil), "no metadata is not a pass")
    }

    func testTheProfileRefusesBadInputs() {
        XCTAssertThrowsError(try LANTLSProfile.serverParameters(peers: [])) { XCTAssertEqual($0 as? LANTLSError, .invalidProfile) }
        XCTAssertThrowsError(try LANTLSProfile.serverParameters(peers: [peer(1), peer(1)]), "duplicate identity")
        XCTAssertThrowsError(try LANTLSProfile.serverParameters(peers: [LANTLSPeer(identity: Data([1]), psk: Data(count: 31))]))
        XCTAssertThrowsError(try LANTLSProfile.clientParameters(psk: Data(count: 32), identity: Data()))
        XCTAssertThrowsError(try LANTLSProfile.clientParameters(psk: Data(count: 16), identity: Data([1])))
    }

    func testTheParametersStayOffPeerToPeer() throws {
        XCTAssertFalse(try LANTLSProfile.serverParameters(peers: [peer(1)]).includePeerToPeer)
        XCTAssertFalse(try LANTLSProfile.clientParameters(psk: peer(1).psk, identity: peer(1).identity).includePeerToPeer)
    }
}
