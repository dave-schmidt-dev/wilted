import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// PB-7: a speed picked while an episode loads is the speed it plays at and
/// the speed saved for it. The load's earlier read of the episode's saved
/// speed never overwrites it, and the outgoing episode never inherits it.
/// The pick lands inside the load through the scripted backend's `onLoad`,
/// which runs after the saved speed was read and before it would be applied.
@MainActor
final class WiltedMacPlaybackSpeedDuringLoadTests: XCTestCase {
    private struct Rig {
        let model: WiltedMacModel
        let backend: WiltedMacScriptedBackend
        let first: WiltedMacEpisode
        let second: WiltedMacEpisode
    }

    /// Two ready episodes; the second has a saved speed of 1.5×, the first
    /// none, and the default stays at the Mac's 1.25×, so every source of a
    /// speed differs from the 2× the tests pick.
    private func makeRig(_ name: String) async throws -> Rig {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            name, count: 2, directory: wiltedTemporaryDirectory(name))
        let model = fixture.model
        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        // Records nothing durable; the save's target is read from its status.
        model.installSpeedSaveForTesting { _ in }
        let store = try XCTUnwrap(model.store)
        try await store.save(playbackSpeed: PodcastPlaybackSpeed(
            itemID: fixture.ids[1], speed: 1.5, updatedAt: Timestamp(Date())))
        let episodes = try fixture.ids.map { id in try XCTUnwrap(model.episodes.first { $0.id == id.rawValue }) }
        return Rig(model: model, backend: backend, first: episodes[0], second: episodes[1])
    }

    /// Picks `rate` once, at the moment the next load reaches the backend.
    private func pickRateDuringNextLoad(_ rig: Rig, _ rate: Double) {
        rig.backend.onLoad = { [weak model = rig.model, backend = rig.backend] in
            backend.onLoad = nil
            model?.setPlaybackRate(rate)
        }
    }

    func testSpeedPickedWhileAnEpisodeLoadsWinsAndIsSavedForThatEpisode() async throws {
        let rig = try await makeRig("speed-during-load")
        await loadPausedThroughOwner(rig.model, rig.first)
        pickRateDuringNextLoad(rig, 2)

        rig.model.playEpisode(rig.second)
        await rig.model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(rig.model.playback?.itemID?.rawValue, rig.second.id)
        XCTAssertEqual(rig.backend.rate, 2, "the saved 1.5×, read before the pick, did not overwrite it")
        XCTAssertEqual(rig.model.playbackRate, 2, "the picker shows the speed that plays")
        let save = try XCTUnwrap(rig.model.playbackCommands.speedSave)
        XCTAssertEqual(save.itemID, rig.second.id, "saved for the incoming episode, not the outgoing one")
        XCTAssertEqual(save.speed, 2)
        XCTAssertEqual(rig.model.currentSpeedSaveStatus?.itemID, rig.second.id)
    }

    /// The selection's effect waits in the command queue; a pick made before
    /// it runs is still newer than the saved speed the load will read.
    func testSpeedPickedAfterTheClickBeforeTheLoadStartsWins() async throws {
        let rig = try await makeRig("speed-before-load")
        await loadPausedThroughOwner(rig.model, rig.first)

        rig.model.playEpisode(rig.second)
        rig.model.setPlaybackRate(2)
        await rig.model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(rig.model.playback?.itemID?.rawValue, rig.second.id)
        XCTAssertEqual(rig.backend.rate, 2, "the saved 1.5×, read after the pick, did not overwrite it")
        XCTAssertEqual(rig.model.playbackCommands.speedSave?.itemID, rig.second.id)
    }

    func testSavedSpeedAppliesWhenNothingIsPickedDuringTheLoad() async throws {
        let rig = try await makeRig("speed-saved-applies")
        await loadPausedThroughOwner(rig.model, rig.first)
        XCTAssertEqual(rig.backend.rate, Float(WiltedMacModel.initialPlaybackRate),
                       "the first episode has no saved speed, so the default plays")

        rig.model.playEpisode(rig.second)
        await rig.model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(rig.model.playback?.itemID?.rawValue, rig.second.id)
        XCTAssertEqual(rig.backend.rate, 1.5, "the episode's own saved speed applies")
        XCTAssertEqual(rig.model.playbackRate, 1.5)
        XCTAssertNil(rig.model.playbackCommands.speedSave, "a load saves no speed of its own")
    }

    func testSpeedPickedWhileAPlaylistEntryLoadsWins() async throws {
        let rig = try await makeRig("speed-during-playlist-load")
        let made = await rig.model.createPlaylist(kind: .manual, name: "Speed")
        let playlist = try XCTUnwrap(made)
        await rig.model.addToPlaylist(playlist.id, entryID: rig.second.id)
        pickRateDuringNextLoad(rig, 2)

        rig.model.playPlaylist(playlist)
        await rig.model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(rig.model.playback?.itemID?.rawValue, rig.second.id)
        XCTAssertEqual(rig.backend.rate, 2, "the entry's saved 1.5× did not overwrite the pick")
        XCTAssertEqual(rig.model.playbackCommands.speedSave?.itemID, rig.second.id)
        XCTAssertEqual(rig.model.playbackCommands.speedSave?.speed, 2)
    }

    func testSpeedPickedAfterAPlaylistStartsBeforeItsEntryLoadsWins() async throws {
        let rig = try await makeRig("speed-before-playlist-load")
        let made = await rig.model.createPlaylist(kind: .manual, name: "Speed")
        let playlist = try XCTUnwrap(made)
        await rig.model.addToPlaylist(playlist.id, entryID: rig.second.id)

        rig.model.playPlaylist(playlist)
        rig.model.setPlaybackRate(2)
        await rig.model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(rig.model.playback?.itemID?.rawValue, rig.second.id)
        XCTAssertEqual(rig.backend.rate, 2, "the entry's saved 1.5×, read after the pick, did not overwrite it")
        XCTAssertEqual(rig.model.playbackCommands.speedSave?.itemID, rig.second.id)
    }
}
