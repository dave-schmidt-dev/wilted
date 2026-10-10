import Foundation
import XCTest
@testable import WiltedLibrary

final class InMemoryLibraryTransportTests: XCTestCase {
    private func channel() throws -> LibraryBulletins {
        let issued = Date(timeIntervalSince1970: 1_000)
        let headline = try Bulletin(id: "h1", kind: .headline, text: "Headline", issuedAt: issued,
                                    expiresAt: issued.addingTimeInterval(600))
        return try LibraryBulletins(alertsEnabled: true, headlinesEnabled: true, headlines: [headline], updatedAt: issued)
    }

    func testPublishedBulletinsAreFetchedBackByAnotherDevice() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let before = try await phone.fetchBulletins()
        XCTAssertNil(before)
        let value = try channel()
        try await mac.publishBulletins(value)
        let seen = try await phone.fetchBulletins()
        XCTAssertEqual(seen, value)
        let replacement = try LibraryBulletins(alertsEnabled: false, headlinesEnabled: false)
        try await mac.publishBulletins(replacement)
        let replaced = try await phone.fetchBulletins()
        XCTAssertEqual(replaced, replacement)
    }

    func testOnlyTheWriterMayPublishBulletins() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let value = try channel()
        do {
            try await phone.publishBulletins(value)
            XCTFail("a phone must not publish bulletins")
        } catch let error as LibraryTransportError {
            guard case .ownershipViolation = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testBulletinLimitsAreEnforcedIncludingOnDecode() throws {
        let now = Date(timeIntervalSince1970: 1)
        XCTAssertThrowsError(try Bulletin(id: "a", kind: .alert, text: String(repeating: "x", count: 601), issuedAt: now, expiresAt: now))
        let one = try Bulletin(id: "a", kind: .headline, text: "x", issuedAt: now, expiresAt: now)
        XCTAssertThrowsError(try LibraryBulletins(alertsEnabled: true, headlinesEnabled: true,
                                                  headlines: Array(repeating: one, count: 21)))
        XCTAssertNoThrow(try LibraryBulletins(alertsEnabled: true, headlinesEnabled: true,
                                              headlines: Array(repeating: one, count: 20)))
    }
}
