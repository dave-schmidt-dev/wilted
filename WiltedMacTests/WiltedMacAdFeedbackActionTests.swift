import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// The external action can touch only a current exact report and retains its replay receipt.
@MainActor
final class WiltedMacAdFeedbackActionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testActionAndReceiptLandTogetherAndReplayIsAnUnchangedNoOp() async throws {
        let root = wiltedTemporaryDirectory("handled-action")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(entry)

        let (envelope, requestURL) = try writeRequest(payload: payload([entry]), to: actions)
        let first = await inbox.processPendingHandledActions(at: now)
        XCTAssertNil(first.failure)
        XCTAssertEqual(first.receipts.map(\.outcome), [.applied])
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))

        let savedEntries = await inbox.all()
        let saved = try XCTUnwrap(savedEntries.first)
        XCTAssertEqual(saved.handledAt, now)
        XCTAssertTrue(saved.counts)
        XCTAssertEqual(saved.effectiveLabel, .mustCut)

        let raw = try Data(contentsOf: store)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        let receipts = try XCTUnwrap(object["handledActions"] as? [[String: Any]])
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?["actionID"] as? String, envelope.actionID)
        XCTAssertEqual(receipts.first?["candidateCommit"] as? String, String(repeating: "a", count: 40))

        let replayURL = actions.appendingPathComponent("\(envelope.actionID).json")
        try encodedEnvelope(envelope).write(to: replayURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replayURL.path)
        let replayed = await inbox.processPendingHandledActions(at: now.addingTimeInterval(60))
        XCTAssertNil(replayed.failure)
        XCTAssertEqual(replayed.receipts.map(\.outcome), [.applied])
        let replayedEntries = await inbox.all()
        XCTAssertEqual(replayedEntries.first?.handledAt, now, "a replay cannot rewrite the first timestamp")
        let replayedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        XCTAssertEqual((replayedObject["handledActions"] as? [[String: Any]])?.count, 1)
    }

    func testStaleBatchRejectsAllRowsAndPreservesTheHistory() async throws {
        let root = wiltedTemporaryDirectory("handled-stale-batch")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let first = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let second = try feedback(id: "two", kind: .adHere, played: 30, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(first)
        try await inbox.add(second)
        try await inbox.review(id: "two", as: .accepted, label: .mustKeep, at: now)
        try writeRequest(payload: payload([first, second]), to: actions)

        let processed = await inbox.processPendingHandledActions(at: now.addingTimeInterval(1))
        XCTAssertNil(processed.failure)
        XCTAssertEqual(processed.receipts.map(\.outcome), [.rejectedStale])
        let saved = await inbox.all()
        XCTAssertEqual(Set(saved.map(\.id)), Set(["one", "two"]))
        XCTAssertTrue(saved.allSatisfy { $0.handledAt == nil })
        XCTAssertEqual(saved.first(where: { $0.id == "two" })?.effectiveLabel, .mustKeep)
        XCTAssertEqual(saved.first(where: { $0.id == "two" })?.reviewedAt, now)
    }

    func testDismissedOrMissingIDIsRejectedWithoutDeletingOtherReports() async throws {
        let root = wiltedTemporaryDirectory("handled-missing")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(entry)
        try await inbox.add(feedback(id: "keep", kind: .adHere, played: 10, timeline: nil))
        try await inbox.remove(id: "one")
        try writeRequest(payload: payload([entry]), to: actions)

        let processed = await inbox.processPendingHandledActions(at: now)
        XCTAssertEqual(processed.receipts.map(\.outcome), [.rejectedStale])
        let remaining = await inbox.all()
        XCTAssertEqual(remaining.map(\.id), ["keep"])
    }

    func testFailedDurableWriteLeavesRequestForRetryAndDoesNotChangeMemoryOrHistory() async throws {
        let root = wiltedTemporaryDirectory("handled-write-failure")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let seed = WiltedMacAdFeedbackInbox(fileURL: store)
        try await seed.add(entry)
        let (envelope, requestURL) = try writeRequest(payload: payload([entry]), to: actions)
        let failing = WiltedMacAdFeedbackInbox(
            fileURL: store, actionDirectory: actions,
            write: { _, _ in throw POSIXError(.ENOSPC) })

        let failed = await failing.processPendingHandledActions(at: now)
        XCTAssertNotNil(failed.failure)
        XCTAssertTrue(failed.receipts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let unchanged = await WiltedMacAdFeedbackInbox(fileURL: store).all()
        XCTAssertNil(unchanged.first?.handledAt)

        let retry = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        let succeeded = await retry.processPendingHandledActions(at: now)
        XCTAssertEqual(succeeded.receipts.map(\.actionID), [envelope.actionID])
        let retried = await retry.all()
        XCTAssertEqual(retried.first?.handledAt, now)
    }

    func testUncertainDirectorySyncKeepsTheRequestUntilReceiptIsDurable() async throws {
        let root = wiltedTemporaryDirectory("handled-uncertain-sync")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let seed = WiltedMacAdFeedbackInbox(fileURL: store)
        try await seed.add(entry)
        let (envelope, requestURL) = try writeRequest(payload: payload([entry]), to: actions)
        let uncertain = WiltedMacAdFeedbackInbox(
            fileURL: store, actionDirectory: actions,
            write: { data, url in
                try data.write(to: url, options: .atomic)
                return false
            })

        let first = await uncertain.processPendingHandledActions(at: now)
        XCTAssertNotNil(first.failure)
        XCTAssertTrue(first.receipts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let uncertainEntries = await uncertain.all()
        XCTAssertNil(uncertainEntries.first?.handledAt)

        let reopened = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        let retry = await reopened.processPendingHandledActions(at: now.addingTimeInterval(30))
        XCTAssertNil(retry.failure)
        XCTAssertEqual(retry.receipts.map(\.actionID), [envelope.actionID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        let recoveredEntries = await reopened.all()
        XCTAssertEqual(recoveredEntries.first?.handledAt, now)
    }

    func testV1InboxMigratesOnTheSameAtomicActionSave() async throws {
        let root = wiltedTemporaryDirectory("handled-v1")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "legacy", kind: .adHere, played: 25, timeline: timeline())
        let encodedEntries = try WiltedMacAdFeedbackInbox.encoder.encode([entry])
        let legacy = Data("{\"version\":1,\"entries\":\(String(decoding: encodedEntries, as: UTF8.self))}".utf8)
        try legacy.write(to: store)
        try writeRequest(payload: payload([entry]), to: actions)
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)

        let result = await inbox.processPendingHandledActions(at: now)
        XCTAssertEqual(result.receipts.map(\.outcome), [.applied])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["handledActions"] as? [[String: Any]])?.count, 1)
    }

    func testV1ReaderQuarantinesV2ReceiptsWithoutRewritingThem() async throws {
        let root = wiltedTemporaryDirectory("handled-downgrade")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "legacy", kind: .adHere, played: 25, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(entry)
        try writeRequest(payload: payload([entry]), to: actions)
        let result = await inbox.processPendingHandledActions(at: now)
        XCTAssertEqual(result.receipts.map(\.outcome), [.applied])
        let v2Bytes = try Data(contentsOf: store)

        // The prior app's Codable shape ignores new keys, then its version-1 guard
        // moves the unsupported file aside before it can write a version-1 store.
        struct LegacyStored: Decodable {
            let version: Int
            let entries: [WiltedMacAdFeedbackEntry]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(LegacyStored.self, from: v2Bytes)
        XCTAssertEqual(legacy.version, 2)
        XCTAssertEqual(legacy.entries.count, 1)
        let aside = store.appendingPathExtension("unreadable")
        try FileManager.default.moveItem(at: store, to: aside)
        XCTAssertEqual(try Data(contentsOf: aside), v2Bytes)
        let quarantined = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: aside)) as? [String: Any])
        XCTAssertEqual((quarantined["handledActions"] as? [[String: Any]])?.count, 1)
    }

    func testUpgradeFusesQuarantinedReceiptsWithNewV1Feedback() async throws {
        let root = wiltedTemporaryDirectory("handled-upgrade-fusion")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let old = try feedback(id: "old", kind: .adHere, played: 25, timeline: timeline())
        let firstApp = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await firstApp.add(old)
        try writeRequest(payload: payload([old]), to: actions)
        _ = await firstApp.processPendingHandledActions(at: now)
        let v2Bytes = try Data(contentsOf: store)

        // A v1 build moves unsupported state aside, then starts a fresh v1 inbox.
        let archive = store.appendingPathExtension("unreadable")
        try FileManager.default.moveItem(at: store, to: archive)
        let newEntry = try feedback(id: "new", kind: .adHere, played: 27, timeline: timeline())
        let oldWriterBytes = try WiltedMacAdFeedbackInbox.encoder.encode(
            VersionOneStore(version: 1, entries: [newEntry]))
        try oldWriterBytes.write(to: store, options: .atomic)
        let oldLayout = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        XCTAssertEqual(oldLayout["version"] as? Int, 1)

        let upgraded = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        let recovered = await upgraded.all()
        XCTAssertEqual(Set(recovered.map(\.id)), Set(["old", "new"]))
        XCTAssertEqual(recovered.first(where: { $0.id == "old" })?.handledAt, now)
        try await upgraded.add(try feedback(
            id: "later", kind: .adHere, played: 29, timeline: timeline()))

        let fused = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        XCTAssertEqual(fused["version"] as? Int, 2)
        XCTAssertEqual((fused["entries"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((fused["handledActions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try Data(contentsOf: archive), v2Bytes)
    }

    func testHostedControllerDoesNotDrainAnOwnerQueue() async throws {
        let root = wiltedTemporaryDirectory("handled-hosted-gate")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(entry)
        let (_, requestURL) = try writeRequest(payload: payload([entry]), to: actions)
        let hosted = WiltedMacAdFeedbackController(inbox: inbox, allowsExternalActions: false)

        await hosted.processPendingHandledActions()

        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let unchanged = await inbox.all()
        XCTAssertNil(unchanged.first?.handledAt)
    }

    func testInvalidPointProofAndChangedPayloadCannotReachTheStore() async throws {
        let root = wiltedTemporaryDirectory("handled-invalid-proof")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "one", kind: .adHere, played: 25, timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await inbox.add(entry)
        let invalid = payload([entry], reportedPositionWasCut: false)
        let (envelope, url) = try writeRequest(payload: invalid, to: actions)
        let result = await inbox.processPendingHandledActions(at: now)
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(result.receipts.isEmpty)
        let unchanged = await inbox.all()
        XCTAssertNil(unchanged.first?.handledAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("invalid").path))

        let changed = WiltedMacAdFeedbackActionEnvelope(
            actionID: envelope.actionID, payloadSHA256: envelope.payloadSHA256,
            payload: try JSONEncoder().encode(payload([entry])))
        let replayURL = actions.appendingPathComponent("\(envelope.actionID).json")
        try encodedEnvelope(changed).write(to: replayURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replayURL.path)
        let conflict = await inbox.processPendingHandledActions(at: now)
        XCTAssertNotNil(conflict.failure)
        let stillUnchanged = await inbox.all()
        XCTAssertNil(stillUnchanged.first?.handledAt)
    }

    func feedback(
        id: String, kind: AdFeedbackKind, played: Double,
        timeline: PreparationStatus.PreparationTimeline?
    ) throws -> WiltedMacAdFeedbackEntry {
        WiltedMacAdFeedbackEntry.make(
            id: id, kind: kind, itemID: try ItemID(rawValue: "item-verified"),
            revisionID: try RevisionID(rawValue: "revision-verified"), playedSeconds: played,
            timeline: timeline, engineVersion: "engine-1", pipelineFingerprint: "fingerprint-1",
            createdAt: now, deviceID: "mac-test", source: .mac, showTitle: "Synthetic", episodeTitle: "Fixture")
    }

    func payload(
        _ entries: [WiltedMacAdFeedbackEntry], reportedPositionWasCut: Bool = true
    ) -> WiltedMacAdFeedbackActionPayload {
        let candidate = String(repeating: "a", count: 40)
        let report = String(repeating: "b", count: 64)
        let replayForEntry: (WiltedMacAdFeedbackEntry) -> WiltedMacAdFeedbackActionPayload.Replay = { entry in
            let isGoodCut = entry.kind == .goodCut
            let isNotAnAd = entry.kind == .notAnAd
            let evidence = WiltedMacAdFeedbackActionPayload.Replay.LocalEvidence(
                label: isNotAnAd ? "must-keep" : "must-cut",
                startSeconds: isNotAnAd ? 0 : 20, endSeconds: isNotAnAd ? 100 : 40,
                reportedPositionSeconds: entry.originalSeconds ?? 0, localVerdictPassed: true,
                reportedPositionWasCut: entry.kind == .adHere && reportedPositionWasCut,
                nearestCutFullyCut: isGoodCut ? true : (isNotAnAd ? false : nil),
                nearestCutAnyCut: isGoodCut ? true : (isNotAnAd ? false : nil))
            return WiltedMacAdFeedbackActionPayload.Replay(
                candidateCommit: candidate, reportSHA256: report, fixtureID: "fixture-id",
                replayCommand: "[\"phase2_replay_score.py\"]", passed: true, clean: true,
                skipped: false, coverageComplete: true, localEvidence: evidence)
        }
        let replay = entries.first.map(replayForEntry) ?? WiltedMacAdFeedbackActionPayload.Replay(
            candidateCommit: candidate, reportSHA256: report, fixtureID: "fixture-id",
            replayCommand: "[\"phase2_replay_score.py\"]", passed: true, clean: true,
            skipped: false, coverageComplete: true,
            localEvidence: .init(label: "must-cut", startSeconds: 20, endSeconds: 40,
                                 reportedPositionSeconds: 25, localVerdictPassed: true,
                                 reportedPositionWasCut: reportedPositionWasCut,
                                 nearestCutFullyCut: nil, nearestCutAnyCut: nil))
        return WiltedMacAdFeedbackActionPayload(
            schemaVersion: 1, candidateCommit: replay.candidateCommit, candidateBranch: "ad-tuning/test",
            intakeSnapshotSHA256: String(repeating: "c", count: 64),
            replayReportSHA256: replay.reportSHA256,
            entries: entries.map {
                .init(identity: .init($0), caseID: "verified-case",
                      sourceHash: "sha256:" + String(repeating: "d", count: 64), replay: replayForEntry($0))
            })
    }

    func timeline() throws -> PreparationStatus.PreparationTimeline {
        try PreparationStatus.PreparationTimeline(
            removed: [],
            kept: [.init(originalStartSeconds: 0, originalEndSeconds: 100, outputStartSeconds: 0)])
    }

    func writeRequest(
        payload: WiltedMacAdFeedbackActionPayload, to directory: URL
    ) throws -> (WiltedMacAdFeedbackActionEnvelope, URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let envelope = WiltedMacAdFeedbackActionEnvelope(actionID: digest, payloadSHA256: digest, payload: bytes)
        let requestURL = directory.appendingPathComponent("\(digest).json")
        try encodedEnvelope(envelope).write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        return (envelope, requestURL)
    }

    func encodedEnvelope(_ envelope: WiltedMacAdFeedbackActionEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    struct VersionOneStore: Codable {
        let version: Int
        let entries: [WiltedMacAdFeedbackEntry]
    }
}
