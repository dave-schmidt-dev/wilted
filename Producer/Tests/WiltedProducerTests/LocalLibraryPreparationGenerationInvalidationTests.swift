import CryptoKit
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testInvalidationUsesReadyGenerationRatherThanNewFailureAndPreservesMedia() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let when = Timestamp(Date())
        let media = url.deletingLastPathComponent().appendingPathComponent("generation.mp3")
        let bytes = Data("uncut source".utf8); try bytes.write(to: media)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: RevisionID(rawValue: "generation-ready"),
            durationSeconds: 3, byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mpeg",
            createdAt: when, schemaVersion: 3)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
            download: PodcastDownload(episodeID: episode.itemID, status: .completed,
                bytesReceived: Int64(bytes.count), expectedByteCount: Int64(bytes.count), localURL: media,
                contentHash: hash, updatedAt: when))
        let outcome = PodcastPreparationOutcome(episodeID: episode.itemID, revisionID: revision.revisionID,
            policyDigest: "policy", pipelineFingerprint: "ready-pipeline", semanticVersion: "v1", producedAt: when)
        try await store.saveReadyRevision(revision, mediaURL: media,
            transcript: Transcript(itemID: episode.itemID, revisionID: revision.revisionID,
                availability: .available, text: "Unchanged.", updatedAt: when), outcome: outcome)
        let request = PodcastPreparationPipeline.requestID(for: episode.itemID)
        for sequence in 1...2 {
            let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation,
                subjectID: episode.itemID.rawValue, requestSequence: sequence, to: .running, at: when)
            let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
                "fingerprint": sequence == 1 ? "ready-pipeline" : "new-failure-pipeline",
                "sourceRevisionID": revision.revisionID.rawValue, "sourceHash": hash
            ])
            let terminal = sequence == 1
                ? try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID)
                : try PreparationTerminalResult(outcome: .failed,
                    error: ProducerError(code: .failed, message: "failed", retryable: true))
            let status = try PreparationStatus(stage: sequence == 1 ? .completed : .failed,
                detail: "terminal", cancellable: false, terminalResult: terminal, emittedAt: when,
                evidence: evidence, attempt: attempt)
            try await store.record(preparation: .init(id: request + "|" + attempt.key + "|terminal",
                itemID: episode.itemID, requestID: request, status: status))
        }
        let failureOnly = PodcastPreparationInvalidationRule(id: "failure-only", consequence: .forceRedownload,
            applies: { $0.pipelineFingerprint == "new-failure-pipeline" })
        let untouched = try await store.invalidateStalePodcastPreparations(currentFingerprint: "current", rules: [failureOnly])
        XCTAssertEqual(untouched, PodcastPreparationInvalidationResult())
        let readyRule = PodcastPreparationInvalidationRule(id: "ready-rule", consequence: .resetPreparation,
            applies: { $0.pipelineFingerprint == "ready-pipeline" })
        let reset = try await store.invalidateStalePodcastPreparations(currentFingerprint: "current", rules: [readyRule])
        XCTAssertEqual(reset.resetEpisodeIDs, [episode.itemID])
        XCTAssertTrue(reset.forcedRedownloadEpisodeIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: media), bytes)
        let ready = try await store.readyRevision(for: episode.itemID)
        XCTAssertEqual(ready?.revisionID, revision.revisionID)
    }
}

