import Foundation
import CryptoKit
import WiltedLibrary
import WiltedProducer
import WiltedWeather
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacBulletinAudioCoordinatorTests: XCTestCase {
    private let owner = "bulletin-audio-owner"
    private let macID = "bulletin-audio-mac"
    private let phoneID = "bulletin-audio-phone"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRequestIntentRendersCurrentBulletinAndPublishesOwnerBoundReadyAudio() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-ready")
        let story = try bulletin(id: "headline:active", text: "Current headline")
        let recorder = BulletinAudioRenderRecorder()
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 4)
        let at = now
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { $0 == story.id ? story : nil },
            readyAudioURL: { _, _ in nil },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                try writeSilentAAC(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 0.1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
            })
        defer { coordinator.invalidate() }
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-audio-success")
        let resultServer = InMemoryLibraryServer(writerDeviceID: macID)
        let resultTransport = InMemoryLibraryTransport(deviceID: macID, server: resultServer)
        let applier = WiltedMacIntentApplier(
            host: BulletinAudioDecisionHost(), ledger: WiltedMacIntentLedger(fileURL: nil, now: { at }),
            book: WiltedMacIntentOutcomeBook(fileURL: nil, now: { at }),
            transport: resultTransport, now: { at },
            listenNextHandler: { try await coordinator.handle($0) })

        try await applier.apply(intent)

        let ready = try await eventuallyStatus(intent.id, phase: .ready, from: audioTransport)
        let offer = try XCTUnwrap(ready.audioOffer)
        let recording = await audioTransport.snapshot()
        let renderedCalls = await recorder.value()
        let rendered = try XCTUnwrap(renderedCalls.first)
        let intentOutcomes = try await resultTransport.intentOutcomes()
        let publishedAudio = try XCTUnwrap(recording.audio.first)
        XCTAssertEqual(intentOutcomes.first?.intentID, intent.id)
        XCTAssertEqual(intentOutcomes.first?.disposition, .applied)
        XCTAssertEqual(rendered.text, story.text)
        XCTAssertEqual(rendered.voice, ApprovedReadingVoiceID.caseyKasem)
        XCTAssertEqual(recording.statusHistory.map(\.phase), [.preparing, .ready])
        XCTAssertEqual(ready.requestID, intent.id)
        XCTAssertEqual(ready.storyID, story.id)
        XCTAssertEqual(ready.requesterDeviceID, phoneID)
        XCTAssertEqual(ready.voiceID, ApprovedReadingVoiceID.caseyKasem.rawValue)
        XCTAssertEqual(ready.voiceRevision,
                       ArticleNarrationCoordinator.shortTextVoiceRevision(for: .caseyKasem))
        XCTAssertEqual(offer.requestID, intent.id)
        XCTAssertEqual(offer.storyID, story.id)
        XCTAssertEqual(offer.requesterDeviceID, phoneID)
        XCTAssertEqual(offer.spokenTextSHA256, intent.spokenTextSHA256)
        XCTAssertEqual(offer.spokenTextSHA256, MediaHash.sha256(text: rendered.text))
        XCTAssertEqual(offer.mediaType, "audio/mp4")
        XCTAssertEqual(offer.byteCount, Int64(publishedAudio.bytes.count))
        XCTAssertEqual(publishedAudio.offer, offer)
        XCTAssertEqual(recording.ownerChecks, [owner, owner, owner, owner])
    }

    func testExpiredOrDifferentBulletinIDFailsWithoutRendering() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-unavailable")
        let expired = try bulletin(id: "headline:expired", text: "Expired headline", expiresAt: now)
        let active = try bulletin(id: "headline:active", text: "Active headline")
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 1)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { id in id == expired.id ? expired : (id == active.id ? active : nil) },
            readyAudioURL: { _, _ in nil },
            render: { _, _, _ in
                await recorder.record(text: "unexpected", voice: .caseyKasem)
                throw BulletinAudioTestError.renderFailed
            })
        defer { coordinator.invalidate() }
        let expiredIntent = try LibraryIntent.requestBulletinAudio(
            bulletinID: expired.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: expired.text),
            createdAt: now, id: "bulletin-audio-expired")
        let wrongIDIntent = try LibraryIntent.requestBulletinAudio(
            bulletinID: "headline:not-active", deviceID: phoneID,
            spokenTextSHA256: MediaHash.sha256(text: "not active"), createdAt: now,
            id: "bulletin-audio-wrong-id")

        let expiredOutcome = try await coordinator.handle(expiredIntent)
        let wrongIDOutcome = try await coordinator.handle(wrongIDIntent)
        XCTAssertTrue(expiredOutcome.isApplied)
        XCTAssertTrue(wrongIDOutcome.isApplied)

        let expiredStatus = try await eventuallyStatus(expiredIntent.id, phase: .failed, from: audioTransport)
        let wrongIDStatus = try await eventuallyStatus(wrongIDIntent.id, phase: .failed, from: audioTransport)
        let trace = await audioTransport.snapshot()
        XCTAssertEqual(expiredStatus.failure, .unavailableStory)
        XCTAssertEqual(wrongIDStatus.failure, .unavailableStory)
        XCTAssertTrue(trace.audio.isEmpty)
        let renderCalls = await recorder.value()
        XCTAssertEqual(renderCalls.count, 0)
    }

    func testThrownAndInvalidAudioRendersPublishOnlyFixedFailure() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-render-failures")
        let story = try bulletin(id: "headline:render-failure", text: "A headline to narrate")
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 2)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { $0 == story.id ? story : nil },
            readyAudioURL: { _, _ in nil },
            render: { _, voice, outputURL in
                let call = await recorder.record(text: "request", voice: voice)
                if call == 2 {
                    try Data("not audio".utf8).write(to: outputURL)
                    return ArticleNarrationAudio(
                        audioURL: outputURL, duration: 0.1,
                        voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
                }
                throw BulletinAudioTestError.renderFailed
            })
        defer { coordinator.invalidate() }
        let thrown = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-audio-thrown")
        let invalid = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-audio-invalid")

        let thrownOutcome = try await coordinator.handle(thrown)
        XCTAssertTrue(thrownOutcome.isApplied)
        let thrownStatus = try await eventuallyStatus(thrown.id, phase: .failed, from: audioTransport)

        let invalidOutcome = try await coordinator.handle(invalid)
        XCTAssertTrue(invalidOutcome.isApplied)
        let invalidStatus = try await eventuallyStatus(invalid.id, phase: .failed, from: audioTransport)
        let trace = await audioTransport.snapshot()
        XCTAssertEqual(thrownStatus.failure, .narrationFailed)
        XCTAssertEqual(invalidStatus.failure, .narrationFailed)
        XCTAssertTrue(trace.audio.isEmpty)
        XCTAssertFalse(trace.statusHistory.contains { $0.phase == .ready })
    }

    func testReadyMacAudioSkipsRendererAndStillPublishesScopedOffer() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-existing")
        let story = try bulletin(id: "headline:ready", text: "Already narrated headline")
        let readyURL = directory.appending(path: "ready.m4a")
        try writeSilentAAC(to: readyURL)
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 7)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { $0 == story.id ? story : nil },
            readyAudioURL: { _, _ in readyURL },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                throw BulletinAudioTestError.renderFailed
            })
        defer { coordinator.invalidate() }
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-audio-prepared")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)

        let ready = try await eventuallyStatus(intent.id, phase: .ready, from: audioTransport)
        let trace = await audioTransport.snapshot()
        let offer = try XCTUnwrap(ready.audioOffer)
        let uploaded = try XCTUnwrap(trace.audio.first)
        let renderCalls = await recorder.value()
        XCTAssertEqual(renderCalls.count, 0)
        XCTAssertEqual(uploaded.offer, offer)
        XCTAssertEqual(uploaded.bytes, try Data(contentsOf: readyURL))
        XCTAssertEqual(ready.requesterDeviceID, phoneID)
        XCTAssertEqual(offer.requesterDeviceID, phoneID)
        XCTAssertEqual(offer.spokenTextSHA256, intent.spokenTextSHA256)
        XCTAssertTrue(trace.ownerChecks.allSatisfy { $0 == owner })
    }

    func testBulletinChangedDuringRenderCannotPublishStaleAudio() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-stale-render")
        let story = try bulletin(id: "headline:changing", text: "Version one")
        let revisedStory = try bulletin(id: story.id, text: "Version two")
        var active = story
        let gate = BulletinAudioRenderGate()
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 3)
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { id in active.id == id ? active : nil },
            readyAudioURL: { _, _ in nil },
            render: { _, voice, outputURL in
                await gate.pauseUntilReleased()
                try writeSilentAAC(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 0.1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
            })
        defer {
            Task { await gate.release() }
            coordinator.invalidate()
        }
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-audio-stale")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)
        await gate.waitUntilStarted()
        active = revisedStory
        await gate.release()
        let failed = try await eventuallyStatus(intent.id, phase: .failed, from: audioTransport)

        let trace = await audioTransport.snapshot()
        XCTAssertEqual(failed.failure, .unavailableStory)
        XCTAssertTrue(trace.audio.isEmpty, "A render for old bulletin text must not be uploaded.")
        XCTAssertFalse(trace.statusHistory.contains { $0.phase == .ready })
    }

    func testNewMacRejectsOlderPhoneRequestWithoutDigest() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-old-phone")
        let story = try bulletin(id: "headline:old-phone", text: "An older phone has no digest")
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 5)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { $0 == story.id ? story : nil },
            readyAudioURL: { _, _ in nil },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                throw BulletinAudioTestError.renderFailed
            })
        defer { coordinator.invalidate() }
        let oldPhoneIntent = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID, createdAt: now, id: "bulletin-audio-old-phone")

        let outcome = try await coordinator.handle(oldPhoneIntent)

        XCTAssertEqual(outcome.disposition, .rejected)
        let oldPhoneTrace = await audioTransport.snapshot()
        let oldPhoneRenderCalls = await recorder.value()
        XCTAssertTrue(oldPhoneTrace.statusHistory.isEmpty)
        XCTAssertTrue(oldPhoneRenderCalls.isEmpty)
    }

    func testSameBulletinIDWithChangedMacTextFailsBeforeRendering() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-version-skew")
        let phoneCopy = try bulletin(id: "urn:oid:version-skew", text: "Phone's alert version")
        let macCopy = try bulletin(id: phoneCopy.id, text: "Mac has a revised alert version")
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 6)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { $0 == macCopy.id ? macCopy : nil },
            readyAudioURL: { _, _ in nil },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                throw BulletinAudioTestError.renderFailed
            })
        defer { coordinator.invalidate() }
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: phoneCopy.id, deviceID: phoneID,
            spokenTextSHA256: MediaHash.sha256(text: phoneCopy.text),
            createdAt: now, id: "bulletin-audio-version-skew")

        let outcome = try await coordinator.handle(intent)

        XCTAssertTrue(outcome.isApplied)
        let failed = try await eventuallyStatus(intent.id, phase: .failed, from: audioTransport)
        XCTAssertEqual(failed.failure, .unavailableStory)
        XCTAssertNil(failed.audioOffer)
        let renderCalls = await recorder.value()
        let trace = await audioTransport.snapshot()
        XCTAssertTrue(renderCalls.isEmpty)
        XCTAssertTrue(trace.audio.isEmpty)
    }

    func testSettingsTestSampleUsesLocalResolverWithoutStartingPublicNWSLookup() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-test-sample")
        let at = now
        let sample = try XCTUnwrap(LibraryBulletinAudioTestSample.make(at: at))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory.appending(path: "library-state"),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let hub = WiltedMacBulletinHub(model: model, now: { at })
        XCTAssertEqual(hub.localBulletin(id: sample.id), sample)
        let nwsTransport = BulletinAudioNWSResponseTransport(body: Data())
        let publicLookup = WiltedMacPublicNWSBulletinLookup(transport: nwsTransport, now: { at })
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 8)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { hub.localBulletin(id: $0) },
            bulletinFallback: { id in await publicLookup.bulletin(id: id) },
            readyAudioURL: { _, _ in nil },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                try writeSilentAAC(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 0.1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
            })
        defer { coordinator.invalidate() }
        let requestsWhileIdle = await nwsTransport.requests()
        XCTAssertTrue(requestsWhileIdle.isEmpty, "The public adapter stays idle until fallback is needed.")
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: sample.id, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: sample.text),
            createdAt: at, id: "bulletin-audio-local-test-sample")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)

        let ready = try await eventuallyStatus(intent.id, phase: .ready, from: audioTransport)
        let requests = await nwsTransport.requests()
        let renderCalls = await recorder.value()
        XCTAssertEqual(ready.storyID, sample.id)
        XCTAssertEqual(renderCalls.first?.text, LibraryBulletinAudioTestSample.text)
        XCTAssertTrue(requests.isEmpty, "A current local test sample must bypass the NWS fallback.")
    }

    func testPhoneLocalWeatherAlertUsesTheInjectedPublicNWSAdapterOnDemand() async throws {
        let directory = wiltedTemporaryDirectory("bulletin-audio-nws-fallback")
        let at = now
        let alertID = "urn:oid:2.49.0.1.840.0.54321"
        let body = try nwsAlertBody(id: alertID, now: at)
        let detailFeature = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let activeBody = try JSONSerialization.data(withJSONObject: ["features": [detailFeature]])
        let activeClient = NWSClient(
            transport: BulletinAudioNWSResponseTransport(body: activeBody), appVersion: "test",
            repositoryURL: "https://github.com/dave-schmidt-dev/wilted")
        let activeResponse = try await activeClient.activeAlerts(zones: ["FLZ074"])
        let phoneAlert = try XCTUnwrap(activeResponse.alerts.first)
        let phoneBulletin = try XCTUnwrap(AlertMonitor.bulletin(for: phoneAlert, now: at))
        let nwsTransport = BulletinAudioNWSResponseTransport(body: body)
        let publicLookup = WiltedMacPublicNWSBulletinLookup(transport: nwsTransport, now: { at })
        let comparisonLookup = WiltedMacPublicNWSBulletinLookup(
            transport: BulletinAudioNWSResponseTransport(body: body), now: { at })
        let maybeRemoteBulletin = await comparisonLookup.bulletin(id: alertID)
        let remoteBulletin = try XCTUnwrap(maybeRemoteBulletin)
        XCTAssertEqual(Data(phoneBulletin.text.utf8), Data(remoteBulletin.text.utf8),
                       "phone and Mac format the same alert byte for byte")
        XCTAssertEqual(phoneBulletin.issuedAt, remoteBulletin.issuedAt)
        XCTAssertEqual(phoneBulletin.expiresAt, remoteBulletin.expiresAt)
        XCTAssertEqual(
            Data(SHA256.hash(data: Data(phoneBulletin.text.utf8))),
            Data(SHA256.hash(data: Data(remoteBulletin.text.utf8))),
            "the phone's spoken-text cache hash is identical on the Mac path")
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 9)
        let recorder = BulletinAudioRenderRecorder()
        let coordinator = makeCoordinator(
            directory: directory, transport: audioTransport, authority: authority,
            activeBulletin: { _ in nil },
            bulletinFallback: { id in await publicLookup.bulletin(id: id) },
            readyAudioURL: { _, _ in nil },
            render: { text, voice, outputURL in
                await recorder.record(text: text, voice: voice)
                try writeSilentAAC(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 0.1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
            })
        defer { coordinator.invalidate() }
        let requestsWhileIdle = await nwsTransport.requests()
        XCTAssertTrue(requestsWhileIdle.isEmpty, "No public lookup runs while the Mac is idle.")
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: alertID, deviceID: phoneID, spokenTextSHA256: MediaHash.sha256(text: phoneBulletin.text),
            createdAt: at, id: "bulletin-audio-nws-fallback")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)

        let ready = try await eventuallyStatus(intent.id, phase: .ready, from: audioTransport)
        let requests = await nwsTransport.requests()
        let request = try XCTUnwrap(requests.first)
        let rendered = await recorder.value()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.host, NWSClient.host)
        XCTAssertEqual(request.url?.path, "/alerts/\(alertID)")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(ready.storyID, alertID)
        XCTAssertEqual(ready.requesterDeviceID, phoneID)
        XCTAssertEqual(ready.audioOffer?.spokenTextSHA256, MediaHash.sha256(text: phoneBulletin.text))
        XCTAssertEqual(Data(try XCTUnwrap(rendered.first?.text).utf8), Data(phoneBulletin.text.utf8))
        XCTAssertEqual(rendered.first?.voice, .rodSerling)
    }

    private func makeCoordinator(
        directory: URL,
        transport: BulletinAudioTransportRecorder,
        authority: BulletinAudioAuthority,
        activeBulletin: @escaping @MainActor (String) -> Bulletin?,
        bulletinFallback: @escaping @MainActor (String) async -> Bulletin? = { _ in nil },
        readyAudioURL: @escaping @MainActor (Bulletin, ApprovedReadingVoiceID) -> URL?,
        render: @escaping WiltedMacBulletinAudioCoordinator.RenderOperation
    ) -> WiltedMacBulletinAudioCoordinator {
        let fixedNow = now
        return WiltedMacBulletinAudioCoordinator(
            audioTransport: transport, deviceID: macID, directory: directory,
            currentOwner: { await authority.owner() },
            currentGeneration: { await authority.generation() },
            bulletin: activeBulletin, bulletinFallback: bulletinFallback, readyAudioURL: readyAudioURL,
            selectedVoice: { bulletin in bulletin.kind == .alert ? .rodSerling : .caseyKasem },
            voiceAvailability: { _ in .available },
            render: render, now: { fixedNow })
    }

    private func bulletin(id: String, text: String, expiresAt: Date? = nil) throws -> Bulletin {
        try Bulletin(
            id: id, kind: .headline, text: text, issuedAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(600))
    }

    private func eventuallyStatus(
        _ requestID: String, phase: LibraryListenNextStatus.Phase,
        from transport: BulletinAudioTransportRecorder
    ) async throws -> LibraryListenNextStatus {
        for _ in 0..<100 {
            let snapshot = await transport.snapshot()
            let statuses = snapshot.statusHistory
            if let status = statuses.last(where: { $0.requestID == requestID && $0.phase == phase }) {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await transport.snapshot()
        let statuses = snapshot.statusHistory
        XCTFail("Timed out waiting for \(phase.rawValue) status for \(requestID); saw \(statuses).")
        throw BulletinAudioTestError.statusTimedOut
    }
}
