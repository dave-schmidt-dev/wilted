import Foundation
import XCTest
import WiltedDomain
@testable import WiltedLibrary
import WiltedPlayback
@testable import WiltediOS

@MainActor
final class RecordingSettingsBulletinSpeaker: LibrarySpeaking {
    private(set) var spoken: [Bulletin] = []
    private(set) var textFallbackCalls = 0

    func prepare(_ bulletin: Bulletin) {}
    func refreshPreparedAudio() async {}
    func canSpeak(_ bulletin: Bulletin) -> Bool { false }
    func speak(_ bulletin: Bulletin, onFinish: @escaping @MainActor () -> Void) -> Bool {
        spoken.append(bulletin)
        return true
    }
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool {
        textFallbackCalls += 1
        return false
    }
    func stop() {}
}

@MainActor
extension LibraryListenNextPhoneModelTests {
    func testBulletinAudioRequestCachesOnceForOfflineOwnerAndRejectsUnknownOrMissingAudio() async throws {
        let activeTransport = transport(OutboxSendScript(.deliver), autoReadyBulletinAudio: true)
        let activeModel = model(activeTransport)
        await activeModel.loadLocalState()
        activeModel.macAddActions = ["requestBulletinAudio"]
        let bulletin = try Bulletin(
            id: "headline:fixture-audio", kind: .headline, text: "A local headline",
            issuedAt: now, expiresAt: now.addingTimeInterval(300), storyID: "fixture-audio")
        let manager = activeModel.bulletinAudioManager
        manager.prepare(bulletin)

        await manager.refreshPreparedAudio()

        let intents = await server.allIntents()
        let request = try XCTUnwrap(intents.first { if case .requestBulletinAudio = $0.action { true } else { false } })
        guard case let .requestBulletinAudio(bulletinID) = request.action else {
            return XCTFail("The Mac request must contain the bulletin identity.")
        }
        XCTAssertEqual(bulletinID, bulletin.id)
        XCTAssertTrue(manager.canSpeak(bulletin))
        let cachedURL = try XCTUnwrap(manager.audioURL(for: bulletin))
        XCTAssertEqual(try Data(contentsOf: cachedURL), try Data(contentsOf: sourceFile))

        let unknownOwnerModel = model(activeTransport)
        XCTAssertNil(unknownOwnerModel.bulletinAudioManager.audioURL(for: bulletin),
                     "cached speech stays unavailable until the local library owner is known")

        let offlineTransport = transport(OutboxSendScript(.deliver))
        await offlineTransport.disconnect()
        let offlineModel = model(offlineTransport)
        await offlineModel.loadLocalState()
        let offlineManager = offlineModel.bulletinAudioManager
        offlineManager.prepare(bulletin)
        await offlineManager.refreshPreparedAudio()
        XCTAssertTrue(offlineManager.canSpeak(bulletin), "a verified owner-scoped clip remains usable offline")

        try offlineModel.listenNextState.audioCache.removeAudio(for: request.id, ownerToken: owner)
        XCTAssertFalse(offlineManager.canSpeak(bulletin), "a missing local asset must never pause playback")
    }

    func testOlderMacCapabilityDoesNotReceiveAutomaticBulletinRequests() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["listenNext", "cancelListenNext"]
        let bulletin = try Bulletin(
            id: "headline:older-mac", kind: .headline, text: "A queued headline",
            issuedAt: now, expiresAt: now.addingTimeInterval(300))

        model.bulletinAudioManager.prepare(bulletin)
        await model.bulletinAudioManager.refreshPreparedAudio()

