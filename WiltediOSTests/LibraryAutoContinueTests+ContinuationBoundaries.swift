import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
extension LibraryAutoContinueTests {
    func testRouteLossAndUnchangedRefreshKeepUnfinishedLocalEpisodeListedAndResumable() async throws {
        let rig = try await makeRig(entries: ["car-unfinished"], autoPlayNext: false)
        let episodeID = id("car-unfinished")
        try await inProgressOnMac("car-unfinished", position: 137)
        await rig.model.refresh()

        XCTAssertEqual(rig.model.mediaState(for: episodeID), .onPhone, "the episode has current owner-bound local preparation")
        XCTAssertEqual(rig.model.visibleRows.map(\.id), [episodeID])
        await start(rig, "car-unfinished")
        XCTAssertEqual(rig.player.item?.entryID, episodeID)
        XCTAssertEqual(rig.player.position, 137, accuracy: 0.1, "playback starts at the unfinished checkpoint")
        XCTAssertTrue(rig.player.isPlaying)

        rig.player.handle(.routeLost)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 137, accuracy: 1)
        let afterRouteLoss = try await mac.listIntents().map(\.action)
        XCTAssertFalse(afterRouteLoss.contains(.markDone(entryID: episodeID)), "route loss is not natural completion")

        let queuedBeforeRefresh = rig.model.queued.map(\.id)
        XCTAssertTrue(rig.model.readyOffers.isEmpty, "this local episode has no current Mac offer")
        await rig.model.refresh()

        XCTAssertEqual(rig.model.queued.map(\.id), queuedBeforeRefresh, "the successful refresh leaves the queue unchanged")
        XCTAssertTrue(rig.model.readyOffers.isEmpty, "an empty offer response does not withdraw local preparation")
        XCTAssertNil(rig.model.errorMessage, "the unchanged refresh succeeded")
        XCTAssertEqual(rig.model.mediaState(for: episodeID), .onPhone)
        XCTAssertEqual(rig.model.visibleRows.map(\.id), [episodeID])
        XCTAssertEqual(rig.model.playOrderRows.map(\.id), [episodeID])
        XCTAssertEqual(rig.player.status, .paused, "refresh does not restart audio after the route is lost")
        XCTAssertEqual(rig.player.position, 137, accuracy: 1)
        XCTAssertNil(rig.model.finished[episodeID], "an unfinished checkpoint is not treated as completed")

