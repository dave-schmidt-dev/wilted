import Foundation
import Security
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

    func testAnnouncementConstantsAndActiveDevicesFiltering() {
        XCTAssertEqual(LibraryDeviceAnnouncement.refreshInterval, 7 * 24 * 60 * 60)
        XCTAssertEqual(LibraryDeviceDirectory.announcementLifetime, 30 * 24 * 60 * 60)

        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "fresh", kind: "iPhone", announcedAt: at),
            LibraryDeviceAnnouncement(deviceID: "stale", kind: "iPad", announcedAt: at.addingTimeInterval(-31 * 24 * 60 * 60)),
        ])
        let active = directory.activeDevices(asOf: at)
        XCTAssertEqual(active.map(\.deviceID), ["fresh"])
    }

    func testALinkKeepsAtMostItsLimitOfRequests() throws {
        let many = try (0..<(LibraryDeviceLink.maximumRequests + 5)).map { try status("r-\($0)", .answered, Double($0)) }
        let link = LibraryDeviceLink(deviceID: "ipad", linkedAt: at, requests: many)
            .updating(nil, server: nil, now: at.addingTimeInterval(100))
        XCTAssertEqual(link.requests.count, LibraryDeviceLink.maximumRequests)
        XCTAssertNil(link.status(intentID: "r-0"), "the oldest go first")
    }

    // MARK: LAN trust fields

    /// Today's payloads, as the CloudKit mapper's default encoder writes them (sorted keys, dates as seconds).
    private static let todaysAnnouncement = #"{"announcedAt":782000000,"deviceID":"phone","kind":"iPhone"}"#
    private static let todaysDirectory = #"{"devices":[{"announcedAt":782000000,"deviceID":"phone","kind":"iPhone"}]}"#
    private static let todaysLink = #"{"deviceID":"phone","linkedAt":782000000,"requests":[{"entryID":"ep-1","intentID":"r-1","stage":"received","updatedAt":782000001}]}"#
    private static let keyBase64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw=="
    private let key = Data(0..<64)

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// The shapes an older build decodes into: no LAN fields.
    private struct OldAnnouncement: Codable { let deviceID: String; let kind: String; let announcedAt: Date }
    private struct OldDirectory: Codable { let devices: [OldAnnouncement] }
    private struct OldLink: Codable { let deviceID: String; let linkedAt: Date; let requests: [LibraryMediaRequestStatus] }

    func testTodaysPayloadsStillDecodeWithoutTheLANFields() throws {
        let announcement = try JSONDecoder().decode(LibraryDeviceAnnouncement.self, from: Data(Self.todaysAnnouncement.utf8))
        XCTAssertEqual(announcement.deviceID, "phone")
        XCTAssertNil(announcement.lanPublicKey)
        let directory = try JSONDecoder().decode(LibraryDeviceDirectory.self, from: Data(Self.todaysDirectory.utf8))
        XCTAssertEqual(directory.devices, [announcement])
        let link = try JSONDecoder().decode(LibraryDeviceLink.self, from: Data(Self.todaysLink.utf8))
        XCTAssertEqual(link.requests.map(\.intentID), ["r-1"])
        XCTAssertNil(link.lanPublicKey)
        XCTAssertNil(link.knownPhoneKeyFingerprint)
    }

    func testPayloadsWithTheLANFieldsDecodeAndTheKeyIsBase64() throws {
        let announced = #"{"announcedAt":782000000,"deviceID":"phone","kind":"iPhone","lanPublicKey":"\#(Self.keyBase64)"}"#
        XCTAssertEqual(try JSONDecoder().decode(LibraryDeviceAnnouncement.self, from: Data(announced.utf8)).lanPublicKey, key)
        let linked = #"{"deviceID":"phone","knownPhoneKeyFingerprint":"ff00","lanPublicKey":"\#(Self.keyBase64)","linkedAt":782000000,"requests":[]}"#
        let link = try JSONDecoder().decode(LibraryDeviceLink.self, from: Data(linked.utf8))
        XCTAssertEqual(link.lanPublicKey, key)
        XCTAssertEqual(link.knownPhoneKeyFingerprint, "ff00")

        let written = String(decoding: try encoder.encode(LibraryDeviceAnnouncement(
            deviceID: "phone", kind: "iPhone", announcedAt: Date(timeIntervalSinceReferenceDate: 782_000_000), lanPublicKey: key)), as: UTF8.self)
        XCTAssertEqual(written, announced)
    }

    func testPayloadsWithoutTheKeysEncodeExactlyAsTodayAndAnOldDecoderAcceptsThem() throws {
        let when = Date(timeIntervalSinceReferenceDate: 782_000_000)
        let announcement = LibraryDeviceAnnouncement(deviceID: "phone", kind: "iPhone", announcedAt: when)
        XCTAssertEqual(String(decoding: try encoder.encode(announcement), as: UTF8.self), Self.todaysAnnouncement)
        let link = LibraryDeviceLink(deviceID: "phone", linkedAt: when, requests: [
            try status("r-1", .received, 0).withUpdatedAt(Date(timeIntervalSinceReferenceDate: 782_000_001)),
        ])
        XCTAssertEqual(String(decoding: try encoder.encode(link), as: UTF8.self), Self.todaysLink)

        // And with the keys set, an older decoder still reads the record (it ignores what it does not know).
        let withKeys = LibraryDeviceAnnouncement(deviceID: "phone", kind: "iPhone", announcedAt: when, lanPublicKey: key)
        XCTAssertEqual(try JSONDecoder().decode(OldAnnouncement.self, from: encoder.encode(withKeys)).deviceID, "phone")
        let linkWithKeys = LibraryDeviceLink(deviceID: "phone", linkedAt: when, lanPublicKey: key, knownPhoneKeyFingerprint: "ff00")
        XCTAssertEqual(try JSONDecoder().decode(OldLink.self, from: encoder.encode(linkWithKeys)).deviceID, "phone")
    }

    /// Why the Mac keeps each device's last-seen key: an older build that reads the directory and writes it
    /// back drops every entry's key, and nothing in the record says it was ever there.
    func testAnOlderBuildsDirectoryRoundTripDropsEveryKey() throws {
        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "phone", kind: "iPhone", announcedAt: at, lanPublicKey: key),
            LibraryDeviceAnnouncement(deviceID: "ipad", kind: "iPad", announcedAt: at, lanPublicKey: key),
        ])
        let old = try JSONDecoder().decode(OldDirectory.self, from: encoder.encode(directory))
        let resaved = try JSONDecoder().decode(LibraryDeviceDirectory.self, from: encoder.encode(old))
        XCTAssertEqual(resaved.devices.map(\.deviceID), ["ipad", "phone"], "the entries survive")
        XCTAssertEqual(resaved.devices.map(\.lanPublicKey), [nil, nil], "the keys do not")
    }

    func testALinkUpdateKeepsTheLANFieldsAndNeverBringsBackAClearedOne() throws {
        let withKeys = LibraryDeviceLink(deviceID: "phone", linkedAt: at, lanPublicKey: key, knownPhoneKeyFingerprint: "aa")
        let updated = withKeys.updating(try status("r-1", .received, 1), server: nil, now: at.addingTimeInterval(2))
        XCTAssertEqual(updated.lanPublicKey, key)
        XCTAssertEqual(updated.knownPhoneKeyFingerprint, "aa")

        let cleared = LibraryDeviceLink(deviceID: "phone", linkedAt: at)
            .updating(nil, server: withKeys, now: at.addingTimeInterval(2))
        XCTAssertNil(cleared.lanPublicKey, "the Mac is the only writer; a key it dropped stays dropped")
        XCTAssertNil(cleared.knownPhoneKeyFingerprint)
    }

    // MARK: LAN key store

    func testTheKeychainItemIsThisDeviceOnlyAndNotSynchronizable() throws {
        let add = KeychainLANKeyStore.addQuery(service: "test.service", keyData: Data([1, 2, 3]))
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(add[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService as String] as? String, "test.service")
        XCTAssertEqual(add[kSecValueData as String] as? Data, Data([1, 2, 3]))

        for query in [KeychainLANKeyStore.baseQuery(service: "s"), KeychainLANKeyStore.readQuery(service: "s")] {
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, "reads and updates only ever see the local item")
            XCTAssertNil(query[kSecAttrAccessible as String])
        }
        XCTAssertEqual(KeychainLANKeyStore.readQuery(service: "s")[kSecReturnData as String] as? Bool, true)
    }

    func testNoKeyBytesAppearInAnyPrintedFormOfTheKeyOrItsStores() throws {
        let raw = Data((0..<32).map { UInt8($0 + 1) })
        let key = try LANKeyAgreementKey(rawRepresentation: raw)
        let store = InMemoryLANKeyStore(key: key)
        var printed = [String(describing: key), String(reflecting: key), "\(key)", String(describing: store),
                       String(describing: KeychainLANKeyStore())]
        var dumped = ""
        dump(key, to: &dumped)
        dump([key], to: &dumped)
        printed.append(dumped)
        for text in printed {
            let lowered = text.lowercased()
            XCTAssertFalse(lowered.contains(raw.hex), text)
            XCTAssertFalse(lowered.contains(raw.base64EncodedString().lowercased()), text)
            XCTAssertFalse(lowered.contains("010203"), text)
        }
        XCTAssertEqual(String(describing: key), "LANKeyAgreementKey(redacted)")
    }

    func testTheInMemoryStoreCreatesOnceRotatesAndDeletes() throws {
        let store = InMemoryLANKeyStore()
        let first = try store.currentKey()
        XCTAssertEqual(try store.currentKey().publicKey, first.publicKey, "created once, then stable")
        let rotated = try store.rotate()
        XCTAssertNotEqual(rotated.publicKey, first.publicKey)
        XCTAssertEqual(try store.currentKey().publicKey, rotated.publicKey)
        try store.delete()
        try store.delete()
        XCTAssertNotEqual(try store.currentKey().publicKey, rotated.publicKey, "a deleted key is not reused")
    }
}

private extension LibraryMediaRequestStatus {
    func withUpdatedAt(_ date: Date) -> LibraryMediaRequestStatus {
        LibraryMediaRequestStatus(intentID: intentID, entryID: entryID, stage: stage, detail: detail, updatedAt: date)
    }
}
