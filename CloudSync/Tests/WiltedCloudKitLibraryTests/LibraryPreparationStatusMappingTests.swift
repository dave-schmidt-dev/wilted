import CloudKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// The optional preparation display field travels inside the existing whole-entry JSON payload:
/// no new record kind, no transport change, and a malformed value still maps the entry.
final class LibraryPreparationStatusMappingTests: XCTestCase {
    private let mapper = LibraryRecordMapper()

    private func item(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    private func status(
        state: LibraryPreparationStatus.State = .active
    ) throws -> LibraryPreparationStatus {
        try LibraryPreparationStatus(
            attemptID: "attempt-1", state: state, stage: "cutting", detail: "Removing ads",
            fraction: 0.5, updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revisionID: try RevisionID(rawValue: "rev-1")
        )
    }

    private func entry(status: LibraryPreparationStatus?) throws -> LibraryEntry {
        try LibraryEntry(
            id: item("ep-1"), kind: .podcastEpisode, sourceID: item("feed-1"), title: "Title",
            summary: "Summary", publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            preparationStatus: status
        )
    }

    private func savedEntryRecord(_ entry: LibraryEntry, payload payloadBytes: Data? = nil) throws -> CKRecord {
        if let payloadBytes {
            let record = CKRecord(
                recordType: LibraryRecordType.entry.rawValue,
                recordID: mapper.recordID(for: LibraryChange.entry(entry).key)
            )
            record[LibraryRecordMapper.payloadField] = payloadBytes as CKRecordValue
            return record
        }
        guard case let .save(record) = try mapper.operation(for: .entry(entry), existing: nil) else {
            XCTFail("expected a save")
            throw LibraryRecordMapperError.missingPayload("expected-entry-save")
        }
        return record
    }

    func testPreparationStatusRoundTripsThroughTheEntryRecord() throws {
        let original = try entry(status: try status(state: .active))
        let record = try savedEntryRecord(original)
        guard case let .library(.entry(decoded)) = try mapper.decode(record) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.preparationStatus, original.preparationStatus)
        XCTAssertEqual(decoded.preparationStatus?.state, .active)
    }

    func testRecordsWithoutTheFieldStillDecodeTheEntry() throws {
        let original = try entry(status: nil)
        let record = try savedEntryRecord(original)
        let data = try XCTUnwrap(record[LibraryRecordMapper.payloadField] as? Data)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("preparationStatus"))
        guard case let .library(.entry(decoded)) = try mapper.decode(record) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.preparationStatus)
    }

    func testMalformedStatusIsAbsentButTheEntryStillMaps() throws {
        let original = try entry(status: nil)
        let data = try LibraryRecordMapper.encoder.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["preparationStatus"] = [
            "version": 2, "attemptID": "a", "state": "running",
            "stage": "s", "detail": "d", "updatedAt": 0.0,
        ]
        let record = try savedEntryRecord(
            original, payload: try JSONSerialization.data(withJSONObject: object)
        )
        guard case let .library(.entry(decoded)) = try mapper.decode(record) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.preparationStatus)
    }
}
