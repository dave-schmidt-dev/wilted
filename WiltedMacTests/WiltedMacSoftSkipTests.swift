import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

/// Skip from Feeds with Undo: the audio stays until the offer ends, Undo gives the episode back whole,
/// an Undo that is no longer the latest word does nothing, and a playlist that is still saving keeps
/// its removal's offer open.
@MainActor
extension WiltedMacFeedDecisionTests {
    /// Puts a downloaded copy of the episode on disk and in the library, with listening history.
    private func seedDownloadedEpisode(_ fixture: FeedDecisionFixture) async throws -> URL {
        let itemID = fixture.itemIDs[0]
        let mediaURL = fixture.directory.appendingPathComponent("soft-skip.m4a")
        let contentHash = "sha256:" + String(repeating: "b", count: 64)
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "b", count: 64))
        try Data("audio".utf8).write(to: mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 12,
                                        byteCount: 5, contentHash: contentHash, mediaType: "audio/mpeg",
                                        createdAt: fixture.createdAt, schemaVersion: 3),
            mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: itemID, status: .completed, bytesReceived: 5,
                                          expectedByteCount: 5, localURL: mediaURL, contentHash: contentHash,
                                          updatedAt: fixture.createdAt)
        )
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: itemID, completedAt: fixture.createdAt, lastRevisionID: revisionID, updatedAt: fixture.createdAt
        ))
        return mediaURL
    }

    func testASkipWithUndoKeepsTheAudioUntilTheOfferEndsThenDeletesIt() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let mediaURL = try await seedDownloadedEpisode(fixture)

        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        XCTAssertNotNil(fixture.model.undoToast.current, "the Skip offers Undo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path), "the audio waits out the window")
        let during = try await fixture.store.revisions(for: fixture.itemIDs[0])
        XCTAssertEqual(during.count, 1)

        fixture.model.undoToast.withdrawAll()
        await drainDecisionWriters(fixture.model)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: mediaURL.path) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path), "closing the offer reclaims the audio")
        let after = try await fixture.store.revisions(for: fixture.itemIDs[0])
        XCTAssertEqual(after.count, 0)
    }

    func testTheCleanupIsOnTheLedgerOnceAndAFinishedSkipLeavesNone() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        _ = try await seedDownloadedEpisode(fixture)

        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        XCTAssertEqual(fixture.model.pendingSoftSkips.count, 1, "the write-ahead entry was replaced, not added to")
        XCTAssertFalse(fixture.model.pendingSoftSkips[0].entries.isEmpty, "and now carries what Undo needs")

        fixture.model.undoToast.undoCurrent()
        await drainDecisionWriters(fixture.model)
        XCTAssertTrue(fixture.model.pendingSoftSkips.isEmpty, "an Undo leaves nothing to clean")
    }

    func testASkipThatChangesNothingLeavesNoCleanupOnTheLedger() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        _ = try await fixture.store.retireEpisodes(
            [fixture.itemIDs[0]], at: fixture.createdAt, asOwnerChoice: true, deferringMediaDeletion: false)
        await fixture.model.reloadLibraryRows()

        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)

        XCTAssertTrue(fixture.model.pendingSoftSkips.isEmpty)
    }

    func testALaunchAfterAQuitInsideTheWindowReclaimsTheAudioAndFreesTheSlot() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let mediaURL = try await seedDownloadedEpisode(fixture)
        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        // The quit: the offer is gone with the process, the ledger entry stays.
        fixture.model.openSoftSkips.removeAll()
        await fixture.model.closeAbandonedSoftSkips(in: fixture.store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertEqual(fixture.model.pendingSoftSkips.count, 1, "the entry stays until the slot has been released")
        XCTAssertEqual(fixture.model.softSkipReleaseFeedIDs, [fixture.feedID.rawValue],
                       "the feed is owed a release of the slot, done once its rows are loaded")

        fixture.model.releaseSlotsOfAbandonedSoftSkips()
        await drainDecisionWriters(fixture.model)
        XCTAssertTrue(fixture.model.pendingSoftSkips.isEmpty, "the entry goes once the release has run")
        XCTAssertTrue(fixture.model.softSkipReleaseFeedIDs.isEmpty)
    }

    func testAQuitBeforeTheSlotReleaseLeavesTheEntryForTheNextLaunch() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let mediaURL = try await seedDownloadedEpisode(fixture)
        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        fixture.model.openSoftSkips.removeAll()
        await fixture.model.closeAbandonedSoftSkips(in: fixture.store)

        // A second quit before the release: only the ledger survives.
        fixture.model.softSkipReleaseFeedIDs = []
        fixture.model.softSkipRecoveryLedgerUpdates = []
        XCTAssertEqual(fixture.model.pendingSoftSkips.count, 1)
        await fixture.model.closeAbandonedSoftSkips(in: fixture.store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertEqual(fixture.model.softSkipReleaseFeedIDs, [fixture.feedID.rawValue],
                       "the next launch owes the same release again")
    }

    func testClosingASkipOfThePlayingEpisodeKeepsItsAudioAndItsEntry() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]
        let mediaURL = try await seedDownloadedEpisode(fixture)
        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        fixture.model.currentPodcastEpisodeID = itemID.rawValue

        fixture.model.undoToast.withdrawAll()
        await drainDecisionWriters(fixture.model)
        for _ in 0..<100 where fixture.model.pendingSoftSkips.first?.retiredIDs != [itemID] {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path), "the loaded episode keeps its audio")
        XCTAssertEqual(fixture.model.pendingSoftSkips.first?.retiredIDs, [itemID], "its cleanup is still owed")
        let reserved = try await fixture.store.manualCompletionCapacityReservations()
        XCTAssertNil(reserved[fixture.feedID], "but the slot is given up all the same")
    }

    func testClosingASkipWhileItsAudioIsStillLoadingKeepsTheAudioAndItsEntry() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]
        let mediaURL = try await seedDownloadedEpisode(fixture)
        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        // A load that has started but not yet shown the episode as loaded: the playing check cannot see it.
        let gate = RuleAdmissionMediaOpenGate()
        let backend = WiltedMacScriptedBackend()
        backend.beforeMediaOpenForTesting = { await gate.hold() }
        let controller = PlaybackController(store: fixture.store, backend: backend, deviceID: "fixture")
        fixture.model.playback = controller
        let revisions = try await fixture.store.revisions(for: itemID)
        let revision = try XCTUnwrap(revisions.first).revision
        let loading = Task { try await controller.load(revision: revision, mediaURL: mediaURL) }
        guard await gate.waitUntilHeld() else {
            gate.release()
            _ = await loading.result
            throw RuleAdmissionGateTimeout()
        }

        fixture.model.undoToast.withdrawAll()
        await drainDecisionWriters(fixture.model)
        for _ in 0..<100 where fixture.model.openSoftSkips.isEmpty == false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let kept = FileManager.default.fileExists(atPath: mediaURL.path)
        let owed = fixture.model.pendingSoftSkips.first?.retiredIDs
        gate.release()
        _ = await loading.result

        XCTAssertTrue(fixture.model.openSoftSkips.isEmpty, "the offer closed")
        XCTAssertTrue(kept, "audio a load is opening is not deleted under it")
        XCTAssertEqual(owed, [itemID], "its cleanup is still owed")
    }

    func testUndoGivesTheEpisodeBackWithItsAudioHistoryAndNoNewKeep() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]
        let mediaURL = try await seedDownloadedEpisode(fixture)

        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        fixture.model.undoToast.undoCurrent()
        await drainDecisionWriters(fixture.model)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
        let listening = try await fixture.store.listeningState(for: itemID)
        XCTAssertEqual(listening?.completedAt, fixture.createdAt, "the listening history is untouched")
        let decision = try await fixture.store.episodeDecision(for: itemID)
        XCTAssertNil(decision, "Undo puts back the missing decision; it does not write a manual Keep")
        XCTAssertTrue(fixture.model.skippedFeedEpisodes.isEmpty)
        XCTAssertNil(fixture.model.undoToast.current)
    }

    func testUndoingASkipOfALinkedPairRestoresBothEpisodes() async throws {
        let fixture = try await makeFixture(count: 2, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let (a, b) = (fixture.itemIDs[0], fixture.itemIDs[1])
        let preview = try await fixture.store.previewEpisodeAssociation(
            confirming: PodcastEpisodePairConfirmation(
                confirmationID: UUID(), feedID: fixture.feedID, first: a, second: b, confirmedAt: fixture.createdAt),
            representativeID: a)
        _ = try await fixture.store.applyEpisodeAssociation(preview, at: fixture.createdAt)
        await fixture.model.reloadLibraryRows()

        fixture.model.skipFeedEpisode(try XCTUnwrap(fixture.model.episodes.first { $0.id == a.rawValue }), offerUndo: true)
        await drainDecisionWriters(fixture.model)
        let removedA = try await fixture.store.removalKind(for: a)
        let removedB = try await fixture.store.removalKind(for: b)
        XCTAssertNotNil(removedA)
        XCTAssertNotNil(removedB)

        fixture.model.undoToast.undoCurrent()
        await drainDecisionWriters(fixture.model)

        let backA = try await fixture.store.removalKind(for: a)
        let backB = try await fixture.store.removalKind(for: b)
        XCTAssertNil(backA)
        XCTAssertNil(backB, "the linked twin comes back with the row that was skipped")
    }

    func testAnOlderUndoDoesNothingAfterANewerSkip() async throws {
        let fixture = try await makeFixture(count: 1, queueIndexes: [])
        addTeardownBlock { await fixture.model.close() }
        let itemID = fixture.itemIDs[0]

        fixture.model.skipFeedEpisode(fixture.episodes[0], offerUndo: true)
        await drainDecisionWriters(fixture.model)
        let first = try XCTUnwrap(fixture.model.undoToast.current)

        // The owner brings it back and skips it again: a newer Skip, with its own offer.
        fixture.model.restoreSkippedFeedEpisode(try XCTUnwrap(fixture.model.skippedFeedEpisodes.first))
        await drainDecisionWriters(fixture.model)
        let restored = try XCTUnwrap(fixture.model.episodes.first { $0.id == itemID.rawValue })
        try await Task.sleep(nanoseconds: 20_000_000)
        fixture.model.skipFeedEpisode(restored, offerUndo: true)
        await drainDecisionWriters(fixture.model)

        fixture.model.undoToast.undo(first.id)
        await drainDecisionWriters(fixture.model)
        let decision = try await fixture.store.episodeDecision(for: itemID)
        XCTAssertEqual(decision?.decision, .skip, "the newer Skip stands")
        XCTAssertEqual(decision?.source, .manual)
    }
}

