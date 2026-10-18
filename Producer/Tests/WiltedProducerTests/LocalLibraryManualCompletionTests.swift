import Foundation
import SwiftData
import SQLite3
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testLegacyGenuineCompletionPreservesSuppliedRevisionAndLeavesQueueAndDecisionsAlone() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        try await store.addPodcastQueueEpisode(episode.itemID)
        let prior = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep, source: .rule,
            ruleID: UUID(), decidedAt: episode.createdAt)
        try await store.save(episodeDecision: prior)
        let supplied = PodcastListeningState(episodeID: episode.itemID, completedAt: episode.createdAt,
            lastRevisionID: try RevisionID(rawValue: "genuine-revision"), updatedAt: episode.createdAt)
        let committed = try await store.completeAndRetireEpisode(listening: supplied, at: episode.createdAt)
        let listening = try await store.listeningState(for: episode.itemID)
        let queue = try await store.podcastQueueState()
        let decision = try await store.episodeDecision(for: episode.itemID)
        let receipt = try await store.restoreManualCompletion(episode.itemID)
        XCTAssertTrue(committed)
        XCTAssertEqual(listening, supplied)
        XCTAssertEqual(queue.episodeIDs, [episode.itemID])
        XCTAssertEqual(decision, prior)
        XCTAssertNil(receipt, "Genuine completion does not manufacture manual Undo provenance")
    }

    func testNewerManualKeepFencesLegacyPlaybackRetirementAcrossRelaunchButNotNewEOF() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        var store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        let revision = try podcastRevision(itemID: episode.itemID, id: "legacy-kept-revision", hashDigit: "c")
        let audio = url.deletingLastPathComponent().appendingPathComponent("legacy-kept.m4a")
        try Data(repeating: 0, count: Int(revision.byteCount)).write(to: audio)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: audio,
            download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: audio))
        let finishedAt = Timestamp(Date(timeIntervalSince1970: 1_700_001_000))
        let legacyPlayback = try PlaybackState(itemID: episode.itemID, revisionID: revision.revisionID,
            sessionID: "old-eof", sequence: 1, positionSeconds: 90, durationSeconds: 90,
            completed: true, intent: .progress, deviceID: "fixture-mac", updatedAt: finishedAt)
        try await store.save(playback: legacyPlayback)
        let keptAt = Timestamp(Date(timeIntervalSince1970: 1_700_002_000))
        _ = try await store.admitEpisode(EpisodeDecisionRecord(episodeID: episode.itemID,
            decision: .keep, source: .manual, ruleID: nil, decidedAt: keptAt))
        store = try LocalLibraryStore(url: url)
        try await store.reconcilePodcastStateV10()
        try await store.retireCompletedEpisodesMissingRetirement()
        let retained = try await store.removalKind(for: episode.itemID)
        let legacyListening = try await store.listeningState(for: episode.itemID)
        let savedPlayback = try await store.playbackState(for: episode.itemID, revisionID: revision.revisionID)
        XCTAssertNil(retained, "A newer manual Keep defeats old completed playback during bootstrap")
        XCTAssertEqual(legacyListening?.completedAt, finishedAt, "The genuine legacy completion remains recorded")
        XCTAssertEqual(legacyListening?.lastRevisionID, revision.revisionID)
        XCTAssertEqual(savedPlayback, legacyPlayback)
        let nextFinish = Timestamp(Date(timeIntervalSince1970: 1_700_003_000))
        try await store.saveListening(PodcastListeningState(episodeID: episode.itemID, completedAt: nextFinish,
            lastRevisionID: revision.revisionID, updatedAt: nextFinish))
        try await store.retireCompletedEpisodesMissingRetirement()
        let newlyRetired = try await store.removalKind(for: episode.itemID)
        XCTAssertEqual(newlyRetired, .retired, "The earlier Keep does not suppress a genuine later EOF")
    }

    func testBulkLegacyRestoreKeepsGenuineListeningAndCommitsNewOwnerKeepAtomically() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, first) = try podcastValues()
        let secondURL = URL(string: "https://podcasts.example.test/audio/second.mp3")!
        let second = try PodcastEpisode(itemID: ItemID.derivePodcastEpisode(feedURL: first.feedURL,
                rssGUID: "second", enclosureURL: secondURL), feedID: first.feedID, feedURL: first.feedURL,
            rssGUID: "second", title: "Second", enclosureURL: secondURL, enclosureMediaType: "audio/mpeg", createdAt: first.createdAt)
        var store = try LocalLibraryStore(url: url)
        var before: [ItemID: PodcastListeningState] = [:]
        for episode in [first, second] {
            try await store.save(episode: episode)
            let genuine = PodcastListeningState(episodeID: episode.itemID,
                completedAt: episode.createdAt, lastRevisionID: try RevisionID(rawValue: "genuine-\(episode.rssGUID ?? "episode")"),
                updatedAt: episode.createdAt)
            before[episode.itemID] = genuine
            _ = try await store.completeAndRetireEpisode(listening: genuine)
        }
        let restored = try await store.restoreEpisodes([first.itemID, second.itemID])
        XCTAssertEqual(restored.committed, [first.itemID, second.itemID])
        XCTAssertEqual(restored.atomicOwnerDecisionIDs, restored.committed,
            "Every legacy Restore commits Keep in its lifecycle save, requiring no later provenance mutation")
        XCTAssertEqual(restored.saveCount, 1)
        store = try LocalLibraryStore(url: url)
        for episode in [first, second] {
            let listening = try await store.listeningState(for: episode.itemID)
            let decision = try await store.episodeDecision(for: episode.itemID)
            let removal = try await store.removalKind(for: episode.itemID)
            XCTAssertEqual(listening, before[episode.itemID])
            XCTAssertEqual(decision?.decision, .keep)
            XCTAssertEqual(decision?.source, .manual)
            XCTAssertNil(decision?.ruleID)
            XCTAssertNil(removal)
        }
    }

    func testManualFinishRetainsAudioProgressAndRestoresExactProvenanceAfterRestart() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, episode) = try podcastValues()
        var store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed); try await store.save(episode: episode)
        let revision = try podcastRevision(itemID: episode.itemID, id: "manual-retained", hashDigit: "a")
        let audio = url.deletingLastPathComponent().appendingPathComponent("retained.m4a")
        try Data([1, 2, 3]).write(to: audio)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: audio,
            download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: audio))
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_004_000))
        let prior = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep,
            source: .rule, ruleID: UUID(), decidedAt: timestamp)
        try await store.save(episodeDecision: prior)
        let listening = PodcastListeningState(episodeID: episode.itemID, completedAt: nil,
            lastRevisionID: revision.revisionID, updatedAt: timestamp)
        try await store.saveListening(listening)
        let playback = try PlaybackState(itemID: episode.itemID, revisionID: revision.revisionID,
            sessionID: "manual-progress", sequence: 1, positionSeconds: 23, durationSeconds: 90,
            completed: false, intent: .progress, deviceID: "fixture-mac", updatedAt: timestamp)
        try await store.save(playback: playback)
        try await store.addPodcastQueueEpisode(episode.itemID, addedAt: timestamp)
        try await store.setCurrentPodcastQueueEpisode(episode.itemID)
        let queueBefore = try await store.queue()
        let totalsBefore = try await store.lifetimeStatistics()
        let result = try await store.manuallyCompleteEpisodes([episode.itemID], at: timestamp, localNow: timestamp.date)
        let removal = try await store.removalKind(for: episode.itemID)
        let queueAfter = try await store.podcastQueueState()
        let retained = try await store.readyRevision(for: episode.itemID)
        let totalsAfter = try await store.lifetimeStatistics()
        let playbackAfter = try await store.playbackState(for: episode.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(playbackAfter, playback, "Manual finish does not move the measured playhead")
        XCTAssertEqual(removal, .retired); XCTAssertTrue(queueAfter.episodeIDs.isEmpty)
        XCTAssertEqual(retained?.revisionID, revision.revisionID)
        XCTAssertEqual(totalsBefore, totalsAfter); XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        store = try LocalLibraryStore(url: url)
        let restored = try await store.undoManualCompletion(XCTUnwrap(result.operationID), at: timestamp.date)
        XCTAssertEqual(restored.committed, [episode.itemID])
        let decisionAfter = try await store.episodeDecision(for: episode.itemID)
        let listeningAfter = try await store.listeningState(for: episode.itemID)
        let restoredQueue = try await store.queue()
        let state = try await store.podcastQueueState()
        XCTAssertEqual(decisionAfter, prior); XCTAssertEqual(listeningAfter, listening)
        XCTAssertEqual(restoredQueue, queueBefore); XCTAssertEqual(state.currentEpisodeID, episode.itemID)
    }

    func testReceiptUndoKeepsNewerQueueEditsAndRefusesNewerDecisions() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        let first = try ItemID(rawValue: "before"), last = try ItemID(rawValue: "after"), added = try ItemID(rawValue: "added-later")
        try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: [first, episode.itemID, last], currentEpisodeID: nil))
        let receipt = try await store.manuallyCompleteEpisodes([episode.itemID])
        try await store.addPodcastQueueEpisode(added)
        let undo = try await store.undoManualCompletion(XCTUnwrap(receipt.operationID))
        XCTAssertEqual(undo.committed, [episode.itemID])
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, [first, episode.itemID, last, added])
        let second = try await store.manuallyCompleteEpisodes([episode.itemID])
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: episode.itemID,
            decision: .keep, source: .manual, ruleID: nil, decidedAt: Timestamp(Date().addingTimeInterval(1))))
        let conflict = try await store.undoManualCompletion(XCTUnwrap(second.operationID))
        XCTAssertEqual(conflict.unresolved, [episode.itemID]); XCTAssertTrue(conflict.committed.isEmpty)
        let retired = try await store.removalKind(for: episode.itemID)
        XCTAssertEqual(retired, .retired)
    }

    func testExplicitRestorePreservesPriorRealCompletionAndLegacyCompletion() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        let genuine = PodcastListeningState(episodeID: episode.itemID, completedAt: stamp,
            lastRevisionID: try RevisionID(rawValue: "real-eof"), updatedAt: stamp)
        try await store.saveListening(genuine)
        _ = try await store.manuallyCompleteEpisodes([episode.itemID], undoDuration: 0)
        let restored = try await store.restoreEpisode(episode.itemID)
        let listening = try await store.listeningState(for: episode.itemID)
        XCTAssertTrue(restored); XCTAssertEqual(listening, genuine)
        let restoredDecision = try await store.episodeDecision(for: episode.itemID)
        XCTAssertEqual(restoredDecision?.decision, .keep)
        XCTAssertEqual(restoredDecision?.source, .manual)
        _ = try await store.retireEpisode(episode.itemID)
        let legacyRestored = try await store.restoreEpisode(episode.itemID)
        let legacy = try await store.listeningState(for: episode.itemID)
        XCTAssertTrue(legacyRestored); XCTAssertEqual(legacy?.completedAt, stamp)
    }

    func testUndoAtNineSecondsAndDurableSealAtTenSecondsSurviveRestartAndClockRollback() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        var store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        try await store.addPodcastQueueEpisode(episode.itemID)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now), localNow: now)
        XCTAssertEqual(first.undoAvailableUntil, now.addingTimeInterval(10))
        store = try LocalLibraryStore(url: url)
        let atNine = try await store.undoManualCompletion(XCTUnwrap(first.operationID), at: now.addingTimeInterval(9))
        XCTAssertEqual(atNine.committed, [episode.itemID])
        let undoneCapacity = try await store.manualCompletionCapacityReservations(at: now)
        XCTAssertTrue(undoneCapacity.isEmpty)
        let second = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now), localNow: now)
        store = try LocalLibraryStore(url: url)
        let overdueCapacity = try await store.manualCompletionCapacityReservations(at: now.addingTimeInterval(11))
        XCTAssertEqual(overdueCapacity[episode.feedID], 1, "Overdue capacity remains reserved until sealing commits")
        let atTen = try await store.undoManualCompletion(XCTUnwrap(second.operationID), at: now.addingTimeInterval(10))
        XCTAssertTrue(atTen.committed.isEmpty)
        let compatibilityUndo = try await store.undoCompletedAndRetiredEpisode(episode.itemID, updatedAt: Timestamp(now.addingTimeInterval(10)))
        XCTAssertFalse(compatibilityUndo)
        let sealed = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(10))
        XCTAssertEqual(sealed, [episode.feedID])
        let repeated = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(10))
        XCTAssertTrue(repeated.isEmpty)
        store = try LocalLibraryStore(url: url)
        let rolledBack = try await store.undoManualCompletion(XCTUnwrap(second.operationID), at: now)
        let capacity = try await store.manualCompletionCapacityReservations(at: now)
        XCTAssertTrue(rolledBack.committed.isEmpty); XCTAssertTrue(capacity.isEmpty)
        let restored = try await store.restoreManualCompletion(episode.itemID)
        XCTAssertEqual(restored, true, "A later explicit owner Restore remains available")
    }

    func testAtomicAdmissionRejectsStaleRuleAndPolicyPlansUntilReceiptIsSealed() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        let waitingURL = URL(string: "https://example.test/waiting.mp3")!
        let waitingID = try ItemID.derivePodcastEpisode(feedURL: episode.feedURL, rssGUID: "waiting-capacity", enclosureURL: waitingURL)
        let waiting = try PodcastEpisode(itemID: waitingID, feedID: episode.feedID,
            feedURL: episode.feedURL, rssGUID: "waiting-capacity", title: "Waiting", publishedTime: episode.publishedTime,
            enclosureURL: waitingURL, enclosureMediaType: "audio/mpeg", createdAt: episode.createdAt)
        try await store.save(episode: waiting)
        try await store.addPodcastQueueEpisode(episode.itemID)
        try await store.save(feedAutomationPolicy: .init(autoKeep: .on, keptLimit: .explicit(1)), for: episode.feedID)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now), localNow: now)
        for source in [EpisodeDecisionSource.rule, .policy] {
            do {
                _ = try await store.admitEpisode(.init(episodeID: waiting.itemID, decision: .keep, source: source,
                    decidedAt: Timestamp(now)), workTicketKinds: [.podcastDownload], requestedAt: Timestamp(now.addingTimeInterval(11)))
                XCTFail("A stale request must not use unsealed capacity")
            } catch AutomaticEpisodeAdmissionError.capacityUnavailable {}
        }
        let before = try await store.workTickets()
        XCTAssertTrue(before.isEmpty)
        _ = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(10))
        _ = try await store.admitEpisode(.init(episodeID: waiting.itemID, decision: .keep, source: .policy,
            decidedAt: Timestamp(now)), workTicketKinds: [.podcastDownload])
        let restored = try await store.restoreManualCompletion(episode.itemID)
        XCTAssertEqual(restored, true)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.count, 2, "Explicit Restore can exceed the ceiling without eviction")
    }

    func testAutomaticReadmissionCountsOnlyOtherKeepsAndDistinguishesStalePlans() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode)
        let otherURL = URL(string: "https://example.test/other.mp3")!
        let otherID = try ItemID.derivePodcastEpisode(feedURL: episode.feedURL,
            rssGUID: "readmission-other", enclosureURL: otherURL)
        let other = try PodcastEpisode(itemID: otherID, feedID: episode.feedID,
            feedURL: episode.feedURL, rssGUID: "readmission-other", title: "Other", publishedTime: episode.publishedTime,
            enclosureURL: otherURL, enclosureMediaType: "audio/mpeg", createdAt: episode.createdAt)
        try await store.save(episode: other)
        try await store.save(feedAutomationPolicy: .init(autoKeep: .on, keptLimit: .explicit(2)), for: episode.feedID)
        _ = try await store.admitEpisode(.init(episodeID: other.itemID, decision: .keep, source: .manual, decidedAt: episode.createdAt))
        for source in [EpisodeDecisionSource.policy, .rule] {
            try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: [other.itemID], currentEpisodeID: nil))
            try await store.save(episodeDecision: .init(episodeID: episode.itemID, decision: .keep, source: source, decidedAt: episode.createdAt))
            _ = try await store.admitEpisode(.init(episodeID: episode.itemID, decision: .keep, source: source, decidedAt: episode.createdAt))
            let queue = try await store.podcastQueueState()
            XCTAssertEqual(queue.episodeIDs, [other.itemID, episode.itemID], "N-1 other keeps leave one slot for readmission")
        }
        do {
            _ = try await store.admitEpisode(.init(episodeID: other.itemID, decision: .keep, source: .policy, decidedAt: episode.createdAt))
            XCTFail("A manual choice must reject a stale automatic plan")
        } catch let error as AutomaticEpisodeAdmissionError { XCTAssertEqual(error, .manualDecisionExists) }
        do {
            _ = try await store.admitEpisode(.init(episodeID: ItemID(rawValue: "missing-readmission"), decision: .keep, source: .policy, decidedAt: episode.createdAt))
            XCTFail("A missing episode must reject a stale automatic plan")
        } catch let error as AutomaticEpisodeAdmissionError { XCTAssertEqual(error, .episodeUnavailable) }
    }

    func testReservationScanDoesNotDecodeSealedLifetimeReceipts() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let context = ModelContext(store.container)
        context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(operationID: UUID(),
            createdAt: Date(), undoAvailableUntil: .distantPast, members: Data("unreadable historical payload".utf8)))
        try context.save()
        let reservations = try await store.manualCompletionCapacityReservations()
        let pending = try await store.pendingManualCompletionWindows()
        let sealed = try await store.sealExpiredManualCompletions()
        XCTAssertTrue(reservations.isEmpty); XCTAssertTrue(pending.isEmpty); XCTAssertTrue(sealed.isEmpty)
    }

    func testReadOnlySaveFailureAndWritableControlsPreserveTheCompletionContractAfterReopen() async throws {
        for priorDecisionExists in [false, true] {
            for readOnly in [false, true] {
                let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let (_, episode) = try podcastValues()
                var store = try LocalLibraryStore(url: url)
                try await store.save(episode: episode)
                let stamp = Timestamp(Date(timeIntervalSince1970: 1_800_000_000))
                let revision = try podcastRevision(itemID: episode.itemID, id: "readonly-retained", hashDigit: "d")
                let audio = url.deletingLastPathComponent().appendingPathComponent("readonly-retained.m4a")
                let bytes = Data([1, 2, 3, 4])
                try bytes.write(to: audio)
                try await store.finalizePodcastDownload(revision: revision, mediaURL: audio,
                    download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: audio))
                let listening = PodcastListeningState(episodeID: episode.itemID, completedAt: nil,
                    lastRevisionID: revision.revisionID, updatedAt: episode.createdAt)
                try await store.saveListening(listening)
                let prior = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep,
                    source: .rule, ruleID: UUID(), decidedAt: episode.createdAt)
                if priorDecisionExists { try await store.save(episodeDecision: prior) }
                let before = try ItemID(rawValue: "readonly-before"), after = try ItemID(rawValue: "readonly-after")
                let queue = try PodcastQueueState(episodeIDs: [before, episode.itemID, after], currentEpisodeID: episode.itemID)
                try await store.replacePodcastQueue(queue, addedAt: episode.createdAt)
                let queueEntries = try await store.queue()
                let playback = try PlaybackState(itemID: episode.itemID, revisionID: revision.revisionID,
                    sessionID: "readonly-progress", sequence: 1, positionSeconds: 23, durationSeconds: 90,
                    completed: false, intent: .progress, deviceID: "fixture-mac", updatedAt: episode.createdAt)
                try await store.save(playback: playback)
                _ = try await store.recordLifetimeStatistic(id: "readonly-measured", kind: .speechGenerated, seconds: 5)
                let totals = try await store.lifetimeStatistics()
                let staged = expectation(description: "All completion writes staged before the real save")
                var result: PodcastManualCompletionResult?
                do {
                    result = try await store.stageManualCompletion([episode.itemID], at: stamp, undoDuration: 10,
                        beforeSave: { staged.fulfill() }, contextFactory: {
                            let schema = Schema(versionedSchema: LocalLibraryCurrentSchema.self)
                            let configuration = ModelConfiguration("fault-qualification", schema: schema, url: url,
                                allowsSave: !readOnly, cloudKitDatabase: .none)
                            let container = try ModelContainer(for: schema, configurations: [configuration])
                            return ModelContext(container)
                        })
                    XCTAssertFalse(readOnly, "The real read-only context.save must reject the staged transaction")
                } catch { if !readOnly { throw error } }
                await fulfillment(of: [staged], timeout: 0.1)
                store = try LocalLibraryStore(url: url)
                // Inspect durable receipts with a fresh context, not the writer's registered objects.
                let context = ModelContext(store.container)
                let receipts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
                let currentListening = try await store.listeningState(for: episode.itemID)
                let currentDecision = try await store.episodeDecision(for: episode.itemID)
                let currentRemoval = try await store.removalKind(for: episode.itemID)
                let currentRetiredAt = try await store.retiredAt(for: episode.itemID)
                let currentEntries = try await store.queue()
                let currentQueue = try await store.podcastQueueState()
                let capacity = try await store.manualCompletionCapacityReservations(at: stamp.date)
                if readOnly {
                    XCTAssertNil(result); XCTAssertTrue(receipts.isEmpty); XCTAssertTrue(capacity.isEmpty)
                    XCTAssertEqual(currentListening, listening); XCTAssertEqual(currentDecision, priorDecisionExists ? prior : nil)
                    XCTAssertNil(currentRemoval); XCTAssertNil(currentRetiredAt)
                    XCTAssertEqual(currentQueue, queue); XCTAssertEqual(currentEntries, queueEntries)
                } else {
                    let completion = try XCTUnwrap(result)
                    XCTAssertEqual(completion.committed, [episode.itemID]); XCTAssertEqual(receipts.count, 1)
                    XCTAssertEqual(receipts.first?.operationID, completion.operationID)
                    XCTAssertEqual(currentListening?.completedAt, stamp); XCTAssertEqual(currentListening?.lastRevisionID, revision.revisionID)
                    XCTAssertEqual(currentDecision?.decision, .skip); XCTAssertEqual(currentDecision?.source, .manual)
                    XCTAssertEqual(currentRemoval, .retired); XCTAssertEqual(currentRetiredAt, stamp)
                    XCTAssertEqual(currentQueue.episodeIDs, [before, after])
                    XCTAssertEqual(capacity[episode.feedID], 1)
                    let undone = try await store.undoManualCompletion(XCTUnwrap(completion.operationID), at: stamp.date)
                    XCTAssertEqual(undone.committed, [episode.itemID])
                    let restoredListening = try await store.listeningState(for: episode.itemID)
                    let restoredDecision = try await store.episodeDecision(for: episode.itemID)
                    let restoredQueue = try await store.podcastQueueState()
                    let restoredEntries = try await store.queue()
                    XCTAssertEqual(restoredListening, listening); XCTAssertEqual(restoredDecision, priorDecisionExists ? prior : nil)
                    XCTAssertEqual(restoredQueue, queue); XCTAssertEqual(restoredEntries, queueEntries)
                    _ = try await store.manuallyCompleteEpisodes([episode.itemID], at: stamp, localNow: stamp.date)
                    store = try LocalLibraryStore(url: url)
                    let explicit = try await store.restoreManualCompletion(episode.itemID)
                    let owner = try await store.episodeDecision(for: episode.itemID)
                    XCTAssertEqual(explicit, true); XCTAssertEqual(owner?.decision, .keep); XCTAssertEqual(owner?.source, .manual)
                }
                let currentPlayback = try await store.playbackState(for: episode.itemID, revisionID: revision.revisionID)
                let currentTotals = try await store.lifetimeStatistics()
                let retained = try await store.readyRevision(for: episode.itemID)
                XCTAssertEqual(currentPlayback, playback); XCTAssertEqual(currentTotals, totals)
                XCTAssertEqual(retained?.revisionID, revision.revisionID); XCTAssertEqual(try Data(contentsOf: audio), bytes)
            }
        }
    }

    func testSQLDecisionWriteFailureRollsBackCompletionAndReceiptAtomically() async throws {
        guard ProcessInfo.processInfo.environment["WILTED_UNSUPPORTED_SQL_TRIGGER_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Opt-in only: native SQLite trigger mutation violates Apple's Core Data store contract and can crash unique-key reconciliation")
        }
        for priorDecisionExists in [false, true] {
            let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (_, episode) = try podcastValues()
            var store = try LocalLibraryStore(url: url)
            try await store.save(episode: episode)
            try await store.addPodcastQueueEpisode(episode.itemID)
            let prior = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep,
                source: .rule, decidedAt: episode.createdAt)
            if priorDecisionExists { try await store.save(episodeDecision: prior) }
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                if let database { sqlite3_close(database) }
                throw NSError(domain: "CompletionAtomicityFixture", code: 1)
            }
            let sql = """
                CREATE TRIGGER reject_completion_insert BEFORE INSERT ON ZEPISODEDECISIONRECORD
                WHEN NEW.ZSOURCE = 'manual' BEGIN SELECT RAISE(ABORT, 'fixture decision failure'); END;
                CREATE TRIGGER reject_completion_update BEFORE UPDATE ON ZEPISODEDECISIONRECORD
                WHEN NEW.ZSOURCE = 'manual' BEGIN SELECT RAISE(ABORT, 'fixture decision failure'); END;
                """
            let installed = sqlite3_exec(database, sql, nil, nil, nil)
            sqlite3_close(database)
            XCTAssertEqual(installed, SQLITE_OK, "The failure must attach to the real migrated decision table")
            do {
                _ = try await store.manuallyCompleteEpisodes([episode.itemID])
                XCTFail("A rejected manual decision must fail the entire completion transaction")
            } catch {}
            store = try LocalLibraryStore(url: url)
            let listening = try await store.listeningState(for: episode.itemID)
            let decision = try await store.episodeDecision(for: episode.itemID)
            let removal = try await store.removalKind(for: episode.itemID)
            let queue = try await store.podcastQueueState()
            let windows = try await store.pendingManualCompletionWindows()
            XCTAssertNil(listening); XCTAssertNil(removal); XCTAssertTrue(windows.isEmpty)
            XCTAssertEqual(decision, priorDecisionExists ? prior : nil)
            XCTAssertEqual(queue.episodeIDs, [episode.itemID])
        }
    }

    func testManualCompletionBeforeSaveCancellationDiscardsEveryStagedFieldAndReceipt() async throws {
        struct Failure: Error {}
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(episode: episode); try await store.addPodcastQueueEpisode(episode.itemID)
        do {
            _ = try await store.stageManualCompletion([episode.itemID], at: Timestamp(Date()),
                undoDuration: 30, beforeSave: { throw Failure() })
            XCTFail("Injected failure must throw")
        } catch is Failure {}
        let listening = try await store.listeningState(for: episode.itemID)
        let decision = try await store.episodeDecision(for: episode.itemID)
        let removal = try await store.removalKind(for: episode.itemID)
        let queue = try await store.podcastQueueState()
        XCTAssertNil(listening); XCTAssertNil(decision); XCTAssertNil(removal)
        XCTAssertEqual(queue.episodeIDs, [episode.itemID])
        let restored = try await store.restoreManualCompletion(episode.itemID)
        XCTAssertNil(restored)
    }
}


