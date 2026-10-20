import Foundation
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// A renamed manual playlist and its entry come back from the store after a
/// relaunch. This was the Mac UI playlist journey's relaunch step; it is
/// proved here so a native UI run launches the app only once.
@MainActor
final class WiltedMacPlaylistRelaunchTests: XCTestCase {
    func testARenamedManualPlaylistAndItsEntrySurviveARelaunch() async throws {
        let directory = wiltedTemporaryDirectory("playlist-relaunch")
        let first = try await WiltedMacPlaylistTests.makeFixture("playlist-relaunch", count: 1, directory: directory)
        let entryID = first.ids[0].rawValue
        let made = await first.model.createPlaylist(kind: .manual, name: "Before", adding: entryID)
        let playlist = try XCTUnwrap(made, "the playlist was created")
        await first.model.renamePlaylist(playlist.id, to: "Field Notes List")
        XCTAssertNil(first.model.playlistOperation(playlist.id), "the rename's write settled before the relaunch")
        await first.model.close()

        let relaunched = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) }, preferences: WiltedMacTestPreferences.ephemeral())
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        await relaunched.loadPlaylists()
        let reloaded = try XCTUnwrap(relaunched.playlist(playlist.id), "the playlist survives a relaunch")
        XCTAssertEqual(reloaded.name, "Field Notes List", "the rename survives a relaunch")
        XCTAssertEqual(reloaded.kind, .manual)
        XCTAssertEqual(relaunched.playlists.entryIDs[playlist.id], [entryID], "the entry survives a relaunch")
        await relaunched.close()
    }
}