        let intents = await server.allIntents()
        XCTAssertTrue(intents.isEmpty)
        XCTAssertFalse(model.bulletinAudioManager.canSpeak(bulletin))
    }

    func testBulletinAudioContinuesSparsePollingUntilLateReadyStatus() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let bulletin = try Bulletin(
            id: "headline:late-ready", kind: .headline, text: "A slowly prepared headline",
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600))
        let manager = model.bulletinAudioManager
        manager.prepare(bulletin)

        await manager.refreshPreparedAudio()
        let intents = await server.allIntents()
        let request = try XCTUnwrap(intents.first)
        var statusReadCount = await transport.audio.statusReadCount
        XCTAssertEqual(statusReadCount, 1)

        let preparing = try LibraryListenNextStatus(
            requestID: request.id, storyID: bulletin.id, requesterDeviceID: "phone-1",
            phase: .preparing, statusRevision: 1, updatedAt: now)
        await transport.audio.setStatus(preparing)
        clock.advance(by: 11)
        await manager.refreshPreparedAudio()
        statusReadCount = await transport.audio.statusReadCount
        XCTAssertEqual(statusReadCount, 2)
        XCTAssertFalse(manager.canSpeak(bulletin))

        let stillPreparing = try LibraryListenNextStatus(
            requestID: request.id, storyID: bulletin.id, requesterDeviceID: "phone-1",
            phase: .preparing, statusRevision: 2, updatedAt: now)
        await transport.audio.setStatus(stillPreparing)
        clock.advance(by: 31)
        await manager.refreshPreparedAudio()
        statusReadCount = await transport.audio.statusReadCount
        XCTAssertEqual(statusReadCount, 3)
        XCTAssertFalse(manager.canSpeak(bulletin), "three slow polls must not fail a still-running Mac render")

        try await transport.audio.publishReadyBulletinStatus(for: request, at: now, revision: 3)
        clock.advance(by: 121)
        await manager.refreshPreparedAudio()

        statusReadCount = await transport.audio.statusReadCount
        XCTAssertEqual(statusReadCount, 4)
        XCTAssertTrue(manager.canSpeak(bulletin), "a later ready status must still be accepted before expiry")
    }

    func testBulletinAudioRetriesTransientDownloadsButStopsAtTheBound() async throws {
        let transport = transport(
            OutboxSendScript(.deliver), downloadFailures: 3, autoReadyBulletinAudio: true)
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let bulletin = try Bulletin(
            id: "headline:transient-audio", kind: .headline, text: "A headline with a transient transfer error",
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600))
        let manager = model.bulletinAudioManager
        manager.prepare(bulletin)

        await manager.refreshPreparedAudio()
        var fetchAttemptCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(fetchAttemptCount, 1)
        XCTAssertFalse(manager.canSpeak(bulletin))

        clock.advance(by: 11)
        await manager.refreshPreparedAudio()
        fetchAttemptCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(fetchAttemptCount, 2)
        clock.advance(by: 61)
        await manager.refreshPreparedAudio()
        fetchAttemptCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(fetchAttemptCount, 3)
        XCTAssertFalse(manager.canSpeak(bulletin))

        clock.advance(by: 1_000)
        await manager.refreshPreparedAudio()
        fetchAttemptCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(fetchAttemptCount, 3, "a terminal transfer failure must not poll or download forever")
    }

    func testSettingsTestBulletinRequestsVerifiedMacVoiceBeforePlayingAndNeverFallsBack() async throws {
        let transport = transport(OutboxSendScript(.deliver), autoReadyBulletinAudio: true)
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let speaker = RecordingSettingsBulletinSpeaker()
        let player = LibrarySettingsTestBulletinPlayer(
            audio: model.bulletinAudioManager, speaker: speaker,
            now: { [clock] in clock.current() },
            sleep: { [clock] interval in clock.advance(by: interval) })
        let expected = try XCTUnwrap(LibraryBulletinAudioTestSample.make(at: now))

        let task = try XCTUnwrap(player.play())
        await task.value

        XCTAssertEqual(speaker.spoken, [expected])
        XCTAssertEqual(speaker.textFallbackCalls, 0)
        XCTAssertEqual(player.state, .playing)
        let intents = await server.allIntents()
        let request = try XCTUnwrap(intents.first { if case .requestBulletinAudio = $0.action { true } else { false } })
        guard case let .requestBulletinAudio(bulletinID) = request.action else {
            return XCTFail("The Mac request must carry only the test bulletin identity.")
        }
        XCTAssertEqual(bulletinID, expected.id)
        XCTAssertTrue(model.bulletinAudioManager.canSpeak(expected))

        let unsupportedModel = self.model(self.transport(OutboxSendScript(.deliver)))
        await unsupportedModel.loadLocalState()
        unsupportedModel.macAddActions = ["listenNext"]
        let unsupportedSpeaker = RecordingSettingsBulletinSpeaker()
        let unsupportedPlayer = LibrarySettingsTestBulletinPlayer(
            audio: unsupportedModel.bulletinAudioManager, speaker: unsupportedSpeaker,
            now: { [clock] in clock.current() })
        XCTAssertNil(unsupportedPlayer.play())
        XCTAssertEqual(unsupportedPlayer.state, LibrarySettingsTestBulletinPlayer.State.waiting)
        XCTAssertTrue(unsupportedSpeaker.spoken.isEmpty)
        XCTAssertEqual(unsupportedSpeaker.textFallbackCalls, 0)
    }

}
