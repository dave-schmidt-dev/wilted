import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
extension LibraryHandoffModelTests {
    func testSeededHandoffInterleavingsPreservePhoneRewindAndAcceptFreshMacTakeover() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let transport = OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline)
        let mirrorURL = scratch.appendingPathComponent("seeded-handoff-mirror.json")
        let ownPositionsURL = scratch.appendingPathComponent("seeded-handoff-positions.json")
        var rig = try await makeRig(
            cached: rev1, transport: transport, ownPositionsURL: ownPositionsURL, mirrorURL: mirrorURL)
        try await macStoredPosition(98, epoch: 0)
        await rig.model.refresh()

        var expectedPosition = 98.0
        let schedules: [(seed: Int, takeOffline: Bool, relaunchBeforeSync: Bool, acceptMacTakeover: Bool)] = [
            (17, true, true, false),
            (29, false, false, false),
            (43, true, true, true),
        ]

        for schedule in schedules {
            offline.offline = false
            rig.player.start(try await item(rig), at: expectedPosition)
            await rig.model.waitForHandoff()

            await setTime(clock.now.timeIntervalSince1970 + Double(schedule.seed))
            let nextPosition = schedule.seed == 17 ? 8.4 : expectedPosition + Double(schedule.seed)
            rig.engine.currentTime = nextPosition
            rig.player.seek(to: nextPosition)
            await rig.model.waitForHandoff()
            if schedule.takeOffline { offline.offline = true }
            rig.player.pause()
            await rig.model.waitForHandoff()
            XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), nextPosition)

            // A delayed Mac record can carry a later timestamp but an older session epoch.
            try await macPublishes(
                epoch: 0, playing: false, position: 98,
                at: clock.now.timeIntervalSince1970 + 30)
            if schedule.relaunchBeforeSync {
                rig = try await makeRig(
                    cached: rev1, transport: transport, ownPositionsURL: ownPositionsURL,
                    mirrorURL: mirrorURL, seedLibrary: false, bootstrap: false, refresh: false)
            }

            offline.offline = false
            await rig.model.refresh()
            XCTAssertEqual(
                rig.model.resumeStart(for: entryID, cachedRevision: rev1), nextPosition,
                "seed=\(schedule.seed) stale Mac state must preserve the phone's explicit position")

            if !schedule.relaunchBeforeSync {
                rig = try await makeRig(
                    cached: rev1, transport: transport, ownPositionsURL: ownPositionsURL,
                    mirrorURL: mirrorURL, seedLibrary: false, bootstrap: false, refresh: false)
                XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), nextPosition)
            }

            if schedule.acceptMacTakeover {
                let macPosition = nextPosition + 120
                try await macPublishes(
                    epoch: 100, playing: false, position: macPosition,
                    at: clock.now.timeIntervalSince1970 + 30)
                await rig.model.refresh()
                XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), macPosition)
                await rig.model.playCached(try row())
                await rig.model.waitForHandoff()
                XCTAssertEqual(rig.player.position, macPosition, "a fresh higher-epoch Mac takeover is honored")
                expectedPosition = macPosition
            } else {
                expectedPosition = nextPosition
            }
        }
    }

    func testStaleMacRewindAfterColdRelaunchPreservesPhone98SecondResume() async throws {
        let ownPositionsURL = scratch.appendingPathComponent("phone-positions.json")
        let mirrorURL = scratch.appendingPathComponent("phone-library.json")
        var rig = try await makeRig(
            cached: rev1, ownPositionsURL: ownPositionsURL, mirrorURL: mirrorURL)

        rig.player.start(try await item(rig), at: 98)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let paused = try await phoneRecord()
        XCTAssertEqual(paused.positionSeconds, 98)

        // The delayed Mac record is older by session epoch, even though its wall clock is later.
        try await macPublishes(epoch: 0, playing: false, position: 8.4,
                               at: clock.now.timeIntervalSince1970 + 30)
        rig = try await makeRig(
            cached: rev1, ownPositionsURL: ownPositionsURL, mirrorURL: mirrorURL,
            seedLibrary: false, bootstrap: false, refresh: false)
        await rig.model.refresh()
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 98)

        // A real row launch resumes from the durable phone checkpoint without seeking backward.
        await rig.model.playCached(try row())
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.position, 98)
        let resumed = try await phoneRecord()
        XCTAssertEqual(resumed.positionSeconds, 98)
    }
}


