import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// The merge rules of the two handshake records, which every write applies to the server copy.
final class LibraryDeviceLinkModelTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(_ intent: String, _ stage: LibraryMediaRequestStatus.Stage, _ offset: TimeInterval) throws -> LibraryMediaRequestStatus {
        LibraryMediaRequestStatus(intentID: intent, entryID: try ItemID(rawValue: "ep-1"), stage: stage, updatedAt: at.addingTimeInterval(offset))
    }

    func testTheDirectoryKeepsTheNewestDevicesAndOneEntryEach() {
        var directory = LibraryDeviceDirectory()
        for index in 0..<(LibraryDeviceDirectory.maximumDevices + 3) {
            directory = directory.merging(.init(deviceID: "d\(index)", kind: "iPhone", announcedAt: at.addingTimeInterval(Double(index))))
        }
        directory = directory.merging(.init(deviceID: "d5", kind: "iPad", announcedAt: at.addingTimeInterval(1_000)))
        XCTAssertEqual(directory.devices.count, LibraryDeviceDirectory.maximumDevices)
        XCTAssertFalse(directory.devices.contains { ["d0", "d1", "d2"].contains($0.deviceID) }, "the oldest go first")
        XCTAssertTrue(directory.devices.contains { $0.deviceID == "d3" })
        XCTAssertEqual(directory.devices.filter { $0.deviceID == "d5" }.map(\.kind), ["iPad"])
    }

    func testALinkUpdateKeepsTheNewerStatusTheFirstLinkTimeAndDropsExpiredRequests() throws {
        let server = LibraryDeviceLink(deviceID: "ipad", linkedAt: at, requests: [
            try status("old", .answered, 0), try status("r-1", .sending, 50), try status("r-2", .received, 10),
        ])
        let local = LibraryDeviceLink(deviceID: "ipad", linkedAt: at.addingTimeInterval(100), requests: [try status("r-1", .received, 20)])
        let now = at.addingTimeInterval(LibraryDeviceLink.requestLifetime + 5)
        let merged = local.updating(try status("r-2", .failed, LibraryDeviceLink.requestLifetime + 1), server: server, now: now)
        XCTAssertEqual(merged.linkedAt, at)
        XCTAssertNil(merged.status(intentID: "old"), "past its lifetime")
        XCTAssertEqual(merged.status(intentID: "r-1")?.stage, .sending, "an older local status never undoes a newer server one")
        XCTAssertEqual(merged.status(intentID: "r-2")?.stage, .failed)

        let fresh = local.updating(nil, server: server, now: at.addingTimeInterval(60))
        XCTAssertEqual(fresh.requests.map(\.intentID), ["old", "r-2", "r-1"], "oldest first")
    }

    func testALinkKeepsAtMostItsLimitOfRequests() throws {
        let many = try (0..<(LibraryDeviceLink.maximumRequests + 5)).map { try status("r-\($0)", .answered, Double($0)) }
        let link = LibraryDeviceLink(deviceID: "ipad", linkedAt: at, requests: many)
            .updating(nil, server: nil, now: at.addingTimeInterval(100))
        XCTAssertEqual(link.requests.count, LibraryDeviceLink.maximumRequests)
        XCTAssertNil(link.status(intentID: "r-0"), "the oldest go first")
    }
}
