import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testTranscriptSearchReadsTheCurrentRevisionAndIgnoresTheOneItReplaced() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let episode = try ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
        let other = try ItemID(rawValue: "item-" + String(repeating: "b", count: 64))
        let store = try LocalLibraryStore(url: url)

        try await save(revision: "rev-uncut", of: episode, at: 100,
                       saying: "Today's episode is sponsored by Wilted Greens.", into: store, near: url)
        try await save(revision: "rev-cut", of: episode, at: 200,
                       saying: "The heron stands very still in the shallows.", into: store, near: url)
        try await save(revision: "rev-other", of: other, at: 150,
                       saying: "A kestrel hovers over the verge.", into: store, near: url)

        let current = try await store.itemIDsWithTranscript(matching: "heron stands")
        XCTAssertEqual(current, [episode])

        let superseded = try await store.itemIDsWithTranscript(matching: "sponsored by Wilted Greens")
        XCTAssertEqual(superseded, [], "the replaced revision's advertising must not match")

        let caseFolded = try await store.itemIDsWithTranscript(matching: "HERON STANDS")
        XCTAssertEqual(caseFolded, [episode], "search is case-insensitive")

        let across = try await store.itemIDsWithTranscript(matching: "e")
        XCTAssertEqual(across, [episode, other])

        let absent = try await store.itemIDsWithTranscript(matching: "cormorant")
        XCTAssertEqual(absent, [])

        let blank = try await store.itemIDsWithTranscript(matching: "   ")
        XCTAssertEqual(blank, [], "a blank query selects nothing rather than everything")
    }

    func testPipelineInvalidationResetsStaleFailuresButPreservesTheSourceDownload() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let sourceURL = url.deletingLastPathComponent().appendingPathComponent("source.mp3")
        let sourceBytes = Data("source".utf8)
        try sourceBytes.write(to: sourceURL)
        let hash = "sha256:" + SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: RevisionID(rawValue: "source-revision"),
                                         durationSeconds: 12, byteCount: 6, contentHash: hash,
                                         mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 3)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: sourceURL,
            download: try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                          bytesReceived: 6, expectedByteCount: 6, localURL: sourceURL,
                                          contentHash: hash, updatedAt: Timestamp(Date()))
        )
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "old", "sourceRevisionID": revision.revisionID.rawValue,
            "sourceHash": hash, "sourceURL": sourceURL.absoluteString
        ])
        let failure = try PreparationStatus(
            stage: .failed, detail: "old failure", cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .failed,
                error: try ProducerError(code: .failed, message: "old failure", retryable: true)
            ), emittedAt: Timestamp(Date()), evidence: evidence
        )
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episode.itemID, requestID: requestID, status: failure
        ))

        let first = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(first.resetEpisodeIDs, [episode.itemID])
        XCTAssertEqual(first.forcedRedownloadEpisodeIDs, [])
        let journalAfterReset = try await store.preparationJournal(for: requestID)
        XCTAssertTrue(journalAfterReset.isEmpty)
        let preservedDownload = try await store.download(for: episode.itemID)
        XCTAssertEqual(preservedDownload?.localURL, sourceURL)
        XCTAssertEqual(preservedDownload?.contentHash, hash)

        let second = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(second.resetEpisodeIDs, [episode.itemID],
                       "the reset survives a relaunch before the app can admit it")
        let visibleRunsAfterReset = try await store.preparationRuns()
        XCTAssertTrue(visibleRunsAfterReset.isEmpty,
                      "a durable scheduling marker is not a visible preparation run")
        let currentEvidence = try PreparationEvidence(
            kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
            fields: ["fingerprint": "new", "sourceRevisionID": revision.revisionID.rawValue, "sourceHash": hash]
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|current", itemID: episode.itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .preparing, detail: "current attempt", cancellable: true,
                emittedAt: Timestamp(Date()), evidence: currentEvidence
            )
        ))
        let admitted = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(admitted, PodcastPreparationInvalidationResult(),
                       "current provenance clears the durable reset marker")
        let repeatedAfterAdmission = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(repeatedAfterAdmission, PodcastPreparationInvalidationResult())
    }

    func testPipelineInvalidationForcesRedownloadWhenLocalBytesDoNotMatchStoredHashes() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let sourceURL = url.deletingLastPathComponent().appendingPathComponent("corrupted-source.mp3")
        let originalBytes = Data("original source".utf8)
        try originalBytes.write(to: sourceURL)
        let hash = "sha256:" + SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: episode.itemID, revisionID: RevisionID(rawValue: "corrupted-source-revision"),
            durationSeconds: 12, byteCount: Int64(originalBytes.count), contentHash: hash,
            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 3
        )
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: sourceURL,
            download: try PodcastDownload(
                episodeID: episode.itemID, status: .completed,
                bytesReceived: Int64(originalBytes.count), expectedByteCount: Int64(originalBytes.count),
                localURL: sourceURL, contentHash: hash, updatedAt: Timestamp(Date())
            )
        )
        let evidence = try PreparationEvidence(
            kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
            fields: [
                "fingerprint": "old", "sourceRevisionID": revision.revisionID.rawValue,
                "sourceHash": hash
            ]
        )
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episode.itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .failed, detail: "old failure", cancellable: false,
                terminalResult: try PreparationTerminalResult(
                    outcome: .failed,
                    error: try ProducerError(code: .failed, message: "old failure", retryable: true)
                ),
                emittedAt: Timestamp(Date()), evidence: evidence
            )
        ))

        try Data("replacement bytes".utf8).write(to: sourceURL)
        let result = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])

        XCTAssertEqual(result.resetEpisodeIDs, [])
        XCTAssertEqual(result.forcedRedownloadEpisodeIDs, [episode.itemID],
                       "persisted metadata cannot vouch for bytes that no longer match it")
    }

    func testPipelineInvalidationPersistsAForcedRedownloadForAStalePreparedSuccess() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let preparedURL = url.deletingLastPathComponent().appendingPathComponent("prepared.mp3")
        try Data("prepared".utf8).write(to: preparedURL)
        let preparedHash = "sha256:" + String(repeating: "c", count: 64)
        try await store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8,
            expectedByteCount: 8, localURL: preparedURL, contentHash: preparedHash, updatedAt: Timestamp(Date())
        ))
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let status = try PreparationStatus(
            stage: .completed, detail: "old prepared", fraction: 1, cancellable: false,
            terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: try RevisionID(rawValue: "prepared-revision")),
            emittedAt: Timestamp(Date())
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episode.itemID, requestID: requestID, status: status
        ))
        let preexistingForcedRequestID = LocalLibraryStore.forcedRedownloadRequestPrefix + episode.itemID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: preexistingForcedRequestID + "|old", itemID: episode.itemID,
            requestID: preexistingForcedRequestID, status: status
        ))

        let result = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(result.resetEpisodeIDs, [])
        XCTAssertEqual(result.forcedRedownloadEpisodeIDs, [episode.itemID])
        let journalAfterReset = try await store.preparationJournal(for: requestID)
        XCTAssertTrue(journalAfterReset.isEmpty)
        let repeated = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(repeated.forcedRedownloadEpisodeIDs, [episode.itemID])
        let requiresForcedRedownload = try await store.requiresForcedRedownload(for: episode.itemID)
        XCTAssertTrue(requiresForcedRedownload)
        let visibleRunsAfterForcedRedownload = try await store.preparationRuns()
        XCTAssertTrue(visibleRunsAfterForcedRedownload.isEmpty,
                      "a forced-download marker is not a visible failed preparation")
        let oldResetRequestID = LocalLibraryStore.resetPreparationRequestPrefix + episode.itemID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: oldResetRequestID + "|old", itemID: episode.itemID,
            requestID: oldResetRequestID, status: status
        ))
        let conflictingMarkers = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(conflictingMarkers.resetEpisodeIDs, [])
        XCTAssertEqual(conflictingMarkers.forcedRedownloadEpisodeIDs, [episode.itemID],
                       "forced redownload wins when two upgrades left both marker generations")
        try await store.markForcedRedownloadCompleted(
            for: episode.itemID, currentFingerprint: "new"
        )
        let stillRequiresForcedRedownload = try await store.requiresForcedRedownload(for: episode.itemID)
        XCTAssertFalse(stillRequiresForcedRedownload)
        let afterFreshDownload = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(afterFreshDownload.forcedRedownloadEpisodeIDs, [])
        XCTAssertEqual(afterFreshDownload.resetEpisodeIDs, [episode.itemID],
                       "a successful redownload becomes durable pending preparation")
        let currentEvidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "new", "sourceRevisionID": "fresh-source",
            "sourceHash": "sha256:" + String(repeating: "e", count: 64)
        ])
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|current", itemID: episode.itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .preparing, detail: "current attempt", cancellable: true,
                emittedAt: Timestamp(Date()), evidence: currentEvidence
            )
        ))
        let admitted = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [Self.blanketDriftRule])
        XCTAssertEqual(admitted, PodcastPreparationInvalidationResult(),
                       "the pending marker clears only after a current preparation attempt is durable")
    }

    func testPipelineInvalidationLeavesMatchingAndNeverAttemptedEpisodesUntouched() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, matchingEpisode) = try podcastValues()
        let neverAttempted = try ItemID(rawValue: "never-" + String(repeating: "n", count: 58))
        let requestID = PodcastPreparationPipeline.requestID(for: matchingEpisode.itemID)
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": PodcastPreparationPipeline.semanticFingerprint,
            "sourceRevisionID": "source", "sourceHash": "sha256:" + String(repeating: "d", count: 64)
        ])
        let status = try PreparationStatus(
            stage: .failed, detail: "current failure", cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .failed,
                error: try ProducerError(code: .failed, message: "current failure", retryable: true)
            ), emittedAt: Timestamp(Date()), evidence: evidence
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: matchingEpisode.itemID, requestID: requestID, status: status
        ))
        let before = try await store.preparationJournal(for: requestID)
        let result = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: PodcastPreparationPipeline.semanticFingerprint, rules: [Self.blanketDriftRule]
        )
        XCTAssertEqual(result, PodcastPreparationInvalidationResult())
        let after = try await store.preparationJournal(for: requestID)
        XCTAssertEqual(after, before)
        let neverJournal = try await store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: neverAttempted)
        )
        XCTAssertTrue(neverJournal.isEmpty)
    }

    func testFingerprintDriftWithAnEmptyRuleTableInvalidatesNothing() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "old", "sourceRevisionID": "source", "sourceHash": "sha256:" + String(repeating: "d", count: 64)
        ])
        let status = try PreparationStatus(
            stage: .failed, detail: "old failure", cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .failed, error: try ProducerError(code: .failed, message: "old failure", retryable: true)
            ), emittedAt: Timestamp(Date()), evidence: evidence
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episode.itemID, requestID: requestID, status: status
        ))

        let result = try await store.invalidateStalePodcastPreparations(currentFingerprint: "new", rules: [])
        XCTAssertEqual(result, PodcastPreparationInvalidationResult(),
                       "a bare fingerprint mismatch with no rule must invalidate nothing")
        let journalAfter = try await store.preparationJournal(for: requestID)
        XCTAssertEqual(journalAfter.count, 1, "the journal group survives untouched, not just its effects")
        let requiresForcedRedownload = try await store.requiresForcedRedownload(for: episode.itemID)
        XCTAssertFalse(requiresForcedRedownload, "no marker should be written when no rule fires")
    }

    func testSeededInvalidationRuleInvalidatesTheOutcomeRowAndSchedulesRecovery() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/seeded-rule.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://cdn.example.test/seeded-rule.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "sr1", enclosureURL: enclosureURL)
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("seeded-rule-audio.mp3")
        let bytes = Data("seeded rule audio".utf8)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        // Outcome row with no journal -- the shape a cleared or unfinished
        // journal leaves behind.
        let revision = try AudioRevision(itemID: episodeID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: hash,
                                         mediaType: "audio/mpeg", createdAt: when, schemaVersion: 3)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: episodeID, status: .completed, bytesReceived: Int64(bytes.count),
                                          expectedByteCount: Int64(bytes.count), localURL: mediaURL,
                                          contentHash: hash, updatedAt: when)
        )
        let transcript = try Transcript(itemID: episodeID, revisionID: revisionID, availability: .available,
                                        text: "No ads to cut.", updatedAt: when)
        let outcome = PodcastPreparationOutcome(episodeID: episodeID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "old", semanticVersion: "v1", producedAt: when)
        try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript, outcome: outcome)

        let knownBadRule = PodcastPreparationInvalidationRule(
            id: "known-bad-v1", consequence: .resetPreparation,
            applies: { $0.pipelineFingerprint == "old" }
        )
        let irrelevantRule = PodcastPreparationInvalidationRule(
            id: "irrelevant", consequence: .resetPreparation, applies: { _ in false }
        )

        let result = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: "new", rules: [irrelevantRule, knownBadRule]
        )
        XCTAssertEqual(result.forcedRedownloadEpisodeIDs, [episodeID],
                       "no journal survives an outcome-only preparation, so pass 2 has no pre-cut provenance to " +
                       "trust a reset against -- it must always force a fresh download")
        XCTAssertEqual(result.resetEpisodeIDs, [],
                       "an outcome-only preparation can never safely resolve to a reset")

        let invalidated = try await store.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(invalidated?.eligibility, .invalid)
        XCTAssertEqual(invalidated?.invalidationRuleID, "known-bad-v1",
                       "the marked rule must be the one that actually fired, not any rule in the table")

        // Idempotent: a relaunch before the app admits the recovery must not
        // re-derive a different verdict or duplicate the marker.
        let repeated = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: "new", rules: [irrelevantRule, knownBadRule]
        )
        XCTAssertEqual(repeated.forcedRedownloadEpisodeIDs, [episodeID])
    }

    /// Regression for a data-loss bug: reconcile's step 4 used to delete any
    /// forced-redownload/reset marker with a matching outcome row
    /// unconditionally, which included every marker pass 2 above ever
    /// writes (pass 2's population is defined as "has a matching outcome
    /// row"). That destroyed the recovery marker before the app ever got a
    /// chance to admit it -- on the very next launch, before the download it
    /// names could even start. The fix gates step 4's translate-and-delete on
    /// `eligibility == .current`: an `.invalid` outcome with a marker is live
    /// scheduling state from the rule table, not legacy debt, and must
    /// survive reconcile.
    func testReconcileDoesNotDestroyALiveForcedRedownloadMarkerWithAMatchingInvalidOutcome() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/reconcile-step4.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://cdn.example.test/reconcile-step4.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "rc4", enclosureURL: enclosureURL)
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "b", count: 64))
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("reconcile-step4-audio.mp3")
        let bytes = Data("reconcile step 4 audio".utf8)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let revision = try AudioRevision(itemID: episodeID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: hash,
                                         mediaType: "audio/mpeg", createdAt: when, schemaVersion: 3)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: episodeID, status: .completed, bytesReceived: Int64(bytes.count),
                                          expectedByteCount: Int64(bytes.count), localURL: mediaURL,
                                          contentHash: hash, updatedAt: when)
        )
        let transcript = try Transcript(itemID: episodeID, revisionID: revisionID, availability: .available,
                                        text: "No ads to cut.", updatedAt: when)
        let outcome = PodcastPreparationOutcome(episodeID: episodeID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "old", semanticVersion: "v1", producedAt: when)
        try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript, outcome: outcome)

        let knownBadRule = PodcastPreparationInvalidationRule(
            id: "known-bad-v1", consequence: .resetPreparation,
            applies: { $0.pipelineFingerprint == "old" }
        )

        // First launch: pass 2 condemns the outcome-only preparation and
        // writes a durable forced-redownload marker.
        let firstLaunch = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: "new", rules: [knownBadRule]
        )
        XCTAssertEqual(firstLaunch.forcedRedownloadEpisodeIDs, [episodeID])

        // Second launch, before the app ever admitted the recovery: V10
        // reconcile's step 4 runs first, exactly as it does in production.
        try await store.reconcilePodcastStateV10()

        // Only after reconcile does the app re-run invalidation. Without the
        // fix, step 4 would already have deleted the marker, so this call's
        // marker-rebuild pass would find nothing and silently drop recovery.
        let secondLaunch = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: "new", rules: [knownBadRule]
        )
        XCTAssertEqual(secondLaunch.forcedRedownloadEpisodeIDs, [episodeID],
                       "a live recovery marker must survive V10 reconcile, not be treated as legacy debt")

        let survived = try await store.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(survived?.eligibility, .invalid)
        XCTAssertEqual(survived?.invalidationRuleID, "known-bad-v1")
    }

    func testUnrelatedFingerprintDriftIsUntouchedWhileASeededRuleInvalidatesItsOwnTarget() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, matchingEpisode) = try podcastValues()
        let requestID = PodcastPreparationPipeline.requestID(for: matchingEpisode.itemID)
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "harmless-drift", "sourceRevisionID": "source",
            "sourceHash": "sha256:" + String(repeating: "d", count: 64)
        ])
        let status = try PreparationStatus(
            stage: .failed, detail: "old failure", cancellable: false,
            terminalResult: try PreparationTerminalResult(
                outcome: .failed, error: try ProducerError(code: .failed, message: "old failure", retryable: true)
            ), emittedAt: Timestamp(Date()), evidence: evidence
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: matchingEpisode.itemID, requestID: requestID, status: status
        ))

        let onlyMatchesKnownBad = PodcastPreparationInvalidationRule(
            id: "known-bad-v1", consequence: .resetPreparation,
            applies: { $0.pipelineFingerprint == "known-bad-fingerprint" }
        )
        let result = try await store.invalidateStalePodcastPreparations(
            currentFingerprint: "new", rules: [onlyMatchesKnownBad]
        )
        XCTAssertEqual(result, PodcastPreparationInvalidationResult(),
                       "a rule table that names other fingerprints must not condemn an uninvolved drift")
        let journalAfter = try await store.preparationJournal(for: requestID)
        XCTAssertEqual(journalAfter.count, 1)
    }

}