extension LocalLibraryStoreTests {
    private func completionAliasPair(in store: LocalLibraryStore) async throws -> (PodcastEpisode, PodcastEpisode) {
        let (_, first) = try podcastValues()
        let enclosure = URL(string: "https://podcasts.example.test/audio/completion-alias.mp3")!
        let second = try PodcastEpisode(itemID: ItemID.derivePodcastEpisode(feedURL: first.feedURL,
            rssGUID: "completion-alias", enclosureURL: enclosure), feedID: first.feedID, feedURL: first.feedURL,
            rssGUID: "completion-alias", title: "Alias backing", enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", createdAt: first.createdAt)
        for episode in [first, second] {
            try await store.save(episode: episode)
            try await store.addPodcastQueueEpisode(episode.itemID)
        }
        let confirmation = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: first.feedID,
            first: first.itemID, second: second.itemID, confirmedAt: first.createdAt)
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: first.itemID)
        _ = try await store.applyEpisodeAssociation(preview, at: first.createdAt)
        return (first, second)
    }

    func testAliasFinishReservesOneSlotAndUndoRestoresAllRawPlacementAndGenuineHistory() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        for (index, episode) in [first, second].enumerated() {
            let revision = try podcastRevision(itemID: episode.itemID, id: "receipt-backing-\(index)", hashDigit: "a")
            let media = url.deletingLastPathComponent().appendingPathComponent("receipt-backing-\(index).m4a")
            try Data(repeating: 17, count: Int(revision.byteCount)).write(to: media)
            try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
                download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: media))
            try await store.save(playback: PlaybackState(itemID: episode.itemID, revisionID: revision.revisionID,
                sessionID: "receipt-backing", sequence: 1, positionSeconds: Double(30 + index * 40),
                durationSeconds: 90, completed: false, intent: .progress, deviceID: "synthetic", updatedAt: first.createdAt))
        }
        let genuine = PodcastListeningState(episodeID: first.itemID, completedAt: first.createdAt,
            lastRevisionID: try RevisionID(rawValue: "genuine-before-group-finish"), updatedAt: first.createdAt)
        try await store.saveListening(genuine)
        try await store.setCurrentPodcastQueueEpisode(second.itemID)
        let before = try await store.podcastLibrarySnapshot()
        let at = first.createdAt.date.addingTimeInterval(10)
        let result = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(at), localNow: at)
        XCTAssertEqual(Set(result.committed), [first.itemID, second.itemID])
        let reserved = try await store.manualCompletionCapacityReservations(at: at)
        XCTAssertEqual(reserved[first.feedID], 1)
        let finishedQueue = try await store.podcastQueueState()
        XCTAssertTrue(finishedQueue.episodeIDs.isEmpty)
        store = try LocalLibraryStore(url: url)
        let restored = try await store.undoManualCompletion(XCTUnwrap(result.operationID), at: at.addingTimeInterval(9))
        XCTAssertEqual(Set(restored.committed), [first.itemID, second.itemID])
        let after = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(after.podcastQueue, before.podcastQueue)
        XCTAssertEqual(after.listeningStates, before.listeningStates)
        XCTAssertEqual(after.playbackStates, before.playbackStates)
        XCTAssertEqual(after.readyRevisions, before.readyRevisions)
        XCTAssertEqual(after.downloads, before.downloads)
        for revision in after.readyRevisions.values { XCTAssertTrue(FileManager.default.fileExists(atPath: revision.mediaURL.path)) }
    }

    func testAliasFinishRollbackAndNewerGroupChoiceFenceEveryMember() async throws {
        enum SyntheticFailure: Error { case beforeSave }
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        let at = first.createdAt.date.addingTimeInterval(10)
        do {
            _ = try await store.stageManualCompletion([first.itemID], at: Timestamp(at), undoDuration: 10,
                beforeSave: { throw SyntheticFailure.beforeSave })
            XCTFail("Expected synthetic rollback")
        } catch SyntheticFailure.beforeSave {}
        let unchanged = try await store.podcastQueueState()
        XCTAssertEqual(unchanged.episodeIDs, [first.itemID, second.itemID])
        _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(at.addingTimeInterval(20))))
        let refused = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(at), localNow: at)
        XCTAssertTrue(refused.committed.isEmpty)
        XCTAssertEqual(Set(refused.unresolved), [first.itemID, second.itemID])
        let firstRemoval = try await store.removalKind(for: first.itemID)
        let secondRemoval = try await store.removalKind(for: second.itemID)
        XCTAssertNil(firstRemoval)
        XCTAssertNil(secondRemoval)
    }

    func testOldRawRestoreRestoresWholeReceiptAtOriginalTimeAndEqualKeepWins() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        let at = first.createdAt.date.addingTimeInterval(10)
        _ = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(at), localNow: at)
        let restoredAt = at.addingTimeInterval(20)
        let restored = try await store.restoreEpisode(second.itemID, at: restoredAt)
        XCTAssertTrue(restored)
        for id in [first.itemID, second.itemID] {
            let decision = try await store.episodeDecision(for: id)
            XCTAssertEqual(decision?.decision, .keep)
            XCTAssertEqual(decision?.decidedAt.date, restoredAt)
            let removal = try await store.removalKind(for: id)
            XCTAssertNil(removal)
        }
        let equalSkip = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(restoredAt), localNow: restoredAt)
        XCTAssertTrue(equalSkip.committed.isEmpty)
        let state = try await store.podcastEpisodeLogicalState(for: second.itemID)
        XCTAssertEqual(state?.manualDecision, .keep)
        XCTAssertEqual(state?.hasConflictingManualChoices, true)
        let restoredQueue = try await store.podcastQueueState()
        XCTAssertEqual(restoredQueue.episodeIDs, [first.itemID, second.itemID])
    }
}


