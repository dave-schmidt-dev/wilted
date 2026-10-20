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
        evidence: PreparationEvidence? = nil, terminal: PreparationTerminalResult? = nil,
        timeline: PreparationStatus.PreparationTimeline? = nil
    ) throws {
        let status = try PreparationStatus(stage: stage, detail: "history \(id)", cancellable: terminal == nil,
            terminalResult: terminal, emittedAt: Timestamp(date), evidence: evidence, timeline: timeline, attempt: attempt)
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
        depth: Int, name: String, timeline: PreparationStatus.PreparationTimeline? = nil
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
                outcome: .succeeded, revisionID: fixture.revision.revisionID), timeline: timeline)
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

    func testPreparationTimelineFindsReadyProofBuriedUnderRetainedFailures() async throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [.init(originalStartSeconds: 0.5, originalEndSeconds: 1, label: "Ad", confidence: 1)],
            kept: [.init(originalStartSeconds: 0, originalEndSeconds: 0.5, outputStartSeconds: 0),
                   .init(originalStartSeconds: 1, originalEndSeconds: 3, outputStartSeconds: 0.5)])
        var rowsRead: [Int] = []
        for depth in [100, 200] {
            let fixture = try await makeBuriedPreparationHistory(
                depth: depth, name: "buried-timeline-\(depth)", timeline: timeline)
            defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
            let found = try await fixture.store.latestPreparationTimeline(
                for: fixture.itemID, revisionID: fixture.revision.revisionID)
            XCTAssertEqual(found, timeline)
            rowsRead.append(await fixture.store.preparationMaintenanceRowsRead)
            let wrong = try await fixture.store.latestPreparationTimeline(
                for: fixture.itemID, revisionID: try RevisionID(rawValue: "another-revision"))
            XCTAssertNil(wrong)
        }
        XCTAssertEqual(rowsRead[0], rowsRead[1], "materialized journal rows must not grow with retained failures")
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
        XCTAssertGreaterThanOrEqual(shallowAfter - shallowBefore, LocalLibraryStore.maintenanceDiscoveryWindow)
        XCTAssertLessThan(shallowAfter - shallowBefore, 3 * 100)
        let requiresBefore = await shallow.store.preparationMaintenanceRowsRead
        let requires = try await shallow.store.requiresForcedRedownload(for: shallow.itemID)
        XCTAssertFalse(requires)
        let requiresAfter = await shallow.store.preparationMaintenanceRowsRead
        XCTAssertLessThanOrEqual(requiresAfter - requiresBefore, 1)
    }

    func testPreparationHistoryForcedRedownloadCompletionClearsOnlyThatItemsMarkers() async throws {
        let fixture = try await makePreparationHistoryDownload("marker-completion")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let other = try ItemID(rawValue: fixture.itemID.rawValue + "b")
        let context = ModelContext(fixture.store.container)
        let markerResult = try PreparationTerminalResult(outcome: .failed,
            error: try ProducerError(code: .failed, message: "marker", retryable: true))
        for item in [fixture.itemID, other] {
            for prefix in [LocalLibraryStore.forcedRedownloadRequestPrefix, LocalLibraryStore.resetPreparationRequestPrefix] {
                try insertPreparation(context, id: prefix + item.rawValue + "|marker", itemID: item,
                    requestID: prefix + item.rawValue, stage: .failed, at: fixture.base, attempt: nil,
                    terminal: markerResult)
            }
        }
        for ordinal in 1...100 {
            try insertPreparation(context, id: fixture.requestID + "|extracting#\(ordinal)", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .extracting,
                at: fixture.base.addingTimeInterval(Double(ordinal)), attempt: nil)
        }
        try context.save()
        let before = await fixture.store.preparationMaintenanceRowsRead
        try await fixture.store.markForcedRedownloadCompleted(for: fixture.itemID, currentFingerprint: "current")
        let after = await fixture.store.preparationMaintenanceRowsRead
        // One exact forced-marker probe plus this item's two markers; no journal history.
        XCTAssertEqual(after - before, 3)
        let cleared = try await fixture.store.requiresForcedRedownload(for: fixture.itemID)
        XCTAssertFalse(cleared)
        let untouched = try await fixture.store.requiresForcedRedownload(for: other)
        XCTAssertTrue(untouched)
        let otherReset = LocalLibraryStore.resetPreparationRequestPrefix + other.rawValue
        XCTAssertEqual(try preparationHistoryRowCount(in: fixture.store.container, requestID: otherReset), 1)
        XCTAssertEqual(try preparationHistoryRowCount(
            in: fixture.store.container, requestID: fixture.requestID), 100)
    }

    func testPreparationRecoveryProjectionIsEmptyAndReadsNoRowsWithoutMarkers() async throws {
        let fixture = try await makePreparationHistoryStore("recovery-empty")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let before = await fixture.store.preparationMaintenanceRowsRead
        let projection = try await fixture.store.pendingPreparationRecoveryIDs()
        let after = await fixture.store.preparationMaintenanceRowsRead
        XCTAssertEqual(projection, PodcastPreparationInvalidationResult())
        XCTAssertEqual(after - before, 0, "an empty marker query reads no journal rows")
        XCTAssertEqual(try preparationHistoryRowCount(
            in: fixture.store.container, requestID: fixture.requestID), 0)
    }

    func testPreparationRecoveryProjectionDeduplicatesSortsAndLetsForcedWinWithoutWritingMarkers() async throws {
        let fixture = try await makePreparationHistoryDownload("recovery-projection")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let first = fixture.itemID
        let second = try ItemID(rawValue: fixture.itemID.rawValue + "b")
        let third = try ItemID(rawValue: fixture.itemID.rawValue + "c")
        let context = ModelContext(fixture.store.container)
        let markerResult = try PreparationTerminalResult(outcome: .failed,
            error: try ProducerError(code: .failed, message: "marker", retryable: true))
        let forced = LocalLibraryStore.forcedRedownloadRequestPrefix
        let reset = LocalLibraryStore.resetPreparationRequestPrefix
        // Inserted in reverse order, with duplicate reset markers for `first`,
        // so deterministic sorting and deduplication are observable.
        try insertPreparation(context, id: reset + third.rawValue + "|marker", itemID: third,
            requestID: reset + third.rawValue, stage: .failed, at: fixture.base, attempt: nil,
            terminal: markerResult)
        try insertPreparation(context, id: forced + second.rawValue + "|marker", itemID: second,
            requestID: forced + second.rawValue, stage: .failed, at: fixture.base, attempt: nil,
            terminal: markerResult)
        for suffix in ["a", "b"] {
            try insertPreparation(context, id: reset + first.rawValue + "|marker-\(suffix)", itemID: first,
                requestID: reset + first.rawValue, stage: .failed, at: fixture.base, attempt: nil,
                terminal: markerResult)
        }
        try insertPreparation(context, id: forced + first.rawValue + "|marker", itemID: first,
            requestID: forced + first.rawValue, stage: .failed, at: fixture.base, attempt: nil,
            terminal: markerResult)
        try context.save()

        func markerSnapshot() throws -> [String: String] {
            let readContext = ModelContext(fixture.store.container)
            let rows = try readContext.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.id, "\(row.itemID)|\(row.requestID)|\(row.statusData.base64EncodedString())")
            })
        }

        let before = try markerSnapshot()
        let firstProjection = try await fixture.store.pendingPreparationRecoveryIDs()
        let secondProjection = try await fixture.store.pendingPreparationRecoveryIDs()
        XCTAssertEqual(firstProjection.resetEpisodeIDs, [third])
        XCTAssertEqual(firstProjection.forcedRedownloadEpisodeIDs, [first, second])
        XCTAssertEqual(secondProjection, firstProjection, "projection order is deterministic")
        XCTAssertEqual(try markerSnapshot(), before, "a projection never rewrites or clears markers")
    }

    func testPreparationRecoveryProjectionSkipsMalformedIDsWithoutReadingJournalHistory() async throws {
        let fixture = try await makePreparationHistoryDownload("recovery-malformed")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let context = ModelContext(fixture.store.container)
        for ordinal in 1...100 {
            try insertPreparation(context, id: fixture.requestID + "|extracting#\(ordinal)",
                itemID: fixture.itemID, requestID: fixture.requestID, stage: .extracting,
                at: fixture.base.addingTimeInterval(Double(ordinal)), attempt: nil)
        }
        let forcedRequestID = LocalLibraryStore.forcedRedownloadRequestPrefix + fixture.itemID.rawValue
        let resetRequestID = LocalLibraryStore.resetPreparationRequestPrefix + fixture.itemID.rawValue
        let markerResult = try PreparationTerminalResult(outcome: .failed,
            error: try ProducerError(code: .failed, message: "marker", retryable: true))
        try insertPreparation(context, id: forcedRequestID + "|marker", itemID: fixture.itemID,
            requestID: forcedRequestID, stage: .failed, at: fixture.base, attempt: nil, terminal: markerResult)
        try insertPreparation(context, id: resetRequestID + "|marker", itemID: fixture.itemID,
            requestID: resetRequestID, stage: .preparing, at: fixture.base, attempt: nil)
        try context.save()
        let markers = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == forcedRequestID || $0.requestID == resetRequestID }))
        XCTAssertEqual(markers.count, 2)
        for marker in markers { marker.itemID = "not an item id" }
        try context.save()

        let before = await fixture.store.preparationMaintenanceRowsRead
        let projection = try await fixture.store.pendingPreparationRecoveryIDs()
        let after = await fixture.store.preparationMaintenanceRowsRead
        XCTAssertEqual(projection, PodcastPreparationInvalidationResult(),
                       "a malformed marker names no episode to recover")
        XCTAssertEqual(after - before, 2,
                       "only the two marker rows are read, not the unrelated 100-row journal")
        XCTAssertEqual(try preparationHistoryRowCount(
            in: fixture.store.container, requestID: fixture.requestID), 100)
    }
}
