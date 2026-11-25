import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacShowPlaybackSpeedIntentHandlerTests: XCTestCase {
    private actor BytesBox {
        var values: [String: Data] = [:]
        func value(for key: String) -> Data? { values[key] }
        func set(_ data: Data, for key: String) { values[key] = data }
    }

    func testPhoneRevisionConflictReturnsOutcomeAndKeepsMacAuthority() async throws {
        let bytes = BytesBox()
        let speedStore = WiltedMacShowPlaybackSpeedStore(
            loadBytes: { await bytes.value(for: $0) }, saveBytes: { await bytes.set($1, for: $0) })
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let feed = try ItemID(rawValue: "speed-handler-feed")
        let handler = WiltedMacShowPlaybackSpeedIntentHandler(
            store: speedStore, transport: mac, ownerProvider: { "owner" }, feedValidator: { _ in true })
        let accepted = try LibraryIntent.setShowPlaybackSpeed(
            feedID: feed, speed: 1.5, basedOnRevision: 0, deviceID: "phone", id: "speed-first")
        let stale = try LibraryIntent.setShowPlaybackSpeed(
            feedID: feed, speed: 1.75, basedOnRevision: 0, deviceID: "phone", id: "speed-stale")

        let acceptedHandled = try await handler.applyIfShowPlaybackSpeed(accepted)
        let staleHandled = try await handler.applyIfShowPlaybackSpeed(stale)
        XCTAssertTrue(acceptedHandled)
        XCTAssertTrue(staleHandled)
        let outcomes = try await mac.intentOutcomes()
        XCTAssertEqual(outcomes.first(where: { $0.intentID == accepted.id })?.disposition, .applied)
        let conflict = try XCTUnwrap(outcomes.first(where: { $0.intentID == stale.id }))
        XCTAssertEqual(conflict.disposition, .rejected)
        XCTAssertEqual(conflict.reason, WiltedMacShowPlaybackSpeedIntentHandler.conflictReason)
        let authoritative = try await speedStore.speeds(owner: "owner")
        XCTAssertEqual(authoritative[feed.rawValue]?.speed, 1.5)
    }
}
