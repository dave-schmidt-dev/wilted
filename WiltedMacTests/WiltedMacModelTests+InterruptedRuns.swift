import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: - Interrupted preparation runs

    /// The bug this covers: an install quit Wilted at 18:59 while an episode
    /// downloaded at 18:56 was still transcribing. The pipeline writes a run's
    /// terminal entry from inside the run, so the journal kept a live entry
    /// with nothing behind it, and the next launch read it back as
    /// "Preparing…" with a Stop that stopped nothing.
    func testBootstrapClosesARunTheJournalStillCallsLive() async throws {
        let directory = temporaryDirectory("interrupted-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://podcasts.example.test/interrupted.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Waveform", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        func episode(_ guid: String) async throws -> ItemID {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            return id
        }
        let interrupted = try await episode("interrupted")
        let finished = try await episode("finished")
        let interruptedRequest = WiltedMacModel.podcastRequestPrefix + interrupted.rawValue
        let finishedRequest = WiltedMacModel.podcastRequestPrefix + finished.rawValue
        // What the journal held when the process died: a start and a stage,
        // no terminal.
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|pipeline.start#1", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .preparing, detail: "Episode interrupted", cancellable: true, emittedAt: created)
        ))
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|transcript.stt.start#2", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .extracting, detail: "rev-abc.mp3", cancellable: true,
                                          emittedAt: Timestamp(created.date.addingTimeInterval(1)))
        ))
        // A run that did finish is not this launch's business.
        try await store.record(preparation: PreparationJournalEntry(
            id: finishedRequest + "|terminal", itemID: finished, requestID: finishedRequest,
            status: try PreparationStatus(stage: .completed, detail: "Prepared.", cancellable: false,
                                          terminalResult: try PreparationTerminalResult(
                                              outcome: .succeeded,
                                              revisionID: try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
                                          ),
                                          emittedAt: created)
        ))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let runs = Dictionary(uniqueKeysWithValues: try await store.preparationRuns().map { ($0.requestID, $0) })
        let closed = try XCTUnwrap(runs[interruptedRequest])
        XCTAssertTrue(closed.isTerminal, "a run no process is running must not stay live across a launch")
        XCTAssertEqual(closed.outcome, .failed)
        XCTAssertEqual(closed.failure?.message, WiltedMacModel.preparationInterruptedMessage)
        XCTAssertEqual(closed.entries.count, 3, "the run's own entries stay; one closing entry is added")
        let untouched = try XCTUnwrap(runs[finishedRequest])
        XCTAssertEqual(untouched.outcome, .succeeded)
        XCTAssertEqual(untouched.entries.count, 1)

        let row = try XCTUnwrap(model.episodes.first { $0.id == interrupted.rawValue })
        XCTAssertEqual(row.preparationState, .failed(WiltedMacModel.preparationFailedLabel),
                       "the row says the run failed and points at Prep, where the retry is")
        XCTAssertEqual(model.episodes.first { $0.id == finished.rawValue }?.preparationState.isRunning, false)
    }

    /// The closing entry is written only for a run that has no terminal
    /// entry, and it is one the journal reader recognises as a failure.
    func testInterruptedEntryIsWrittenOnlyForALiveRun() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "c", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func run(isTerminal: Bool) -> PreparationRunSummary {
            PreparationRunSummary(requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when,
                                  stage: isTerminal ? .completed : .extracting, detail: "x", fraction: nil,
                                  isTerminal: isTerminal, outcome: isTerminal ? .succeeded : nil, failure: nil)
        }
        XCTAssertNil(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: true), at: when))
        let entry = try XCTUnwrap(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: false), at: when))
        XCTAssertEqual(entry.id, requestID + "|interrupted")
        XCTAssertEqual(entry.requestID, requestID)
        XCTAssertTrue(entry.status.terminal)
        XCTAssertEqual(entry.status.terminalResult?.outcome, .failed)
        XCTAssertEqual(entry.status.terminalResult?.error?.retryable, true)
        XCTAssertEqual(entry.status.detail, WiltedMacModel.preparationInterruptedMessage)
    }

    /// Phase 4 gate: `closeInterruptedPreparationRuns` must not stamp a
    /// false `.failed` over a run whose own outcome already proves it
    /// finished before the process died -- only a genuinely stuck run (no
    /// outcome, or one that predates this run) gets closed.
    func testBootstrapDoesNotCloseALiveRunAnOutcomeAlreadyProves() async throws {
        let directory = temporaryDirectory("interrupted-run-proven")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://podcasts.example.test/proven.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Waveform", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))

        func episode(_ guid: String) async throws -> ItemID {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            return id
        }
        func makeReadyRevision(for id: ItemID, suffix: String) async throws -> RevisionID {
            let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: suffix, count: 64))
            let hash = "sha256:" + String(repeating: suffix, count: 64)
            let url = directory.appendingPathComponent("\(suffix).mp3")
            try Data("audio-\(suffix)".utf8).write(to: url)
            try await store.finalizePodcastDownload(
                revision: try AudioRevision(itemID: id, revisionID: revisionID, durationSeconds: 12, byteCount: 12,
                                            contentHash: hash, mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3),
                mediaURL: url,
                download: try PodcastDownload(episodeID: id, status: .completed, bytesReceived: 12,
                                              expectedByteCount: 12, localURL: url, contentHash: hash, updatedAt: created)
            )
            return revisionID
        }
        func nonTerminalEntry(for id: ItemID) throws -> PreparationJournalEntry {
            let requestID = WiltedMacModel.podcastRequestPrefix + id.rawValue
            return try PreparationJournalEntry(
                id: requestID + "|pipeline.start#1", itemID: id, requestID: requestID,
                status: try PreparationStatus(stage: .preparing, detail: "in flight", cancellable: true, emittedAt: created)
            )
        }

        // Proven: this run's own outcome landed (dated at the run's own
        // start) before the process died mid-journal-write.
        let proven = try await episode("proven")
        let provenRevisionID = try await makeReadyRevision(for: proven, suffix: "1")
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: proven, revisionID: provenRevisionID, policyDigest: "d", pipelineFingerprint: "f",
            semanticVersion: "v", producedAt: created
        ))
        try await store.record(preparation: nonTerminalEntry(for: proven))

        // Stuck: no outcome at all -- a genuinely interrupted run.
        let stuck = try await episode("stuck")
        _ = try await makeReadyRevision(for: stuck, suffix: "2")
        try await store.record(preparation: nonTerminalEntry(for: stuck))

        // Stale: an outcome exists, but it predates this run's own start, so
        // it proves nothing about whether *this* run finished.
        let stale = try await episode("stale")
        let staleRevisionID = try await makeReadyRevision(for: stale, suffix: "3")
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: stale, revisionID: staleRevisionID, policyDigest: "d", pipelineFingerprint: "f",
            semanticVersion: "v", producedAt: Timestamp(created.date.addingTimeInterval(-60))
        ))
        try await store.record(preparation: nonTerminalEntry(for: stale))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let runs = Dictionary(uniqueKeysWithValues: try await store.preparationRuns().map { ($0.requestID, $0) })
        let provenRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + proven.rawValue])
        XCTAssertFalse(provenRun.isTerminal,
                       "an outcome the run itself produced must not be overwritten with a false failure")
        XCTAssertEqual(provenRun.entries.count, 1, "no interrupted-closing entry should be added")

        let stuckRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + stuck.rawValue])
        XCTAssertTrue(stuckRun.isTerminal, "a run with no outcome proving it finished is genuinely stuck")
        XCTAssertEqual(stuckRun.outcome, .failed)
        XCTAssertEqual(stuckRun.failure?.message, WiltedMacModel.preparationInterruptedMessage)

        let staleRun = try XCTUnwrap(runs[WiltedMacModel.podcastRequestPrefix + stale.rawValue])
        XCTAssertTrue(staleRun.isTerminal, "an outcome from before this run started proves nothing about it")
        XCTAssertEqual(staleRun.outcome, .failed)

        let provenEpisode = try XCTUnwrap(model.episodes.first { $0.id == proven.rawValue })
        XCTAssertTrue(provenEpisode.preparationState.isPrepared,
                      "the proven episode must read as prepared even though its journal entry is still open")
        let stuckEpisode = try XCTUnwrap(model.episodes.first { $0.id == stuck.rawValue })
        XCTAssertEqual(stuckEpisode.preparationState, .failed(WiltedMacModel.preparationFailedLabel))
    }

}
