import Foundation
import XCTest
@testable import WiltedDomain

final class TranscriptTests: XCTestCase {
    private let itemID = try! ItemID(rawValue: "item-transcript")
    private let revisionID = try! RevisionID(rawValue: "rev-transcript")
    private let timestamp = try! Timestamp(iso8601: "2026-08-23T20:00:00Z")

    func testAvailableTranscriptRoundTripsWithMetadata() throws {
        let value = try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                   text: "Article body", languageCode: "en-US", updatedAt: timestamp)
        XCTAssertEqual(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(value.format, .plainText)
        XCTAssertEqual(value.schemaVersion, 1)
    }

    func testUnavailableStatesRequireNoText() throws {
        for state in [TranscriptAvailability.absent, .oversized, .malformed] {
            XCTAssertNoThrow(try Transcript(itemID: itemID, revisionID: revisionID,
                                             availability: state, updatedAt: timestamp))
            XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                                 availability: state, text: "unexpected", updatedAt: timestamp))
        }
    }

    func testAvailableAndStaleStatesRequireNonemptyBoundedText() throws {
        for state in [TranscriptAvailability.available, .stale] {
            XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                                 availability: state, updatedAt: timestamp))
            XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                                 availability: state, text: "", updatedAt: timestamp))
        }
        let oversized = String(repeating: "x", count: Transcript.maximumTextUTF8Bytes + 1)
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                             availability: .available, text: oversized, updatedAt: timestamp))
    }

    func testMalformedLanguageAndFutureSchemaFailClosed() throws {
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                             availability: .available, text: "body", languageCode: "not valid!",
                                             updatedAt: timestamp))
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID,
                                             availability: .available, text: "body", updatedAt: timestamp,
                                             schemaVersion: 2))
    }
}
