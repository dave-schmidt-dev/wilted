import CloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class LibraryStatsRecordTests: XCTestCase {
    private let mapper = LibraryRecordMapper()
    private let stamp = Date(timeIntervalSince1970: 3_000)

    private func stats(_ processed: Double = 60) -> LibraryStats {
        LibraryStats(
            audioProcessedSeconds: processed, speechGeneratedSeconds: 2, confirmedAdTimeRemovedSeconds: 3,
            fasterPlaybackTimeSavedSeconds: 4, minutesPlayed: 5, updatedAt: stamp
        )
    }

    func testStatsRecordLivesInTheLibraryZoneUnderOneNameAndRoundTrips() throws {
        let record = try mapper.record(stats: stats())
        XCTAssertEqual(record.recordType, "LibraryStatsRecord")
        XCTAssertEqual(record.recordID.recordName, "stats:library")
        XCTAssertEqual(record.recordID.zoneID, mapper.zoneID)
        XCTAssertEqual(record.allKeys(), [LibraryRecordMapper.payloadField])
        XCTAssertEqual(try mapper.decode(record), .stats(stats()))
    }

    func testAStatsRecordWhoseNameIsNotTheSingletonIsRejected() throws {
        let source = try mapper.record(stats: stats())
        let forged = CKRecord(recordType: source.recordType, recordID: CKRecord.ID(recordName: "stats:other", zoneID: mapper.zoneID))
        forged[LibraryRecordMapper.payloadField] = source[LibraryRecordMapper.payloadField]
        XCTAssertThrowsError(try mapper.decode(forged)) {
            XCTAssertEqual($0 as? LibraryRecordMapperError, .identityMismatch("stats:other"))
        }
    }

    func testAMalformedStatsPayloadThrowsAndAnOldPayloadDecodes() throws {
        let bad = CKRecord(recordType: "LibraryStatsRecord", recordID: mapper.statsRecordID)
        bad[LibraryRecordMapper.payloadField] = Data("nope".utf8) as CKRecordValue
        XCTAssertThrowsError(try mapper.decode(bad))
        let old = CKRecord(recordType: "LibraryStatsRecord", recordID: mapper.statsRecordID)
        old[LibraryRecordMapper.payloadField] = Data(#"{"audioProcessedSeconds":1,"speechGeneratedSeconds":2,"confirmedAdTimeRemovedSeconds":3,"fasterPlaybackTimeSavedSeconds":4}"#.utf8) as CKRecordValue
        XCTAssertEqual(try mapper.decode(old), .stats(LibraryStats(audioProcessedSeconds: 1, speechGeneratedSeconds: 2, confirmedAdTimeRemovedSeconds: 3, fasterPlaybackTimeSavedSeconds: 4)))
    }

    func testMacPublishesStatsAndThePhoneReadsThemByNameWithoutAnEngine() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let before = try await phone.transport.readStats()
        XCTAssertNil(before)
        try await mac.transport.publishStats(stats(60))
        let seen = try await phone.transport.readStats()
        XCTAssertEqual(seen, stats(60))
        XCTAssertTrue(phone.log.states.isEmpty, "no engine was created for the read")
        let scopes = await phone.driver.scopes
        XCTAssertTrue(scopes.isEmpty, "no zone scan")
    }

    func testARepublishReplacesTheSingleRecordEvenFromARestartedMac() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        try await mac.transport.publishStats(stats(60))
        try await mac.transport.publishStats(stats(90))
        let restarted = try fixture.endpoint("mac", writer: true)
        try await restarted.transport.publishStats(stats(120))
        let phone = try fixture.endpoint("phone", writer: false)
        let seen = try await phone.transport.readStats()
        XCTAssertEqual(seen?.audioProcessedSeconds, 120)
        let names = await fixture.server.records.keys.filter { $0.hasPrefix("stats:") }
        XCTAssertEqual(Array(names), ["stats:library"])
    }

    func testOnlyTheLibraryWriterMayPublishStats() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        await XCTAssertThrowsErrorAsync(try await phone.transport.publishStats(self.stats())) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let names = await fixture.server.records.keys.filter { $0.hasPrefix("stats:") }
        XCTAssertTrue(names.isEmpty)
    }
}