@MainActor
extension LibraryHandoffModelTests {

    func phoneProgress() async throws -> DevicePlaybackPosition? {
        try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }?.record
    }

    func testAPauseThatCouldNotBePublishedIsRepublishedOnTheNextSync() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        offline.offline = true
        await setTime(1_030)
        rig.engine.currentTime = 300
        rig.player.seek(to: 300)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let stale = try await phoneRecord()
        XCTAssertTrue(stale.isPlaying, "the pause never reached the server")
        XCTAssertLessThan(stale.positionSeconds, 300)

        offline.offline = false
        await setTime(1_040)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.isPlaying, false)
        XCTAssertEqual(progress?.positionSeconds, 300)
        XCTAssertEqual(progress?.revision, rev1)
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 300)
    }

    func testAListenWithNoSessionAtAllIsPublishedOnceBackOnline() async throws {
        let offline = OfflineSwitchTransport.Switch()
        offline.offline = true
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 30)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 200
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let nothing = try await phoneProgress()
        XCTAssertNil(nothing, "takeover failed offline, so nothing was published")

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 200)
        XCTAssertEqual(progress?.isPlaying, false)
        XCTAssertEqual(progress?.revision, rev1)
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 200)
    }

    func testAnOfflineListenAfterAMacTakeoverIsPublishedAtTheMacsEpochSoTheMacAdoptsIt() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)   // the phone's session, epoch 1
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        try await macPublishes(epoch: 2, playing: false, position: 600, at: 1_020)
        await rig.model.refresh()

        offline.offline = true
        await setTime(1_030)
        rig.player.start(try await item(rig), at: 700)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 900
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 900, "offline, the phone's newer listen beats the Mac's older record")

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 900)
        XCTAssertGreaterThanOrEqual(progress?.epoch ?? 0, 2, "published at the entry's highest epoch")
        let records = try await mac.fetchDeviceRecords()
        let candidates = HandoffPositionImport.candidates(records: records, localDeviceID: "mac")
        XCTAssertEqual(candidates.map(\.positionSeconds), [900], "the Mac would adopt the phone's listen")
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 900)
    }

    func testAnOfflineListenAfterAnEarlierStopIsStillPublished() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        rig.player.stop()   // the session ends with the item gone
        await rig.model.waitForHandoff()

        offline.offline = true
        await setTime(1_030)
        rig.player.start(try await item(rig), at: 300)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 450
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 450)
        XCTAssertEqual(progress?.isPlaying, false)
    }

    func testAPublishedPauseIsNotRepublishedAndProgressStaysAtThePause() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        await setTime(1_030)
        rig.engine.currentTime = 400
        rig.player.seek(to: 400)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let before = try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }

        await setTime(1_100)
        await rig.model.refresh()

        let after = try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }
        XCTAssertEqual(after?.serverModifiedAt, before?.serverModifiedAt, "nothing pending, nothing written")
        XCTAssertEqual(after?.record.positionSeconds, 400)
    }

    func testStartingBWhileAPlaysSavesAPosition() async throws {
        let rig = try await makeRig(cached: rev1)
        let itemA = try await item(rig)
        let idB = try ItemID(rawValue: "item-b")
        let entryB = try LibraryEntry(
            id: idB, kind: .podcastEpisode, sourceID: idB, title: "B", summary: "",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 3_600)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 3, change: .entry(entryB), baseVersion: 1),
            PendingLibraryChange(localSeq: 4, change: .slot(try QueueSlot(entryID: idB, sortKey: 1)), baseVersion: 1),
        ])
        let fileB = scratch.appendingPathComponent("b")
        try payload.write(to: fileB)
        let offerB = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: idB, revisionID: rev1, contentHash: hash(payload), byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 3_600))
        _ = try await PreparedMediaFixture.adopt(into: rig.cache, verifiedFile: fileB, for: offerB, owner: "fixture-owner")
        await rig.model.refresh()
        let cachedEntries = await rig.cache.cachedEntries()
        let cachedB = try XCTUnwrap(cachedEntries[idB])
        let itemB = LibraryPlayer.Item(entryID: idB, title: "B", showTitle: "Show", fileURL: cachedB.url)

        rig.player.start(itemA)
        rig.engine.currentTime = 42
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()

        rig.player.start(itemB)
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.model.handoffState.ownPositions[itemA.entryID]?.record.positionSeconds, 42)
    }
}
