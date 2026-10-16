import Foundation
import CryptoKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

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
}
