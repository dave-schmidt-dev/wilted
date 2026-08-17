import Foundation
import XCTest
@testable import WiltedDomain

final class DomainTests: XCTestCase {
    func testItemIdentityCanonicalizesURL() throws {
        let first = try ItemID.derive(from: XCTUnwrap(URL(string: "HTTPS://Example.COM:443/a?q=1#fragment")))
        let second = try ItemID.derive(from: XCTUnwrap(URL(string: "https://example.com/a?q=1")))
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.rawValue.range(of: #"^item-[0-9a-f]{64}$"#, options: .regularExpression) != nil)
    }

    func testItemIdentityPreservesPathAndQuery() throws {
        let first = try ItemID.derive(from: XCTUnwrap(URL(string: "https://example.test/a?q=1")))
        let second = try ItemID.derive(from: XCTUnwrap(URL(string: "https://example.test/A?q=1")))
        let third = try ItemID.derive(from: XCTUnwrap(URL(string: "https://example.test/a?q=2")))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
    }

    func testArticleRejectsIdentityThatDoesNotMatchCanonicalURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/article"))
        let timestamp = try Timestamp(iso8601: "2026-08-17T12:00:00Z")
        XCTAssertThrowsError(try Article(
            itemID: ItemID(rawValue: "item-wrong"), canonicalURL: url,
            title: "Article", source: "Example", createdAt: timestamp
        ))
        XCTAssertNoThrow(try Article(
            itemID: ItemID.derive(from: url), canonicalURL: url,
            title: "Article", source: "Example", createdAt: timestamp
        ))
    }

    func testRevisionIdentityIsDeterministicAndInputSensitive() throws {
        let settings = try RevisionID.canonicalJSON(["speed": 1.0, "voice": "af_heart"])
        let format = try RevisionID.canonicalJSON(["codec": "aac", "rate": 44_100])
        let first = try RevisionID.derive(
            extractedTextSHA256: String(repeating: "a", count: 64),
            voiceID: "af_heart",
            synthesisSettingsCanonicalJSON: settings,
            audioFormatCanonicalJSON: format
        )
        let second = try RevisionID.derive(
            extractedTextSHA256: String(repeating: "a", count: 64),
            voiceID: "af_heart",
            synthesisSettingsCanonicalJSON: settings,
            audioFormatCanonicalJSON: format
        )
        let changed = try RevisionID.derive(
            extractedTextSHA256: String(repeating: "b", count: 64),
            voiceID: "af_heart",
            synthesisSettingsCanonicalJSON: settings,
            audioFormatCanonicalJSON: format
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, changed)
        XCTAssertTrue(first.rawValue.range(of: #"^rev-[0-9a-f]{64}$"#, options: .regularExpression) != nil)
    }

    func testCanonicalJSONSortsKeys() throws {
        XCTAssertEqual(try RevisionID.canonicalJSON(["z": 1, "a": "x"]), #"{"a":"x","z":1}"#)
    }

    func testTimestampRoundTripAlwaysUsesUTCZ() throws {
        let timestamp = try Timestamp(iso8601: "2026-08-17T12:00:00.125Z")
        let data = try JSONEncoder().encode(timestamp)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""2026-08-17T12:00:00.125Z""#)
        XCTAssertEqual(try JSONDecoder().decode(Timestamp.self, from: data), timestamp)
        XCTAssertThrowsError(try Timestamp(iso8601: "2026-08-17T08:00:00-04:00"))
    }

    func testAudioRevisionOnlyRepresentsValidatedReadyMedia() throws {
        let revision = try makeRevision()
        XCTAssertEqual(revision.readiness, .ready)
        XCTAssertThrowsError(try makeRevision(duration: 0))
        XCTAssertThrowsError(try makeRevision(hash: "sha256:not-a-hash"))
        XCTAssertThrowsError(try makeRevision(bytes: 0))
    }

    func testAudioRevisionDecodeRejectsNonReadyOrInvalidMedia() throws {
        let valid = try JSONEncoder().encode(makeRevision())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["readiness"] = "preparing"
        XCTAssertThrowsError(try JSONDecoder().decode(AudioRevision.self, from: JSONSerialization.data(withJSONObject: object)))
        object["readiness"] = "ready"
        object["contentHash"] = "sha256:invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(AudioRevision.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testPlaybackMergeProtectsMonotonicProgressAndCompletion() throws {
        let current = try makePlayback(sequence: 2, position: 100, completed: true)
        let backward = try makePlayback(sequence: 3, position: 90, completed: true)
        XCTAssertEqual(mergePlayback(current: current, incoming: backward, changeTagMatches: true).reason, .backwardProgress)
        let undo = try makePlayback(sequence: 3, position: 100, completed: false)
        XCTAssertEqual(mergePlayback(current: current, incoming: undo, changeTagMatches: true).reason, .completionCannotBeReversed)
    }

    func testExplicitIntentRequiresNewSessionAndCurrentTag() throws {
        let current = try makePlayback(sequence: 2, position: 100)
        let sameSession = try makePlayback(sequence: 3, position: 10, intent: .rewind)
        XCTAssertEqual(mergePlayback(current: current, incoming: sameSession, changeTagMatches: true).reason, .explicitIntentRequiresNewSession)
        let newSession = try makePlayback(session: "session-new", sequence: 1, position: 10, intent: .rewind)
        XCTAssertEqual(mergePlayback(current: current, incoming: newSession, changeTagMatches: false).reason, .staleChangeTag)
        XCTAssertEqual(mergePlayback(current: current, incoming: newSession, changeTagMatches: true).decision, .accept)
    }

    func testPreparationStatusRequiresConsistentTerminalPayload() throws {
        let time = try Timestamp(iso8601: "2026-08-17T12:00:00Z")
        XCTAssertNoThrow(try PreparationStatus(stage: .fetching, detail: "Fetching", fraction: 0.5, cancellable: true, emittedAt: time))
        XCTAssertThrowsError(try PreparationStatus(stage: .fetching, detail: "Fetching", fraction: 2, cancellable: true, emittedAt: time))
        XCTAssertThrowsError(try PreparationStatus(stage: .completed, detail: "Done", cancellable: false, emittedAt: time))
        let revisionID = try RevisionID(rawValue: "rev-test")
        let result = try PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID)
        XCTAssertNoThrow(try PreparationStatus(stage: .completed, detail: "Done", fraction: 1, cancellable: false, terminalResult: result, emittedAt: time))
    }

    private func makeRevision(duration: Double = 10, hash: String = "sha256:" + String(repeating: "a", count: 64), bytes: Int64 = 100) throws -> AudioRevision {
        try AudioRevision(
            itemID: ItemID(rawValue: "item-test"), revisionID: RevisionID(rawValue: "rev-test"),
            durationSeconds: duration, byteCount: bytes, contentHash: hash, mediaType: "audio/mp4",
            createdAt: Timestamp(iso8601: "2026-08-17T12:00:00Z"), schemaVersion: 1
        )
    }

    private func makePlayback(
        session: String = "session-one", sequence: Int64, position: Double,
        completed: Bool = false, intent: PlaybackIntent = .progress
    ) throws -> PlaybackState {
        try PlaybackState(
            itemID: ItemID(rawValue: "item-test"), revisionID: RevisionID(rawValue: "rev-test"),
            sessionID: session, sequence: sequence, positionSeconds: position, durationSeconds: 100,
            completed: completed, intent: intent, deviceID: "device-test",
            updatedAt: Timestamp(iso8601: "2026-08-17T12:00:00Z")
        )
    }
}