extension LocalLibraryStoreTests {
    func testNewestInFlightGenerationWithoutOutcomeCannotBeCondemnedByOlderFailure() async throws {
        for recoveredSameSequence in [false, true] {
            let url = makeURL("newest-inflight-\(recoveredSameSequence)")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try LocalLibraryStore(url: url)
            let (_, episode) = try podcastValues()
            let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            let media = url.deletingLastPathComponent().appendingPathComponent("uncut.mp3")
            let bytes = Data("current uncut source".utf8); try bytes.write(to: media)
            let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let revision = try AudioRevision(itemID: episode.itemID, revisionID: RevisionID(rawValue: "inflight-source"),
                durationSeconds: 3, byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mpeg",
                createdAt: when, schemaVersion: 3)
            try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
                download: PodcastDownload(episodeID: episode.itemID, status: .completed,
                    bytesReceived: Int64(bytes.count), expectedByteCount: Int64(bytes.count), localURL: media,
                    contentHash: hash, updatedAt: when))
            let request = PodcastPreparationPipeline.requestID(for: episode.itemID)
            var ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
                requestSequence: 1, to: .running, at: when)
            let old = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let oldEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                fields: ["fingerprint": "old", "sourceRevisionID": "old-source", "sourceHash": hash])
            let oldFailure = try PreparationStatus(stage: .failed, detail: "old failure", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .failed,
                    error: ProducerError(code: .failed, message: "failed", retryable: true)),
                emittedAt: Timestamp(when.date.addingTimeInterval(100)), evidence: oldEvidence, attempt: old)
            try await store.record(preparation: .init(id: request + "|" + old.key + "|terminal",
                itemID: episode.itemID, requestID: request, status: oldFailure))
            if recoveredSameSequence {
                ticket.attemptCount += 1
                ticket = try await store.upsertWorkTicket(ticket)
            } else {
                ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
                    requestSequence: 2, to: .running, at: when)
            }
            let current = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let currentEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                fields: ["fingerprint": "current", "sourceRevisionID": revision.revisionID.rawValue, "sourceHash": hash])
            let active = try PreparationStatus(stage: .extracting, detail: "current work", cancellable: true,
                emittedAt: when, evidence: currentEvidence, attempt: current)
            try await store.record(preparation: .init(id: request + "|" + current.key + "|extracting#1",
                itemID: episode.itemID, requestID: request, status: active))
            let before = try await store.preparationJournal(for: request)
            let blanket = PodcastPreparationInvalidationRule(id: "old-drift", consequence: .forceRedownload, applies: { _ in true })
            for _ in 0..<3 {
                let result = try await store.invalidateStalePodcastPreparations(currentFingerprint: "current", rules: [blanket])
                XCTAssertEqual(result, PodcastPreparationInvalidationResult())
            }
            let after = try await store.preparationJournal(for: request)
            XCTAssertEqual(after, before)
            let outcome = try await store.preparationOutcome(for: episode.itemID, revisionID: revision.revisionID)
            XCTAssertNil(outcome)
            XCTAssertEqual(try Data(contentsOf: media), bytes)
        }
    }
}

extension LocalLibraryStoreTests {
    func testLegacyFailedTerminalCanResetOnlyItsExactlyProvenOriginalSourceWithoutPreparedOutcome() async throws {
        for exactSource in [true, false] {
            let url = makeURL("legacy-original-source-\(exactSource)")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try LocalLibraryStore(url: url)
            let (_, episode) = try podcastValues()
            let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            let media = url.deletingLastPathComponent().appendingPathComponent("legacy-original.mp3")
            let bytes = Data("unchanged original download".utf8); try bytes.write(to: media)
            let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let revision = try AudioRevision(itemID: episode.itemID, revisionID: RevisionID(rawValue: "legacy-original"),
                durationSeconds: 3, byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mpeg",
                createdAt: when, schemaVersion: 3)
            try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
                download: PodcastDownload(episodeID: episode.itemID, status: .completed,
                    bytesReceived: Int64(bytes.count), expectedByteCount: Int64(bytes.count), localURL: media,
                    contentHash: hash, updatedAt: when))
            let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
            let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                fields: ["fingerprint": "old", "sourceHash": hash,
                         "sourceRevisionID": exactSource ? revision.revisionID.rawValue : "different-source"])
            let failed = try PreparationStatus(stage: .failed, detail: "legacy failure", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .failed,
                    error: ProducerError(code: .failed, message: "failed", retryable: true)),
                emittedAt: when, evidence: evidence)
            try await store.record(preparation: .init(id: requestID + "|terminal", itemID: episode.itemID,
                requestID: requestID, status: failed))
            let displayBefore = try await store.currentPreparationStatuses(for: [episode.itemID])
            XCTAssertTrue(displayBefore.isEmpty, "Legacy source proof never acknowledges a publication generation")
            let rule = PodcastPreparationInvalidationRule(id: "legacy-failed-source", consequence: .resetPreparation,
                applies: { _ in true })
            let result = try await store.invalidateStalePodcastPreparations(currentFingerprint: "current", rules: [rule])
            XCTAssertEqual(result.resetEpisodeIDs, exactSource ? [episode.itemID] : [])
            XCTAssertEqual(result.forcedRedownloadEpisodeIDs, exactSource ? [] : [episode.itemID])
            let outcome = try await store.preparationOutcome(for: episode.itemID, revisionID: revision.revisionID)
            XCTAssertNil(outcome)
            let retained = try await store.readyRevision(for: episode.itemID)
            XCTAssertEqual(retained?.revisionID, revision.revisionID)
            XCTAssertEqual(try Data(contentsOf: media), bytes)
        }
    }
}
