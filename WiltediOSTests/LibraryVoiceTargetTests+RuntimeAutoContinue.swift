import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

@MainActor
extension LibraryVoiceTargetTests {
    func testRuntimeCompletedRemovalAndMissingNextCacheContinuesToC() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: true, pausing: false, missingB: true)
    }

    func testRuntimeRemovalBeforeInitialAutoReadKeepsFinalPositionAndSpeed() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: true, pausing: false, beforeInitialRead: true)
    }

    func testRuntimeCompletedAndNextRemovedDuringCandidateAwaitContinuesToC() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: true, pausing: false, removingB: true)
    }

    func testRuntimeRemovalBeforeInitialReadSkipsMissingNextCache() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: true, pausing: false, beforeInitialRead: true, missingB: true)
    }

    func testRuntimeSeekCancelsHeldNaturalContinuation() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: false, pausing: false, cancellation: .seek(to: 50))
    }

    func testRuntimeStopCancelsHeldNaturalContinuation() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: false, pausing: false, stopping: true)
    }

    func testRuntimeNewSelectionSupersedesHeldNaturalContinuation() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: false, pausing: false, selectingC: true)
    }

    func testRuntimeNaturalFinishContinuesWithoutMacRemoval() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: false, pausing: false)
    }

    func testRuntimeNaturalFinishContinuesAfterMacProcessesCompletion() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: true, pausing: false)
    }

    func testRuntimeExplicitPauseCancelsHeldNaturalContinuation() async throws {
        try await checkRuntimeAutoContinuation(removingCompleted: false, pausing: true)
    }

    func testRuntimeVoiceMarkDoneUnloadsImmediatelyAndRejectedDecisionRestoresOnlyRow() async throws {
        let rig = try await loadedRig()
        let runtime = LibraryRuntime(model: rig.model, player: rig.player,
            settings: LibrarySettingsStore(defaults: UserDefaults(suiteName: suite)!))
        await runtime.prepare()
        let resumed = await rig.target.perform(.resume)
        XCTAssertEqual(resumed, .done)
        XCTAssertTrue(rig.player.isPlaying)
        let url = try XCTUnwrap(rig.player.item?.fileURL)
        let marked = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(marked, .done)
        XCTAssertFalse(rig.model.queued.contains { $0.id == id("a") })
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertFalse(rig.player.handle(.play))
        let denied = await rig.target.perform(.resume)
        XCTAssertEqual(denied, .failed)
        let intents = try await mac.listIntents()
        let intent = try XCTUnwrap(intents.first { $0.action == .markDone(entryID: id("a")) })
        try await mac.publishIntentOutcome(IntentOutcome.rejected(for: intent,
            reason: IntentOutcome.reasonNotApplicable, at: Date(timeIntervalSince1970: 1_000)))
        await rig.model.refresh()
        await settleVoiceRig(rig)
        XCTAssertTrue(rig.model.queued.contains { $0.id == id("a") })
        XCTAssertNil(rig.player.item, "rollback restores the row without loading or resuming audio")
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertFalse(rig.player.handle(.play))
        let restoredResume = await rig.target.perform(.resume)
        XCTAssertEqual(restoredResume, .failed)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let cached = await rig.cache.cachedEntries()
        XCTAssertEqual(cached[id("a")]?.url, url)
        withExtendedLifetime(runtime) {}
    }

    /// Exercises the real finish callback, persisted final position, silent completion decision,
    /// runtime subscriptions and automatic command. Only cache suspension is controlled here.
    private func checkRuntimeAutoContinuation(removingCompleted: Bool, pausing: Bool, beforeInitialRead: Bool = false, cancellation: LibraryRemoteCommand? = nil, stopping: Bool = false, selectingC: Bool = false, removingB: Bool = false, missingB: Bool = false) async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "Garden Radio")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Episode B", show: "show", sortKey: 1),
            EpisodeSpec(raw: "c", title: "Episode C", show: "show", sortKey: 2),
        ])
        let seeded = try await makeRig(cached: ["a", "b", "c"])
        let files = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let gate = LookupGate()
        let cache = AutoContinueGatedMediaCache(base: files, gate: gate)
        let engine = VoiceFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let sleeper = sleeper
        let phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phoneTransport)
        let model = LibraryAppModel(
            transport: phoneTransport, store: mirror, deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { try await sleeper.sleep($0) }, settleSleep: { _ in }),
            preferences: UserDefaults(suiteName: suite)!, now: { Date(timeIntervalSince1970: 1_000) },
            timeZone: TimeZone(identifier: "UTC")!)
        let runtime = LibraryRuntime(model: model, player: player,
            settings: LibrarySettingsStore(defaults: UserDefaults(suiteName: suite)!))
        await runtime.prepare()
        await model.refresh()
        // Capture the real grants while every seeded row is still eligible, before any withdrawal.
        let admittedBeforeRemoval = await files.cachedEntries()
        let generation = await phoneTransport.operationGeneration()
        var grantsBeforeRemoval: [ItemID: MediaCacheAdmission] = [:]
        for raw in ["a", "b", "c"] {
            let grant = await files.admission(entryID: id(raw), ownerToken: "fixture-owner",
                libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: generation)
            grantsBeforeRemoval[id(raw)] = try XCTUnwrap(grant)
            let cached = try XCTUnwrap(admittedBeforeRemoval[id(raw)])
            XCTAssertEqual(cached.url, seeded.cachedURLs[id(raw)])
            XCTAssertNotNil(cached.preparation)
        }
        let target = LibraryVoiceTarget(model: model, player: player)
        let started = await target.perform(.play(id("a")))
        XCTAssertEqual(started, .done)
        await model.waitForHandoff()
        for _ in 0..<20 { await Task.yield() }
        player.setRate(1.5)
        await gate.arm()
        engine.finishNaturally()
        // Release earlier final-position and snapshot lookups; hold the actual B start lookup.
        for _ in 0..<20 {
            try await gate.waitForHold()
            if beforeInitialRead || model.playbackCommand?.entryID == id("b") { break }
            await gate.releaseNext()
            for _ in 0..<20 { await Task.yield() }
        }
        try await eventually("the actual natural completion was accepted") { model.playedOut[self.id("a")] != nil }
        if beforeInitialRead {
            XCTAssertNil(model.playbackCommand)
            XCTAssertNotEqual(model.handoffState.ownPositions[id("a")]?.record.positionSeconds, 600,
                "final position is still awaiting cache, before the initial auto lookup can begin")
        } else {
            XCTAssertEqual(model.playbackCommand?.entryID, id("b"), "the automatic B command reached its own cache wait")
            XCTAssertEqual(model.handoffState.ownPositions[id("a")]?.record.positionSeconds, 600)
        }
        XCTAssertEqual(player.status, .ended)
        XCTAssertNotNil(model.playedOut[id("a")], "natural completion was accepted before any removal")
        if pausing { player.pause() }
        if stopping { player.stop() }
        if let cancellation { _ = player.handle(cancellation) }
        var selection: Task<VoiceOutcome, Never>?
        if selectingC {
            selection = Task { await target.perform(.play(self.id("c"))) }
            try await eventually("new C selection owns the command") { model.playbackCommand?.entryID == self.id("c") }
        }
        if removingCompleted {
            if !beforeInitialRead {
                try await eventually("silent natural completion intent") {
                    let intents = try? await self.mac.listIntents()
                    return intents?.contains { $0.action == .markDone(entryID: self.id("a")) } == true
                }
                let intents = try await mac.listIntents()
                let intent = try XCTUnwrap(intents.first { $0.action == .markDone(entryID: id("a")) })
                try await mac.publishIntentOutcome(IntentOutcome.applied(for: intent, at: Date(timeIntervalSince1970: 1_000)))
            }
            var changes = [LibraryChange.slotRemoved(entryID: id("a"))]
            if removingB { changes.append(.slotRemoved(entryID: id("b"))) }
            try await macPush(changes)
            if missingB { try await files.remove(entryID: id("b")) }
            let refresh = Task { await model.refresh() }
            try await eventually("Mac completion removed A while B remained queued") {
                !model.queued.contains { $0.id == self.id("a") } && model.queued.contains { $0.id == self.id("c") }
            }
            XCTAssertNotEqual(player.item?.entryID, id("a"), "library invalidation immediately unloads completed A; an eligible successor may already be loaded")
            await gate.disarm()
            await refresh.value
        } else {
            await gate.disarm()
        }
        let cancelled = pausing || cancellation != nil || stopping
        let next = selectingC || removingB || missingB ? "c" : "b"
        if !cancelled {
            try await eventually("the actual eligible successor is playing") {
                player.item?.entryID == self.id(next) && player.isPlaying
            }
        }
        try await eventually("automatic command settled") { model.playbackCommand == nil }
        await model.waitForHandoff()
        if let selection { let outcome = await selection.value; XCTAssertEqual(outcome, .done) }
        if stopping { XCTAssertNil(player.item) }
        else { XCTAssertEqual(player.item?.entryID, id(cancelled ? "a" : next)) }
        XCTAssertEqual(engine.isPlaying, !cancelled)
        XCTAssertEqual(engine.loadedURLs.count, cancelled ? 1 : 2)
        if !cancelled { XCTAssertEqual(model.handoffState.ownPositions[id("a")]?.record.positionSeconds, 600) }
        if !cancelled && !selectingC { XCTAssertEqual(player.rate, 1.5, "natural continuation preserves captured speed") }
        let cached = await files.cachedEntries()
        for raw in ["a", "b", "c"] where !(raw == "b" && missingB) {
            let entry = id(raw)
            let retainedURL = try XCTUnwrap(seeded.cachedURLs[entry])
            let prior = try XCTUnwrap(admittedBeforeRemoval[entry])
            let proof = try XCTUnwrap(prior.preparation)
            let grant = try XCTUnwrap(grantsBeforeRemoval[entry])
            let removed = removingCompleted && (raw == "a" || (raw == "b" && removingB))
            if removed {
                XCTAssertNil(cached[entry], "confirmed removal withdraws playable inventory")
                XCTAssertEqual(model.mediaState(for: entry), .notPrepared)
                let permitted = await files.permits(grant, for: proof.offer)
                XCTAssertFalse(permitted, "the real pre-removal grant cannot authorize retained bytes")
                let readmitted = await files.cachedFile(for: proof.offer, admission: grant)
                XCTAssertNil(readmitted, "retained bytes cannot regain preparation through their old grant")
                let verified = await files.verifies(prior)
                XCTAssertFalse(verified, "a revoked preparation marker cannot authorize playback")
            } else {
                XCTAssertEqual(cached[entry]?.url, retainedURL)
                XCTAssertEqual(cached[entry]?.preparation, prior.preparation)
                let permitted = await files.permits(grant, for: proof.offer)
                XCTAssertTrue(permitted, "unchanged eligible successor keeps its exact preparation grant")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
            XCTAssertEqual(try Data(contentsOf: retainedURL), payload, "permission withdrawal preserves inert bytes")
        }
        player.stop()
        withExtendedLifetime(runtime) {}
    }

}
