import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac


// MARK: - Through the real model

private struct ModelRig {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let episodes: [ItemID]
}

extension WiltedMacIntentApplierTests {
    /// Four episodes on one feed; the first two are in the Larder, in order.
    private func modelRig(_ name: String) async throws -> ModelRig {
        let feedURL = URL(string: "https://feeds.example.test/applier.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let episodeIDs = try (0..<4).map { index in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "episode-\(index)",
                enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!
            )
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Applier feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, itemID) in episodeIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-\(index)",
                        title: "Episode \(index)", publishedTime: created,
                        enclosureURL: URL(string: "https://media.example.test/episode-\(index).mp3")!,
                        enclosureMediaType: "audio/mpeg", createdAt: created
                    ))
                }
                try await store.replacePodcastQueue(try PodcastQueueState(
                    episodeIDs: [episodeIDs[0], episodeIDs[1]], currentEpisodeID: episodeIDs[0]
                ))
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await MainActor.run { model.stopLibrarySync() }; await model.close() }
        return ModelRig(model: model, store: try XCTUnwrap(model.store), episodes: episodeIDs)
    }

    func testDatedLegacySkipSeparatesFeedsRetirementFromQueuedCompletion() async throws {
        let rig = try await modelRig("applier-feed-versus-queued-skip")
        let at = Date(timeIntervalSince1970: 1_700_002_000)
        let feedID = rig.episodes[2], queuedID = rig.episodes[1]
        let feedResult = await rig.model.applyOwnerIntent(try LibraryIntent.skip(entryID: feedID,
            deviceID: "iphone", createdAt: at, id: "feed-skip"))
        if case .applied? = feedResult {} else { XCTFail("Feed Skip must apply") }
        let feedListening = try await rig.store.listeningState(for: feedID)
        XCTAssertNil(feedListening, "A Feed Skip is not listening completion")
        let feedReceipt = try await rig.store.restoreManualCompletion(feedID, at: at.addingTimeInterval(1))
        XCTAssertNil(feedReceipt, "Feed Skip must not fabricate a completion receipt")
        let queuedResult = await rig.model.applyOwnerIntent(try LibraryIntent.skip(entryID: queuedID,
            deviceID: "iphone", createdAt: at, id: "queued-skip"))
        if case .applied? = queuedResult {} else { XCTFail("Legacy queued Skip must finish") }
        let queuedListening = try await rig.store.listeningState(for: queuedID)
        XCTAssertEqual(queuedListening?.completedAt?.date, at)
        let queue = try await rig.store.podcastQueueState()
        XCTAssertFalse(queue.episodeIDs.contains(queuedID))
        let receiptRestore = try await rig.store.restoreManualCompletion(queuedID, at: at.addingTimeInterval(1))
        XCTAssertEqual(receiptRestore, true)
    }

    func testModelHostKeepsSkipsAndRestoresThroughTheExistingMethods() async throws {
        let rig = try await modelRig("applier-model-decisions")
        let model = rig.model
        let e = rig.episodes
        XCTAssertEqual(model.decisionState(of: e[2]), .live(queued: false, started: false))
        // The Larder's current episode counts as started; the second slot does not.
        XCTAssertEqual(model.decisionState(of: e[0]), .live(queued: true, started: true))
        XCTAssertEqual(model.decisionState(of: e[1]), .live(queued: true, started: false))
        XCTAssertEqual(model.decisionState(of: try ItemID(rawValue: "nope")), .unknown)

        let kept = await model.keepEntry(e[2])
        XCTAssertTrue(kept)
        let durableQueue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(durableQueue, [e[0], e[1], e[2]])
        XCTAssertEqual(model.decisionState(of: e[2]), .live(queued: true, started: false))

        let skipped = await model.skipEntry(e[3])
        XCTAssertTrue(skipped)
        XCTAssertEqual(model.decisionState(of: e[3]), .retired)
        let skippedKind = try await rig.store.removalKind(for: e[3])
        XCTAssertEqual(skippedKind, .retired)

        let restored = await model.restoreEntry(e[3])
        XCTAssertTrue(restored)
        XCTAssertEqual(model.decisionState(of: e[3]), .live(queued: false, started: false))
        let restoredKind = try await rig.store.removalKind(for: e[3])
        XCTAssertNil(restoredKind)
    }

    func testModelHostRestoresADismissedEntry() async throws {
        let rig = try await modelRig("applier-model-dismissed")
        let target = rig.episodes[3]
        _ = try await rig.store.dismissPodcastEpisode(target)
        await rig.model.reloadLibraryRows()
        rig.model.dismissedEpisodes = try await rig.model.loadDismissedEpisodes(from: rig.store)
        XCTAssertEqual(rig.model.decisionState(of: target), .dismissed)

        let restored = await rig.model.restoreEntry(target)

        XCTAssertTrue(restored)
        XCTAssertEqual(rig.model.decisionState(of: target), .live(queued: false, started: false))
    }

    func testModelHostMarksAStartedEpisodeDoneAndRetiresIt() async throws {
        let rig = try await modelRig("applier-model-done")
        let started = try XCTUnwrap(rig.model.episodes.first { $0.id == rig.episodes[1].rawValue })
        rig.model.installPlaybackStateForTesting(
            episode: started, isPlaying: false, position: 120, duration: 600,
            queue: [rig.episodes[0].rawValue, rig.episodes[1].rawValue]
        )
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .live(queued: true, started: true))

        let done = await rig.model.markEntryDone(rig.episodes[1])

        XCTAssertTrue(done)
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .retired)
        let listening = try await rig.store.listeningState(for: rig.episodes[1])
        XCTAssertNotNil(listening?.completedAt)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertFalse(queue.contains(rig.episodes[1]), "a finished episode leaves the Larder")
    }

    func testModelHostCompletesAnEpisodeOnlyThePhoneListenedTo() async throws {
        let rig = try await modelRig("applier-model-done-unstarted")
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .live(queued: true, started: false))

        let done = await rig.model.markEntryDone(rig.episodes[1])

        XCTAssertTrue(done)
        XCTAssertEqual(rig.model.decisionState(of: rig.episodes[1]), .retired)
        let listening = try await rig.store.listeningState(for: rig.episodes[1])
        XCTAssertNotNil(listening?.completedAt, "completed, not merely dismissed")
        let kind = try await rig.store.removalKind(for: rig.episodes[1])
        XCTAssertNotEqual(kind, .dismissed)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertFalse(queue.contains(rig.episodes[1]))
    }

    func testModelHostRemoveCompletesAndRetiresAQueuedPodcast() async throws {
        let rig = try await modelRig("applier-model-remove")
        let target = rig.episodes[1]
        XCTAssertEqual(rig.model.decisionState(of: target), .live(queued: true, started: false))

        let removed = await rig.model.removeEntryFromLarder(target)

        XCTAssertTrue(removed)
        XCTAssertEqual(rig.model.decisionState(of: target), .retired)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [rig.episodes[0]])
        let kind = try await rig.store.removalKind(for: target)
        XCTAssertEqual(kind, .retired, "Remove and Mark completed share manual retirement")
    }

    func testDuplicateFinishPreservesReceiptDecisionForUndoAndExplicitRestore() async throws {
        let rig = try await modelRig("applier-duplicate-finish")
        let target = rig.episodes[1]
        let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let mediaURL = wiltedTemporaryDirectory("duplicate-finish-media").appendingPathComponent("retained.m4a")
        let bytes = Data("retained duplicate finish audio".utf8)
        try bytes.write(to: mediaURL)
        let revisionID = try RevisionID(rawValue: "duplicate-finish-revision")
        let revision = try AudioRevision(itemID: target, revisionID: revisionID,
            durationSeconds: 600, byteCount: Int64(bytes.count),
            contentHash: "sha256:" + String(repeating: "b", count: 64), mediaType: "audio/mp4",
            createdAt: stamp, schemaVersion: 1)
        try await rig.store.finalizePodcastDownload(revision: revision, mediaURL: mediaURL,
            download: PodcastDownload(episodeID: target, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: mediaURL, contentHash: revision.contentHash, updatedAt: stamp))
        let committedRevision = try await rig.store.readyRevision(for: target)
        let priorRevision = try XCTUnwrap(committedRevision?.revision)
        try await rig.store.saveListening(PodcastListeningState(episodeID: target,
            completedAt: stamp, lastRevisionID: revisionID, updatedAt: stamp))
        let progress = try PlaybackState(itemID: target, revisionID: revisionID,
            sessionID: "prior-listen", sequence: 1, positionSeconds: 123, durationSeconds: 600,
            completed: false, intent: .progress, deviceID: "fixture-mac", updatedAt: stamp)
        try await rig.store.save(playback: progress)
        let priorDownload = try await rig.store.download(for: target)
        let priorQueue = try await rig.store.podcastQueueState()
        let priorListening = try await rig.store.listeningState(for: target)
        for explicitRestore in [false, true] {
            let removed = await rig.model.removeEntryFromLarder(target)
            XCTAssertTrue(removed)
            let undo = try XCTUnwrap(rig.model.undoableSkip)
            let decision = try await rig.store.episodeDecision(for: target)
            let listening = try await rig.store.listeningState(for: target)
            let duplicateDone = await rig.model.markEntryDone(target)
            let duplicateRemove = await rig.model.removeEntryFromLarder(target)
            XCTAssertTrue(duplicateDone)
            XCTAssertTrue(duplicateRemove)
            let afterDecision = try await rig.store.episodeDecision(for: target)
            let afterListening = try await rig.store.listeningState(for: target)
            XCTAssertEqual(afterDecision, decision)
            XCTAssertEqual(afterListening, listening)
            XCTAssertEqual(rig.model.undoableSkip?.manualCompletionOperationID, undo.manualCompletionOperationID)
            if explicitRestore {
                let restored = await rig.model.restoreEntry(target)
                XCTAssertTrue(restored)
                let keep = try await rig.store.episodeDecision(for: target)
                XCTAssertEqual(keep?.decision, .keep)
                XCTAssertEqual(keep?.source, .manual)
            } else {
                rig.model.undoSkipEpisode(undo)
                await rig.model.waitForPodcastOperations()
                let restoredDecision = try await rig.store.episodeDecision(for: target)
                XCTAssertNil(restoredDecision)
            }
            let restoredListening = try await rig.store.listeningState(for: target)
            let restoredQueue = try await rig.store.podcastQueueState()
            XCTAssertEqual(restoredListening, priorListening)
            XCTAssertEqual(restoredQueue, priorQueue)
            let restoredDownload = try await rig.store.download(for: target)
            let restoredProgress = try await rig.store.playbackState(for: target, revisionID: revisionID)
            let retained = try await rig.store.readyRevision(for: target)
            XCTAssertEqual(restoredDownload, priorDownload)
            XCTAssertEqual(restoredProgress, progress)
            XCTAssertEqual(retained?.revision, priorRevision)
            XCTAssertEqual(try Data(contentsOf: mediaURL), bytes)
            XCTAssertFalse(rig.model.isPlaying)
        }
    }

    func testMissingLiveRemoveRecordsManualSkipAndPreservesItOnReplay() async throws {
        let rig = try await modelRig("applier-missing-live-remove")
        for dismissed in [false, true] {
            let target = rig.episodes[dismissed ? 3 : 2]
            if dismissed { _ = try await rig.store.dismissPodcastEpisode(target) }
            else {
                _ = try await rig.store.retireEpisode(target)
                try await rig.store.save(episodeDecision: EpisodeDecisionRecord(episodeID: target,
                    decision: .keep, source: .policy,
                    decidedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
            }
            rig.model.episodes.removeAll { $0.id == target.rawValue }
            let priorListening = try await rig.store.listeningState(for: target)
            let priorRetiredAt = try await rig.store.retiredAt(for: target)
            let priorQueue = try await rig.store.podcastQueueState()
            let removed = await rig.model.removeEntryFromLarder(target)
            XCTAssertTrue(removed)
            let decision = try await rig.store.episodeDecision(for: target)
            XCTAssertEqual(decision?.source, .manual)
            XCTAssertEqual(decision?.decision, .skip)
            let repeated = await rig.model.removeEntryFromLarder(target)
            XCTAssertTrue(repeated)
            let after = try await rig.store.episodeDecision(for: target)
            let afterListening = try await rig.store.listeningState(for: target)
            let afterRetiredAt = try await rig.store.retiredAt(for: target)
            let afterQueue = try await rig.store.podcastQueueState()
            XCTAssertEqual(after, decision, "Duplicate Remove preserves the exact owner timestamp")
            XCTAssertEqual(afterListening, priorListening)
            XCTAssertEqual(afterRetiredAt, priorRetiredAt)
            XCTAssertEqual(afterQueue, priorQueue)
        }
        let unknown = try ItemID(rawValue: "unknown-remove")
        let removed = await rig.model.removeEntryFromLarder(unknown)
        XCTAssertFalse(removed)
        let unknownDecision = try await rig.store.episodeDecision(for: unknown)
        XCTAssertNil(unknownDecision)
    }

    func testModelHostMovesTheQueueByIndex() async throws {
        let rig = try await modelRig("applier-model-move")
        let e = rig.episodes
        let move = try XCTUnwrap(WiltedMacIntentApplier.queueMove(of: e[1], after: nil, in: rig.model.decisionQueue)?.change)

        let moved = await rig.model.moveQueueEntry(from: move.from, to: move.to, resulting: move.resulting)

        XCTAssertTrue(moved)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [e[1], e[0]])
    }

    func testTransportRemoveAcknowledgesMissingLiveTerminalRowsAndRejectsUnknown() async throws {
        let rig = try await modelRig("applier-terminal-remove-e2e")
        let retired = rig.episodes[2]
        let dismissed = rig.episodes[3]
        let knownDismissed = rig.episodes[1]
        _ = try await rig.store.retireEpisode(retired)
        _ = try await rig.store.dismissPodcastEpisode(dismissed)
        _ = try await rig.store.dismissPodcastEpisode(knownDismissed)
        await rig.model.reloadLibraryRows()
        rig.model.episodes.removeAll { $0.id == retired.rawValue || $0.id == dismissed.rawValue }
        rig.model.dismissedEpisodes = try await rig.model.loadDismissedEpisodes(from: rig.store)
        rig.model.dismissedEpisodes.removeAll { $0.id == dismissed.rawValue }
        XCTAssertEqual(rig.model.decisionState(of: retired), .unknown)
        XCTAssertEqual(rig.model.decisionState(of: dismissed), .unknown)
        XCTAssertEqual(rig.model.decisionState(of: knownDismissed), .dismissed)
        let unknown = try ItemID(rawValue: "terminal-remove-unknown")
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = InMemoryLibraryTransport(deviceID: "iphone", server: server)
        let entries = [retired, dismissed, knownDismissed, unknown]
        let beforeTerminalIntents = try await rig.store.podcastLibrarySnapshot()
        var originatingTimes: [ItemID: Date] = [:]
        for (index, entry) in entries.enumerated() {
            let createdAt = Date().addingTimeInterval(-2 + Double(index) / 100)
            originatingTimes[entry] = createdAt
            try await phone.send(intent: LibraryIntent.removeFromLarder(
                entryID: entry, deviceID: "iphone", createdAt: createdAt, id: "terminal-remove-\(index)"))
        }
        XCTAssertTrue(rig.model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20)))
        var outcomes: [String: IntentOutcome] = [:]
        let firstDeadline = ContinuousClock.now + .seconds(30)
        while outcomes.count < entries.count, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(50))
            outcomes = Dictionary(uniqueKeysWithValues: try await phone.intentOutcomes().map { ($0.intentID, $0) })
        }
        XCTAssertEqual(outcomes.count, entries.count)
        for index in 0..<3 { XCTAssertEqual(outcomes["terminal-remove-\(index)"]?.disposition, .applied) }
        XCTAssertEqual(outcomes["terminal-remove-3"]?.reason, IntentOutcome.reasonUnknownEntry)
        var decisions: [ItemID: EpisodeDecisionRecord] = [:]
        for entry in entries.prefix(3) {
            let decision = try await rig.store.episodeDecision(for: entry)
            XCTAssertEqual(decision?.source, .manual)
            XCTAssertEqual(decision?.decision, .skip)
            decisions[entry] = try XCTUnwrap(decision)
            XCTAssertEqual(decision?.decidedAt.date, originatingTimes[entry], "Durable terminal proof retains original intent time")
        }
        let afterTerminalIntents = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(afterTerminalIntents.retiredAtByEpisode, beforeTerminalIntents.retiredAtByEpisode)
        XCTAssertEqual(afterTerminalIntents.removalKindByEpisode, beforeTerminalIntents.removalKindByEpisode)
        XCTAssertEqual(afterTerminalIntents.readyRevisions, beforeTerminalIntents.readyRevisions)
        XCTAssertEqual(afterTerminalIntents.downloads, beforeTerminalIntents.downloads)
        XCTAssertEqual(afterTerminalIntents.playbackStates, beforeTerminalIntents.playbackStates)
        let unknownDecision = try await rig.store.episodeDecision(for: unknown)
        XCTAssertNil(unknownDecision)
        for (index, entry) in entries.prefix(3).enumerated() {
            try await phone.send(intent: LibraryIntent.removeFromLarder(
                entryID: entry, deviceID: "iphone", id: "terminal-replay-\(index)"))
        }
        // The incoming poll runs every 30 seconds. Explicit Sync now drives
        // the real poller instead of making replay depend on that timer.
        // Sync now joins a round already in flight, and under load the startup round can still be
        // finishing after it read the inbox, before these replays were sent: ask until one reads them.
        let controller = try XCTUnwrap(rig.model.librarySyncController)
        let replayDeadline = ContinuousClock.now + .seconds(30)
        while outcomes.count < 7, ContinuousClock.now < replayDeadline {
            await controller.syncNow().value
            outcomes = Dictionary(uniqueKeysWithValues: try await phone.intentOutcomes().map { ($0.intentID, $0) })
            if outcomes.count < 7 { try await Task.sleep(for: .milliseconds(50)) }
        }
        for (index, entry) in entries.prefix(3).enumerated() {
            XCTAssertEqual(outcomes["terminal-replay-\(index)"]?.disposition, .applied)
            let after = try await rig.store.episodeDecision(for: entry)
            XCTAssertEqual(after, decisions[entry], "A new duplicate intent preserves receipt-compatible provenance")
        }
        let retiredKind = try await rig.store.removalKind(for: retired)
        let dismissedKind = try await rig.store.removalKind(for: dismissed)
        let knownKind = try await rig.store.removalKind(for: knownDismissed)
        XCTAssertEqual(retiredKind, .retired)
        XCTAssertEqual(dismissedKind, .dismissed)
        XCTAssertEqual(knownKind, .dismissed)
    }

    /// Phone intents arrive over the transport, reach the applier through the sink, and are answered.
    func testIntentsFromTheServerAreAppliedAndAnswered() async throws {
        let rig = try await modelRig("applier-model-e2e")
        let e = rig.episodes
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = InMemoryLibraryTransport(deviceID: "iphone", server: server)
        try await phone.send(intent: LibraryIntent.keep(entryID: e[2], deviceID: "iphone", id: "e2e-keep"))
        try await phone.send(intent: LibraryIntent.reorder(entryID: e[2], afterEntryID: nil, deviceID: "iphone", id: "e2e-move"))
        try await phone.send(intent: LibraryIntent.skip(entryID: e[3], deviceID: "iphone", id: "e2e-skip"))
        try await phone.send(intent: LibraryIntent.keep(
            entryID: try ItemID(rawValue: "not-an-entry"), deviceID: "iphone", id: "e2e-unknown"
        ))

        XCTAssertTrue(rig.model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20)
        ))
        var published: [String: IntentOutcome] = [:]
        for _ in 0..<200 where published.count < 4 {
            try await Task.sleep(for: .milliseconds(50))
            published = Dictionary(uniqueKeysWithValues: try await phone.intentOutcomes().map { ($0.intentID, $0) })
        }

        XCTAssertEqual(published.count, 4)
        XCTAssertEqual(published["e2e-keep"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-move"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-skip"]?.disposition, .applied)
        XCTAssertEqual(published["e2e-unknown"]?.reason, IntentOutcome.reasonUnknownEntry)
        let queue = try await rig.store.podcastQueueState().episodeIDs
        XCTAssertEqual(queue, [e[2], e[0], e[1]])
        let skippedKind = try await rig.store.removalKind(for: e[3])
        XCTAssertEqual(skippedKind, .retired)
        // The change reaches the phone's snapshot through the publisher.
        var snapshotQueue: [ItemID] = []
        for _ in 0..<200 where snapshotQueue != [e[2], e[0], e[1]] {
            try await Task.sleep(for: .milliseconds(50))
            snapshotQueue = await server.currentSnapshot.queue.map(\.entryID)
        }
        XCTAssertEqual(snapshotQueue, [e[2], e[0], e[1]])
    }
}
