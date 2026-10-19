import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    private struct PreparationHistoryFixture {
        let store: LocalLibraryStore
        let url: URL
        let itemID: ItemID
        let requestID: String
        let revision: AudioRevision
        let mediaURL: URL
        let bytes: Data
        let hash: String
        let base: Date
    }

    private func makePreparationHistoryDownload(
        _ name: String, revisionID: String = "history-ready"
    ) async throws -> PreparationHistoryFixture {
        let url = makeURL(name)
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("history-source.mp3")
        let bytes = Data("uncut source".utf8)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: try RevisionID(rawValue: revisionID),
            durationSeconds: 3, byteCount: Int64(bytes.count), contentHash: hash,
            mediaType: "audio/mpeg", createdAt: Timestamp(base), schemaVersion: 3)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: episode.itemID, status: .completed,
                bytesReceived: Int64(bytes.count), expectedByteCount: Int64(bytes.count),
                localURL: mediaURL, contentHash: hash, updatedAt: Timestamp(base)))
        return PreparationHistoryFixture(store: store, url: url, itemID: episode.itemID,
            requestID: PodcastPreparationPipeline.requestID(for: episode.itemID), revision: revision,
            mediaURL: mediaURL, bytes: bytes, hash: hash, base: base)
    }

    private func makePreparationHistoryStore(
        _ name: String, fingerprint: String = "ready-pipeline", producedAtOffset: TimeInterval = 1
    ) async throws -> PreparationHistoryFixture {
        let fixture = try await makePreparationHistoryDownload(name)
        try await fixture.store.saveReadyRevision(fixture.revision, mediaURL: fixture.mediaURL,
            transcript: Transcript(itemID: fixture.itemID, revisionID: fixture.revision.revisionID,
                availability: .available, text: "Unchanged.", updatedAt: Timestamp(fixture.base)),
            outcome: PodcastPreparationOutcome(episodeID: fixture.itemID,
                revisionID: fixture.revision.revisionID, policyDigest: "policy",
                pipelineFingerprint: fingerprint, semanticVersion: "v1",
                producedAt: Timestamp(fixture.base.addingTimeInterval(producedAtOffset))))
        return fixture
    }

    private func insertPreparation(
        _ context: ModelContext, id: String, itemID: ItemID, requestID: String,
        stage: PreparationStage, at date: Date, attempt: PreparationAttemptIdentity?,
        evidence: PreparationEvidence? = nil, terminal: PreparationTerminalResult? = nil
    ) throws {
        let status = try PreparationStatus(stage: stage, detail: "history \(id)", cancellable: terminal == nil,
            terminalResult: terminal, emittedAt: Timestamp(date), evidence: evidence, attempt: attempt)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: id, itemID: itemID, requestID: requestID, status: status)))
    }

    private func preparationHistoryRowCount(
        in container: ModelContainer, requestID: String
    ) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID }))
    }

    private func makeBuriedPreparationHistory(
        depth: Int, name: String
    ) async throws -> PreparationHistoryFixture {
        let fixture = try await makePreparationHistoryStore(name)
        let context = ModelContext(fixture.store.container)
        let ready = try PreparationAttemptIdentity(requestSequence: 1, attemptCount: 1)
        let readyEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "ready-pipeline", "sourceRevisionID": fixture.revision.revisionID.rawValue,
            "sourceHash": fixture.hash
        ])
        let readyPrefix = fixture.requestID + "|" + ready.key + "|"
        try insertPreparation(context, id: readyPrefix + "pipeline.start#1", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .preparing, at: fixture.base, attempt: ready,
            evidence: readyEvidence)
        try insertPreparation(context, id: readyPrefix + "terminal", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .completed, at: fixture.base.addingTimeInterval(2),
            attempt: ready, terminal: try PreparationTerminalResult(
                outcome: .succeeded, revisionID: fixture.revision.revisionID))
        let failureEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "new-failure-pipeline",
            "sourceRevisionID": fixture.revision.revisionID.rawValue, "sourceHash": fixture.hash
        ])
        let failure = try PreparationTerminalResult(outcome: .failed,
            error: try ProducerError(code: .failed, message: "failed", retryable: true))
        for sequence in 2...(depth + 1) {
            let attempt = try PreparationAttemptIdentity(requestSequence: sequence, attemptCount: 1)
            let prefix = fixture.requestID + "|" + attempt.key + "|"
            let at = fixture.base.addingTimeInterval(10 * Double(sequence))
            try insertPreparation(context, id: prefix + "pipeline.start#1", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .preparing, at: at, attempt: attempt,
                evidence: failureEvidence)
            try insertPreparation(context, id: prefix + "extracting#2", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .extracting, at: at.addingTimeInterval(1),
                attempt: attempt)
            try insertPreparation(context, id: prefix + "terminal", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .failed, at: at.addingTimeInterval(2),
                attempt: attempt, terminal: failure)
        }
        try context.save()
        _ = try await fixture.store.readmitWorkTicket(kind: .podcastPreparation,
            subjectID: fixture.itemID.rawValue, requestSequence: depth + 1, to: .running,
            at: Timestamp(fixture.base.addingTimeInterval(10 * Double(depth + 1))))
        return fixture
    }

    func testPreparationHistoryFindsReadyProofBuriedUnderRetainedFailures() async throws {
        let fixture = try await makeBuriedPreparationHistory(depth: 100, name: "buried-ready")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let failureOnly = PodcastPreparationInvalidationRule(id: "failure-only",
            consequence: .forceRedownload, applies: { $0.pipelineFingerprint == "new-failure-pipeline" })
        let untouched = try await fixture.store.invalidateStalePodcastPreparations(
            currentFingerprint: "current", rules: [failureOnly])
        XCTAssertEqual(untouched, PodcastPreparationInvalidationResult())
        let readyRule = PodcastPreparationInvalidationRule(id: "ready-rule",
            consequence: .resetPreparation, applies: { $0.pipelineFingerprint == "ready-pipeline" })
        let reset = try await fixture.store.invalidateStalePodcastPreparations(
            currentFingerprint: "current", rules: [readyRule])
        XCTAssertEqual(reset.resetEpisodeIDs, [fixture.itemID])
        XCTAssertTrue(reset.forcedRedownloadEpisodeIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.mediaURL), fixture.bytes)
        let download = try await fixture.store.download(for: fixture.itemID)
        XCTAssertEqual(download?.contentHash, fixture.hash)
        XCTAssertEqual(download?.localURL, fixture.mediaURL)
        let ready = try await fixture.store.readyRevision(for: fixture.itemID)
        XCTAssertEqual(ready?.revisionID, fixture.revision.revisionID)
        XCTAssertEqual(try preparationHistoryRowCount(
            in: fixture.store.container, requestID: fixture.requestID), 300)
    }

    func testPreparationHistoryReadsTheWholeReadyGenerationBeyondTheOldWindow() async throws {
        let fixture = try await makePreparationHistoryStore(
            "whole-ready", fingerprint: "current", producedAtOffset: 350)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let context = ModelContext(fixture.store.container)
        let attempt = try PreparationAttemptIdentity(requestSequence: 1, attemptCount: 1)
        let prefix = fixture.requestID + "|" + attempt.key + "|"
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "current", "sourceRevisionID": fixture.revision.revisionID.rawValue,
            "sourceHash": fixture.hash
        ])
        try insertPreparation(context, id: prefix + "pipeline.start#1", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .preparing, at: fixture.base, attempt: attempt,
            evidence: evidence)
        for ordinal in 2...301 {
            try insertPreparation(context, id: prefix + "extracting#\(ordinal)", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .extracting,
                at: fixture.base.addingTimeInterval(Double(ordinal - 1)), attempt: attempt)
        }
        try insertPreparation(context, id: prefix + "terminal", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .completed,
            at: fixture.base.addingTimeInterval(400), attempt: attempt,
            terminal: try PreparationTerminalResult(
                outcome: .succeeded, revisionID: fixture.revision.revisionID))
        try context.save()
        let rule = PodcastPreparationInvalidationRule(id: "reset-current",
            consequence: .resetPreparation, applies: { _ in true })
        let result = try await fixture.store.invalidateStalePodcastPreparations(
            currentFingerprint: "current", rules: [rule])
        XCTAssertEqual(result, PodcastPreparationInvalidationResult())
        let outcome = try await fixture.store.preparationOutcome(
            for: fixture.itemID, revisionID: fixture.revision.revisionID)
        XCTAssertEqual(outcome?.eligibility, .current)
        XCTAssertEqual(try preparationHistoryRowCount(
            in: fixture.store.container, requestID: fixture.requestID), 302)
    }

    func testPreparationHistorySelectsNewestGenerationDeterministicallyWithTiedTimestamps() async throws {
        let fixture = try await makePreparationHistoryDownload("tied-newest")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let context = ModelContext(fixture.store.container)
        let oldEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "old", "sourceRevisionID": "old-source", "sourceHash": fixture.hash
        ])
        let currentEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "current", "sourceRevisionID": fixture.revision.revisionID.rawValue,
            "sourceHash": fixture.hash
        ])
        let failure = try PreparationTerminalResult(outcome: .failed,
            error: try ProducerError(code: .failed, message: "failed", retryable: true))
        for sequence in 1...100 {
            let attempt = try PreparationAttemptIdentity(requestSequence: sequence, attemptCount: 1)
            let prefix = fixture.requestID + "|" + attempt.key + "|"
            try insertPreparation(context, id: prefix + "pipeline.start#1", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .preparing, at: fixture.base, attempt: attempt,
                evidence: sequence == 100 ? currentEvidence : oldEvidence)
            try insertPreparation(context, id: prefix + "extracting#2", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .extracting, at: fixture.base, attempt: attempt)
            if sequence < 100 {
                try insertPreparation(context, id: prefix + "terminal", itemID: fixture.itemID,
                    requestID: fixture.requestID, stage: .failed, at: fixture.base,
                    attempt: attempt, terminal: failure)
            }
        }
        try context.save()
        _ = try await fixture.store.readmitWorkTicket(kind: .podcastPreparation,
            subjectID: fixture.itemID.rawValue, requestSequence: 100, to: .running,
            at: Timestamp(fixture.base))
        let blanket = PodcastPreparationInvalidationRule(id: "blanket",
            consequence: .forceRedownload, applies: { _ in true })
        for _ in 0..<3 {
            let result = try await fixture.store.invalidateStalePodcastPreparations(
                currentFingerprint: "current", rules: [blanket])
            XCTAssertEqual(result, PodcastPreparationInvalidationResult())
            XCTAssertEqual(try preparationHistoryRowCount(
                in: fixture.store.container, requestID: fixture.requestID), 299)
            XCTAssertEqual(try Data(contentsOf: fixture.mediaURL), fixture.bytes)
        }
    }

    func testPreparationHistoryMaintenanceReadsDoNotGrowWithRetainedDepth() async throws {
        let shallow = try await makeBuriedPreparationHistory(depth: 100, name: "depth-100")
        let deep = try await makeBuriedPreparationHistory(depth: 200, name: "depth-200")
        defer {
            try? FileManager.default.removeItem(at: shallow.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: deep.url.deletingLastPathComponent())
        }
        let shallowBefore = await shallow.store.preparationMaintenanceRowsRead
        _ = try await shallow.store.invalidateStalePodcastPreparations(
            currentFingerprint: "current", rules: [])
        let shallowAfter = await shallow.store.preparationMaintenanceRowsRead
        let deepBefore = await deep.store.preparationMaintenanceRowsRead
        _ = try await deep.store.invalidateStalePodcastPreparations(
            currentFingerprint: "current", rules: [])
        let deepAfter = await deep.store.preparationMaintenanceRowsRead
        XCTAssertEqual(shallowAfter - shallowBefore, deepAfter - deepBefore)
        XCTAssertLessThan(shallowAfter - shallowBefore, 3 * 100)
        let requiresBefore = await shallow.store.preparationMaintenanceRowsRead
        let requires = try await shallow.store.requiresForcedRedownload(for: shallow.itemID)
        XCTAssertFalse(requires)
        let requiresAfter = await shallow.store.preparationMaintenanceRowsRead
        XCTAssertLessThanOrEqual(requiresAfter - requiresBefore, 1)
    }
}
