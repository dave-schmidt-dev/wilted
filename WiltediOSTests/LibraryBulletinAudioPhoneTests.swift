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
        XCTAssertEqual(request.spokenTextSHA256, MediaHash.sha256(text: bulletin.text))
        XCTAssertNotEqual(request.spokenTextSHA256, bulletin.text)
        let fetchedOffers = await activeTransport.audio.fetchedOffers
        XCTAssertEqual(fetchedOffers.first?.spokenTextSHA256, request.spokenTextSHA256)
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

    func testBulletinAudioKeepsTheMacSelectedVoiceForHeadlinesAndWeather() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let manager = model.bulletinAudioManager
        let cases: [(String, BulletinKind, String)] = [
            ("headline:paul-harvey", .headline, "paul-harvey"),
            ("alert:rod-serling", .alert, "rod-serling"),
        ]

        for (id, kind, voiceID) in cases {
            let bulletin = try Bulletin(
                id: id, kind: kind, text: "A role-specific bulletin",
                issuedAt: now, expiresAt: now.addingTimeInterval(900))
            manager.prepare(bulletin)
            await manager.refreshPreparedAudio()
            let intents = await server.allIntents()
            let request = try XCTUnwrap(intents.last)

            try await transport.audio.publishReadyBulletinStatus(
                for: request, at: now, voiceID: voiceID, voiceRevision: "\(voiceID)-short-v1")
            clock.advance(by: 11)
            await manager.refreshPreparedAudio()

            XCTAssertTrue(manager.canSpeak(bulletin), "approved Mac voice \(voiceID) must remain playable on iPhone")
            let fetchedOffers = await transport.audio.fetchedOffers
            XCTAssertEqual(fetchedOffers.last?.voiceID, voiceID)
            XCTAssertEqual(fetchedOffers.last?.voiceRevision, "\(voiceID)-short-v1")
        }
    }

    func testUpdatedSameIDBulletinPurgesLegacyCachedSpeech() async throws {
        let activeTransport = transport(OutboxSendScript(.deliver), autoReadyBulletinAudio: true)
        let activeModel = model(activeTransport)
        await activeModel.loadLocalState()
        activeModel.macAddActions = ["requestBulletinAudio"]
        let original = try Bulletin(
            id: "urn:oid:stable-weather-id", kind: .alert, text: "Original alert wording",
            issuedAt: now, expiresAt: now.addingTimeInterval(900))
        let originalManager = activeModel.bulletinAudioManager
        originalManager.prepare(original)
        await originalManager.refreshPreparedAudio()
        XCTAssertTrue(originalManager.canSpeak(original))
        let originalIntents = await server.allIntents()
        let originalIntent = try XCTUnwrap(originalIntents.first)
        let originalDigest = try XCTUnwrap(originalIntent.spokenTextSHA256)

        // Recreate a v2 manifest from an installed build before digest binding existed.
        let manifestURL = scratch.appendingPathComponent("bulletin-audio-cache.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["version"] = 2
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        var entry = try XCTUnwrap(entries.first)
        entry["textHash"] = String(originalDigest.dropFirst(MediaHash.prefix.count))
        var oldIntent = try XCTUnwrap(entry["intent"] as? [String: Any])
        oldIntent.removeValue(forKey: "spokenTextSHA256")
        entry["intent"] = oldIntent
        var oldOffer = try XCTUnwrap(entry["offer"] as? [String: Any])
        oldOffer.removeValue(forKey: "spokenTextSHA256")
        entry["offer"] = oldOffer
        entries[0] = entry
        manifest["entries"] = entries
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: [.atomic])

        let updated = try Bulletin(
            id: original.id, kind: .alert, text: "Revised alert wording for the same bulletin ID",
            issuedAt: original.issuedAt, expiresAt: original.expiresAt)
        let newModel = model(transport(OutboxSendScript(.deliver)))
        await newModel.loadLocalState()
        newModel.macAddActions = ["requestBulletinAudio"]
        let newManager = newModel.bulletinAudioManager
        newManager.prepare(updated)

        XCTAssertFalse(newManager.canSpeak(updated), "legacy audio without a matching digest is discarded")
        await newManager.refreshPreparedAudio()

        let intents = await server.allIntents()
        let updatedIntent = try XCTUnwrap(intents.last)
        XCTAssertNotEqual(updatedIntent.id, originalIntent.id)
        XCTAssertEqual(updatedIntent.spokenTextSHA256, MediaHash.sha256(text: updated.text))
        XCTAssertFalse(newManager.canSpeak(updated), "new audio stays unavailable until the Mac attests it")
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

    func testOlderMacOfferWithoutTextDigestIsRejectedBeforeDownload() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let bulletin = try Bulletin(
            id: "headline:old-mac", kind: .alert, text: "Current phone alert copy",
            issuedAt: now, expiresAt: now.addingTimeInterval(600))
        let manager = model.bulletinAudioManager
        manager.prepare(bulletin)
        await manager.refreshPreparedAudio()
        let intents = await server.allIntents()
        let request = try XCTUnwrap(intents.first)

        try await transport.audio.publishReadyBulletinStatus(
            for: request, at: now, includeSpokenTextDigest: false)
        clock.advance(by: 11)
        await manager.refreshPreparedAudio()

        XCTAssertEqual(manager.failure(for: bulletin), .transferFailed)
        XCTAssertEqual(
            manager.issue(for: bulletin),
            "The Mac audio has no text check. Update Wilted on both devices, then retry.")
        XCTAssertFalse(manager.canSpeak(bulletin), "an older Mac's unattested clip must never be spoken")
        let fetchCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(fetchCount, 0)

        let revised = try Bulletin(
            id: "headline:wrong-mac-copy", kind: .alert, text: "Expected revised phone copy",
            issuedAt: now, expiresAt: now.addingTimeInterval(600))
        manager.prepare(revised)
        await manager.refreshPreparedAudio()
        let revisedIntents = await server.allIntents()
        let revisedRequest = try XCTUnwrap(revisedIntents.last)
        try await transport.audio.publishReadyBulletinStatus(
            for: revisedRequest, at: now, digestOverride: MediaHash.sha256(text: "Different Mac copy"))
        clock.advance(by: 11)
        await manager.refreshPreparedAudio()

        XCTAssertEqual(manager.failure(for: revised), .transferFailed)
        XCTAssertEqual(
            manager.issue(for: revised),
            "The bulletin text changed between devices. Update Wilted on both devices, then retry.")
        XCTAssertFalse(manager.canSpeak(revised), "a valid digest for different text still fails closed")
        let finalFetchCount = await transport.audio.fetchAttemptCount
        XCTAssertEqual(finalFetchCount, 0)
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

    func testOlderMacMessageRecoversAfterUpdateAndFreshVerifiedClip() async throws {
        let transport = transport(OutboxSendScript(.deliver), autoReadyBulletinAudio: true)
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["listenNext"]
        let bulletin = try Bulletin(
            id: "weather-old-mac-retry", kind: .alert, text: "A current alert copy.",
            issuedAt: now, expiresAt: now.addingTimeInterval(600))
        let manager = model.bulletinAudioManager
        manager.prepare(bulletin)

        XCTAssertEqual(
            manager.issue(for: bulletin),
            "Update Wilted on both devices to use verified bulletin audio, then retry.")
        await manager.refreshPreparedAudio()
        let olderMacIntents = await server.allIntents()
        XCTAssertTrue(olderMacIntents.isEmpty, "an older Mac must not receive the unsupported request")

        model.macAddActions = ["requestBulletinAudio"]
        manager.retry(bulletin)
        await manager.refreshPreparedAudio()

        let intents = await server.allIntents()
        let request = try XCTUnwrap(intents.first { if case .requestBulletinAudio = $0.action { true } else { false } })
        XCTAssertTrue(request.id.hasPrefix("bulletin-audio-retry-"))
        XCTAssertTrue(manager.canSpeak(bulletin), "a new digest-matched clip becomes usable after the Mac update")
        XCTAssertNil(manager.issue(for: bulletin))
    }

    func testChangedMacCopyShowsExactCauseAndManualRetryAcceptsMatchingClip() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        model.macAddActions = ["requestBulletinAudio"]
        let bulletin = try Bulletin(
            id: "weather-changed-copy-retry", kind: .alert, text: "The phone's current alert copy.",
            issuedAt: now, expiresAt: now.addingTimeInterval(600))
        let manager = model.bulletinAudioManager
        manager.prepare(bulletin)
        await manager.refreshPreparedAudio()
        let initialIntents = await server.allIntents()
        let firstRequest = try XCTUnwrap(initialIntents.first {
            if case .requestBulletinAudio = $0.action { true } else { false }
        })
        try await transport.audio.publishReadyBulletinStatus(
            for: firstRequest, at: now, digestOverride: MediaHash.sha256(text: "Different Mac copy"))
        clock.advance(by: 11)
        await manager.refreshPreparedAudio()

        XCTAssertEqual(
            manager.issue(for: bulletin),
            "The bulletin text changed between devices. Update Wilted on both devices, then retry.")
        XCTAssertFalse(manager.canSpeak(bulletin), "the mismatched clip stays unusable")

        manager.retry(bulletin)
        await manager.refreshPreparedAudio()
        let requestsAfterRetry = await server.allIntents()
        let retryRequest = try XCTUnwrap(requestsAfterRetry.last {
            if case .requestBulletinAudio = $0.action { true } else { false }
        })
        XCTAssertNotEqual(retryRequest.id, firstRequest.id)
        try await transport.audio.publishReadyBulletinStatus(for: retryRequest, at: clock.current())
        clock.advance(by: 11)
        await manager.refreshPreparedAudio()

        XCTAssertTrue(manager.canSpeak(bulletin), "only the fresh, matching Mac clip becomes usable")
        XCTAssertNil(manager.issue(for: bulletin))
    }

}
