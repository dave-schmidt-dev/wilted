import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class LibraryTranscriptRecordTests: XCTestCase {
    private let mapper = LibraryRecordMapper()

    private func transcript(_ entry: String = "ep-1", revision: String = "rev-1", count: Int = 3) throws -> LibraryTranscript {
        try LibraryTranscript(
            entryID: item(entry), revisionID: RevisionID(rawValue: revision),
            cues: (0..<count).map { LibraryTranscriptCue(start: Double($0), end: Double($0) + 0.5, text: "cue \($0)") })
    }

    func testRecordIsAnAssetInTheMediaZoneNotTheLibraryZone() throws {
        let fixture = try MediaFixture()
        let value = try transcript()
        let data = try LibraryTranscriptRecord.encode(value)
        let file = fixture.scratch.appendingPathComponent("t.json")
        try data.write(to: file)
        let record = LibraryTranscriptRecord.record(transcript: value, byteCount: data.count, assetURL: file, zoneID: mapper.mediaZoneID)
        XCTAssertEqual(record.recordType, "WiltedTranscript")
        XCTAssertEqual(record.recordID.recordName, "transcript:ep-1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "WiltedMediaZone")
        XCTAssertNotEqual(record.recordID.zoneID, mapper.zoneID)
        XCTAssertTrue(record[LibraryTranscriptRecord.assetField] is CKAsset)
        XCTAssertTrue(LibraryTranscriptRecord.matches(record, entryID: try item("ep-1"), revisionID: try RevisionID(rawValue: "rev-1")))
        XCTAssertFalse(LibraryTranscriptRecord.matches(record, entryID: try item("ep-1"), revisionID: try RevisionID(rawValue: "rev-2")))
        XCTAssertEqual(try LibraryTranscriptRecord.decode(data, entryID: try item("ep-1"), revisionID: try RevisionID(rawValue: "rev-1")), value)
    }

    func testDecodeRefusesOversizedAndMismatchedBytes() throws {
        let data = try LibraryTranscriptRecord.encode(try transcript())
        XCTAssertThrowsError(try LibraryTranscriptRecord.decode(data, entryID: try item("ep-2"), revisionID: try RevisionID(rawValue: "rev-1")))
        XCTAssertThrowsError(try LibraryTranscriptRecord.decode(Data(count: LibraryTranscript.maximumEncodedBytes + 1),
                                                                 entryID: try item("ep-1"), revisionID: try RevisionID(rawValue: "rev-1")))
    }

    func testTheLibraryZoneMapperNeverDecodesATranscriptRecordAsLibraryState() throws {
        let fixture = try MediaFixture()
        let file = fixture.scratch.appendingPathComponent("t.json")
        try Data("{}".utf8).write(to: file)
        let record = LibraryTranscriptRecord.record(transcript: try transcript(), byteCount: 2, assetURL: file, zoneID: mapper.mediaZoneID)
        XCTAssertEqual(try mapper.decode(record), .skipped(recordType: "WiltedTranscript"), "an old reader ignores the new record type")
    }

    func testMacPublishesBeforeAPhoneReadsByNameWithoutAnEngineOrScan() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let value = try transcript()
        let rev = try RevisionID(rawValue: "rev-1")
        let missing = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: rev)
        XCTAssertNil(missing)

        try await mac.transport.publishTranscript(value)
        let log = await fixture.server.log
        XCTAssertEqual(log, ["ensureZone WiltedMediaZone", "raw save transcript:ep-1"], "one raw save, nothing through the engine")
        let uploaded = await fixture.server.uploadedAssetURLs
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploaded.first?.path ?? ""), "the scratch upload file is removed")

        let seen = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: rev)
        XCTAssertEqual(seen, value)
        XCTAssertTrue(phone.log.states.isEmpty, "no engine was created for the read")
        let scopes = await phone.driver.scopes
        XCTAssertTrue(scopes.isEmpty, "no zone scan")
    }

    func testAnotherRevisionReadsNilAndANewerPublishReplacesTheRecord() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishTranscript(try transcript(revision: "rev-1"))
        let other = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: RevisionID(rawValue: "rev-2"))
        XCTAssertNil(other)
        try await mac.transport.publishTranscript(try transcript(revision: "rev-2", count: 1))
        let old = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: RevisionID(rawValue: "rev-1"))
        let new = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: RevisionID(rawValue: "rev-2"))
        XCTAssertNil(old)
        XCTAssertEqual(new?.cues.count, 1)
        let names = await fixture.server.records.keys.filter { $0.hasPrefix("transcript:") }
        XCTAssertEqual(Array(names), ["transcript:ep-1"])
    }

    func testRemoveWithdrawsTheRecordAndAbsentIsSuccess() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishTranscript(try transcript())
        try await mac.transport.removeTranscript(entryID: item("ep-1"))
        try await mac.transport.removeTranscript(entryID: item("ep-1"))
        let gone = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: RevisionID(rawValue: "rev-1"))
        XCTAssertNil(gone)
        let log = await fixture.server.log
        XCTAssertEqual(log.filter { $0.hasPrefix("raw delete transcript:") }.count, 2)
    }

    func testOnlyTheLibraryWriterMayPublishOrRemove() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        await XCTAssertThrowsErrorAsync(try await phone.transport.publishTranscript(self.transcript())) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await phone.transport.removeTranscript(entryID: item("ep-1"))) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let names = await fixture.server.records.keys.filter { $0.hasPrefix("transcript:") }
        XCTAssertTrue(names.isEmpty)
    }

    func testACorruptStoredTranscriptReadsAsAbsent() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishTranscript(try transcript())
        let rev = try RevisionID(rawValue: "rev-1")
        let junk = fixture.scratch.appendingPathComponent("junk")
        try Data("not json".utf8).write(to: junk)
        let corrupt = LibraryTranscriptRecord.record(transcript: try transcript(), byteCount: 8, assetURL: junk, zoneID: mapper.mediaZoneID)
        await fixture.server.putRaw(corrupt)
        let seen = try await phone.transport.transcript(entryID: item("ep-1"), revisionID: rev)
        XCTAssertNil(seen)
    }
}
