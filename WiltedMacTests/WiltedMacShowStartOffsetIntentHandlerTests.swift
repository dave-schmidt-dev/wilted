import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacShowStartOffsetIntentHandlerTests: XCTestCase {
    private actor BytesBox {
        var values: [String: Data] = [:]
        func value(for key: String) -> Data? { values[key] }
        func set(_ data: Data, for key: String) { values[key] = data }
    }

    func testStalePhoneEditReturnsConflictAndCurrentMacValue() async throws {
        let bytes = BytesBox()
        let offsetStore = makeStore(bytes)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let feedID = try ItemID(rawValue: "offset-handler-feed")
        let handler = WiltedMacShowStartOffsetIntentHandler(
            store: offsetStore, transport: mac, ownerProvider: { "owner" }, feedValidator: { _ in true })
        let first = try LibraryIntent.setShowStartOffset(
            feedID: feedID, seconds: 45, basedOnRevision: 0, deviceID: "phone", id: "first-offset")
        let stale = try LibraryIntent.setShowStartOffset(
            feedID: feedID, seconds: 90, basedOnRevision: 0, deviceID: "phone", id: "stale-offset")

        let firstHandled = try await handler.applyIfOffset(first)
        let staleHandled = try await handler.applyIfOffset(stale)
        XCTAssertTrue(firstHandled)
        XCTAssertTrue(staleHandled)

        let outcomes = try await mac.intentOutcomes()
        XCTAssertEqual(outcomes.first(where: { $0.intentID == first.id })?.disposition, .applied)
        let conflict = try XCTUnwrap(outcomes.first(where: { $0.intentID == stale.id }))
        XCTAssertEqual(conflict.disposition, .rejected)
        XCTAssertEqual(conflict.reason, LibraryShowStartOffset.conflictReason)
        let offsets = try await offsetStore.offsets(owner: "owner")
        XCTAssertEqual(offsets[feedID.rawValue]?.seconds, 45)
    }

    func testAccountChangeDuringFeedValidationCannotApplyOldOwnerCommand() async throws {
        let bytes = BytesBox()
        let offsetStore = makeStore(bytes)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let feedID = try ItemID(rawValue: "offset-handler-race-feed")
        let handler = WiltedMacShowStartOffsetIntentHandler(
            store: offsetStore, transport: mac,
            ownerProvider: { await mac.verifiedOwnerToken() },
            feedValidator: { _ in await mac.invalidateOperations(); return true })
        let intent = try LibraryIntent.setShowStartOffset(
            feedID: feedID, seconds: 45, basedOnRevision: 0, deviceID: "phone", id: "old-owner-offset")

        do {
            _ = try await handler.applyIfOffset(intent)
            XCTFail("Expected the account-change fence to reject the old operation")
        } catch {
            XCTAssertEqual(error as? LibraryTransportError, .superseded)
        }

        let offsets = try await offsetStore.offsets(owner: "owner")
        let outcomes = try await mac.intentOutcomes()
        XCTAssertTrue(offsets.isEmpty)
        XCTAssertTrue(outcomes.isEmpty)
    }

    private func makeStore(_ bytes: BytesBox) -> WiltedMacShowStartOffsetStore {
        WiltedMacShowStartOffsetStore(
            loadBytes: { await bytes.value(for: $0) },
            saveBytes: { await bytes.set($1, for: $0) })
    }
}
