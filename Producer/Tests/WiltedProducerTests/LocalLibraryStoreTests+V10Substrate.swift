import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: - V10 podcast substrate

    func podcastRevision(itemID: ItemID, id: String, hashDigit: String) throws -> AudioRevision {
        try AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: id), durationSeconds: 90, byteCount: 4_096,
                          contentHash: "sha256:" + String(repeating: hashDigit, count: 64), mediaType: "audio/mp4",
                          createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)), schemaVersion: 3)
    }

    func completedPodcastDownload(episodeID: ItemID, revision: AudioRevision, mediaURL: URL) throws -> PodcastDownload {
        try PodcastDownload(episodeID: episodeID, status: .completed, bytesReceived: revision.byteCount,
                            expectedByteCount: revision.byteCount, localURL: mediaURL, contentHash: revision.contentHash,
                            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_500)))
    }

    func succeededPreparationEntry(
        itemID: ItemID, revisionID: RevisionID, requestID: String, fingerprint: String?, at time: TimeInterval
    ) throws -> PreparationJournalEntry {
        let evidence = try fingerprint.map { try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: ["fingerprint": $0]) }
        let status = try PreparationStatus(stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                                           terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                                           emittedAt: Timestamp(Date(timeIntervalSince1970: time)), evidence: evidence)
        return PreparationJournalEntry(id: requestID + "|terminal", itemID: itemID, requestID: requestID, status: status)
    }

    private func forcedRedownloadMarkerEntry(itemID: ItemID, at time: TimeInterval) throws -> PreparationJournalEntry {
        let requestID = LocalLibraryStore.forcedRedownloadRequestPrefix + itemID.rawValue
        let markerError = try ProducerError(code: .invalidRequest, message: "needs a fresh download", retryable: true, stage: "pipeline-invalidation")
        let status = try PreparationStatus(stage: .failed, detail: markerError.message, cancellable: false,
                                           terminalResult: try PreparationTerminalResult(outcome: .failed, error: markerError),
                                           emittedAt: Timestamp(Date(timeIntervalSince1970: time)),
                                           evidence: try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: ["fingerprint": "fp-new", "requiresRedownload": "true"]))
        return PreparationJournalEntry(id: requestID + "|marker", itemID: itemID, requestID: requestID, status: status)
    }

    private func resetPreparationMarkerEntry(itemID: ItemID, at time: TimeInterval) throws -> PreparationJournalEntry {
        let requestID = LocalLibraryStore.resetPreparationRequestPrefix + itemID.rawValue
        let status = try PreparationStatus(stage: .preparing, detail: "will be prepared again", cancellable: false,
                                           emittedAt: Timestamp(Date(timeIntervalSince1970: time)),
                                           evidence: try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: ["fingerprint": "fp-new", "requiresRedownload": "false"]))
        return PreparationJournalEntry(id: requestID + "|marker", itemID: itemID, requestID: requestID, status: status)
    }

    /// The load-bearing compatibility promise: a V9 store whose only proof of
    /// preparation is a journal terminal success, and whose only proof of
    /// completion is a `PlaybackRecord`, must come out of `reconcilePodcastStateV10()`
    /// still Prepared and still Finished. A legacy forced-redownload or
    /// reset-preparation marker must translate onto the matching outcome row
    /// when it is at least as new as that row, must survive untouched when
    /// there is no outcome row at all to annotate (so `requiresForcedRedownload`
    /// and `resetEpisodeIDs` keep seeing it), and must never overwrite a
    /// newer, good outcome with a stale invalidation.
    func testV9StoreBackfillsPreparationOutcomeListeningAndLegacyInvalidationMarkersIntoV10() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let feedURL = URL(string: "https://podcasts.example.test/v10-backfill/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Backfill Show", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        let subscription = PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))

        func makeEpisode(_ guid: String) throws -> PodcastEpisode {
            let enclosureURL = URL(string: "https://podcasts.example.test/v10-backfill/\(guid).mp3")!
            return try PodcastEpisode(itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                                      feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                                      enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                                      createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        }

        // Episode 1: journal-only proof of preparation, plus a completed
        // playback record -- exercises backfill steps 1 and 2.
        let episode1 = try makeEpisode("journal-only-proof")
        let revision1 = try podcastRevision(itemID: episode1.itemID, id: "rev-v10-1", hashDigit: "1")
        let mediaURL1 = URL(fileURLWithPath: "/tmp/v10-backfill-1.m4a")
        let download1 = try completedPodcastDownload(episodeID: episode1.itemID, revision: revision1, mediaURL: mediaURL1)
        let playback1 = try PlaybackState(itemID: episode1.itemID, revisionID: revision1.revisionID, sessionID: "session-1",
                                          sequence: 1, positionSeconds: 90, durationSeconds: 90, completed: true, intent: .progress,
                                          deviceID: "device-mac", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_600)))
        let journal1 = try succeededPreparationEntry(itemID: episode1.itemID, revisionID: revision1.revisionID,
                                                     requestID: "podcast-prepare|\(episode1.itemID.rawValue)",
                                                     fingerprint: "fp-episode-1", at: 1_700_000_550)

        // Episode 2: also proved by the journal, additionally carries a legacy
        // forced-redownload marker -- exercises step 4 translating onto an
        // existing outcome row.
        let episode2 = try makeEpisode("forced-redownload-with-outcome")
        let revision2 = try podcastRevision(itemID: episode2.itemID, id: "rev-v10-2", hashDigit: "2")
        let mediaURL2 = URL(fileURLWithPath: "/tmp/v10-backfill-2.m4a")
        let download2 = try completedPodcastDownload(episodeID: episode2.itemID, revision: revision2, mediaURL: mediaURL2)
        let journal2 = try succeededPreparationEntry(itemID: episode2.itemID, revisionID: revision2.revisionID,
                                                     requestID: "podcast-prepare|\(episode2.itemID.rawValue)",
                                                     fingerprint: "fp-episode-2", at: 1_700_000_550)
        let marker2 = try forcedRedownloadMarkerEntry(itemID: episode2.itemID, at: 1_700_000_700)

        // Episode 3: only a legacy forced-redownload marker and nothing else --
        // never re-prepared, so per Fix 1 step 4 must leave the marker in
        // place untouched: there is no outcome row to annotate, so nothing
        // else carries the "needs a fresh source" fact forward.
        let episode3 = try makeEpisode("forced-redownload-without-outcome")
        let marker3 = try forcedRedownloadMarkerEntry(itemID: episode3.itemID, at: 1_700_000_700)

        // Episode 4: journal-proved preparation whose outcome is *newer* than
        // a stale forced-redownload marker left over from before that
        // success succeeded -- exercises the inverse timestamp ordering: a
        // matched marker must not overwrite a newer, good outcome, but must
        // still be deleted since its information is superseded.
        let episode4 = try makeEpisode("forced-redownload-older-than-outcome")
        let revision4 = try podcastRevision(itemID: episode4.itemID, id: "rev-v10-4", hashDigit: "4")
        let mediaURL4 = URL(fileURLWithPath: "/tmp/v10-backfill-4.m4a")
        let download4 = try completedPodcastDownload(episodeID: episode4.itemID, revision: revision4, mediaURL: mediaURL4)
        let journal4 = try succeededPreparationEntry(itemID: episode4.itemID, revisionID: revision4.revisionID,
                                                     requestID: "podcast-prepare|\(episode4.itemID.rawValue)",
                                                     fingerprint: "fp-episode-4", at: 1_700_000_900)
        let marker4 = try forcedRedownloadMarkerEntry(itemID: episode4.itemID, at: 1_700_000_100)

        // Episode 5: journal-proved preparation whose only evidence carries no
        // pipeline provenance (nil fingerprint) -- exercises Fix 3's
        // `semanticVersion` sentinel for genuinely unknown-provenance legacy
        // rows.
        let episode5 = try makeEpisode("unknown-provenance")
        let revision5 = try podcastRevision(itemID: episode5.itemID, id: "rev-v10-5", hashDigit: "5")
        let mediaURL5 = URL(fileURLWithPath: "/tmp/v10-backfill-5.m4a")
        let download5 = try completedPodcastDownload(episodeID: episode5.itemID, revision: revision5, mediaURL: mediaURL5)
        let journal5 = try succeededPreparationEntry(itemID: episode5.itemID, revisionID: revision5.revisionID,
                                                     requestID: "podcast-prepare|\(episode5.itemID.rawValue)",
                                                     fingerprint: nil, at: 1_700_000_550)

        // Episode 6: only a legacy reset-preparation marker and nothing else --
        // `invalidateStalePodcastPreparations` deletes the journal group for
        // reset markers too, so this must survive reconcile the same way
        // episode 3's forced marker does, or `resetEpisodeIDs` silently stops
        // re-queuing it for preparation.
        let episode6 = try makeEpisode("reset-preparation-without-outcome")
        let marker6 = try resetPreparationMarkerEntry(itemID: episode6.itemID, at: 1_700_000_700)

        try LocalLibraryStore.createV9MigrationFixture(
            at: url, feed: feed, subscription: subscription,
            episodes: [
                LocalLibraryStore.PodcastEpisodeMigrationFixture(
                    episode: episode1, download: download1, revision: revision1, mediaURL: mediaURL1,
                    playback: playback1, journalEntries: [journal1]
                ),
                LocalLibraryStore.PodcastEpisodeMigrationFixture(
                    episode: episode2, download: download2, revision: revision2, mediaURL: mediaURL2,
                    journalEntries: [journal2, marker2]
                ),
                LocalLibraryStore.PodcastEpisodeMigrationFixture(episode: episode3, journalEntries: [marker3]),
                LocalLibraryStore.PodcastEpisodeMigrationFixture(
                    episode: episode4, download: download4, revision: revision4, mediaURL: mediaURL4,
                    journalEntries: [journal4, marker4]
                ),
                LocalLibraryStore.PodcastEpisodeMigrationFixture(
                    episode: episode5, download: download5, revision: revision5, mediaURL: mediaURL5,
                    journalEntries: [journal5]
                ),
                LocalLibraryStore.PodcastEpisodeMigrationFixture(episode: episode6, journalEntries: [marker6]),
            ]
        )

        let migrated = try LocalLibraryStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, .v15, "the migration plan must carry a V9 store all the way to V15")

        // Fix 4: prove the migrated store's live call sites actually see the
        // V9 fixture's rows through the new V10 classes end-to-end, not just
        // that `.id` resolves.
        let loadedEpisode1 = try await migrated.podcastEpisode(for: episode1.itemID)
        XCTAssertEqual(loadedEpisode1?.title, episode1.title)
        XCTAssertEqual(loadedEpisode1?.notes, episode1.notes)
        XCTAssertEqual(loadedEpisode1?.transcriptSources, episode1.transcriptSources)
        let loadedDownload1 = try await migrated.download(for: episode1.itemID)
        XCTAssertEqual(loadedDownload1, download1)
        XCTAssertNil(loadedDownload1?.failureKind)
        let retiredAtAfterMigration = try await migrated.retiredAt(for: episode1.itemID)
        XCTAssertNil(retiredAtAfterMigration)

        let episode2MarkerBeforeReconcile = try await migrated.requiresForcedRedownload(for: episode2.itemID)
        let episode3MarkerBeforeReconcile = try await migrated.requiresForcedRedownload(for: episode3.itemID)
        XCTAssertTrue(episode2MarkerBeforeReconcile, "the legacy marker must survive the schema migration itself")
        XCTAssertTrue(episode3MarkerBeforeReconcile)

        try await migrated.reconcilePodcastStateV10()

        // Step 1: episode 1 is Prepared from journal evidence alone.
        let outcome1 = try await migrated.preparationOutcome(for: episode1.itemID, revisionID: revision1.revisionID)
        XCTAssertEqual(outcome1?.eligibility, .current)
        XCTAssertEqual(outcome1?.pipelineFingerprint, "fp-episode-1")
        XCTAssertEqual(outcome1?.policyDigest, "", "legacy rows carry no digest; this default is deliberate, not a bug")
        XCTAssertEqual(outcome1?.semanticVersion, PodcastPreparationPipeline.semanticVersion)

        // Step 2: episode 1 is also Finished from the completed playback record.
        let listening1 = try await migrated.listeningState(for: episode1.itemID)
        XCTAssertNotNil(listening1?.completedAt, "a completed PlaybackRecord must become a completed listening fact")
        XCTAssertEqual(listening1?.lastRevisionID, revision1.revisionID)

        // Step 4: episode 2's outcome row exists (from step 1) and is now
        // invalid, and its marker is gone.
        let outcome2 = try await migrated.preparationOutcome(for: episode2.itemID, revisionID: revision2.revisionID)
        XCTAssertEqual(outcome2?.eligibility, .invalid)
        XCTAssertEqual(outcome2?.invalidationRuleID, LocalLibraryStore.legacyForcedRedownloadInvalidationRuleID)
        let episode2MarkerAfterReconcile = try await migrated.requiresForcedRedownload(for: episode2.itemID)
        XCTAssertFalse(episode2MarkerAfterReconcile)

        // Fix 1: episode 3's forced-redownload marker has no outcome row to
        // annotate, so it must survive reconcile completely untouched --
        // `requiresForcedRedownload` must keep returning true, and the
        // marker's own `PreparationRecord` must still be present and
        // decodable, not silently dropped.
        let episode3MarkerAfterReconcile = try await migrated.requiresForcedRedownload(for: episode3.itemID)
        XCTAssertTrue(episode3MarkerAfterReconcile, "a forced-redownload marker with nothing to annotate must not be dropped")
        let episode3Journal = try await migrated.preparationJournal(
            for: LocalLibraryStore.forcedRedownloadRequestPrefix + episode3.itemID.rawValue
        )
        XCTAssertEqual(episode3Journal.count, 1, "the marker's PreparationRecord itself must still be present and decodable")

        // Episode 6's reset-preparation marker has no outcome row to annotate
        // either, and must survive the same way: `invalidateStalePodcastPreparations`
        // rebuilds `resetEpisodeIDs` from surviving markers, not from the
        // journal, so dropping this one would silently stop re-queuing it.
        let episode6Journal = try await migrated.preparationJournal(
            for: LocalLibraryStore.resetPreparationRequestPrefix + episode6.itemID.rawValue
        )
        XCTAssertEqual(episode6Journal.count, 1, "a reset-preparation marker with nothing to annotate must not be dropped")

        // Fix 2: episode 4's marker matched an outcome row but predates it,
        // so it must not overwrite that newer, good outcome -- it is simply
        // deleted since its information is superseded.
        let outcome4 = try await migrated.preparationOutcome(for: episode4.itemID, revisionID: revision4.revisionID)
        XCTAssertEqual(outcome4?.eligibility, .current, "a marker older than the outcome it would invalidate must not mislabel a newer, good artifact")
        XCTAssertNil(outcome4?.invalidationRuleID)
        let episode4MarkerAfterReconcile = try await migrated.requiresForcedRedownload(for: episode4.itemID)
        XCTAssertFalse(episode4MarkerAfterReconcile, "the now-obsolete marker must still be deleted even though it didn't invalidate anything")

        // Fix 3: episode 5's outcome has no real provenance evidence, so its
        // semanticVersion must be the explicit unknown-legacy sentinel, not
        // today's pipeline version.
        let outcome5 = try await migrated.preparationOutcome(for: episode5.itemID, revisionID: revision5.revisionID)
        XCTAssertNil(outcome5?.pipelineFingerprint)
        XCTAssertEqual(outcome5?.eligibility, .current, "legacy artifacts of unknown provenance stay playable")
        XCTAssertEqual(outcome5?.semanticVersion, LocalLibraryStore.legacyUnknownProvenanceSemanticVersion,
                       "a nil fingerprint is real unknown provenance; it must not claim today's exact pipeline version")

        // Idempotency: a second call is a true no-op. No duplicate rows, no
        // rows overwritten with worse data.
        try await migrated.reconcilePodcastStateV10()
        let outcome1Again = try await migrated.preparationOutcome(for: episode1.itemID, revisionID: revision1.revisionID)
        let listening1Again = try await migrated.listeningState(for: episode1.itemID)
        let outcome2Again = try await migrated.preparationOutcome(for: episode2.itemID, revisionID: revision2.revisionID)
        let outcome4Again = try await migrated.preparationOutcome(for: episode4.itemID, revisionID: revision4.revisionID)
        let episode2MarkerAfterSecondReconcile = try await migrated.requiresForcedRedownload(for: episode2.itemID)
        let episode3MarkerAfterSecondReconcile = try await migrated.requiresForcedRedownload(for: episode3.itemID)
        let episode4MarkerAfterSecondReconcile = try await migrated.requiresForcedRedownload(for: episode4.itemID)
        XCTAssertEqual(outcome1Again, outcome1)
        XCTAssertEqual(listening1Again, listening1)
        XCTAssertEqual(outcome2Again, outcome2)
        XCTAssertEqual(outcome4Again, outcome4)
        XCTAssertFalse(episode2MarkerAfterSecondReconcile)
        XCTAssertTrue(episode3MarkerAfterSecondReconcile, "the surviving marker must remain after a second idempotent reconcile")
        XCTAssertFalse(episode4MarkerAfterSecondReconcile)
        let episode6JournalAfterSecondReconcile = try await migrated.preparationJournal(
            for: LocalLibraryStore.resetPreparationRequestPrefix + episode6.itemID.rawValue
        )
        XCTAssertEqual(episode6JournalAfterSecondReconcile.count, 1, "the surviving reset marker must remain after a second idempotent reconcile")
    }

    /// Round-trips every new V10 store method independent of migration: save
    /// then read back a preparation outcome, a listening state, and episode
    /// retirement, including retirement's documented idempotency.
    func testV10StoreMethodsRoundTripOutcomeListeningAndRetirement() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: episode)

        let revisionID = try RevisionID(rawValue: "rev-v10-roundtrip")
        let outcome = PodcastPreparationOutcome(
            episodeID: episode.itemID, revisionID: revisionID, policyDigest: "digest-1",
            pipelineFingerprint: "fp-1", semanticVersion: PodcastPreparationPipeline.semanticVersion,
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_001_000)), eligibility: .current
        )
        try await store.savePreparationOutcome(outcome)
        var readOutcome = try await store.preparationOutcome(for: episode.itemID, revisionID: revisionID)
        XCTAssertEqual(readOutcome, outcome)

        let updatedOutcome = PodcastPreparationOutcome(
            episodeID: episode.itemID, revisionID: revisionID, policyDigest: "digest-2",
            pipelineFingerprint: nil, semanticVersion: PodcastPreparationPipeline.semanticVersion,
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_001_100)), eligibility: .eligible,
            invalidationRuleID: "some-rule"
        )
        try await store.savePreparationOutcome(updatedOutcome)
        readOutcome = try await store.preparationOutcome(for: episode.itemID, revisionID: revisionID)
        XCTAssertEqual(readOutcome, updatedOutcome, "an existing row updates in place rather than duplicating")

        let listening = PodcastListeningState(episodeID: episode.itemID, completedAt: Timestamp(Date(timeIntervalSince1970: 1_700_001_200)),
                                              lastRevisionID: revisionID, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_001_200)))
        try await store.saveListening(listening)
        let readListening = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(readListening, listening)

        let retiredAtBeforeRetirement = try await store.retiredAt(for: episode.itemID)
        XCTAssertNil(retiredAtBeforeRetirement)
        let firstRetirement = try await store.retireEpisode(episode.itemID, at: Timestamp(Date(timeIntervalSince1970: 1_700_001_300)))
        XCTAssertTrue(firstRetirement)
        let retiredAtAfterFirstRetirement = try await store.retiredAt(for: episode.itemID)
        XCTAssertEqual(retiredAtAfterFirstRetirement, Timestamp(Date(timeIntervalSince1970: 1_700_001_300)))
        let secondRetirement = try await store.retireEpisode(episode.itemID, at: Timestamp(Date(timeIntervalSince1970: 1_700_001_400)))
        XCTAssertFalse(secondRetirement, "retiring an already-retired episode is a no-op returning false")
        let retiredAtAfterSecondAttempt = try await store.retiredAt(for: episode.itemID)
        XCTAssertEqual(retiredAtAfterSecondAttempt, Timestamp(Date(timeIntervalSince1970: 1_700_001_300)),
                       "the no-op must not overwrite the original retirement timestamp")

        // An upsert from feed data must never resurrect, clear, or otherwise
        // change retirement -- assert the exact timestamp survives, not just
        // non-nil-ness.
        try await store.save(episode: episode)
        let retiredAtAfterUpsert = try await store.retiredAt(for: episode.itemID)
        XCTAssertEqual(retiredAtAfterUpsert, Timestamp(Date(timeIntervalSince1970: 1_700_001_300)),
                       "apply(_:to:) must not touch retiredAt")
    }

    /// The combined save is what `checkpointCompletedRevision` relies on for
    /// atomicity: one `ModelContext`, one `context.save()`, so a crash between
    /// the checkpoint and the listening fact cannot happen.
    func testCombinedPlaybackAndListeningSaveRoundTripsBoth() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: episode)
        let revisionID = try RevisionID(rawValue: "rev-combined-save")
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_002_000))
        let playback = try PlaybackState(
            itemID: episode.itemID, revisionID: revisionID, sessionID: "session-combined", sequence: 4,
            positionSeconds: 120, durationSeconds: 120, completed: true, intent: .progress,
            deviceID: "device-mac", updatedAt: now
        )
        let listening = PodcastListeningState(
            episodeID: episode.itemID, completedAt: now, lastRevisionID: revisionID, updatedAt: now
        )
        try await store.save(playback: playback, listening: listening)

        let readPlayback = try await store.playbackState(for: episode.itemID, revisionID: revisionID)
        XCTAssertEqual(readPlayback, playback)
        let readListening = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(readListening, listening)

        // A second call for the same episode/revision must update both rows in
        // place, not duplicate them.
        let later = Timestamp(Date(timeIntervalSince1970: 1_700_002_100))
        let updatedPlayback = try PlaybackState(
            itemID: episode.itemID, revisionID: revisionID, sessionID: "session-combined", sequence: 5,
            positionSeconds: 120, durationSeconds: 120, completed: true, intent: .progress,
            deviceID: "device-mac", updatedAt: later
        )
        let updatedListening = PodcastListeningState(
            episodeID: episode.itemID, completedAt: later, lastRevisionID: revisionID, updatedAt: later
        )
        try await store.save(playback: updatedPlayback, listening: updatedListening)
        let readUpdatedPlayback = try await store.playbackState(for: episode.itemID, revisionID: revisionID)
        XCTAssertEqual(readUpdatedPlayback, updatedPlayback, "an existing playback row updates in place rather than duplicating")
        let readUpdatedListening = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(readUpdatedListening, updatedListening, "an existing listening row updates in place rather than duplicating")
    }

    /// A started Larder row is both a finished-listening fact and a retirement.
    /// The paired transitions must never leave Feeds an active completed row,
    /// and a stale Undo Skip must not undo a later dismissal.
}
