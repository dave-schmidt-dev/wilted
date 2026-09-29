import CloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class IntentOutcomeTests: XCTestCase {
    private let mapper = LibraryRecordMapper()
    private let created = Date(timeIntervalSince1970: 1_000)

    private func intent(_ id: String, _ device: String = "phone") throws -> LibraryIntent {
        try .keep(entryID: item("ep-1"), deviceID: device, createdAt: created, id: id)
    }

    func testDecisionIntentsRoundTripThroughTheirRecords() throws {
        let intents: [LibraryIntent] = [
            try .keep(entryID: item("ep-1"), deviceID: "phone", createdAt: created, id: "k"),
            try .skip(entryID: item("ep-1"), deviceID: "phone", createdAt: created, id: "s"),
            try .markDone(entryID: item("ep-1"), deviceID: "phone", createdAt: created, id: "m"),
            try .restore(entryID: item("ep-1"), deviceID: "phone", createdAt: created, id: "r"),
            try .reorder(entryID: item("ep-1"), afterEntryID: item("ep-2"), deviceID: "phone", createdAt: created, id: "o"),
            try .reorder(entryID: item("ep-1"), afterEntryID: nil, deviceID: "phone", createdAt: created, id: "f"),
        ]
        for value in intents {
            let record = try mapper.record(intent: value)
            XCTAssertEqual(record.allKeys(), [LibraryRecordMapper.payloadField])
            XCTAssertEqual(try mapper.decode(record), .intent(value))
        }
    }

    func testOutcomeRecordsLiveInTheLibraryZoneAndRoundTrip() throws {
        let applied = try IntentOutcome.applied(for: intent("k"), at: created)
        let rejected = try IntentOutcome.rejected(for: intent("s"), reason: IntentOutcome.reasonExpired, at: created)
        for outcome in [applied, rejected] {
            let record = try mapper.record(outcome: outcome)
            XCTAssertEqual(record.recordType, LibraryRecordType.outcome.rawValue)
            XCTAssertEqual(record.recordID.recordName, "outcome:phone:" + outcome.intentID)
            XCTAssertEqual(record.recordID.zoneID, mapper.zoneID)
            XCTAssertEqual(record.allKeys(), [LibraryRecordMapper.payloadField])
            XCTAssertEqual(try mapper.decode(record), .outcome(outcome))
        }
        let index = IntentOutcomeIndex(deviceID: "phone", intentIDs: ["k", "s"])
        let indexRecord = try mapper.record(outcomeIndex: index)
        XCTAssertEqual(indexRecord.recordID.recordName, "outcomeindex:phone")
        XCTAssertEqual(try mapper.decode(indexRecord), .outcomeIndex(index))
    }

    func testAnOutcomeRecordWhoseNameDisagreesWithItsPayloadIsRejected() throws {
        let source = try mapper.record(outcome: .applied(for: intent("k"), at: created))
        let forged = CKRecord(recordType: source.recordType, recordID: CKRecord.ID(recordName: "outcome:phone:other", zoneID: mapper.zoneID))
        forged[LibraryRecordMapper.payloadField] = source[LibraryRecordMapper.payloadField]
        XCTAssertThrowsError(try mapper.decode(forged)) {
            XCTAssertEqual($0 as? LibraryRecordMapperError, .identityMismatch("outcome:phone:other"))
        }
    }

    func testOnlyTheLibraryWriterMayPublishOutcomes() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        await XCTAssertThrowsErrorAsync(try await phone.transport.publishIntentOutcome(.applied(for: self.intent("k"), at: self.created))) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let names = await fixture.server.records.keys.filter { $0.hasPrefix("outcome") }
        XCTAssertTrue(names.isEmpty, "nothing was written")
    }

    func testMacPublishesOutcomesAndThePhoneReadsThemByName() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let early = try IntentOutcome.applied(for: intent("k1"), at: Date(timeIntervalSince1970: 10))
        let late = try IntentOutcome.rejected(for: intent("k2"), reason: IntentOutcome.reasonUnknownEntry, at: Date(timeIntervalSince1970: 20))
        try await mac.transport.publishIntentOutcome(late)
        try await mac.transport.publishIntentOutcome(early)
        let seen = try await phone.transport.intentOutcomes()
        XCTAssertEqual(seen, [early, late])
        XCTAssertTrue(phone.log.states.isEmpty, "no engine was created for the read")
        let scopes = await phone.driver.scopes
        XCTAssertTrue(scopes.isEmpty)
        let index = try await fixture.server.records["outcomeindex:phone"].map { try mapper.decode($0) }
        XCTAssertEqual(index, .outcomeIndex(IntentOutcomeIndex(deviceID: "phone", intentIDs: ["k1", "k2"])))
    }

    func testAnOutcomeIsImmutableSoARepublishKeepsTheFirstAnswer() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let first = try IntentOutcome.rejected(for: intent("k"), reason: IntentOutcome.reasonNotApplicable, at: created)
        try await mac.transport.publishIntentOutcome(first)
        // A second Mac session has no cached server record, so its save conflicts and must not overwrite.
        let restarted = try fixture.endpoint("mac", writer: true)
        try await restarted.transport.publishIntentOutcome(.applied(for: intent("k"), at: created.addingTimeInterval(5)))
        let seen = try await restarted.transport.intentOutcomes()
        XCTAssertEqual(seen, [first])
    }

    func testOutcomesForDifferentDevicesStaySeparate() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishIntentOutcome(.applied(for: intent("k", "phone"), at: created))
        try await mac.transport.publishIntentOutcome(.applied(for: intent("k", "tablet"), at: created))
        let mine = try await phone.transport.intentOutcomes()
        XCTAssertEqual(mine.map(\.deviceID), ["phone"])
        let tablet = try fixture.endpoint("tablet", writer: false)
        let theirs = try await tablet.transport.intentOutcomes()
        XCTAssertEqual(theirs.map(\.deviceID), ["tablet"])
    }
}
