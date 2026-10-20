import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
extension LibraryAutoContinueTests {
    /// An item the player already holds (a restored session) has no captured suffix. A manual
    /// resume of its row establishes the row's forward suffix, so the natural end advances within
    /// it instead of stopping, and never falls back to the global list order at completion.
    func testAManualResumeOfAnAlreadyLoadedRowAdoptsTheForwardSuffixForItsNaturalEnd() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("20") })
        let cachedEntries = await rig.model.mediaCache.cachedEntries()
        let cached = try XCTUnwrap(cachedEntries[id("20")])
        let preloaded = LibraryPlayer.Item(
            entryID: row.id, title: row.title, showTitle: row.showTitle,
            fileURL: cached.url, artworkURL: row.artworkURL)
        XCTAssertTrue(rig.player.start(preloaded, autoplay: false))
        await settle()
        XCTAssertTrue(rig.model.handoffState.forwardSequenceIDs.isEmpty, "the preload captured no suffix")

        await start(rig, "20")   // a manual resume of the row that is already loaded
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, [id("20"), id("21")],
                       "the resume establishes the row's forward suffix")

        rig.engine.finishNaturally()
        try await eventually("21 after 20") { rig.player.item?.entryID == self.id("21") }
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended, "the suffix runs out and playback stops")
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "no wrap backwards to 19")
    }

    /// Task 4.2: a middle episode the Larder no longer holds, removed before 19 ends (not during a
    /// lookup), is pruned by the continuation's own snapshot; the walk reaches 21 and stops there.
    func testAMiddleEpisodeRemovedBeforeTheEndIsSkippedAndTheWalkStopsAtTheLast() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        await start(rig, "19")
        await rig.model.decide(.removeFromLarder, entryID: id("20"))
        try await assertWalkSkips20AndStopsAt21(rig)
    }

    /// Task 4.2: a middle episode whose audio the Mac never prepared is not on the phone, so the
    /// suffix the manual start captures leaves it out; the walk reaches 21 and stops there.
    func testAnUnpreparedMiddleEpisodeIsSkippedAndTheWalkStopsAtTheLast() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        try await rig.model.mediaCache.remove(entryID: id("20"))
        rig.model.media[id("20")] = .notPrepared
        await start(rig, "19")
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, [id("19"), id("21")])
        try await assertWalkSkips20AndStopsAt21(rig)
    }

    private func assertWalkSkips20AndStopsAt21(_ rig: Rig) async throws {
        rig.engine.finishNaturally()
        try await eventually("21 after 19") { rig.player.item?.entryID == self.id("21") && rig.player.isPlaying }
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "no wrap back to 19")
        XCTAssertEqual(rig.player.status, .ended)
    }

    /// Task 4.2: the end of one load reported twice (the engine's completion delivered again before
    /// anything else ran) is one completion: one Mark completed to the Mac and one advance, to 20,
    /// never a second advance past it.
    func testAnEndReportedTwiceSendsOneCompletionAndAdvancesOnce() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        await start(rig, "19")
        rig.engine.finishNaturally()
        rig.engine.finishNaturally()
        try await eventually("20 after 19") { rig.player.item?.entryID == self.id("20") && rig.player.isPlaying }
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("20"), "one end, one advance")
        XCTAssertTrue(rig.player.isPlaying)
        let sent = try await mac.listIntents().map(\.action)
        XCTAssertEqual(sent, [.markDone(entryID: id("19"))], "one completion record for one play-out")
        XCTAssertEqual(rig.model.decisions.filter { $0.isSilent && $0.entryID == id("19") }.count, 1)
    }
}
