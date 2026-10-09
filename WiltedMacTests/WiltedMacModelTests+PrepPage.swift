import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Show notes

    /// The row leads with what the episode is about when the feed says so,
    /// and the fixture carries notes so the pane has something to show.
    func testEpisodeRowSummaryComesFromTheNotesOpeningParagraph() throws {
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: "\n\n  Hosts discuss M6.  \n\nGuest: Ada", fallback: "Leo"),
            "Hosts discuss M6."
        )
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: nil, fallback: "Leo"), "Leo")
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: "   \n ", fallback: "Leo"), "Leo")
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: String(repeating: "x", count: 500), fallback: "Leo").count, 180
        )

        let directory = temporaryDirectory("fixture-notes")
        let fixture = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(fixture.episodes.first)
        XCTAssertEqual(episode.notes, WiltedMacModel.fixtureEpisodeNotes)
        XCTAssertEqual(episode.summary, "A walk through the machines that keep the field office quiet.")
    }

    func testNotesLinksAreClickable() {
        let notes = "Guest: Ada (https://example.com/ada) and code WILTED at example.com/quiet."
        let linked = WiltedShowNotes.linked(notes)
        let links = linked.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/ada", "http://example.com/quiet"])
        XCTAssertEqual(String(linked.characters), notes, "linking must not alter the words")
    }

    // MARK: Prep page

    /// After a relaunch the row must still answer "were the advertisements
    /// removed?", not just "is there a transcript?".
    func testPreparedSummaryIsRecoveredFromTheJournal() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "6", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "6", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available, text: "Words.", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")], updatedAt: when
        )
        func run(terminal: String, completion: String?, terminalRevisionID: RevisionID) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let completion {
                entries.append(PreparationJournalEntry(
                    id: requestID + "|pipeline.complete", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(stage: .preparing, detail: completion, cancellable: true, emittedAt: when)
                ))
            }
            entries.append(PreparationJournalEntry(
                id: requestID + "|terminal", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .completed, detail: terminal, cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: terminalRevisionID),
                    emittedAt: when
                )
            ))
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: terminal, fraction: nil, isTerminal: true, outcome: .succeeded, failure: nil, entries: entries
            )
        }
        func outcome(for revisionID: RevisionID) -> PodcastPreparationOutcome {
            PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                      pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        }

        // A current build journals the summary itself as the terminal row.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Ready · 5 ads removed (7:22) · transcript synced",
                                                         completion: "5 advertisements, 1307 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 5 ads removed (7:22) · transcript synced")
        )
        // Older builds wrote "Prepared." and counted advertisements one row
        // earlier; zero there is the honest state of an episode the broken
        // detector build marked prepared.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: "0 advertisements, 1345 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · no ads found · transcript synced")
        )
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: "3 advertisements, 900 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )
        // Transcript timing alone cannot prove that preparation completed.
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: transcript),
                       .notPrepared)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome(for: revisionID),
                                            run: try run(terminal: "Prepared.", completion: nil,
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · transcript synced")
        )
        let staleRevisionID = try RevisionID(rawValue: "rev-" + String(repeating: "8", count: 64))
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: staleRevisionID),
                run: try run(terminal: "Ready · transcript synced", completion: nil,
                             terminalRevisionID: staleRevisionID),
                readyRevisionID: revisionID,
                transcript: transcript
            ),
            .notPrepared,
            "An outcome proven for an older audio revision cannot label the current download prepared."
        )
    }

    /// Phase 4 gate: relaunch must reconstruct the right state from durable
    /// facts alone for every journal state a preparation run can be in --
    /// queued, running, cancelled, failed, or completed -- plus the case
    /// where a run's own terminal result names a revision the outcome row
    /// has since moved past.
    func testRefreshAcrossEveryPreparationStateReconstructsFromDurableFactsAlone() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "7", count: 64))
        let supersededRevisionID = try RevisionID(rawValue: "rev-" + String(repeating: "9", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        func nonTerminalRun(stage: PreparationStage) -> PreparationRunSummary {
            PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: stage,
                detail: "Working…", fraction: nil, isTerminal: false, outcome: nil, failure: nil, entries: []
            )
        }
        func terminalRun(outcome: PreparationOutcome, terminalRevisionID: RevisionID?) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let terminalRevisionID {
                entries = [PreparationJournalEntry(
                    id: requestID + "|terminal", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(
                        stage: .completed, detail: "Prepared.", cancellable: false,
                        terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: terminalRevisionID),
                        emittedAt: when
                    )
                )]
            }
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: "Prepared.", fraction: nil, isTerminal: true, outcome: outcome, failure: nil, entries: entries
            )
        }
        func outcome(for revisionID: RevisionID) -> PodcastPreparationOutcome {
            PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                      pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        }

        // Queued: not yet terminal, no outcome yet. `PreparationStage` has no
        // dedicated `queued` case; `.preparing` is the stage a freshly
        // admitted, not-yet-started run carries.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: nonTerminalRun(stage: .preparing),
                                            readyRevisionID: revisionID, transcript: nil),
            .preparing(stage: "Preparing…")
        )
        // Running: also not yet terminal, no outcome yet.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: nonTerminalRun(stage: .extracting),
                                            readyRevisionID: revisionID, transcript: nil),
            .preparing(stage: "Preparing…")
        )
        // Cancelled: terminal, but cancellation is not failure and not proof.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: try terminalRun(outcome: .cancelled, terminalRevisionID: nil),
                                            readyRevisionID: revisionID, transcript: nil),
            .notPrepared
        )
        // Failed: terminal, no outcome -- the row says it failed.
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: nil, run: try terminalRun(outcome: .failed, terminalRevisionID: nil),
                                            readyRevisionID: revisionID, transcript: nil),
            .failed(WiltedMacModel.preparationFailedLabel)
        )
        // Completed: terminal, succeeded, outcome present and matching.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: try terminalRun(outcome: .succeeded, terminalRevisionID: revisionID),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable")
        )
        // Completed but superseded: this run's own terminal result names an
        // older revision the ready revision has since moved past, but the
        // outcome row proves the *current* ready revision is prepared. The
        // stale run must not derail that proof.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: try terminalRun(outcome: .succeeded, terminalRevisionID: supersededRevisionID),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable"),
            "A proven outcome for the current ready revision must not be demoted by an older run's own result."
        )
        // Committed, died before the terminal write: the run is still open
        // (its own terminal journal entry never landed), but a matching,
        // non-invalid outcome for the current ready revision proves it
        // finished. The outcome guard must win before `!run.isTerminal` is
        // ever consulted -- pinning this ordering so a refactor that hoists
        // the run-terminal check cannot silently regress it back to
        // "Preparing…" forever over a proven artifact.
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                outcome: outcome(for: revisionID),
                run: nonTerminalRun(stage: .saving),
                readyRevisionID: revisionID, transcript: nil
            ),
            .prepared(summary: "Audio ready · Transcript unavailable"),
            "A durable outcome for the current ready revision must win even while its own run is still open."
        )
    }

    /// A failed run is retried from Prep, next to the reason it failed.
    func testRetryFromPrepPreparesTheRunsEpisode() throws {
        let directory = temporaryDirectory("retry-run")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertEqual(episode.preparationState, .notPrepared)
        let failed = WiltedMacProcessorRun(
            id: WiltedMacModel.podcastRequestPrefix + episode.id, itemID: episode.id, isPodcast: true,
            title: episode.title, source: episode.feedTitle, stage: "failed",
            detail: "the model failed 30 of 50 requests", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(failed)
        XCTAssertTrue(model.episodes.first?.preparationState.isRunning == true, "Retry must start a run")

        let article = WiltedMacProcessorRun(
            id: "article-request", itemID: "not-an-episode", isPodcast: false, title: "Article", source: "Web",
            stage: "failed", detail: "Could not fetch", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(article)  // article runs have their own path; nothing to do
    }

    func testFourRapidPrepRetriesPublishOneActiveProjectionAndThreeQueuedRows() async throws {
        let directory = temporaryDirectory("retry-projection")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            podcastPipelineRunnerFactory: { CancellingPodcastPipelineRunner() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let ids = ["retry-one", "retry-two", "retry-three", "retry-four"]
        let episodes = ids.map { id in
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .notPrepared
            )
        }
        episodes.forEach(model.installEpisodeForTesting)

        for episode in episodes {
            model.retryProcessorRun(WiltedMacProcessorRun(
                id: WiltedMacModel.podcastRequestPrefix + episode.id,
                itemID: episode.id, isPodcast: true, title: episode.title, source: episode.feedTitle,
                stage: "failed", detail: "previous failure", fraction: nil, outcome: .failed, updatedAt: Date()
            ))
        }

        XCTAssertEqual(
            model.processorRuns.filter { $0.outcome == .running }.map(\.itemID),
            [ids[0]],
            "the active retry is visible before the journal's first write"
        )
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), Array(ids.dropFirst()))
        XCTAssertTrue(model.episodes.allSatisfy { $0.preparationState.isRunning })

        await model.waitForPodcastPreparationOperationsForTesting()
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertTrue(model.processorRuns.filter { $0.outcome == .running }.isEmpty)
    }

}
