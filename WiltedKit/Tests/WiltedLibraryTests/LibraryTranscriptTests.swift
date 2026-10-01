import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryTranscriptTests: XCTestCase {
    private let macID = "mac-1"
    private let phoneID = "phone-1"

    private func entry(_ raw: String = "ep-1") throws -> ItemID { try ItemID(rawValue: raw) }
    private func revision(_ raw: String = "rev-1") throws -> RevisionID { try RevisionID(rawValue: raw) }

    private func cues(_ count: Int, text: String = "spoken words") -> [LibraryTranscriptCue] {
        (0..<count).map { LibraryTranscriptCue(start: Double($0), end: Double($0) + 0.9, text: "\(text) \($0)") }
    }

    // MARK: Wire model

    func testTimedTranscriptRoundTripsAndFindsTheCueForAPosition() throws {
        let value = try LibraryTranscript(entryID: entry(), revisionID: revision(), cues: cues(5), languageCode: "en")
        let decoded = try JSONDecoder().decode(LibraryTranscript.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isTimed)
        XCTAssertNil(decoded.plainText)
        XCTAssertFalse(decoded.isTruncated)
        XCTAssertNil(decoded.cue(at: -1))
        XCTAssertEqual(decoded.cue(at: 2.95)?.text, "spoken words 2")
        XCTAssertEqual(decoded.cue(at: 99)?.text, "spoken words 4")
    }

    func testPlainTextFallbackRoundTripsAndCarriesNoCues() throws {
        let value = try LibraryTranscript(entryID: entry(), revisionID: revision(), plainText: "Hello there.")
        let decoded = try JSONDecoder().decode(LibraryTranscript.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertFalse(decoded.isTimed)
        XCTAssertNil(decoded.cue(at: 1))
    }

    func testWireShapeUsesTheDocumentedCueKeysAndIgnoresUnknownKeys() throws {
        let json = Data(#"{"entryID":"ep-1","revisionID":"rev-1","cues":[{"start":1,"end":2,"text":"a"}],"future":{"x":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(LibraryTranscript.self, from: json)
        XCTAssertEqual(decoded.cues, [LibraryTranscriptCue(start: 1, end: 2, text: "a")])
        XCTAssertFalse(decoded.isTruncated, "a missing truncated key means not truncated")
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""start":1"#) && encoded.contains(#""end":2"#) && encoded.contains(#""text":"a""#))
    }

    func testTheSpeakerRoundTripsAndAnAbsentSpeakerStaysOffTheWire() throws {
        let named = LibraryTranscriptCue(start: 1, end: 2, text: "a", speaker: "Ann")
        let value = try LibraryTranscript(entryID: entry(), revisionID: revision(), cues: cues(1) + [named])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(LibraryTranscript.self, from: data).cues.map(\.speaker), [nil, "Ann"])
        let unnamed = try JSONEncoder().encode(LibraryTranscriptCue(start: 1, end: 2, text: "a"))
        XCTAssertFalse(String(decoding: unnamed, as: UTF8.self).contains("speaker"), "no key for a nil speaker, so an older reader sees the old shape")
        let fromSpeakerJSON = try JSONDecoder().decode(LibraryTranscriptCue.self, from: Data(#"{"start":1,"end":2,"text":"a","speaker":"Bo"}"#.utf8))
        XCTAssertEqual(fromSpeakerJSON.speaker, "Bo")
    }

    func testValidationRejectsEmptyMixedAndInvalidContent() throws {
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision()))
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(), plainText: ""))
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(), cues: cues(1), plainText: "x"))
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(),
                                                   cues: [LibraryTranscriptCue(start: 5, end: 4, text: "a")]))
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(),
                                                   cues: [LibraryTranscriptCue(start: .nan, end: 4, text: "a")]))
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(),
                                                   cues: [LibraryTranscriptCue(start: 3, end: 4, text: "a"), LibraryTranscriptCue(start: 1, end: 2, text: "b")]))
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryTranscript.self, from: Data(#"{"entryID":"e","revisionID":"r"}"#.utf8)))
    }

    // MARK: Cap

    func testTheValidatingInitializerRefusesAnOverCapValue() throws {
        let huge = String(repeating: "a", count: LibraryTranscript.maximumEncodedBytes)
        XCTAssertThrowsError(try LibraryTranscript(entryID: entry(), revisionID: revision(), plainText: huge))
    }

    func testCappedTimedTranscriptKeepsALeadingPrefixWithinTheCapAndFlagsTruncation() throws {
        let many = cues(30_000, text: String(repeating: "word ", count: 6))
        let value = try XCTUnwrap(LibraryTranscript.capped(entryID: entry(), revisionID: revision(), cues: many))
        XCTAssertTrue(value.isTruncated)
        XCTAssertLessThan(value.cues.count, many.count)
        XCTAssertGreaterThan(value.cues.count, 1_000)
        XCTAssertEqual(value.cues, Array(many.prefix(value.cues.count)))
        let size = try JSONEncoder().encode(value).count
        XCTAssertLessThanOrEqual(size, LibraryTranscript.maximumEncodedBytes)
        XCTAssertGreaterThan(size, LibraryTranscript.maximumEncodedBytes - 512, "the prefix is as long as the cap allows")
    }

    func testCappedPlainTextTruncatesOnACharacterBoundaryWithinTheCap() throws {
        let long = String(repeating: "héllo \"quoted\" wörld 🌱 ", count: 40_000)
        let value = try XCTUnwrap(LibraryTranscript.capped(entryID: entry(), revisionID: revision(), plainText: long))
        XCTAssertTrue(value.isTruncated)
        XCTAssertTrue(long.hasPrefix(try XCTUnwrap(value.plainText)))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value).count, LibraryTranscript.maximumEncodedBytes)
    }

    func testAnUnderCapTranscriptIsNotFlaggedAndNothingUsableYieldsNil() throws {
        let value = try XCTUnwrap(LibraryTranscript.capped(entryID: entry(), revisionID: revision(), cues: cues(10)))
        XCTAssertFalse(value.isTruncated)
        XCTAssertEqual(value.cues.count, 10)
        XCTAssertNil(LibraryTranscript.capped(entryID: try entry(), revisionID: try revision()))
        XCTAssertNil(LibraryTranscript.capped(entryID: try entry(), revisionID: try revision(), plainText: ""))
    }

    // MARK: Mapping from the Mac's stored transcript

    private func stored(
        _ availability: TranscriptAvailability, text: String? = "Full text.", timing: TranscriptTiming = .none,
        cues: [TranscriptCue]? = nil
    ) throws -> Transcript {
        try Transcript(
            itemID: entry(), revisionID: revision("rev-9"), availability: availability, text: text, languageCode: "en",
            timing: timing, cues: cues, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_000)))
    }

    func testStoredTimedTranscriptMapsToCuesAndDropsTheDuplicateText() throws {
        let cue = try TranscriptCue(startSeconds: 1, endSeconds: 3, text: "Hi", speaker: "Ann")
        let value = try XCTUnwrap(LibraryTranscript.capped(entryID: entry(), from: stored(.available, timing: .published, cues: [cue])))
        XCTAssertEqual(value.revisionID, try revision("rev-9"))
        XCTAssertEqual(value.cues, [LibraryTranscriptCue(start: 1, end: 3, text: "Hi", speaker: "Ann")])
        XCTAssertNil(value.plainText)
        XCTAssertEqual(value.languageCode, "en")
    }

    func testStoredUntimedTranscriptFallsBackToPlainTextAndUnavailableOnesArePublishedAsNothing() throws {
        let plain = try XCTUnwrap(LibraryTranscript.capped(entryID: entry(), from: stored(.available)))
        XCTAssertEqual(plain.plainText, "Full text.")
        XCTAssertTrue(plain.cues.isEmpty)
        XCTAssertNil(LibraryTranscript.capped(entryID: try entry(), from: try stored(.stale)))
        XCTAssertNil(LibraryTranscript.capped(entryID: try entry(), from: try stored(.absent, text: nil)))
        XCTAssertNil(LibraryTranscript.capped(entryID: try entry(), from: try stored(.malformed, text: nil)))
    }

    // MARK: Transport

    func testInMemoryTransportServesTheMatchingRevisionOnlyAndTheWriterAloneMayWriteOrRemove() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let mac = InMemoryLibraryTransport(deviceID: macID, server: server)
        let phone = InMemoryLibraryTransport(deviceID: phoneID, server: server)
        let value = try LibraryTranscript(entryID: entry(), revisionID: revision("rev-1"), cues: cues(3))

        let before = try await phone.transcript(entryID: entry(), revisionID: revision("rev-1"))
        XCTAssertNil(before)
        try await mac.publishTranscript(value)
        let seen = try await phone.transcript(entryID: entry(), revisionID: revision("rev-1"))
        XCTAssertEqual(seen, value)
        let otherRevision = try await phone.transcript(entryID: entry(), revisionID: revision("rev-2"))
        XCTAssertNil(otherRevision, "a transcript for another revision is not served")

        do { try await phone.publishTranscript(value); XCTFail("a phone must not publish") } catch {
            guard case .ownershipViolation? = error as? LibraryTransportError else { return XCTFail("\(error)") }
        }
        do { try await phone.removeTranscript(entryID: entry()); XCTFail("a phone must not remove") } catch {
            guard case .ownershipViolation? = error as? LibraryTransportError else { return XCTFail("\(error)") }
        }

        let newer = try LibraryTranscript(entryID: entry(), revisionID: revision("rev-2"), plainText: "new")
        try await mac.publishTranscript(newer)
        let replaced = try await phone.transcript(entryID: entry(), revisionID: revision("rev-1"))
        XCTAssertNil(replaced, "a newer revision replaces the older one")
        try await mac.removeTranscript(entryID: entry())
        let gone = try await phone.transcript(entryID: entry(), revisionID: revision("rev-2"))
        XCTAssertNil(gone)
    }

    func testATransportWithoutTranscriptSupportReadsNilAndRefusesToPublish() async throws {
        struct Bare: LibraryTransport {
            func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { LibraryChangeBatch(generationID: "g", changes: [], token: nil) }
            func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { LibraryPushResult() }
            func send(intent: LibraryIntent) async throws {}
            func listIntents() async throws -> [LibraryIntent] { [] }
            func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
            func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }
            func removeMedia(entryID: ItemID) async throws {}
        }
        let bare = Bare()
        let read = try await bare.transcript(entryID: entry(), revisionID: revision())
        XCTAssertNil(read)
        try await bare.removeTranscript(entryID: entry())
        let value = try LibraryTranscript(entryID: entry(), revisionID: revision(), plainText: "x")
        do { try await bare.publishTranscript(value); XCTFail("expected unsupported") } catch {
            XCTAssertEqual(error as? LibraryTransportError, .transport("transcripts are not supported by this transport"))
        }
    }
}
