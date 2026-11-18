import CloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// A transport in a new process has seen no record yet, so it knows no other device and no pair
/// (2026-11-18). A relaunched phone whose Mac had been idle since the phone's last sync read
/// nothing from the Mac: an episode paused there started from the beginning on the phone.
final class LibraryNewProcessRecordsTests: XCTestCase {
    /// The Mac paused `ep-1` earlier and has since moved on to `ep-2`.
    private func rig() async throws -> (MediaFixture, phone: MediaFixture.Endpoint) {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        try await mac.transport.publish(try makePosition(device: "mac", entry: "ep-1", epoch: 3), as: .progress)
        let current = try makePosition(device: "mac", entry: "ep-2", epoch: 4)
        try await mac.transport.publish([(current, .nowPlaying), (current, .progress)])
        return (fixture, try fixture.endpoint("phone", writer: false))
    }

    private func macProgress(_ records: LibraryDeviceRecords) -> Set<String> {
        Set(records.progress.filter { $0.record.deviceID == "mac" }.map(\.record.entryID.rawValue))
    }

    func testAReadOfNamedEntriesAsksEveryToldDeviceForThemInOneRequest() async throws {
        let (_, phone) = try await rig()
        // Through the protocol, as the app calls it: the transport's own method must be the one that runs.
        let transport: any LibraryTransport = phone.transport
        await transport.track(devices: ["mac"], entries: [])
        let before = await phone.driver.askedNames.count

        let records = try await phone.transport.fetchDeviceRecords(entries: [try item("ep-1")])

        XCTAssertEqual(macProgress(records), ["ep-1"], "the pair was never seen in this process, and is still read")
        let requests = await phone.driver.askedNames.dropFirst(before)
        XCTAssertEqual(requests.count, 1)
    }

    func testANamedEntryNoDeviceHasPlayedIsAskedOnceAndReturnsNothing() async throws {
        let (_, phone) = try await rig()
        await phone.transport.track(devices: ["mac"])

        let records = try await phone.transport.fetchDeviceRecords(entries: [try item("ep-never")])

        XCTAssertTrue(records.progress.isEmpty)
        XCTAssertEqual(records.nowPlaying.map(\.record.deviceID), ["mac"])
    }

    func testAPollInANewProcessToldOfTheMacReturnsItsNowPlayingAndThatProgress() async throws {
        let (_, phone) = try await rig()
        await phone.transport.track(devices: ["mac"], entries: [try item("ep-1")])

        let result = try await phone.transport.poll([.deviceRecords])

        let records = try XCTUnwrap(result.records)
        XCTAssertEqual(records.nowPlaying.map(\.record.entryID.rawValue), ["ep-2"])
        XCTAssertEqual(macProgress(records), ["ep-1", "ep-2"], "the seeded entry and the one now playing")
    }

    /// Why the phone must be told: nothing in a follower's own reads names the Mac.
    func testANewProcessToldNothingReadsNothingFromTheMac() async throws {
        let (_, phone) = try await rig()

        let result = try await phone.transport.poll([.deviceRecords, .deviceLink])

        XCTAssertEqual(result.records?.nowPlaying.count, 0)
        XCTAssertEqual(result.records?.progress.count, 0)
    }
}