extension LocalLibraryStoreTests {
    func testNewerChoiceAfterGroupFinishBlocksWholeUndoWithoutRestoringOneSibling() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        let at = first.createdAt.date.addingTimeInterval(10)
        let finish = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(at), localNow: at)
        _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(at.addingTimeInterval(5))))
        let undo = try await store.undoManualCompletion(XCTUnwrap(finish.operationID), at: at.addingTimeInterval(9))
        XCTAssertTrue(undo.committed.isEmpty)
        XCTAssertEqual(Set(undo.unresolved), [first.itemID, second.itemID])
        let queue = try await store.podcastQueueState()
        XCTAssertTrue(queue.episodeIDs.isEmpty)
        let newer = try await store.episodeDecision(for: second.itemID)
        XCTAssertEqual(newer?.decision, .keep)
        XCTAssertEqual(newer?.decidedAt.date, at.addingTimeInterval(5))
    }
}


extension LocalLibraryStoreTests {
    func testAutomaticCapacityCountsRetainedAliasQueueAsOneLogicalSlot() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        var additions: [ItemID] = []
        for guid in ["capacity-C", "capacity-D"] {
            let enclosure = URL(string: "https://podcasts.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: first.feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: PodcastEpisode(itemID: id, feedID: first.feedID, feedURL: first.feedURL,
                rssGUID: guid, title: guid, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: first.createdAt))
            additions.append(id)
        }
        _ = try await store.admitEpisode(EpisodeDecisionRecord(episodeID: additions[0], decision: .keep,
            source: .rule, ruleID: UUID(), decidedAt: first.createdAt), automaticKeptLimit: 2)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, [first.itemID, second.itemID, additions[0]], "Raw alias transport slots remain")
        do {
            _ = try await store.admitEpisode(EpisodeDecisionRecord(episodeID: additions[1], decision: .keep,
                source: .rule, ruleID: UUID(), decidedAt: first.createdAt), automaticKeptLimit: 2)
            XCTFail("Two logical slots already fill the capacity")
        } catch AutomaticEpisodeAdmissionError.capacityUnavailable {}
    }
}


