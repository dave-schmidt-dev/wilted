import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacShowPlaybackSpeedStoreTests: XCTestCase {
    private actor BytesBox {
        var values: [String: Data] = [:]
        func value(for key: String) -> Data? { values[key] }
        func set(_ data: Data, for key: String) { values[key] = data }
        var isEmpty: Bool { values.isEmpty }
    }

    func testCompareAndSetReplayConflictAndResetSurviveRecreation() async throws {
        let bytes = BytesBox()
        let store = makeStore(bytes)
        let feed = try ItemID(rawValue: "show-speed-feed")
        let first = try await store.apply(
            commandID: "speed-set", owner: "owner-a", feedID: feed, speed: 1.5, basedOnRevision: 0)
        let expected = try LibraryShowPlaybackSpeed(feedID: feed, speed: 1.5, revision: 1)
        XCTAssertEqual(first, .applied(expected))
        let replay = try await makeStore(bytes).apply(
            commandID: "speed-set", owner: "owner-a", feedID: feed, speed: 2, basedOnRevision: 1)
        XCTAssertEqual(replay, first)

        let stale = try await store.apply(
            commandID: "stale", owner: "owner-a", feedID: feed, speed: 1.75, basedOnRevision: 0)
        XCTAssertEqual(stale, .conflict(expected))
        let reset = try await makeStore(bytes).apply(
            commandID: "speed-reset", owner: "owner-a", feedID: feed, speed: nil, basedOnRevision: 1)
        XCTAssertEqual(reset, .applied(try LibraryShowPlaybackSpeed(feedID: feed, speed: nil, revision: 2)))
        let persisted = try await makeStore(bytes).speeds(owner: "owner-a")
        XCTAssertEqual(persisted[feed.rawValue]?.revision, 2)
        XCTAssertNil(persisted[feed.rawValue]?.speed)
    }

    func testOwnersRemainIsolatedAndInvalidRatesDoNotWrite() async throws {
        let bytes = BytesBox()
        let store = makeStore(bytes)
        let feed = try ItemID(rawValue: "show-speed-feed")
        do {
            _ = try await store.apply(commandID: "bad", owner: "owner-a", feedID: feed, speed: 1.1, basedOnRevision: 0)
            XCTFail("Expected unsupported rate to fail")
        } catch {}
        let isEmpty = await bytes.isEmpty
        XCTAssertTrue(isEmpty)

        _ = try await store.apply(commandID: "owner-a", owner: "owner-a", feedID: feed, speed: 1.25, basedOnRevision: 0)
        let otherOwner = try await store.speeds(owner: "owner-b")
        let savedOwner = try await store.speeds(owner: "owner-a")
        XCTAssertTrue(otherOwner.isEmpty)
        XCTAssertEqual(savedOwner[feed.rawValue]?.speed, 1.25)
    }

    private func makeStore(_ bytes: BytesBox) -> WiltedMacShowPlaybackSpeedStore {
        WiltedMacShowPlaybackSpeedStore(
            loadBytes: { await bytes.value(for: $0) },
            saveBytes: { await bytes.set($1, for: $0) },
            now: { Date(timeIntervalSince1970: 100) })
    }
}
