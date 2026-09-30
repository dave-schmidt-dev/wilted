import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// `HandoffCoordinator.publishStoredPositions`: a paused position published on the Progress
/// channel only, with no session, no NowPlaying record and no epoch raise.
final class HandoffStoredPositionTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let other = try! ItemID(rawValue: "item-" + String(repeating: "b", count: 64))
    private let revision = try! RevisionID(rawValue: "rev-a")

    private func makeServer() async -> InMemoryLibraryServer {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        await server.setClock(Date(timeIntervalSince1970: 1_000))
        return server
    }

    private func coordinator(_ server: InMemoryLibraryServer, _ device: String) -> HandoffCoordinator {
        HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: device, server: server), deviceID: device,
            clock: { Date(timeIntervalSince1970: 1_000) }, sleep: { _ in })
    }

    private func records(_ server: InMemoryLibraryServer) async throws -> LibraryDeviceRecords {
        try await InMemoryLibraryTransport(deviceID: "reader", server: server).fetchDeviceRecords()
    }

    private func stored(_ id: ItemID, _ position: Double, updatedAt: Date? = nil) -> HandoffCoordinator.StoredPosition {
        .init(entryID: id, revision: revision, positionSeconds: position, updatedAt: updatedAt)
    }

    func testPublishesPausedProgressOnlyWithoutASession() async throws {
        let server = await makeServer()
        let mac = coordinator(server, "mac")
        let written = try await mac.publishStoredPositions([stored(entry, 321)])
        XCTAssertEqual(written, [entry])
        let all = try await records(server)
        XCTAssertTrue(all.nowPlaying.isEmpty, "a stored position must not write the NowPlaying record")
        let progress = try XCTUnwrap(all.progress.first)
        XCTAssertEqual(progress.record.positionSeconds, 321)
        XCTAssertFalse(progress.record.isPlaying)
        XCTAssertEqual(progress.record.revision, revision)
        XCTAssertEqual(progress.record.epoch, 0)
        let epoch = await mac.epoch
        XCTAssertNil(epoch, "no session may be created")
    }

    func testDoesNotRaiseTheEpochAPlayingPhoneWouldObserve() async throws {
        let server = await makeServer()
        let phone = coordinator(server, "phone")
        try await phone.takeover(entryID: other, revision: revision, positionSeconds: 10)
        try await coordinator(server, "mac").publishStoredPositions([stored(entry, 60)])
        let decision = try await phone.observe()
        XCTAssertEqual(decision, .keepPlaying)
        let mac = try await records(server).progress.first { $0.record.deviceID == "mac" }
        XCTAssertEqual(mac?.record.epoch, 0, "an entry nobody played keeps epoch 0")
    }

    func testReusesTheHighestEpochSeenForTheEntry() async throws {
        let server = await makeServer()
        let mac = coordinator(server, "mac")
        let epoch = try await mac.takeover(entryID: entry, revision: revision, positionSeconds: 30)
        try await mac.stopped(at: 30)
        try await mac.publishStoredPositions([stored(entry, 500)])
        let progress = try await records(server).progress.first { $0.record.deviceID == "mac" }
        XCTAssertEqual(progress?.record.epoch, epoch)
        XCTAssertEqual(progress?.record.positionSeconds, 500)
    }

    func testSkipsTheEntryThisDeviceIsPlaying() async throws {
        let server = await makeServer()
        let mac = coordinator(server, "mac")
        try await mac.takeover(entryID: entry, revision: revision, positionSeconds: 90)
        let written = try await mac.publishStoredPositions([stored(entry, 10)])
        XCTAssertTrue(written.isEmpty)
        let progress = try await records(server).progress.first { $0.record.deviceID == "mac" }
        XCTAssertEqual(progress?.record.positionSeconds, 90, "live progress is not overwritten by a stale checkpoint")
    }

    func testSkipsAnEntryAnotherDevicePlaysOrSavedMoreRecently() async throws {
        let server = await makeServer()
        let phone = coordinator(server, "phone")
        try await phone.takeover(entryID: entry, revision: revision, positionSeconds: 700)
        let mac = coordinator(server, "mac")
        var written = try await mac.publishStoredPositions([stored(entry, 10)])
        XCTAssertTrue(written.isEmpty, "the phone is playing this entry")
        try await phone.stopped(at: 700)
        written = try await mac.publishStoredPositions([stored(entry, 10, updatedAt: Date(timeIntervalSince1970: 500))])
        XCTAssertTrue(written.isEmpty, "the phone saved after the Mac's checkpoint")
        written = try await mac.publishStoredPositions([stored(entry, 900, updatedAt: Date(timeIntervalSince1970: 2_000))])
        XCTAssertEqual(written, [entry], "the Mac's checkpoint is newer than the phone's record")
    }

    func testAListHeldBackWhileADevicePlaysIsMarkedDeferred() async throws {
        let server = await makeServer()
        let phone = coordinator(server, "phone")
        try await phone.takeover(entryID: entry, revision: revision, positionSeconds: 700)
        let mac = coordinator(server, "mac")
        _ = try await mac.publishStoredPositions([stored(entry, 10)])
        let held = await mac.deferredStoredPositions
        XCTAssertTrue(held, "the caller must offer this list again once the phone pauses")
        try await phone.stopped(at: 700)
        _ = try await mac.publishStoredPositions([stored(entry, 900, updatedAt: Date(timeIntervalSince1970: 2_000))])
        let cleared = await mac.deferredStoredPositions
        XCTAssertFalse(cleared)
    }

    func testAnUnchangedPositionIsNotRewritten() async throws {
        let server = await makeServer()
        let mac = coordinator(server, "mac")
        _ = try await mac.publishStoredPositions([stored(entry, 42)])
        let again = try await mac.publishStoredPositions([stored(entry, 42.2)])
        XCTAssertTrue(again.isEmpty)
        let moved = try await mac.publishStoredPositions([stored(entry, 80)])
        XCTAssertEqual(moved, [entry])
    }
}
