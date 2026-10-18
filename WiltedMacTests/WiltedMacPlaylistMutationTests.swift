import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Holds or fails playlist store writes so a test can observe the optimistic state while a write
/// is suspended and drive the rollback path when the write fails.
@MainActor
final class PlaylistWriteGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var entered = 0
    var isHolding = true
    var failure: Error?

    func wait() async throws {
        entered += 1
        if !isHolding {
            if let failure { throw failure }
            return
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() {
        isHolding = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: ()) }
    }

    func fail() { fail(PlaylistRuleError(reason: "the test write failed")) }

    func fail(_ error: Error) {
        failure = error
        isHolding = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }
}

@MainActor
extension WiltedMacPlaylistTests {
    // MARK: - Owner playlist UX

    private func installWriteGate(_ gate: PlaylistWriteGate) {
        WiltedMacModel.playlistWriteHookForTesting = { try await gate.wait() }
    }

    private func waitForWrite(_ gate: PlaylistWriteGate, entering count: Int) async throws {
        for _ in 0..<600 where gate.entered < count {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(gate.entered, count, "the test write reached its hook")
    }

    func testARenameIsVisibleWhileItsWriteIsSuspendedThenPersists() async throws {
        let f = try await fixture("optimistic-rename", count: 1)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let playlist = try await created(model, .manual, "Before")
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }

        let write = Task { await model.renamePlaylist(playlist.id, to: "While Waiting") }
        try await waitForWrite(gate, entering: 1)
        XCTAssertEqual(model.playlist(playlist.id)?.name, "While Waiting", "the edit shows before the write settles")
        XCTAssertEqual(model.playlistOperation(playlist.id), .playlist)
        gate.release()
        await write.value
        XCTAssertNil(model.playlistOperation(playlist.id), "the pending state clears when the write settles")
        let stored = try await store.playlists()
        XCTAssertEqual(stored.first { $0.id == playlist.id }?.name, "While Waiting", "the write reached the store")
    }

    func testASecondRenameForTheSamePlaylistIsRefusedWhileOneIsSuspended() async throws {
        let f = try await fixture("duplicate-rename", count: 1)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let playlist = try await created(model, .manual, "Before")
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }

