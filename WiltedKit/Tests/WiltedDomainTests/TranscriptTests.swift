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
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertEqual(value.timing, .none, "a transcript with no cues claims no timing")
        XCTAssertNil(value.cues)
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
                                             schemaVersion: 3))
    }

    /// Version one is still a real record shape, not a legacy alias. It decodes
    /// as untimed rather than failing, and it does not silently become a
    /// version-two record on the way through.
    func testVersionOneRecordsDecodeAsUntimed() throws {
        let value = try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                   text: "Older body", updatedAt: timestamp, schemaVersion: 1)
        XCTAssertEqual(value.timing, .none)
        XCTAssertNil(value.cues)
        let round = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(round.schemaVersion, 1)
        XCTAssertEqual(round, value)
    }

    /// A payload written before `timing` existed carries neither key. Decoding
    /// has to treat that absence as "untimed" rather than a missing field, or
    /// every record already in the store stops loading.
    func testDecodingToleratesPayloadsWrittenBeforeTimingExisted() throws {
        let json = """
        {"itemID":"item-transcript","revisionID":"rev-transcript","availability":"available",
         "text":"Older body","format":"text/plain","updatedAt":"2026-08-23T20:00:00Z","schemaVersion":1}
        """
        let value = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertEqual(value.timing, .none)
        XCTAssertNil(value.cues)
        XCTAssertEqual(value.text, "Older body")
    }

    func testTimedTranscriptRoundTripsAndReportsProvenance() throws {
        let cues = try Self.cues([(0, 2.5, "First line"), (2.5, 6, "Second line")])
        for timing in [TranscriptTiming.published, .aligned] {
            let value = try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                       text: "First line Second line", timing: timing, cues: cues,
                                       updatedAt: timestamp)
            XCTAssertEqual(value.timing, timing)
            XCTAssertEqual(value.cues?.count, 2)
            XCTAssertEqual(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(value)), value)
        }
    }

    /// `timing` and `cues` state the same fact, so a record may not carry one
    /// without the other. Either half alone would let a reader scroll against
    /// nothing, or present cues as evidence the record never claimed.
    func testTimingAndCuesMustAgree() throws {
        let cues = try Self.cues([(0, 1, "Line")])
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                             text: "Line", timing: .none, cues: cues, updatedAt: timestamp))
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                             text: "Line", timing: .aligned, cues: nil, updatedAt: timestamp))
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                             text: "Line", timing: .aligned, cues: [], updatedAt: timestamp))
    }

    func testCuesAreRejectedForUnavailableContent() throws {
        let cues = try Self.cues([(0, 1, "Line")])
        for state in [TranscriptAvailability.absent, .oversized, .malformed] {
            XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: state,
                                                 timing: .aligned, cues: cues, updatedAt: timestamp))
        }
    }

    /// Cue starts must advance. Overlap is allowed on purpose: published
    /// captions routinely overlap so one line is still on screen as the next
    /// appears, and refusing them would drop real publisher transcripts.
    func testCueOrderIsEnforcedButOverlapIsAllowed() throws {
        let overlapping = try Self.cues([(0, 4, "First"), (2, 6, "Second")])
        XCTAssertNoThrow(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                         text: "First Second", timing: .published, cues: overlapping,
                                         updatedAt: timestamp))
        let backwards = try Self.cues([(5, 6, "Later"), (1, 2, "Earlier")])
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                             text: "Later Earlier", timing: .published, cues: backwards,
                                             updatedAt: timestamp))
    }

    func testIndividualCuesRejectImpossibleTiming() throws {
        XCTAssertThrowsError(try TranscriptCue(startSeconds: -1, endSeconds: 1, text: "Negative"))
        XCTAssertThrowsError(try TranscriptCue(startSeconds: 4, endSeconds: 2, text: "Backwards"))
        XCTAssertThrowsError(try TranscriptCue(startSeconds: .nan, endSeconds: 1, text: "Not a number"))
        XCTAssertThrowsError(try TranscriptCue(startSeconds: 0, endSeconds: .infinity, text: "Unbounded"))
        XCTAssertThrowsError(try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "   "))
        XCTAssertEqual(try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "  padded  ").text, "padded")
    }

    func testCueCountIsBounded() throws {
        let overLimit = try (0...Transcript.maximumCueCount).map {
            try TranscriptCue(startSeconds: Double($0), endSeconds: Double($0) + 1, text: "c")
        }
        XCTAssertThrowsError(try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                             text: "body", timing: .aligned, cues: overLimit, updatedAt: timestamp))
    }

    /// The reading position is the last cue whose start has passed, so a gap
    /// between cues holds the previous line rather than blanking the panel,
    /// and time before the first cue resolves to nothing at all.
    func testCueLookupTracksThePlaybackClock() throws {
        let cues = try Self.cues([(1, 2, "First"), (5, 6, "Second"), (10, 11, "Third")])
        let value = try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                   text: "First Second Third", timing: .aligned, cues: cues, updatedAt: timestamp)
        XCTAssertNil(value.cue(at: 0.5), "playback before the first cue has no reading position")
        XCTAssertEqual(value.cue(at: 1)?.text, "First")
        XCTAssertEqual(value.cue(at: 3)?.text, "First", "a gap holds the previous line")
        XCTAssertEqual(value.cue(at: 5.5)?.text, "Second")
        XCTAssertEqual(value.cue(at: 900)?.text, "Third")
        XCTAssertNil(value.cue(at: .nan))
    }

    func testUntimedTranscriptsHaveNoReadingPosition() throws {
        let value = try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                   text: "body", updatedAt: timestamp)
        XCTAssertNil(value.cue(at: 0))
        XCTAssertNil(value.cue(at: 42))
    }

    func testCueCodecRoundTripsAndRefusesCorruptPayloads() throws {
        let cues = try Self.cues([(0, 1.25, "First"), (1.25, 4, "Second")])
        let encoded = try TranscriptCueCodec.encode(cues)
        XCTAssertEqual(try TranscriptCueCodec.decode(encoded), cues)
        XCTAssertThrowsError(try TranscriptCueCodec.decode(Data()))
        XCTAssertThrowsError(try TranscriptCueCodec.decode(Data("not zlib".utf8)))
    }

    /// The whole reason cues travel compressed: a three-hour episode's timing
    /// is the largest thing a transcript record carries, and it has to fit
    /// beside the plain text in one record.
    func testThreeHourEpisodeCuesFitTheTransportBudget() throws {
        var cues: [TranscriptCue] = []
        var start = 0.0
        while start < 3 * 60 * 60 {
            cues.append(try TranscriptCue(startSeconds: start, endSeconds: start + 4.2,
                                          text: "About ten words of ordinary spoken sentence text here."))
            start += 4.2
        }
        XCTAssertGreaterThan(cues.count, 2_000)
        let encoded = try TranscriptCueCodec.encode(cues)
        XCTAssertLessThan(encoded.count, 200_000, "compressed cues must leave room for the text field")
        XCTAssertEqual(try TranscriptCueCodec.decode(encoded).count, cues.count)
    }

    private static func cues(_ spans: [(Double, Double, String)]) throws -> [TranscriptCue] {
        try spans.map { try TranscriptCue(startSeconds: $0.0, endSeconds: $0.1, text: $0.2) }
    }
}
