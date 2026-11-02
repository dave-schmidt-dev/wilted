import CryptoKit
import Foundation
import Network
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// M3 test 3 (PM-2, SR-1): the iOS TLS stack runs a real PSK handshake against `LANMediaServer` on loopback.
extension LibraryDirectMediaTests {
    // MARK: M3 test 3: a real TLS-PSK transfer over loopback

    func testARealTLSPSKLoopbackHandshakeAndTenMegabyteTransferAdoptsAgainstAnAvailableOffer() async throws {
        let size = 10 * 1_048_576
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in words.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words[index] = state
            }
        }
        let file = scratch.appendingPathComponent("ten-megabytes")
        try data.write(to: file)
        let target = try offer(state: .available, data: data)
        let (port, served) = try await startLoopbackMac(serving: file, target: target)
        let real = DirectFakeLocator(.found([.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)]))

        try seedDirect(offers: [target])
        let model = makeModel(direct: false)
        let key = phoneKey
        model.directState.environment = LibraryDirectEnvironment(
            locator: real, phoneKey: { key },
            makeSource: { connection in
                LANMediaClient(endpoints: connection.endpoints, peer: connection.peer,
                               partialDirectory: connection.partialDirectory, binding: .loopback, onPhase: connection.onPhase)
            }, scheduler: nil)
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)

        XCTAssertEqual(model.mediaState(for: entryA), .onPhone, notice(model))
        XCTAssertEqual(counter.serverCalls, 0)
        XCTAssertTrue(causes(model).isEmpty, "\(causes(model))")
        XCTAssertEqual(served.requests.count, 1)
        let played = await model.verifiedCachedMedia(entryA, token: model.commandState.token)
        let cachedFile = try XCTUnwrap(played?.url)
        XCTAssertEqual(try MediaHash.sha256(fileAt: cachedFile), target.contentHash)
        XCTAssertEqual(played?.preparation?.offer.state, .available)
    }

    func testARealHandshakeWithADifferentPairingFactFallsBackToICloud() async throws {
        let file = scratch.appendingPathComponent("served")
        try payload.write(to: file)
        let target = try offer(state: .available)
        let (port, _) = try await startLoopbackMac(serving: file, target: target)
        let real = DirectFakeLocator(.found([.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)]))
        try seedDirect(macDeviceID: "some-other-mac")
        let model = makeModel(direct: false)
        let key = phoneKey
        model.directState.environment = LibraryDirectEnvironment(
            locator: real, phoneKey: { key },
            makeSource: { connection in
                LANMediaClient(endpoints: connection.endpoints, peer: connection.peer,
                               partialDirectory: connection.partialDirectory, binding: .loopback, onPhase: connection.onPhase)
            }, scheduler: nil)
        try await expectFallback(.handshakeFailed, model)
    }

    /// A Mac-side server on loopback with the key the Mac derives on its own from the pairing facts
    /// (owner token, `LibraryPublication.writerDeviceID`, the phone's device id).
    private func startLoopbackMac(serving file: URL, target: LibraryMediaOffer) async throws -> (UInt16, LoopbackRequests) {
        let psk = try LANPairingKey.derive(
            ownKey: macKey, peerPublicKey: phoneKey.publicKey, ownerBindingTag: owner, macDeviceID: "mac",
            phoneDeviceID: "phone", macPublicKey: macKey.publicKey, phonePublicKey: phoneKey.publicKey)
        let peer = LANTLSPeer(identity: LANPairingKey.identity(phonePublicKey: phoneKey.publicKey), psk: psk)
        let requests = LoopbackRequests()
        let served = LANServedFile(
            fileURL: file, revisionID: target.revisionID!, contentHash: target.contentHash, byteCount: target.byteCount)
        let lan = LANMediaServer(
            configuration: .init(binding: .loopback), isHeld: { false },
            source: { request in requests.add(request); return .ready(served) })
        addTeardownBlock { await lan.stop() }
        let port = try await lan.start(peers: [peer])
        return (try XCTUnwrap(port), requests)
    }
}

private final class LoopbackRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [LANMediaRequest] = []
    var requests: [LANMediaRequest] { lock.withLock { seen } }
    func add(_ request: LANMediaRequest) { lock.withLock { seen.append(request) } }
}