        let first = Task { await model.renamePlaylist(playlist.id, to: "First") }
        try await waitForWrite(gate, entering: 1)
        await model.renamePlaylist(playlist.id, to: "Second")
        XCTAssertEqual(gate.entered, 1, "the duplicate never reached a write")
        XCTAssertEqual(model.playlist(playlist.id)?.name, "First")
        XCTAssertEqual(model.playlists.failures[playlist.id],
                       "Another change was not applied while this playlist was saving. Try again.")
        XCTAssertEqual(model.playlists.message,
                       "Another change was not applied while this playlist was saving. Try again.")
        gate.release()
        await first.value
        XCTAssertNil(model.playlists.failures[playlist.id], "a successful settle clears the transient refusal")
        XCTAssertNil(model.playlists.message)
        let stored = try await store.playlists()
        XCTAssertEqual(stored.first { $0.id == playlist.id }?.name, "First")
    }

    func testDifferentPlaylistsWriteIndependentlyWhileOneIsSuspended() async throws {
        let f = try await fixture("independent-playlists", count: 1)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let first = try await created(model, .manual, "One")
        let second = try await created(model, .manual, "Two")
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }

        let a = Task { await model.renamePlaylist(first.id, to: "One A") }
        try await waitForWrite(gate, entering: 1)
        let b = Task { await model.renamePlaylist(second.id, to: "Two B") }
        try await waitForWrite(gate, entering: 2)
        XCTAssertNotNil(model.playlistOperation(first.id))
        XCTAssertNotNil(model.playlistOperation(second.id), "a different playlist is free to write")
        gate.release()
        await a.value
        await b.value
        let stored = try await store.playlists()
        XCTAssertEqual(stored.first { $0.id == first.id }?.name, "One A")
        XCTAssertEqual(stored.first { $0.id == second.id }?.name, "Two B")
    }

    func testSuspendedCreatesReserveUniqueNamesAndBothPersist() async throws {
        let f = try await fixture("create-names", count: 1)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }

        let first = Task { await model.createPlaylist(kind: .manual) }
        try await waitForWrite(gate, entering: 1)
        let second = Task { await model.createPlaylist(kind: .automatic) }
        try await waitForWrite(gate, entering: 2)
        XCTAssertEqual(model.playlists.creatingCount, 2)
        XCTAssertEqual(Set(model.playlists.playlists.map(\.name)), ["New Playlist", "New Playlist 2"])
        gate.release()
        let madeFirst = await first.value
        let madeSecond = await second.value
        XCTAssertNotNil(madeFirst)
        XCTAssertNotNil(madeSecond)
        let stored = try await store.playlists()
        XCTAssertEqual(Set(stored.map(\.name)), ["New Playlist", "New Playlist 2"])
        XCTAssertEqual(model.playlists.creatingCount, 0)
    }

    func testAFailedCreateRemovesOnlyItsNewPlaylistAndKeepsMovedNavigation() async throws {
        let f = try await fixture("create-failure", count: 1)
        let model = f.model
        let gate = PlaylistWriteGate()
        gate.fail()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }
        XCTAssertEqual(model.selectedNavigation, .larder)

        let made = await model.createPlaylist(kind: .manual)
        XCTAssertNil(made)
        XCTAssertFalse(model.playlists.playlists.contains { $0.name.hasPrefix("New Playlist") })
        XCTAssertEqual(model.selectedNavigation, .larder, "the fallback selection is restored")
        XCTAssertEqual(model.playlists.createFailure, "The playlist could not be created.")
        XCTAssertEqual(model.playlists.creatingCount, 0)
        XCTAssertTrue(model.playlists.pending.isEmpty)

        let moved = PlaylistWriteGate()
        installWriteGate(moved)
        let task = Task { await model.createPlaylist(kind: .manual) }
        try await waitForWrite(moved, entering: 1)
        model.selectedNavigation = .feeds
        moved.fail()
        _ = await task.value
        XCTAssertEqual(model.selectedNavigation, .feeds, "the reader's move is not undone")
        XCTAssertFalse(model.playlists.playlists.contains { $0.name.hasPrefix("New Playlist") })
    }

    func testAFailedDeleteRestoresTheRowOrderAndTheFallbackSelectionOnly() async throws {
        let f = try await fixture("delete-failure", count: 1)
        let model = f.model
        let first = try await created(model, .manual, "First")
        let second = try await created(model, .manual, "Second")
        model.selectedNavigation = .playlist(first.id)
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }

        let task = Task { await model.deletePlaylist(first.id) }
        try await waitForWrite(gate, entering: 1)
        XCTAssertEqual(model.playlists.playlists.map(\.id), [second.id], "the row is gone while the write runs")
        XCTAssertEqual(model.selectedNavigation, .larder)
        gate.fail()
        await task.value
        XCTAssertEqual(model.playlists.playlists.map(\.id), [first.id, second.id], "its relative order returns")
        XCTAssertEqual(model.selectedNavigation, .playlist(first.id), "and the fallback selection returns")
        XCTAssertEqual(model.playlists.failures[first.id], "The playlist could not be deleted.")
        XCTAssertNil(model.playlists.pending[first.id])

        model.selectedNavigation = .settings
        model.playlists.session = WiltedMacPlaylistSession(
            playlistID: first.id, entryIDs: f.ids.map(\.rawValue), index: 0)
        let moved = PlaylistWriteGate()
        installWriteGate(moved)
        let again = Task { await model.deletePlaylist(first.id) }
        try await waitForWrite(moved, entering: 1)
        model.selectedNavigation = .settings
        let playbackGeneration = model.playbackCommands.generation
        model.playLarderEpisode(model.episodes[0])
        XCTAssertGreaterThan(model.playbackCommands.generation, playbackGeneration)
        await model.waitForPlaybackOperationForTesting()
        moved.fail()
        await again.value
        XCTAssertEqual(model.selectedNavigation, .settings, "a moved reader is not pulled back")
        XCTAssertTrue(model.playlists.playlists.contains { $0.id == first.id })
        XCTAssertNil(model.playlists.session, "a newer playback command owns the failed delete's rollback")
    }

    func testManualEntryEditsAreOptimisticAndRollBackOnlyTheEditedPlaylist() async throws {
        let f = try await fixture("entry-rollback", count: 3)
        let model = f.model
        let edited = try await created(model, .manual, "Edited")
        let other = try await created(model, .manual, "Other")
        let raw = f.ids.map(\.rawValue)
        await model.addToPlaylist(other.id, entryID: raw[0])
        await model.addToPlaylist(edited.id, entryID: raw[0])
        await model.addToPlaylist(edited.id, entryID: raw[1])

        let addGate = PlaylistWriteGate()
        installWriteGate(addGate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }
        let add = Task { await model.addToPlaylist(edited.id, entryID: raw[2]) }
        try await waitForWrite(addGate, entering: 1)
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[0], raw[1], raw[2]], "the add shows while suspended")
        addGate.fail()
        await add.value
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[0], raw[1]], "the add rolls back")
        XCTAssertEqual(model.playlists.entryIDs[other.id], [raw[0]], "an unrelated playlist is untouched")

        let removeGate = PlaylistWriteGate()
        installWriteGate(removeGate)
        let remove = Task { await model.removeFromPlaylist(edited.id, entryID: raw[0]) }
        try await waitForWrite(removeGate, entering: 1)
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[1]], "the removal shows while suspended")
        removeGate.fail()
        await remove.value
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[0], raw[1]], "the removal rolls back")

        let moveGate = PlaylistWriteGate()
        installWriteGate(moveGate)
        let move = Task { await model.movePlaylistEntry(edited.id, entryID: raw[1], to: 0) }
        try await waitForWrite(moveGate, entering: 1)
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[1], raw[0]], "the move shows while suspended")
        moveGate.fail()
        await move.value
        XCTAssertEqual(model.playlists.entryIDs[edited.id], [raw[0], raw[1]], "the move rolls back")
    }

    func testSavingRulesShowsTheProjectionAndRollsBackOnlyThatPlaylist() async throws {
        let f = try await fixture("rules-rollback", count: 3)
        let model = f.model
        let playlist = try await created(model, .automatic, "Rules")
        let other = try await created(model, .automatic, "Other")
        let first = try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue)
        let second = try PlaylistRule(field: .length, comparator: .shorterThan, value: "30")
        let otherRule = try PlaylistRule(field: .kind, comparator: .is, value: "article")
        _ = await model.savePlaylistRules(other.id, rules: [otherRule], matchAll: false)

        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        defer { WiltedMacModel.playlistWriteHookForTesting = nil }
        let task = Task { await model.savePlaylistRules(playlist.id, rules: [first, second], matchAll: false) }
        try await waitForWrite(gate, entering: 1)
        XCTAssertEqual(model.playlists.rules[playlist.id], [first, second], "the projection is immediate")
        XCTAssertEqual(model.playlist(playlist.id)?.matchAll, false)
        gate.fail()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertEqual(model.playlists.rules[playlist.id] ?? [], [])
        XCTAssertEqual(model.playlist(playlist.id)?.matchAll, true)
        XCTAssertEqual(model.playlists.rules[other.id], [otherRule], "another playlist's rules are untouched")
    }

    func testAnOlderLoadThatSettlesAfterAnEditNeverRevertsIt() async throws {
        let f = try await fixture("stale-edit", count: 1)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let playlist = try await created(model, .manual, "Before")
        let hold = LoadHold()
        WiltedMacModel.afterPlaylistsRead = {
            hold.entered += 1
            if hold.entered == 1 { await withCheckedContinuation { hold.release = $0 } }
        }
        defer { WiltedMacModel.afterPlaylistsRead = nil }

        let stale = Task { await model.loadPlaylists() }
        for _ in 0..<400 where hold.release == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(hold.release)
        await model.renamePlaylist(playlist.id, to: "After")
        hold.release?.resume()
        await stale.value
        XCTAssertEqual(model.playlist(playlist.id)?.name, "After", "the stale read is discarded")
        let stored = try await store.playlists()
        XCTAssertEqual(stored.first { $0.id == playlist.id }?.name, "After")
    }

    func testALoadThatBeginsDuringASuspendedWriteCannotOverwriteItWhenItSettles() async throws {
        let f = try await fixture("load-during-write", count: 1)
        let model = f.model
        let playlist = try await created(model, .manual, "Before")
        let gate = PlaylistWriteGate()
        installWriteGate(gate)
        let hold = LoadHold()
        WiltedMacModel.afterPlaylistsRead = {
            hold.entered += 1
            if hold.entered == 1 { await withCheckedContinuation { hold.release = $0 } }
        }
        defer {
            WiltedMacModel.playlistWriteHookForTesting = nil
            WiltedMacModel.afterPlaylistsRead = nil
        }

        let write = Task { await model.renamePlaylist(playlist.id, to: "After") }
        try await waitForWrite(gate, entering: 1)
        let load = Task { await model.loadPlaylists() }
        for _ in 0..<400 where hold.release == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(hold.release, "the load read the store before the write settled")
        gate.release()
        await write.value
        hold.release?.resume()
        await load.value
        XCTAssertEqual(model.playlist(playlist.id)?.name, "After", "the settled load does not restore the old name")
    }
}
