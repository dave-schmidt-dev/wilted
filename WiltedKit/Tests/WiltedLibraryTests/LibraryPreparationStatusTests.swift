import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// The display-only V1 preparation contract. A malformed or unsupported status must never
/// poison the entry that carries it, and the field must never reach media or command authority.
final class LibraryPreparationStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func revision(_ raw: String) -> RevisionID { try! RevisionID(rawValue: raw) }

    private func status(
        version: Int = 1,
        attemptID: String = "attempt-1",
        state: LibraryPreparationStatus.State = .active,
        stage: String = "cutting",
        detail: String = "Removing advertisements",
        fraction: Double? = 0.5,
        updatedAt: Date? = nil,
        revisionID: RevisionID? = nil
    ) throws -> LibraryPreparationStatus {
        try LibraryPreparationStatus(
            version: version, attemptID: attemptID, state: state, stage: stage, detail: detail,
            fraction: fraction, updatedAt: updatedAt ?? now, revisionID: revisionID
        )
    }

    private func entry(
        status: LibraryPreparationStatus? = nil, removal: LibraryRemoval = .none
    ) throws -> LibraryEntry {
        try LibraryEntry(
            id: id("ep-1"), kind: .podcastEpisode, sourceID: id("feed-1"), title: "Title",
            summary: "Summary", publishedAt: now, durationSeconds: 1800, artworkRef: "art",
            removal: removal, preparationStatus: status
        )
    }

    private func object(_ entry: LibraryEntry) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    }

    private func statusObject(_ value: LibraryPreparationStatus) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> LibraryEntry {
        try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Decode compatibility

    func testMissingPreparationStatusDecodesEntryWithAllOriginalFields() throws {
        let raw = try entry(status: nil)
        var object = try object(raw)
        XCTAssertNil(object["preparationStatus"], "nil is omitted from the wire")
        object.removeValue(forKey: "preparationStatus")
        let decoded = try decode(object)
        XCTAssertEqual(decoded, raw)
        XCTAssertNil(decoded.preparationStatus)
        XCTAssertEqual(decoded.title, "Title")
        XCTAssertEqual(decoded.summary, "Summary")
        XCTAssertEqual(decoded.durationSeconds, 1800)
        XCTAssertEqual(decoded.artworkRef, "art")
        XCTAssertEqual(decoded.payload, raw.payload)
    }

    func testUnsupportedMalformedAndOversizedStatusDecodeAsAbsentWhileEntrySurvives() throws {
        let base = try status()
        let valid = try statusObject(base)
        var variants: [[String: Any]] = []
        var unsupportedVersion = valid
        unsupportedVersion["version"] = 2
        var unknownState = valid
        unknownState["state"] = "running"
        var missingAttempt = valid
        missingAttempt.removeValue(forKey: "attemptID")
        var emptyAttempt = valid
        emptyAttempt["attemptID"] = ""
        var oversizedAttempt = valid
        oversizedAttempt["attemptID"] = String(repeating: "a", count: 129)
        var oversizedStage = valid
        oversizedStage["stage"] = String(repeating: "s", count: 65)
        var oversizedDetail = valid
        oversizedDetail["detail"] = String(repeating: "d", count: 241)
        var wrongTypeVersion = valid
        wrongTypeVersion["version"] = "1"
        var wrongTypeDate = valid
        wrongTypeDate["updatedAt"] = "soon"
        var wrongTypeState = valid
        wrongTypeState["state"] = 7
        var wrongTypeRevision = valid
        wrongTypeRevision["revisionID"] = 42
        variants += [
            unsupportedVersion, unknownState, missingAttempt, emptyAttempt, oversizedAttempt,
            oversizedStage, oversizedDetail, wrongTypeVersion, wrongTypeDate, wrongTypeState, wrongTypeRevision,
        ]

        let expected = try entry(status: nil)
        for variant in variants {
            var object = try object(try entry(status: base))
            object["preparationStatus"] = variant
            let decoded = try decode(object)
            XCTAssertNil(decoded.preparationStatus, "variant should decode absent: \(variant)")
            XCTAssertEqual(decoded, expected, "entry survives absent status: \(variant)")
        }
    }

    func testNumericFractionOutsideRangeBecomesNilAndWrongTypeDropsStatus() throws {
        let expected = try entry(status: nil)
        for raw in [2.0, -0.5] as [Double] {
            let decoded = try decode(withFraction: raw)
            XCTAssertEqual(decoded.preparationStatus?.fraction, nil)
            XCTAssertEqual(decoded.preparationStatus, Optional(try self.status(fraction: nil)))
            XCTAssertEqual(decoded.title, expected.title)
        }
        let wrongType = try decode(withFractionJSON: "half")
        XCTAssertNil(wrongType.preparationStatus?.fraction)
        XCTAssertNil(wrongType.preparationStatus, "a wrong-typed fraction drops only the malformed status")
        XCTAssertEqual(wrongType, expected)
        XCTAssertEqual(try decode(withFraction: 0.25).preparationStatus?.fraction, 0.25)
        XCTAssertEqual(try decode(withFraction: 0).preparationStatus?.fraction, 0)
        XCTAssertEqual(try decode(withFraction: 1).preparationStatus?.fraction, 1)
    }

    func testEmptyStageAndDetailAndUnknownBoundedStageRoundTripGenerically() throws {
        for stage in ["", "totally-unknown-stage"] {
            let value = try status(stage: stage, detail: "")
            let decoded = try JSONDecoder().decode(
                LibraryPreparationStatus.self, from: JSONEncoder().encode(value)
            )
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(decoded.stage, stage)
            XCTAssertEqual(decoded.detail, "")
        }
    }

    func testRoundTripPreservesEveryStatusField() throws {
        let value = try status(
            state: .failed, stage: "assembling", detail: "Render failed", fraction: 0.75,
            revisionID: revision("rev-9")
        )
        let decoded = try JSONDecoder().decode(
            LibraryPreparationStatus.self, from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.attemptID, "attempt-1")
        XCTAssertEqual(decoded.state, .failed)
        XCTAssertEqual(decoded.fraction, 0.75)
        XCTAssertEqual(decoded.updatedAt, now)
        XCTAssertEqual(decoded.revisionID, revision("rev-9"))
    }

    // MARK: Construction bounds

    func testInitRejectsUnsupportedVersionEmptyAttemptAndOversizedMetadata() throws {
        XCTAssertThrowsError(try status(version: 2))
        XCTAssertThrowsError(try status(attemptID: ""))
        XCTAssertThrowsError(try status(attemptID: String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try status(stage: String(repeating: "s", count: 65)))
        XCTAssertThrowsError(try status(detail: String(repeating: "d", count: 241)))
        XCTAssertThrowsError(try status(updatedAt: Date(timeIntervalSince1970: .infinity)))
        XCTAssertNoThrow(try status(attemptID: String(repeating: "a", count: 128)))
        XCTAssertNoThrow(try status(stage: String(repeating: "s", count: 64)))
        XCTAssertNoThrow(try status(detail: String(repeating: "d", count: 240)))
    }

    // MARK: Copies and removal

    func testCopyAndRemovalHelpersPreserveProducerField() throws {
        let value = try status(state: .queued, revisionID: revision("rev-2"))
        let source = try entry(status: value)
        XCTAssertEqual(try source.with(removal: .retired).preparationStatus, value)
        XCTAssertEqual(try source.with(removal: .retired, removedAt: now).preparationStatus, value)
        XCTAssertEqual(try source.applyingRemoval(.dismissed).preparationStatus, value)
        XCTAssertEqual(try source.applyingRemoval(.none).preparationStatus, value)
        let podcast = try LibraryEntry.podcastEpisode(
            id: id("ep-1"), sourceID: id("feed-1"), title: "Title", summary: "Summary",
            publishedAt: now, preparationStatus: value,
            payload: PodcastEpisodePayload(enclosureURL: try XCTUnwrap(URL(string: "https://example.test/a.mp3")))
        )
        XCTAssertEqual(podcast.preparationStatus, value)
    }

    // MARK: Display-only isolation

    /// Guard the package authority paths themselves, rather than comparing test
    /// helpers that manufacture equal offers from the same entry ID.
    func testPreparationStatusIsNotConsumedByMediaOrCommandAuthority() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["LibraryMedia.swift", "MediaFetcher.swift", "MediaCacheAdmission.swift", "LibraryIntent.swift", "TransportGate.swift"] {
            let url = package.appendingPathComponent("Sources/WiltedLibrary/" + file)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("preparationStatus"), "display status must not enter authority: \(file)")
        }
    }

    func testEveryStateRoundTripsWithRevisionIDAbsent() throws {
        for state: LibraryPreparationStatus.State in [.queued, .active, .failed, .cancelled] {
            let value = try status(state: state, revisionID: nil)
            let data = try JSONEncoder().encode(value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["revisionID"])
            let decoded = try JSONDecoder().decode(LibraryPreparationStatus.self, from: data)
            XCTAssertEqual(decoded, value)
            XCTAssertNil(decoded.revisionID)
            XCTAssertEqual(try decode(try self.object(entry(status: value))).preparationStatus, value)
        }
    }

    private func decode(withFraction value: Double) throws -> LibraryEntry {
        try decode(withFractionJSON: value)
    }

    private func decode(withFractionJSON value: Any) throws -> LibraryEntry {
        var object = try object(try entry(status: try status()))
        var statusJSON = try XCTUnwrap(object["preparationStatus"] as? [String: Any])
        statusJSON["fraction"] = value
        object["preparationStatus"] = statusJSON
        return try decode(object)
    }
}
