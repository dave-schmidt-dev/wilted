import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacShowStartOffsetStoreTests: XCTestCase {
    private actor BytesBox {
        var values: [String: Data] = [:]
        func value(for key: String) -> Data? { values[key] }
        func set(_ data: Data, for key: String) { values[key] = data }
        var isEmpty: Bool { values.isEmpty }
    }

    func testCompareAndSetIsIdempotentAndSurvivesStoreRecreation() async throws {
        let bytes = BytesBox()
        let store = makeStore(bytes)
        let feedID = try ItemID(rawValue: "feed")
        let authoritative = try LibraryShowStartOffset(feedID: feedID, seconds: 45, revision: 1)

        let first = try await store.apply(commandID: "set-1", owner: "owner-a", feedID: feedID,
                                    seconds: 45, basedOnRevision: 0)
        XCTAssertEqual(first, .applied(authoritative))

        let replay = try await store.apply(commandID: "set-1", owner: "owner-a", feedID: feedID,
                                     seconds: 90, basedOnRevision: 1)
        XCTAssertEqual(replay, first)

        let recreated = makeStore(bytes)
        let recreatedOffsets = try await recreated.offsets(owner: "owner-a")
        XCTAssertEqual(recreatedOffsets[feedID.rawValue]?.seconds, 45)
        let stale = try await recreated.apply(commandID: "set-stale", owner: "owner-a", feedID: feedID,
                                        seconds: 60, basedOnRevision: 0)
        XCTAssertEqual(stale, .conflict(authoritative))
        let staleReplay = try await recreated.apply(commandID: "set-stale", owner: "owner-a", feedID: feedID,
                                                    seconds: 15, basedOnRevision: 1)
        XCTAssertEqual(staleReplay, stale)
        let afterStaleReplay = try await recreated.offsets(owner: "owner-a")
        XCTAssertEqual(afterStaleReplay[feedID.rawValue], authoritative)
    }

    func testDifferentOwnersUseSeparateOffsets() async throws {
        let bytes = BytesBox()
        let store = makeStore(bytes)
        let feedID = try ItemID(rawValue: "feed")
        _ = try await store.apply(commandID: "set-a", owner: "owner-a", feedID: feedID,
                            seconds: 45, basedOnRevision: 0)

        let otherOffsets = try await store.offsets(owner: "owner-b")
        let ownerOffsets = try await store.offsets(owner: "owner-a")
        XCTAssertTrue(otherOffsets.isEmpty)
        XCTAssertEqual(ownerOffsets[feedID.rawValue]?.seconds, 45)
    }

    func testInvalidCommandDoesNotWriteState() async throws {
        let bytes = BytesBox()
        let store = makeStore(bytes)
        let feedID = try ItemID(rawValue: "feed")

        do {
            _ = try await store.apply(commandID: "bad", owner: "owner-a", feedID: feedID,
                                      seconds: .infinity, basedOnRevision: 0)
            XCTFail("Expected invalid offset to fail")
        } catch {}
        let didWrite = await bytes.isEmpty
        XCTAssertTrue(didWrite)
    }

    private func makeStore(_ bytes: BytesBox) -> WiltedMacShowStartOffsetStore {
        WiltedMacShowStartOffsetStore(
            loadBytes: { await bytes.value(for: $0) },
            saveBytes: { await bytes.set($1, for: $0) },
            now: { Date(timeIntervalSince1970: 100) })
    }
}