@MainActor
extension WiltedMacPlaylistTests {
    func testUndoingAPlaylistRemovalWhileItIsSavingKeepsTheOfferThenRestores() async throws {
        let f = try await fixture("busy-undo", count: 3)
        let model = f.model
        let playlist = try await created(model, .manual, "Busy")
        for id in f.ids { await model.addToPlaylist(playlist.id, entryID: id.rawValue) }
        let raw = f.ids.map(\.rawValue)
        await model.removeFromPlaylist(playlist.id, entryID: raw[1])
        XCTAssertNotNil(model.undoToast.current)

        let gate = PlaylistWriteGate()
        WiltedMacModel.playlistWriteHookForTesting = { try await gate.wait() }
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }
        let rename = Task { await model.renamePlaylist(playlist.id, to: "Renamed") }
        for _ in 0..<600 where gate.entered < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(gate.entered, 1)

        model.undoToast.undoCurrent()
        XCTAssertNotNil(model.undoToast.current, "a busy playlist does not consume the Undo")
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [raw[0], raw[2]])

        gate.release()
        await rename.value
        model.undoToast.undoCurrent()
        for _ in 0..<600 where model.playlists.entryIDs[playlist.id] != raw {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], raw)
        XCTAssertNil(model.undoToast.current)
    }
}
