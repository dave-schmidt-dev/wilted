import Foundation
import CryptoKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
private final class ProcessorRunsRefreshGate {
    private var shouldHold = true
    private var didHold = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func holdFirstReadAfterReturn() async {
        guard shouldHold else { return }
        shouldHold = false
        didHold = true
        let waiters = heldWaiters
        heldWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !didHold else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct ProcessorRunsRefreshFixture {
    let store: LocalLibraryStore
    let itemID: ItemID
    let requestID: String
    let entryID: String
    let emittedAt: Timestamp
}

final class WiltedMacPreparationPublicationTests: XCTestCase {
    @MainActor
    func testSourcePublishesExactBackingAndClearsForUnacknowledgedIntakeWithdrawalAndSuccess() async throws {
        let directory = wiltedTemporaryDirectory("preparation-publication-source")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://example.test/preparation.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000.123456))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: now))
        var ids: [ItemID] = []
        for guid in ["backing", "other"] {
            let audio = URL(string: "https://example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: audio)
            try await store.save(episode: PodcastEpisode(itemID: id, feedID: feedID, feedURL: feedURL,
                rssGUID: guid, title: guid, enclosureURL: audio, enclosureMediaType: "audio/mpeg", createdAt: now))
            _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: id, decision: .keep,
                source: .manual, decidedAt: now))
            ids.append(id)
        }
        // A synthetic explicitly confirmed logical pair does not transfer backing status.
        let confirmation = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: feedID,
            first: ids[0], second: ids[1], confirmedAt: now)
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: ids[1])
        _ = try await store.applyEpisodeAssociation(preview, at: now)
        let backing = ids[0]
        let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: backing.rawValue,
            requestSequence: 30, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: "test") { nil }
        let server = InMemoryLibraryServer(writerDeviceID: "test")
        let publisher = WiltedMacLibraryPublisher(source: source,
            transport: InMemoryLibraryTransport(deviceID: "test", server: server),
            sink: WiltedMacLibraryIntentSink(), isEnabled: true)
        _ = try await publisher.sync()
        let transported = await server.currentSnapshot
        XCTAssertNotNil(transported.entries[backing]?.preparationStatus)
        let published = try await source.currentState()
        XCTAssertNotNil(published.episodes.first { $0.id == backing }?.preparationStatus)
        XCTAssertNil(published.episodes.first { $0.id == ids[1] }?.preparationStatus)
        XCTAssertEqual(LibraryEpisodeAssociation.coherentGroups(in: published.episodes).count, 1)
        XCTAssertEqual(published.episodes.first { $0.id == backing }?.episodeAssociation?.representativeID, ids[1])
        let pending = WiltedMacPreparationPublication.Request(requestSequence: 31)
        let pendingSource = WiltedMacLocalLibraryStateSource(store: store, deviceID: "test", playback: { nil },
            localRequests: { [backing.rawValue: pending] })
        let suppressed = try await pendingSource.currentState()
        XCTAssertNil(suppressed.episodes.first { $0.id == backing }?.preparationStatus)
        let withdrawal = WiltedMacPreparationPublication.Request(requestSequence: nil, withdrawn: true)
        let withdrawnSource = WiltedMacLocalLibraryStateSource(store: store, deviceID: "test", playback: { nil },
            localRequests: { [backing.rawValue: withdrawal] })
        let withdrawn = try await withdrawnSource.currentState()
        XCTAssertNil(withdrawn.episodes.first { $0.id == backing }?.preparationStatus)
        let restarted = WiltedMacLocalLibraryStateSource(store: try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite")),
            deviceID: "test") { nil }
        let resumed = try await restarted.currentState()
        XCTAssertNotNil(resumed.episodes.first { $0.id == backing }?.preparationStatus)
        let requestID = PodcastPreparationPipeline.requestID(for: backing)
        let terminalID = requestID + "|" + attempt.key + "|terminal"
        let missingRevision = try RevisionID(rawValue: "missing-ready-proof")
        try await store.record(preparation: PreparationJournalEntry(id: terminalID, itemID: backing, requestID: requestID,
            status: PreparationStatus(stage: .completed, detail: "Prepared", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: missingRevision),
                emittedAt: now, attempt: attempt)))
        let missingProof = try await source.currentState()
        XCTAssertEqual(missingProof.episodes.first { $0.id == backing }?.preparationStatus?.detail,
                       "Prepared output is not yet confirmed.")
        let bytes = Data("owned prepared fixture".utf8)
        let media = directory.appendingPathComponent("prepared.mp3"); try bytes.write(to: media)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: backing, revisionID: RevisionID(rawValue: "proven-ready"),
            durationSeconds: 2, byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mpeg",
            createdAt: now, schemaVersion: 3)
        let outcome = PodcastPreparationOutcome(episodeID: backing, revisionID: revision.revisionID,
            policyDigest: "fixture", pipelineFingerprint: "fixture-pipeline", semanticVersion: "v1", producedAt: now)
        try await store.saveReadyRevision(revision, mediaURL: media,
            transcript: Transcript(itemID: backing, revisionID: revision.revisionID, availability: .available,
                text: "Prepared fixture", updatedAt: now), outcome: outcome)
        let mismatch = try await source.currentState()
        XCTAssertNotNil(mismatch.episodes.first { $0.id == backing }?.preparationStatus,
                        "A different Ready revision cannot clear this generation's success")
        try await store.record(preparation: PreparationJournalEntry(id: terminalID, itemID: backing, requestID: requestID,
            status: PreparationStatus(stage: .completed, detail: "Prepared", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: now, attempt: attempt)))
        _ = try await store.finishPreparationAttempt(subjectID: backing.rawValue, attempt: attempt, state: .succeeded, at: now)
        XCTAssertEqual(try Data(contentsOf: media), bytes)
        let finished = try await source.currentState()
        XCTAssertNil(finished.episodes.first { $0.id == backing }?.preparationStatus)
        _ = try await publisher.sync()
        let clearedTransport = await server.currentSnapshot
        XCTAssertNil(clearedTransport.entries[backing]?.preparationStatus)
    }

    @MainActor
    func testStaleTerminalCannotClearNewerAcknowledgedGeneration() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let current = WiltedMacPreparationPublication.Request(requestSequence: 8, acknowledged: true,
            attempt: try PreparationAttemptIdentity(requestSequence: 8, attemptCount: 2))
        model.preparationPublicationRequests["episode"] = current
        _ = await model.recordWorkTicketTransition(kind: .podcastPreparation, subjectID: "episode",
            requestSequence: 8, state: .failed,
            expectedAttempt: try PreparationAttemptIdentity(requestSequence: 8, attemptCount: 1), requiresAttempt: true)
        XCTAssertEqual(model.preparationPublicationRequests["episode"], current)
    }

    @MainActor
    func testActualRestartClosesCurrentAndSupersededGenerationsWithDistinctProcessorIDs() async throws {
        let directory = wiltedTemporaryDirectory("retained-generation-restart")
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: url)
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://example.test/restart.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let audio = URL(string: "https://example.test/restart.mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "restart", enclosureURL: audio)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Restart", createdAt: now))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
        try await store.save(episode: PodcastEpisode(itemID: itemID, feedID: feedID, feedURL: feedURL,
            rssGUID: "restart", title: "Restart", enclosureURL: audio, enclosureMediaType: "audio/mpeg", createdAt: now))
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        for sequence in 1...3 {
            let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: itemID.rawValue,
                requestSequence: sequence, to: .running, at: now)
            let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let terminal = sequence == 2 ? try PreparationTerminalResult(outcome: .failed,
                error: ProducerError(code: .failed, message: "existing failure", retryable: true)) : nil
            let status = try PreparationStatus(stage: sequence == 2 ? .failed : .extracting,
                detail: sequence == 2 ? "existing failure" : "interrupted work", cancellable: terminal == nil,
                terminalResult: terminal, emittedAt: Timestamp(now.date.addingTimeInterval(Double(sequence))), attempt: attempt)
            try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|" + (sequence == 2 ? "terminal" : "extracting#1"),
                itemID: itemID, requestID: requestID, status: status))
        }
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, invalidationRules: [],
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap(); await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        let runs = try await store.preparationRuns().filter { $0.requestID == requestID }
        XCTAssertEqual(runs.count, 3, "Restart must not create a phantom legacy generation")
        XCTAssertTrue(runs.allSatisfy(\.isTerminal))
        XCTAssertEqual(Set(runs.map(\.id)).count, 3)
        for run in runs {
            let attempt = try XCTUnwrap(run.entries.first?.status.attempt)
            XCTAssertTrue(run.entries.allSatisfy { $0.status.attempt == attempt })
            if attempt.requestSequence == 2 {
                XCTAssertEqual(run.entries.count, 1, "An existing terminal is append-only restart history")
            } else {
                XCTAssertEqual(run.entries.count, 2)
                XCTAssertEqual(run.entries.last?.status.terminalResult?.outcome, .failed)
                XCTAssertEqual(run.entries.last?.id, requestID + "|" + attempt.key + "|interrupted")
            }
        }
        model.refreshProcessorRuns()
        for _ in 0..<100 where model.processorRuns.filter({ $0.itemID == itemID.rawValue }).count != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let displayed = model.processorRuns.filter { $0.itemID == itemID.rawValue }
        XCTAssertEqual(displayed.count, 3)
        XCTAssertEqual(Set(displayed.map(\.id)), Set(runs.map(\.id)))
        XCTAssertFalse(displayed.contains { $0.outcome == .running })
    }

    @MainActor
    func testActualLibraryLoadProjectsNewestRetainedSequenceAndRecoveredAttemptWithoutDuplicateKeyCrash() async throws {
        let directory = wiltedTemporaryDirectory("retained-preparation-load")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://example.test/retained.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let audio = URL(string: "https://example.test/retained.mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "retained", enclosureURL: audio)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Retained", createdAt: now))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
        try await store.save(episode: PodcastEpisode(itemID: itemID, feedID: feedID, feedURL: feedURL,
            rssGUID: "retained", title: "Retained", enclosureURL: audio, enclosureMediaType: "audio/mpeg", createdAt: now))
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        let failure = try PreparationTerminalResult(outcome: .failed,
            error: ProducerError(code: .failed, message: "old failure", retryable: true))
        let legacy = try PreparationStatus(stage: .failed, detail: "legacy failure", cancellable: false,
            terminalResult: failure, emittedAt: Timestamp(now.date.addingTimeInterval(1_000)))
        try await store.record(preparation: .init(id: requestID + "|terminal", itemID: itemID,
            requestID: requestID, status: legacy))
        var ticket: WorkTicket?
        for sequence in 1...2 {
            let current = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: itemID.rawValue,
                requestSequence: sequence, to: .running, at: now)
            ticket = current
            let attempt = try PreparationAttemptIdentity(requestSequence: current.requestSequence, attemptCount: current.attemptCount)
            let status = try PreparationStatus(stage: .failed, detail: "older failed attempt", cancellable: false,
                terminalResult: failure, emittedAt: Timestamp(now.date.addingTimeInterval(Double(100 + sequence))), attempt: attempt)
            try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|terminal",
                itemID: itemID, requestID: requestID, status: status))
        }
        var recovered = try XCTUnwrap(ticket)
        recovered.attemptCount += 1
        recovered = try await store.upsertWorkTicket(recovered)
        let recoveredAttempt = try PreparationAttemptIdentity(requestSequence: recovered.requestSequence, attemptCount: recovered.attemptCount)
        let active = try PreparationStatus(stage: .extracting, detail: "current", cancellable: true,
            emittedAt: now, attempt: recoveredAttempt)
        try await store.record(preparation: .init(id: requestID + "|" + recoveredAttempt.key + "|extracting#1",
            itemID: itemID, requestID: requestID, status: active))
        let values = try await model.loadLibrary(from: store)
        let currentRow = try XCTUnwrap(values.episodes.first { $0.id == itemID.rawValue })
        XCTAssertEqual(currentRow.preparationState, .preparing(stage: "Preparing…"))
        let retained = try await store.preparationRuns()
        XCTAssertEqual(retained.filter { $0.itemID == itemID }.count, 4)
        let next = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: itemID.rawValue,
            requestSequence: 3, to: .running, at: now)
        let nextAttempt = try PreparationAttemptIdentity(requestSequence: next.requestSequence, attemptCount: next.attemptCount)
        let newestFailure = try PreparationStatus(stage: .failed, detail: "newest failure", cancellable: false,
            terminalResult: failure, emittedAt: now, attempt: nextAttempt)
        try await store.record(preparation: .init(id: requestID + "|" + nextAttempt.key + "|terminal",
            itemID: itemID, requestID: requestID, status: newestFailure))
        let failedValues = try await model.loadLibrary(from: store)
        let failedRow = try XCTUnwrap(failedValues.episodes.first { $0.id == itemID.rawValue })
        XCTAssertEqual(failedRow.preparationState, .failed(WiltedMacModel.preparationFailedLabel))
    }

    @MainActor
    func testUnacknowledgedAdmissionStopsBeforePipelineAndLeavesTruthfulRetryState() async throws {
        let directory = wiltedTemporaryDirectory("preparation-unacknowledged-admission")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.podcastPreparationPipeline = PodcastPreparationPipeline(store: store, workDirectory: directory)
        let itemID = try ItemID(rawValue: "unacknowledged-preparation")
        let episode = WiltedMacEpisode(id: itemID.rawValue, title: "Unsaved request", feedTitle: "Synthetic",
            summary: "", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 3, playbackSeconds: 0, downloadState: .completed)
        model.installEpisodeForTesting(episode)
        model.prepareEpisode(episode)
        await model.waitForPodcastPreparationOperationsForTesting()
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        let journal = try await store.preparationJournal(for: requestID)
        XCTAssertTrue(journal.isEmpty, "Even pipeline's missing-download terminal must not run before acknowledgement")
        let tickets = try await store.workTickets()
        XCTAssertTrue(tickets.isEmpty, "A failed acknowledgement cannot fabricate or terminalize a ticket")
        let failed = try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue })
        if case .failed(let detail) = failed.preparationState {
            XCTAssertTrue(detail.contains("could not start"))
        } else { XCTFail("Unstarted work must offer a truthful retry state") }
        XCTAssertEqual(model.preparationPublicationRequests[itemID.rawValue]?.needsReconciliation, true)
        XCTAssertNil(model.podcastPreparationTasks[itemID.rawValue])
        model.prepareEpisode(failed)
        await model.waitForPodcastPreparationOperationsForTesting()
        let afterRetry = try await store.preparationJournal(for: requestID)
        XCTAssertTrue(afterRetry.isEmpty)
    }

    @MainActor
    func testUnacknowledgedTerminalMarksReconciliationWithoutTouchingNewerPair() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.preparationPublicationRequests["episode"] = .init(requestSequence: 8)
        let skipped = await model.recordWorkTicketTransition(kind: .podcastPreparation, subjectID: "episode",
            requestSequence: 8, state: .failed, requiresAttempt: true)
        XCTAssertNil(skipped)
        XCTAssertEqual(model.preparationPublicationRequests["episode"]?.needsReconciliation, true)
        XCTAssertEqual(model.preparationPublicationRequests["episode"]?.acknowledged, false)
        let current = WiltedMacPreparationPublication.Request(requestSequence: 9, acknowledged: true,
            attempt: try PreparationAttemptIdentity(requestSequence: 9, attemptCount: 2))
        model.preparationPublicationRequests["episode"] = current
        _ = await model.recordWorkTicketTransition(kind: .podcastPreparation, subjectID: "episode",
            requestSequence: 8, state: .succeeded, requiresAttempt: true)
        XCTAssertEqual(model.preparationPublicationRequests["episode"], current)
    }

    func testDelayedSameSequenceAcknowledgmentCannotReplaceRecoveredPair() throws {
        let oldOperation = UUID()
        let now = Timestamp(Date())
        let current = WiltedMacPreparationPublication.Request(requestSequence: 8, acknowledged: true,
            attempt: try PreparationAttemptIdentity(requestSequence: 8, attemptCount: 2))
        let delayed = WorkTicket(kind: .podcastPreparation, subjectID: "episode", requestSequence: 8,
            state: .running, attemptCount: 1, requestedAt: now, updatedAt: now)
        XCTAssertEqual(current.acknowledging(delayed, operationID: oldOperation), current)
    }

    func testApprovedStageCountsSurviveButHostileDetailDoesNot() throws {
        let now = Timestamp(Date())
        for (detail, expected) in [("4 of 12 cues", true), ("4 of 12 cues /Users/owner/private", false),
                                   ("4 of 12 cues\n", false), ("4 of 12 cues\r\n", false)] {
            let journal = try PreparationStatus(stage: .extracting, detail: detail, cancellable: true,
                emittedAt: now, step: "transcript.glossary.progress")
            let status = try XCTUnwrap(WiltedMacPreparationPublication.status(.init(
                requestSequence: 2, attemptCount: 1, state: .running, updatedAt: now, status: journal)))
            XCTAssertEqual(status.detail.contains("4 of 12 cues"), expected)
            XCTAssertFalse(status.detail.contains("/Users"))
            XCTAssertEqual(status.stage, "transcript.glossary.progress")
        }
        for (detail, expected) in [("4 requests, 1 failed", true), ("4 requests, 1 failed\n", false)] {
            let journal = try PreparationStatus(stage: .assembling, detail: detail, cancellable: true,
                emittedAt: now, step: "ads.detect.calls")
            let status = try XCTUnwrap(WiltedMacPreparationPublication.status(.init(
                requestSequence: 2, attemptCount: 1, state: .running, updatedAt: now, status: journal)))
            XCTAssertEqual(status.detail.contains("4 requests, 1 failed"), expected)
            XCTAssertFalse(status.detail.contains("\n"))
        }
    }

    func testCuratedCurrentAttemptStatesNeverExposeWorkerPathsOrErrors() throws {
        let now = Timestamp(Date(timeIntervalSince1970: 100))
        let journal = try PreparationStatus(stage: .extracting, detail: "secret /Users/owner/private.wav error dump",
            fraction: 0.25, cancellable: true, emittedAt: now,
            attempt: PreparationAttemptIdentity(requestSequence: 11, attemptCount: 2))
        for (state, expected) in [(WorkTicketState.pending, LibraryPreparationStatus.State.queued),
            (.deferred, .queued), (.running, .active), (.failed, .failed), (.cancelled, .cancelled)] {
            let value = LocalLibraryStore.CurrentPreparationStatus(requestSequence: 11, attemptCount: 2,
                state: state, updatedAt: now, status: journal)
            let published = try XCTUnwrap(WiltedMacPreparationPublication.status(value))
            XCTAssertEqual(published.state, expected)
            XCTAssertEqual(published.attemptID, "generation-11-2")
            XCTAssertEqual(published.updatedAt, now.date)
            XCTAssertFalse(published.detail.contains("/"))
            XCTAssertFalse(published.detail.contains("secret"))
            XCTAssertNil(published.revisionID)
        }
        let unproven = WiltedMacPreparationPublication.status(.init(requestSequence: 11, attemptCount: 2,
            state: .succeeded, updatedAt: now, status: journal))
        XCTAssertEqual(unproven?.detail, "Prepared output is not yet confirmed.")
        XCTAssertEqual(unproven?.state, .active)
        XCTAssertNil(unproven?.revisionID)
        XCTAssertNil(WiltedMacPreparationPublication.status(.init(requestSequence: 11, attemptCount: 0,
            state: .running, updatedAt: now)))
    }

    @MainActor
    func testProcessorRefreshCoalescesChangesIntoOneLatestFollowUp() async throws {
        let fixture = try await makeProcessorRunsRefreshFixture(
            directoryName: "processor-refresh-coalesced", title: "Show", detail: "older status"
        )
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.store = fixture.store
        let gate = ProcessorRunsRefreshGate()
        model.processorRunsRefreshAfterRunsReadForTesting = { _, _ in await gate.holdFirstReadAfterReturn() }

        model.refreshProcessorRuns()
        await gate.waitUntilHeld()
        let newestStatus = try PreparationStatus(
            stage: .synthesizing, detail: "latest status", cancellable: true,
            emittedAt: Timestamp(fixture.emittedAt.date.addingTimeInterval(1))
        )
        try await fixture.store.record(preparation: .init(
            id: fixture.entryID, itemID: fixture.itemID, requestID: fixture.requestID, status: newestStatus
        ))
        model.refreshProcessorRuns()
        model.refreshProcessorRuns()
        model.refreshProcessorRuns()

        let refreshTask = try XCTUnwrap(model.processorRunsRefreshTask)
        gate.release()
        await refreshTask.value

        XCTAssertEqual(model.processorRunsRefreshReadCountForTesting, 2,
                       "overlapping refresh requests share one in-flight pass and one latest follow-up")
        XCTAssertEqual(model.processorRuns.count, 1)
        XCTAssertEqual(model.processorRuns.first?.detail, "latest status")
        XCTAssertEqual(model.processorRuns.first?.title, "Show")
        XCTAssertNil(model.processorRunsRefreshTask)
    }

    @MainActor
    func testProcessorRefreshDiscardsAReadFromAReplacedStore() async throws {
        let old = try await makeProcessorRunsRefreshFixture(
            directoryName: "processor-refresh-old-store", title: "Old title", detail: "stale store"
        )
        let current = try await makeProcessorRunsRefreshFixture(
            directoryName: "processor-refresh-new-store", title: "Current title", detail: "current store"
        )
        XCTAssertEqual(old.itemID, current.itemID)

        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.store = old.store
        let gate = ProcessorRunsRefreshGate()
        model.processorRunsRefreshAfterRunsReadForTesting = { _, _ in await gate.holdFirstReadAfterReturn() }

        model.refreshProcessorRuns()
        await gate.waitUntilHeld()
        model.store = current.store
        let refreshTask = try XCTUnwrap(model.processorRunsRefreshTask)
        gate.release()
        await refreshTask.value

        XCTAssertEqual(model.processorRunsRefreshReadCountForTesting, 2,
                       "the obsolete store result is discarded before refreshing the replacement")
        XCTAssertEqual(model.processorRuns.count, 1)
        XCTAssertEqual(model.processorRuns.first?.detail, "current store")
        XCTAssertEqual(model.processorRuns.first?.title, "Current title")
    }

    @MainActor
    func testCloseCancelsAndJoinsAProcessorRefreshHeldAfterItsRead() async throws {
        let fixture = try await makeProcessorRunsRefreshFixture(
            directoryName: "processor-refresh-close", title: "Show", detail: "held read"
        )
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.store = fixture.store
        let gate = ProcessorRunsRefreshGate()
        model.processorRunsRefreshAfterRunsReadForTesting = { _, _ in await gate.holdFirstReadAfterReturn() }

        model.refreshProcessorRuns()
        await gate.waitUntilHeld()
        let refreshTask = try XCTUnwrap(model.processorRunsRefreshTask)
        var didClose = false
        let closeTask = Task { @MainActor in
            await model.close()
            didClose = true
        }
        let closing = await waitUntil { model.isClosingTemporaryState }
        XCTAssertTrue(closing)
        XCTAssertTrue(refreshTask.isCancelled)
        XCTAssertFalse(didClose, "close must wait for the cancelled refresh to leave its held read")

        gate.release()
        await closeTask.value
        XCTAssertTrue(didClose)
        XCTAssertNil(model.processorRunsRefreshTask)
    }

    /// Runs that deferred themselves this session are parked by the drain
    /// tick: a stale one is skipped, a later request prepares while the
    /// earlier one waits, and once its time passes it starts exactly once.
    @MainActor
    func testRunDeferredInSessionWaitsForItsTimeWhileALaterRequestPreparesThenStartsOnce() async throws {
        let runner = DeferralRecordingRunner()
        let (model, store, ids) = try await deferralModel(["parked", "other", "stale"], runner: runner)
        let parked = ids["parked"]!, other = ids["other"]!, stale = ids["stale"]!
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let otherTime = now.addingTimeInterval(600), parkedTime = now.addingTimeInterval(3_600)
        var sequences: [String: Int] = [:]
        // Each run reached the worker and then deferred itself, in click order.
        for (id, until) in [(parked, parkedTime), (other, otherTime), (stale, otherTime)] {
            let sequence = model.nextPreparationRequestSequence()
            sequences[id] = sequence
            let running = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: id,
                requestSequence: sequence, policySnapshot: deferralSnapshot, to: .running, at: Timestamp(now))
            let deferred = try await store.deferRunningWorkTicket(subjectID: id, requestSequence: sequence,
                attemptCount: running.attemptCount, until: Timestamp(until), reason: .providerRateLimited)
            XCTAssertEqual(deferred?.state, .deferred)
        }
        // A newer request for `stale`, held in memory and not yet saved, makes its ticket stale.
        _ = model.reservePreparationRequest(for: stale)

        await model.parkDeferredPreparationTickets()
        await model.parkDeferredPreparationTickets()
        XCTAssertEqual(model.deferredAutomaticPreparations.map(\.episodeID).sorted(), [other, parked].sorted(),
                       "each current ticket parks once; the stale one not at all")
        XCTAssertEqual(model.deferredAutomaticPreparations.first { $0.episodeID == parked }?.notBefore, parkedTime)
        XCTAssertEqual(model.preparationQueue.entries.filter { $0.id == parked }.count, 1)
        XCTAssertTrue(model.podcastPreparationTasks.isEmpty)

        model.startEligibleAutomaticPreparations(at: otherTime.addingTimeInterval(1))
        XCTAssertNil(model.podcastPreparationTasks[parked], "a deferred ticket is skipped before its time")
        let otherStarts = try await waitForStarts(of: other, count: 1, runner: runner, model: model)
        XCTAssertEqual(otherStarts, 1, "a later request prepares while the earlier one waits")
        let parkedEarly = await runner.starts(of: parked)
        XCTAssertEqual(parkedEarly, 0)
        let waiting = try await store.workTicket(kind: .podcastPreparation, subjectID: parked)
        XCTAssertEqual(waiting?.state, .deferred)
        XCTAssertEqual(waiting?.attemptCount, 1)

        let after = parkedTime.addingTimeInterval(1)
        await model.parkDeferredPreparationTickets()
        model.startEligibleAutomaticPreparations(at: after)
        let parkedStarts = try await waitForStarts(of: parked, count: 1, runner: runner, model: model)
        XCTAssertEqual(parkedStarts, 1, "the next tick after its time starts it without owner action")
        let resumed = try await store.workTicket(kind: .podcastPreparation, subjectID: parked)
        XCTAssertEqual(resumed?.requestSequence, sequences[parked], "it resumes as the same request")
        XCTAssertEqual(resumed?.attemptCount, 2)
        await model.parkDeferredPreparationTickets()
        model.startEligibleAutomaticPreparations(at: after)
        await model.waitForPodcastPreparationOperationsForTesting()
        let repeated = await runner.starts(of: parked)
        XCTAssertEqual(repeated, 1, "a started ticket is not parked or started again")
        let staleStarts = await runner.starts(of: stale)
        XCTAssertEqual(staleStarts, 0)
        XCTAssertFalse(model.deferredAutomaticPreparations.contains { $0.episodeID == stale })
    }

    /// W-INV-036: a generation that went running and then deferred itself is
    /// waiting, not interrupted. A restart keeps it open and unpublished with
    /// its ticket deferred to the same time, prepares other work, and resumes
    /// it as the next generation of the same request once its wait ends.
    @MainActor
    func testRestartKeepsADeferredGenerationOpenAndUnpublishedUntilItsWaitEnds() async throws {
        let runner = DeferralRecordingRunner()
        let snapshot = deferralSnapshot
        let until = Timestamp(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3_600))
        let (model, store, ids) = try await deferralModel(["parked", "other"], runner: runner) { store, ids in
            let itemID = try ItemID(rawValue: ids["parked"]!)
            let now = Timestamp(Date())
            let running = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: itemID.rawValue,
                requestSequence: 5, policySnapshot: snapshot, to: .running, at: now)
            let attempt = try PreparationAttemptIdentity(requestSequence: 5, attemptCount: running.attemptCount)
            let requestID = PodcastPreparationPipeline.requestID(for: itemID)
            try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|extracting#1",
                itemID: itemID, requestID: requestID, status: PreparationStatus(stage: .extracting,
                    detail: "labelling", cancellable: true, emittedAt: now, attempt: attempt)))
            _ = try await store.deferRunningWorkTicket(subjectID: itemID.rawValue, requestSequence: 5,
                attemptCount: running.attemptCount, until: until, reason: .providerRateLimited, at: now)
            try await store.upsertWorkTicket(WorkTicket(kind: .podcastPreparation, subjectID: ids["other"]!,
                requestSequence: 6, state: .pending, policySnapshot: snapshot, requestedAt: now, updatedAt: now))
        }
        let parked = try ItemID(rawValue: ids["parked"]!)
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: parked.rawValue)
        XCTAssertEqual(ticket?.state, .deferred, "reconciliation keeps the ticket deferred")
        XCTAssertEqual(ticket?.nextEligibleAt, until)
        XCTAssertEqual(ticket?.attemptCount, 1)
        XCTAssertEqual(ticket?.deferralCount, 1)
        let requestID = PodcastPreparationPipeline.requestID(for: parked)
        let runs = try await store.preparationRuns().filter { $0.requestID == requestID }
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertFalse(run.isTerminal, "restart closure leaves the waiting generation open")
        XCTAssertEqual(run.entries.count, 1)
        XCTAssertFalse(run.entries.contains { $0.id.hasSuffix("|interrupted") })
        // The only Ready revision is the downloaded source; no prepared output exists.
        if let source = try await store.readyRevision(for: parked) {
            let outcome = try await store.preparationOutcome(for: parked, revisionID: source.revision.revisionID)
            XCTAssertNil(outcome)
        }
        XCTAssertEqual(model.episodes.first { $0.id == parked.rawValue }?.preparationState.isPrepared, false)
        let current = try await store.currentPreparationStatuses(for: [parked])[parked]
        XCTAssertEqual(current?.state, .deferred)
        let published = try XCTUnwrap(current.flatMap { WiltedMacPreparationPublication.status($0) })
        XCTAssertEqual(published.state, .waiting, "a provider wait is named, with no prepared revision")
        XCTAssertEqual(published.stage, "ads.label.wait")
        XCTAssertNil(published.revisionID)
        XCTAssertEqual(model.deferredAutomaticPreparations.first { $0.episodeID == parked.rawValue }?.notBefore,
                       until.date)
        XCTAssertNil(model.podcastPreparationTasks[parked.rawValue])
        let otherStarts = try await waitForStarts(of: ids["other"]!, count: 1, runner: runner, model: model)
        XCTAssertEqual(otherStarts, 1, "other work prepares while the deferred generation waits")
        let parkedEarly = await runner.starts(of: parked.rawValue)
        XCTAssertEqual(parkedEarly, 0)

        model.startEligibleAutomaticPreparations(at: until.date.addingTimeInterval(1))
        let parkedStarts = try await waitForStarts(of: parked.rawValue, count: 1, runner: runner, model: model)
        XCTAssertEqual(parkedStarts, 1)
        let resumed = try await store.workTicket(kind: .podcastPreparation, subjectID: parked.rawValue)
        XCTAssertEqual(resumed?.requestSequence, 5)
        XCTAssertEqual(resumed?.attemptCount, 2)
    }

    private var deferralSnapshot: Data {
        try! JSONEncoder().encode(PodcastPreparationPolicySnapshot(transcriptPolicy: .alwaysTranscribe, removeAds: false))
    }

    /// A live model over downloaded, kept episodes whose worker is `runner`;
    /// `seed` writes tickets and journal entries before bootstrap reads them.
    @MainActor
    private func deferralModel(
        _ names: [String], runner: DeferralRecordingRunner,
        seed: @escaping @Sendable (LocalLibraryStore, [String: String]) async throws -> Void = { _, _ in }
    ) async throws -> (WiltedMacModel, LocalLibraryStore, [String: String]) {
        let directory = wiltedTemporaryDirectory("preparation-deferral")
        let feedURL = URL(string: "https://example.test/preparation-deferral.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [String: String] = [:]
        for name in names {
            ids[name] = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: name,
                enclosureURL: URL(string: "https://example.test/\(name).mp3")!).rawValue
        }
        let episodeIDs = ids
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL,
                    title: "Deferral", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for name in names {
                    let id = try ItemID(rawValue: episodeIDs[name]!)
                    try await WiltedMacModelTests.addDownloadedUnpreparedEpisode(id, guid: name, feedID: feedID,
                        feedURL: feedURL, enclosureURL: URL(string: "https://example.test/\(name).mp3")!,
                        publishedAt: created.date, directory: directory, store: store, created: created)
                    try await store.addPodcastQueueEpisode(id)
                }
                try await seed(store, episodeIDs)
                return store
            }, podcastDownloadTransportFactory: {
                FailingPodcastDownloadTransport(enclosureURL: URL(string: "https://example.test/unused.mp3")!, statusCode: 404)
            }, podcastPipelineRunnerFactory: { runner }, pipelineFingerprintResolution: { nil },
            staleInvalidationOverride: { _, _ in PodcastPreparationInvalidationResult(forcedRedownloadEpisodeIDs: []) },
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.setAutomationSettings(WiltedAutomationSettings(refreshPolicy: .manual,
            downloadPolicy: .manual, processingPolicy: .manual, transcriptPolicy: .alwaysTranscribe, removeAds: true))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        return (model, try XCTUnwrap(model.store), ids)
    }

    /// Waits until `id`'s worker starts reach `count` and its run has left the task table.
    @MainActor
    private func waitForStarts(
        of id: String, count: Int, runner: DeferralRecordingRunner, model: WiltedMacModel
    ) async throws -> Int {
        var starts = await runner.starts(of: id)
        for _ in 0..<250 where starts < count || model.podcastPreparationTasks[id] != nil {
            try await Task.sleep(for: .milliseconds(20))
            starts = await runner.starts(of: id)
        }
        return starts
    }

    @MainActor
    private func makeProcessorRunsRefreshFixture(
        directoryName: String, title: String, detail: String
    ) async throws -> ProcessorRunsRefreshFixture {
        let directory = wiltedTemporaryDirectory(directoryName)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let articleURL = URL(string: "https://example.test/processor-refresh")!
        let itemID = try ItemID.derive(from: articleURL)
        let emittedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let article = try Article(
            itemID: itemID, canonicalURL: articleURL, title: title, source: "Example", createdAt: emittedAt
        )
        try await store.save(article: article)
        let requestID = "article-prepare|\(itemID.rawValue)"
        let entryID = requestID + "|extracting#1"
        let status = try PreparationStatus(
            stage: .extracting, detail: detail, cancellable: true, emittedAt: emittedAt
        )
        try await store.record(preparation: .init(
            id: entryID, itemID: itemID, requestID: requestID, status: status
        ))
        return ProcessorRunsRefreshFixture(
            store: store, itemID: itemID, requestID: requestID, entryID: entryID, emittedAt: emittedAt
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 2_000
    ) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

/// Records which episode each worker request named, then ends that run at
/// once, so the single preparation slot is free for the next one.
private actor DeferralRecordingRunner: PodcastPipelineRunning {
    private var episodeIDs: [String] = []

    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        let fields = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        episodeIDs.append(fields?["episodeID"] as? String ?? "")
        throw CancellationError()
    }

    func starts(of id: String) -> Int { episodeIDs.filter { $0 == id }.count }
}