extension LocalLibraryStoreTests {
    func testGroupFeedSkipGuardsOriginatingChoiceBeforeRetirementAndRetainsBackingMedia() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        let revision = try podcastRevision(itemID: first.itemID, id: "feed-skip-retained", hashDigit: "a")
        let media = url.deletingLastPathComponent().appendingPathComponent("feed-skip-retained.m4a")
        try Data(repeating: 17, count: Int(revision.byteCount)).write(to: media)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
            download: completedPodcastDownload(episodeID: first.itemID, revision: revision, mediaURL: media))
        let keptAt = first.createdAt.date.addingTimeInterval(20)
        _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(keptAt)))
        let refused = try await store.retireEpisodes([first.itemID], at: first.createdAt, asOwnerChoice: true)
        XCTAssertTrue(refused.committed.isEmpty)
        XCTAssertEqual(Set(refused.unresolved), [first.itemID, second.itemID])
        let skipAt = keptAt.addingTimeInterval(10)
        let skipped = try await store.retireEpisodes([first.itemID], at: Timestamp(skipAt), asOwnerChoice: true)
        XCTAssertEqual(Set(skipped.committed), [first.itemID, second.itemID])
        XCTAssertEqual(skipped.mediaRecordFetchCount, 0)
        let retained = try await store.readyRevision(for: first.itemID)
        XCTAssertEqual(retained?.revision, revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        let listening = try await store.listeningState(for: first.itemID)
        XCTAssertNil(listening, "Feeds Skip does not invent a listening completion")
    }
}


