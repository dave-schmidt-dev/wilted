import CloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// The device handshake: a follower announces itself in the one directory record, the Mac reads the
/// directory with every round's batch and polls a new device in that same round, and the Mac's link
/// record tells the device its requests are being read and how each one is going.
final class LibraryDeviceLinkTests: XCTestCase {
    private let mapper = LibraryRecordMapper()
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let macRound: LibraryPollOptions = [.intents, .deviceRecords, .deviceDirectory]

    private func announcement(_ device: String, _ kind: String = "iPad", offset: TimeInterval = 0) -> LibraryDeviceAnnouncement {
        LibraryDeviceAnnouncement(deviceID: device, kind: kind, announcedAt: at.addingTimeInterval(offset))
    }

    private func status(_ intent: String, _ stage: LibraryMediaRequestStatus.Stage, offset: TimeInterval) throws -> LibraryMediaRequestStatus {
        LibraryMediaRequestStatus(intentID: intent, entryID: try item("ep-1"), stage: stage, updatedAt: at.addingTimeInterval(offset))
    }

    func testAnAnnouncedDeviceHasItsWaitingRequestReadInTheMacsNextRoundWithoutAScan() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let ipad = try fixture.endpoint("ipad", writer: false)
        _ = try await mac.transport.poll(macRound)
        try await ipad.transport.announceDevice(announcement("ipad"))
        let request = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "ipad", createdAt: at, id: "r-1")
        try await ipad.transport.send(intent: request)

        let round = try await mac.transport.poll(macRound)
        XCTAssertEqual(round.intents, [request], "the request is read in the round the Mac learns the device")
        XCTAssertEqual(round.directory?.devices.map(\.deviceID), ["ipad"])
        XCTAssertEqual(round.directory?.devices.first?.kind, "iPad")
        XCTAssertTrue(mac.log.states.isEmpty, "no scan engine")
        let unscoped = await mac.driver.unscopedFetches
        XCTAssertEqual(unscoped, 0)
    }

    func testAnIdleMacRoundThatReadsTheDirectoryIsStillOneOperation() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await phone.transport.announceDevice(announcement("phone", "iPhone"))
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .nowPlaying)
        _ = try await mac.transport.poll(macRound)
        _ = try await mac.transport.poll(macRound)  // learns the entries the now-playing record names
        let before = await mac.driver.targetedFetches
        for _ in 0..<10 { _ = try await mac.transport.poll(macRound) }
        let after = await mac.driver.targetedFetches
        XCTAssertEqual(after - before, 10, "the directory rides along with the intents and records")
    }

    func testEachDeviceAnnouncesWithoutDroppingAnother() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        let ipad = try fixture.endpoint("ipad", writer: false)
        try await phone.transport.announceDevice(announcement("phone", "iPhone"))
        try await ipad.transport.announceDevice(announcement("ipad"))
        try await phone.transport.announceDevice(announcement("phone", "iPhone", offset: 60))
        let mac = try fixture.endpoint("mac", writer: true)
        let directory = try await mac.transport.fetchDeviceDirectory()
        XCTAssertEqual(directory?.devices.map(\.deviceID), ["ipad", "phone"])
        XCTAssertEqual(directory?.devices.last?.announcedAt, at.addingTimeInterval(60), "a re-announcement replaces its own entry")
    }

    func testOnlyAFollowerAnnouncesAndOnlyItselfAndOnlyTheMacLinks() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let attempts: [() async throws -> Void] = [
            { try await mac.transport.announceDevice(self.announcement("mac")) },
            { try await phone.transport.announceDevice(self.announcement("ipad")) },
            { try await phone.transport.publishDeviceLink(LibraryDeviceLink(deviceID: "phone", linkedAt: self.at)) },
        ]
        for attempt in attempts {
            do {
                try await attempt()
                XCTFail("expected an ownership violation")
            } catch let error as LibraryTransportError {
                guard case .ownershipViolation = error else { return XCTFail("wrong error \(error)") }
            }
        }
        let records = await fixture.server.records
        XCTAssertTrue(records.isEmpty, "nothing was written")
    }

    func testTheDeviceReadsItsLinkInItsRoundAndARestartedMacKeepsTheFirstLinkTime() async throws {
        let fixture = try MediaFixture()
        let ipad = try fixture.endpoint("ipad", writer: false)
        let before = try await ipad.transport.poll([.deviceRecords, .deviceLink])
        XCTAssertTrue(before.deviceLinkRead)
        XCTAssertNil(before.deviceLink, "read, and not linked yet")

        let mac = try fixture.endpoint("mac", writer: true)
        try await mac.transport.publishDeviceLink(LibraryDeviceLink(
            deviceID: "ipad", linkedAt: at, requests: [try status("r-1", .received, offset: 1)]))
        let restarted = try fixture.endpoint("mac", writer: true)
        try await restarted.transport.publishDeviceLink(LibraryDeviceLink(
            deviceID: "ipad", linkedAt: at.addingTimeInterval(500), requests: [try status("r-1", .sending, offset: 2)]))

        let after = try await ipad.transport.poll([.deviceRecords, .deviceLink])
        XCTAssertEqual(after.deviceLink?.linkedAt, at)
        XCTAssertEqual(after.deviceLink?.status(intentID: "r-1")?.stage, .sending)
        let other = try fixture.endpoint("phone", writer: false)
        let theirs = try await other.transport.fetchDeviceLink()
        XCTAssertNil(theirs, "a device reads only its own link")
    }

    func testTheNewRecordsRoundTripAndAnUnknownStageReadsAsReceived() throws {
        let directory = LibraryDeviceDirectory(devices: [announcement("phone", "iPhone"), announcement("ipad")])
        let record = try mapper.record(deviceDirectory: directory)
        XCTAssertEqual(record.recordID.recordName, "devicedirectory:library")
        XCTAssertEqual(try mapper.decode(record), .deviceDirectory(directory))

        let link = LibraryDeviceLink(deviceID: "ipad", linkedAt: at, requests: [try status("r-1", .failed, offset: 3)])
        let linkRecord = try mapper.record(deviceLink: link)
        XCTAssertEqual(linkRecord.recordID.recordName, "devicelink:ipad")
        XCTAssertEqual(try mapper.decode(linkRecord), .deviceLink(link))

        let newer = Data(#""queued-on-a-future-mac""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LibraryMediaRequestStatus.Stage.self, from: newer), .received)
    }
}
