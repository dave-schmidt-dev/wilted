import Foundation
import WiltedLibrary
import XCTest
@testable import WiltedMac

final class WiltedMacDeviceRemovalOrderingTests: XCTestCase {
    /// The continuation is installed before the test observes the blocked write.
    private actor HeldWrite {
        let started: XCTestExpectation
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(started: XCTestExpectation) { self.started = started }

        func hold() async {
            guard !released else { return }
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testLateLinkPublicationCannotRecreateTheRemovedRecord() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "fixture-mac")
        let held = HeldWrite(started: expectation(description: "link publication held"))
        let transport = HandshakeTransport(InMemoryLibraryTransport(deviceID: "fixture-mac", server: server),
            beforeLinkWrite: { await held.hold() })
        let links = WiltedMacDeviceLinks(transport: transport, macDeviceID: "fixture-mac",
            preferences: WiltedMacLANPreferences(defaults: WiltedMacTestPreferences.ephemeral()))
        await links.noteDevices(["fixture-phone"])
        let publish = Task { await links.flush() }
        await fulfillment(of: [held.started], timeout: 2)

        let entered = expectation(description: "removal entered link actor")
        let removal = Task { try await startRemoval(on: links, entered: entered) }
        await fulfillment(of: [entered], timeout: 2)
        await held.release()
        await publish.value
        try await removal.value

        let phone = InMemoryLibraryTransport(deviceID: "fixture-phone", server: server)
        let link = try await phone.fetchDeviceLink()
        XCTAssertNil(link)
        XCTAssertEqual(transport.deletedLinkIDs, ["fixture-phone"])
    }
}

private func startRemoval(on links: isolated WiltedMacDeviceLinks, entered: XCTestExpectation) async throws {
    entered.fulfill()
    try await links.removeDevice("fixture-phone")
}