extension LocalLibraryStoreTests {
    func testFreshLocalRestoreFollowsRetainedClockButExplicitOldPhoneRestoreStaysGuarded() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (first, second) = try await completionAliasPair(in: store)
        let future = Date(timeIntervalSince1970: 1_900_000_000.123_45)
        _ = try await store.manuallyCompleteEpisodes([first.itemID], at: Timestamp(future), localNow: future)
        let local = try await store.restoreManualCompletion(second.itemID)
        XCTAssertEqual(local, true)
        let recordedChoice = try await store.episodeDecision(for: second.itemID)
        let choice = try XCTUnwrap(recordedChoice)
        XCTAssertGreaterThan(choice.decidedAt.date, future)
        let encoded = try JSONEncoder().encode(choice.decidedAt)
        let decoded = try JSONDecoder().decode(Timestamp.self, from: encoded)
        XCTAssertGreaterThan(decoded.date, future, "The fresh ordering increment survives Timestamp's millisecond wire codec")
        let laterFinish = future.addingTimeInterval(10)
        _ = try await store.manuallyCompleteEpisodes([second.itemID], at: Timestamp(laterFinish), localNow: laterFinish)
        let oldPhoneAt = future.addingTimeInterval(9)
        let oldPhone = try await store.restoreManualCompletion(first.itemID, at: oldPhoneAt)
        XCTAssertEqual(oldPhone, false)
        let retained = try await store.episodeDecision(for: first.itemID)
        XCTAssertEqual(retained?.decision, .skip)
        XCTAssertEqual(retained?.decidedAt.date, laterFinish)
    }
}


