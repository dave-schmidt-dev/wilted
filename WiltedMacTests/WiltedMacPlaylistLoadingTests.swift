import Foundation
import SwiftData
import WiltedDomain
@testable import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPlaylistLoadingTests: XCTestCase {
    override func tearDown() {
        WiltedMacModel.afterPlaylistsRead = nil
        super.tearDown()
    }

    private func waitFor(_ description: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async {
        _ = await WiltedMacHeadless.eventually(description, condition)
    }

    func testBrokenAutomaticRulesFailClosedWithoutDiscardingHealthyPlaylists() async throws {
        let directory = wiltedTemporaryDirectory("playlist-rule-read-error")
        let fixture = try await WiltedMacPlaylistTests.makeFixture("playlist-rule-read-error", count: 1, directory: directory)
        addTeardownBlock { await fixture.model.close() }
        let store = try XCTUnwrap(fixture.model.store)
        let manual = try await store.createPlaylist(name: "Manual", kind: .manual)
        let healthy = try await store.createPlaylist(name: "Healthy", kind: .automatic)
        let broken = try await store.createPlaylist(name: "Broken", kind: .automatic)
        let rule = try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue)
        try await store.setPlaylistRules(playlistID: healthy.id, rules: [rule])
        let futurePayload = #"{"version":999,"numberedRules":[],"expressionString":""}"#
        let context = ModelContext(store.container)
        context.insert(LocalLibrarySchemaV17Models.PlaylistRuleRecord(
            playlistID: broken.id, field: PlaylistRuleField.expression.rawValue,
            comparator: PlaylistComparator.expression.rawValue, value: futurePayload, sortIndex: 0))
        try context.save()

        await fixture.model.loadPlaylists()

        XCTAssertNotNil(fixture.model.playlist(manual.id))
        XCTAssertNotNil(fixture.model.playlist(healthy.id))
        let brokenVisible = try XCTUnwrap(fixture.model.playlist(broken.id))
        XCTAssertEqual(fixture.model.playlists.ruleReadErrors[broken.id], "The playlist rules could not be read.")
        fixture.model.playlists.rules[broken.id] = [rule]
        XCTAssertTrue(fixture.model.playlistItems(brokenVisible).isEmpty)
        let lines = try WiltedMacHeadless.recognizedLines(
            WiltedMacPlaylistView(model: fixture.model, playlistID: broken.id),
            size: CGSize(width: 760, height: 520))
        XCTAssertTrue(lines.contains { $0.text.contains("These rules are unavailable") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.text.contains("Nothing matches") }, "\(lines)")
        let saved = await fixture.model.savePlaylistRules(broken.id, rules: [rule], matchAll: true)
        XCTAssertFalse(saved)
        let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PlaylistRuleRecord>())
        let raw = try XCTUnwrap(rows.first { $0.playlistID == broken.id })
        XCTAssertEqual(raw.value, futurePayload)
    }

    func testFinalCreateReloadsStoredRowsWhileDiscardingTheHeldInitialRead() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "playlist-create-reload", count: 1, directory: wiltedTemporaryDirectory("playlist-create-reload"))
        addTeardownBlock { await fixture.model.close() }
        let store = try XCTUnwrap(fixture.model.store)
        let existing = try await store.createPlaylist(name: "Existing", kind: .manual)
        let hold = LoadHold()
        fixture.model.playlists.isLoaded = false
        WiltedMacModel.afterPlaylistsRead = {
            hold.entered += 1
            if hold.entered == 1 { await withCheckedContinuation { hold.release = $0 } }
        }

        let oldRead = Task { await fixture.model.loadPlaylists() }
        await waitFor("the initial read hold") { hold.release != nil }
        let made = await fixture.model.createPlaylist(kind: .manual, name: "Fresh")
        let created = try XCTUnwrap(made)
        await waitFor("the final-settle reload") { fixture.model.playlist(existing.id) != nil }
        XCTAssertTrue(fixture.model.playlists.isLoaded)
        XCTAssertEqual(fixture.model.selectedNavigation, .playlist(created.id))
        XCTAssertEqual(fixture.model.playlist(created.id)?.name, "Fresh")
        hold.release?.resume()
        await oldRead.value
        XCTAssertNotNil(fixture.model.playlist(existing.id))
        XCTAssertEqual(fixture.model.selectedNavigation, .playlist(created.id))
        XCTAssertEqual(fixture.model.playlist(created.id)?.name, "Fresh")
    }

    func testFinalRenameReloadsSyncedRowsWithoutLettingTheHeldReadWin() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "playlist-rename-reload", count: 1, directory: wiltedTemporaryDirectory("playlist-rename-reload"))
        addTeardownBlock { await fixture.model.close() }
        let store = try XCTUnwrap(fixture.model.store)
        let renamed = try await store.createPlaylist(name: "Before", kind: .manual)
        await fixture.model.loadPlaylists()
        let hold = LoadHold()
        WiltedMacModel.afterPlaylistsRead = {
            hold.entered += 1
            if hold.entered == 1 { await withCheckedContinuation { hold.release = $0 } }
        }

        let oldRead = Task { await fixture.model.loadPlaylists() }
        await waitFor("the sync read hold") { hold.release != nil }
        let synced = try await store.createPlaylist(name: "Synced", kind: .manual)
        await fixture.model.renamePlaylist(renamed.id, to: "After")
        await waitFor("the final-settle reload") { fixture.model.playlist(synced.id) != nil }
        XCTAssertEqual(fixture.model.playlist(renamed.id)?.name, "After")
        hold.release?.resume()
        await oldRead.value
        XCTAssertNotNil(fixture.model.playlist(synced.id))
        XCTAssertEqual(fixture.model.playlist(renamed.id)?.name, "After")
    }
}