        let row = try XCTUnwrap(rig.model.visibleRows.first)
        let outcome = await rig.model.playCachedWithoutToggling(row)
        XCTAssertEqual(outcome, .resumed)
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.player.item?.entryID, episodeID)
        XCTAssertEqual(rig.player.position, 137, accuracy: 1, "the listed row resumes from the unfinished checkpoint")
        let afterResume = try await mac.listIntents().map(\.action)
        XCTAssertFalse(afterResume.contains(.markDone(entryID: episodeID)), "neither route loss nor resume sends mark-completed")
    }

    func testMiddle19AdvancesThrough20And21AndStopsWithoutRestartingEarlierUnfinished() async throws {
        let rig = try await makeRig(entries: ["18", "19", "20", "21"])
        try await inProgressOnMac("18", position: 50)
        await rig.model.refresh()
        for raw in ["18", "19", "20", "21"] { rig.model.media[id(raw)] = .onPhone }
        let listed = rig.model.playOrderRows.map(\.id.rawValue)
        XCTAssertEqual(listed, ["18", "19", "20", "21"])

        await start(rig, "19")
        var played = ["19"]
        for _ in 0..<5 {
            let current = try XCTUnwrap(rig.player.item?.entryID)
            rig.engine.finishNaturally()
            await settle()
            guard let next = rig.player.item?.entryID, next != current else { break }
            played.append(next.rawValue)
        }
        XCTAssertEqual(played, ["19", "20", "21"], "walks 19 -> 20 -> 21 and stops at end without restarting 18")
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testMissingLaterCacheSkipAdvancesPastMissingCandidate() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        try await rig.model.mediaCache.remove(entryID: id("20"))
        await start(rig, "19")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "skips cache-missing 20 and advances to 21")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testCompletionRemovalAndReorderingDoesNotJumpBackwards() async throws {
        let rig = try await makeRig(entries: ["18", "19", "20", "21"])
        await start(rig, "19")
        try await complete("20", at: 1_695_000_000)
        try await inProgressOnMac("18", position: 200)
        await rig.model.refresh()
        for raw in ["18", "19", "20", "21"] { rig.model.media[id(raw)] = .onPhone }

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "completion of 20 and earlier progress does not jump back to 18")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testSupersedingManualCommandWinsOverAutoContinue() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        await start(rig, "19")
        rig.engine.finishNaturally()
        rig.player.pause()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("19"))
        XCTAssertEqual(rig.player.status, .paused)

        await start(rig, "19")
        rig.engine.finishNaturally()
        await start(rig, "21")
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
        XCTAssertEqual(rig.player.status, .playing)
    }

    /// A command given while the final position is being remembered (the cache and coordinator
    /// lookups inside it) must not lose the completion: it was accepted before the first await,
    /// so the Mac is still told the episode played out. Only the advance is cancelled.
    func testACommandDuringTheFinalPositionLookupStillSendsTheCompletionAndStartsNothing() async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], gate: gate)
        await start(rig, "19")
        await gate.arm()
        rig.engine.finishNaturally()
        // Hold the lookups one at a time until the completion has been accepted; the held
        // lookup is then inside the final-position remember, before the completion is sent.
        while true {
            try await gate.waitForHold()
            if rig.model.playedOut[id("19")] != nil { break }
            await gate.releaseNext()
        }
        rig.player.pause()   // the intervening command, given while the lookup is held
        await gate.disarm()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        let sent = try await mac.listIntents().map(\.action)
        XCTAssertTrue(sent.contains(.markDone(entryID: id("19"))), "the durable completion still reaches the Mac")
        XCTAssertEqual(rig.model.handoffState.ownPositions[id("19")]?.record.positionSeconds, 600,
                       "the end position is still recorded")
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("19"), "no unintended audio start")
        XCTAssertEqual(rig.player.status, .ended)
    }

    /// A file can disappear between the continuation's snapshot and the candidate's own start
    /// lookup. The walk has to try the next candidate instead of stopping: 20 vanishes between
    /// the two lookups, 21 plays.
    func testACandidateThatDisappearsBetweenTheLookupsIsSkippedForTheNextOne() async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()
        // Drive the continuation directly so its snapshot and the start's lookup are the only
        // lookups in flight; the gate holds the snapshot after it captured the entries.
        await gate.arm()
        let advance = Task { await rig.model.autoContinue(after: self.id("19")) }
        try await gate.waitForHold()
        try await rig.model.mediaCache.remove(entryID: id("20"))
        await gate.disarm()
        await advance.value
        XCTAssertEqual(rig.player.item?.entryID, id("21"),
                       "20 disappeared between the lookups; the walk reaches 21")
        XCTAssertTrue(rig.player.isPlaying)
    }

    func testRemovedCachedCandidateDuringStartLookupIsSkippedForTheNextOne() async throws {
        try await assertDecisionDuringCandidateLookupSkipsToNext(.removeFromLarder)
    }

    func testCompletedCachedCandidateDuringStartLookupIsSkippedForTheNextOne() async throws {
        try await assertDecisionDuringCandidateLookupSkipsToNext(.markDone)
    }

    private func assertDecisionDuringCandidateLookupSkipsToNext(_ action: LibraryDecisionAction) async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()

        await gate.arm()
        let advance = Task { await rig.model.autoContinue(after: self.id("19")) }
        try await gate.waitForHold() // initial candidate snapshot
        await gate.releaseNext()
        try await gate.waitForHold() // candidate 20's start lookup
        await rig.model.decide(action, entryID: id("20"))
        await gate.disarm()
        await advance.value

        let cached = await rig.model.mediaCache.cachedEntries()
        XCTAssertNotNil(cached[id("20")], "the decision does not remove the cached audio")
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "an ineligible cached candidate is skipped")
        XCTAssertTrue(rig.player.isPlaying)
    }

    func testCachedRequestedCandidateInitiallyAdvancesToNextEligible() async throws {
        try await assertMediaIneligibleCandidateAdvances(.requested(since: Date()), held: false)
    }

    func testCachedDownloadingCandidateInitiallyAdvancesToNextEligible() async throws {
        try await assertMediaIneligibleCandidateAdvances(.downloading(bytes: 10, total: 100, since: Date()), held: false)
    }

    func testCachedRequestedCandidateDuringStartAwaitAdvancesToNextEligible() async throws {
        try await assertMediaIneligibleCandidateAdvances(.requested(since: Date()), held: true)
    }

    func testCachedDownloadingCandidateDuringStartAwaitAdvancesToNextEligible() async throws {
        try await assertMediaIneligibleCandidateAdvances(.downloading(bytes: 10, total: 100, since: Date()), held: true)
    }

    private func assertMediaIneligibleCandidateAdvances(_ state: LibraryMediaState, held: Bool) async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("accepted completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()
        if held {
            await gate.arm()
            let advance = Task { await rig.model.autoContinue(after: self.id("19")) }
            try await gate.waitForHold()
            await gate.releaseNext()
            try await gate.waitForHold()
            XCTAssertEqual(rig.model.playbackCommand?.entryID, id("20"))
            rig.model.media[id("20")] = state
            await gate.disarm()
            await advance.value
        } else {
            rig.model.media[id("20")] = state
            await rig.model.autoContinue(after: id("19"))
        }
        let cached = await rig.model.mediaCache.cachedEntries()
        XCTAssertNotNil(cached[id("20")], "the rejected media state retains verified cache bytes")
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
        XCTAssertTrue(rig.player.isPlaying)
        rig.player.stop()
    }
}