extension LocalLibraryStoreTests {
    func testSameClockFreshLocalSkipFollowsKeepWithoutExtendingUndoAndDatedTieKeeps() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        try await store.save(episode: episode)
        try await store.addPodcastQueueEpisode(episode.itemID)
        let actionAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: episode.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(actionAt)))
        let first = try await store.manuallyCompleteEpisodes([episode.itemID], localNow: actionAt)
        XCTAssertEqual(first.committed, [episode.itemID])
        XCTAssertEqual(first.undoAvailableUntil, actionAt.addingTimeInterval(10))
        let choice = try await store.episodeDecision(for: episode.itemID)
        XCTAssertEqual(choice?.decision, .skip)
        XCTAssertGreaterThan(try XCTUnwrap(choice?.decidedAt.date), actionAt)
        let atNine = try await store.undoManualCompletion(XCTUnwrap(first.operationID), at: actionAt.addingTimeInterval(9))
        XCTAssertEqual(atNine.committed, [episode.itemID])
        let phoneTie = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(actionAt), localNow: actionAt)
        XCTAssertTrue(phoneTie.committed.isEmpty, "Explicit dated equal-time Skip cannot replace Keep")
        let retainedKeep = try await store.episodeDecision(for: episode.itemID)
        XCTAssertEqual(retainedKeep?.decision, .keep)
        let second = try await store.manuallyCompleteEpisodes([episode.itemID], localNow: actionAt)
        XCTAssertEqual(second.undoAvailableUntil, actionAt.addingTimeInterval(10))
        let atTen = try await store.undoManualCompletion(XCTUnwrap(second.operationID), at: actionAt.addingTimeInterval(10))
        XCTAssertTrue(atTen.committed.isEmpty)
        _ = try await store.sealExpiredManualCompletions(at: actionAt.addingTimeInterval(10))
        let capacity = try await store.manualCompletionCapacityReservations(at: actionAt.addingTimeInterval(10))
        XCTAssertTrue(capacity.isEmpty)
    }
}
