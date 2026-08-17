import Foundation
import CryptoKit
import XCTest
@testable import WiltedDomain

final class FixtureContractTests: XCTestCase {
    func testFixtureManifestPinsAllAuthoritativeCopies() throws {
        let directory = try fixtureDirectory()
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("FixtureManifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["manifestVersion"] as? Int, 1)
        XCTAssertEqual(manifest["hashAlgorithm"] as? String, "sha256")
        let expected = try XCTUnwrap(manifest["fixtures"] as? [String: String])
        XCTAssertEqual(expected.count, 16)
        let actualNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "FixtureManifest.json" && $0.hasSuffix(".json") }
        XCTAssertEqual(Set(actualNames), Set(expected.keys))
        for (name, expectedHash) in expected {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actualHash, expectedHash, "Fixture bytes drifted: \(name)")
        }
    }

    func testPublishDecodeFixture() throws { try evaluate("01-publish-decode") }
    func testForwardProgressFixture() throws { try evaluate("02-forward-progress") }
    func testExplicitRewindFixture() throws { try evaluate("03-explicit-rewind") }
    func testExplicitRestartFixture() throws { try evaluate("04-explicit-restart-after-completion") }
    func testStaleProgressFixture() throws { try evaluate("05-stale-progress-across-sessions") }
    func testSequenceOrderingFixture() throws { try evaluate("06-same-session-sequence-ordering") }
    func testIncompatibleRevisionFixture() throws { try evaluate("07-incompatible-revision") }
    func testRevisionSupersessionFixture() throws { try evaluate("08-revision-supersession") }
    func testDeletionSuccessFixture() throws { try evaluate("09-deletion-full-snapshot-success") }
    func testDeletionPartialFailureFixture() throws { try evaluate("10-deletion-partial-failure") }
    func testDeletionExemptionsFixture() throws { try evaluate("11-deletion-exemptions") }
    func testOfflineCacheFixture() throws { try evaluate("12-offline-cache") }
    func testDelayedDeliveryFixture() throws { try evaluate("13-delayed-delivery") }
    func testSchemaMismatchFixture() throws { try evaluate("14-schema-version-mismatch") }
    func testPreparationFailureFixture() throws { try evaluate("15-partial-preparation-failure") }
    func testTimeoutFixture() throws { try evaluate("16-timeout-terminal-error") }

    private func evaluate(_ name: String) throws {
        let directory = try fixtureDirectory()
        let data = try Data(contentsOf: directory.appendingPathComponent(name).appendingPathExtension("json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fixture["fixtureVersion"] as? Int, 1)
        XCTAssertFalse(try fixture.string("caseID").isEmpty)
        let input = try fixture.object("input")
        let expected = try fixture.object("expected")

        switch try fixture.string("operation") {
        case "publishDecode": try evaluatePublish(input, expected)
        case "playbackMerge": try evaluatePlayback(input, expected)
        case "revisionSupersession":
            XCTAssertEqual(try input.string("playingRevisionID"), try expected.string("activeRevisionID"))
            XCTAssertEqual(input["playingPositionSeconds"] as? Double, expected["activePositionSeconds"] as? Double)
            XCTAssertEqual(expected["translatedPosition"] as? Bool, false)
        case "deletionReconcile": try evaluateDeletion(input, expected)
        case "offlineCache":
            XCTAssertEqual(expected["playable"] as? Bool, input["cachedFilePresent"] as? Bool == true && input["cachedHashVerified"] as? Bool == true)
            XCTAssertEqual(expected["requiresNetwork"] as? Bool, false)
        case "delayedDelivery":
            XCTAssertEqual(expected["localPlayable"] as? Bool, input["cachedHashVerified"] as? Bool)
            XCTAssertEqual(expected["deliveryState"] as? String, input["uploadAcknowledged"] as? Bool == true ? "delivered" : "pending")
        case "schemaCompatibility":
            let accepted = try input.integer("recordSchemaVersion") <= input.integer("supportedSchemaVersion")
            XCTAssertEqual(expected["accepted"] as? Bool, accepted)
        case "preparationFailure":
            XCTAssertEqual(try expected.string("activeRevisionID"), try input.string("priorRevisionID"))
            XCTAssertEqual(expected["candidatePublished"] as? Bool, false)
            XCTAssertEqual(expected["removeCandidateTempFile"] as? Bool, input["candidateTempFilePresent"] as? Bool)
        case "timeoutTerminalError": try evaluateTimeout(input, expected)
        default: XCTFail("Unknown fixture operation")
        }
    }

    private func fixtureDirectory() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    private func evaluatePublish(_ input: [String: Any], _ expected: [String: Any]) throws {
        let article = try input.object("article")
        let revision = try input.object("revision")
        XCTAssertEqual(try article.string("itemID"), try expected.string("itemID"))
        XCTAssertEqual(try revision.string("revisionID"), try expected.string("revisionID"))
        XCTAssertEqual(expected["authorIsUnknown"] as? Bool, article["author"] is NSNull)
        XCTAssertEqual(expected["publishedTimeIsUnknown"] as? Bool, article["publishedTime"] is NSNull)
        XCTAssertEqual(try revision.string("readiness"), try expected.string("readiness"))
    }

    private func evaluatePlayback(_ input: [String: Any], _ expected: [String: Any]) throws {
        let current = try playback(input.object("current"))
        let incoming = try playback(input.object("incoming"))
        let result = mergePlayback(current: current, incoming: incoming, changeTagMatches: input["changeTagMatches"] as? Bool == true)
        XCTAssertEqual(result.decision.rawValue, try expected.string("decision"))
        XCTAssertEqual(result.winner.rawValue, try expected.string("winningState"))
        XCTAssertEqual(result.reason.rawValue, try expected.string("reason"))
    }

    private func evaluateDeletion(_ input: [String: Any], _ expected: [String: Any]) throws {
        let records = try XCTUnwrap(input["localRecords"] as? [[String: Any]])
        let seen = Set(try XCTUnwrap(input["seenRemoteItemIDs"] as? [String]))
        var deleted: [String] = []
        var retained: [String] = []
        for record in records {
            let item = try record.string("itemID")
            if input["fetchComplete"] as? Bool == true,
               try record.string("syncStatus") == "remoteAcknowledged", !seen.contains(item) {
                deleted.append(item)
            } else { retained.append(item) }
        }
        XCTAssertEqual(deleted.sorted(), try XCTUnwrap(expected["deleteItemIDs"] as? [String]).sorted())
        XCTAssertEqual(retained.sorted(), try XCTUnwrap(expected["retainItemIDs"] as? [String]).sorted())
        XCTAssertEqual(expected["mutated"] as? Bool, !deleted.isEmpty)
    }

    private func evaluateTimeout(_ input: [String: Any], _ expected: [String: Any]) throws {
        let events = try XCTUnwrap(input["events"] as? [[String: Any]])
        let terminals = events.filter { $0["kind"] as? String == "terminal" }
        XCTAssertEqual(terminals.count, expected["terminalEventCount"] as? Int)
        XCTAssertEqual(events.first?["kind"] as? String, "status")
        let terminal = try XCTUnwrap(terminals.first?["terminal"] as? [String: Any])
        XCTAssertEqual(terminal["outcome"] as? String, expected["terminalOutcome"] as? String)
        XCTAssertEqual((terminal["error"] as? [String: Any])?["code"] as? String, expected["terminalErrorCode"] as? String)
        XCTAssertEqual(expected["candidatePublished"] as? Bool, false)
        XCTAssertEqual(try expected.string("activeRevisionID"), try input.string("priorRevisionID"))
    }

    private func playback(_ object: [String: Any]) throws -> PlaybackState {
        try PlaybackState(
            itemID: ItemID(rawValue: object.string("itemID")), revisionID: RevisionID(rawValue: object.string("revisionID")),
            sessionID: object.string("sessionID"), sequence: Int64(object.integer("sequence")),
            positionSeconds: object.number("positionSeconds"), durationSeconds: object.number("durationSeconds"),
            completed: object["completed"] as? Bool == true,
            intent: XCTUnwrap(PlaybackIntent(rawValue: object.string("intent"))), deviceID: object.string("deviceID"),
            updatedAt: Timestamp(iso8601: object.string("updatedAt"))
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String { try XCTUnwrap(self[key] as? String) }
    func integer(_ key: String) throws -> Int { try XCTUnwrap(self[key] as? Int) }
    func number(_ key: String) throws -> Double {
        if let value = self[key] as? Double { return value }
        return Double(try integer(key))
    }
    func object(_ key: String) throws -> [String: Any] { try XCTUnwrap(self[key] as? [String: Any]) }
}
