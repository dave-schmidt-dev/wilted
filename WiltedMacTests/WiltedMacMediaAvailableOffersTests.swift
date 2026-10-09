import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Proactive `available` offers: published without an upload, flipped to `ready` by a request, returned
/// to `available` once every requester cached it, and withdrawn when the entry leaves the Larder.

extension WiltedMacMediaServiceTests {
    private func availableRig(_ name: String, revision: String = "rev-1") throws -> (Rig, ItemID, WiltedMacReadyAudio, WiltedMacInboundRuntime) {
        let rig = rig(name)
        let entry = try id("episode-available")
        let audio = try makeAudio(rig.directory, revision: revision)
        rig.source.set(entry, audio)
        rig.source.setQueued(entry, true)
        return (rig, entry, audio, runtime(rig))
    }

    private func onlyOffer(_ rig: Rig) async throws -> LibraryMediaOffer {
        let offers = try await rig.phone.mediaOffers()
        return try XCTUnwrap(offers.first)
    }

    func testAPreparedQueuedEntryGetsAnAvailableOfferWithoutAnyUpload() async throws {
        let (rig, entry, audio, runtime) = try availableRig("available-proactive")

        let ok = await runtime.service.reconcileAvailable()

        XCTAssertTrue(ok)
        let offer = try await onlyOffer(rig)
        XCTAssertEqual(offer.entryID, entry)
        XCTAssertEqual(offer.state, .available)
        XCTAssertEqual(offer.revisionID, audio.revisionID)
        XCTAssertEqual(offer.byteCount, audio.byteCount)
        XCTAssertEqual(offer.mediaType, audio.mediaType)
        XCTAssertEqual(offer.durationSeconds, audio.durationSeconds)
        XCTAssertEqual(offer.contentHash, audio.contentHash, "prepared available certifies the exact audio without uploading")
        XCTAssertEqual(offer.preparation, audio.preparation)
        XCTAssertTrue(offer.isPrepared)
        do {
            _ = try await rig.phone.fetchMedia(offer) { _ in }
            XCTFail("an available offer cannot be fetched")
        } catch {}
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertFalse(holding)
        XCTAssertEqual(rig.source.lookupCount, 0, "reconciling reads the prepared set, not per-entry audio")
    }

    func testARequestUploadsAndFlipsTheOfferToReadyAndAReconcileKeepsItReady() async throws {
        let (rig, entry, audio, runtime) = try availableRig("available-flip")
        await runtime.service.reconcileAvailable()

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "f-1"))
        await runtime.service.reconcileAvailable()

        let offer = try await onlyOffer(rig)
        XCTAssertEqual(offer.state, .ready)
        XCTAssertEqual(offer.contentHash, audio.contentHash)
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testAfterEveryRequesterCachedTheOfferReturnsToAvailableInsteadOfDisappearing() async throws {
        let (rig, entry, audio, runtime) = try availableRig("available-return")
        await runtime.service.reconcileAvailable()
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "w-1"))

        await runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, intentID: "w-2"))

        let offer = try await onlyOffer(rig)
        XCTAssertEqual(offer.state, .available)
        XCTAssertEqual(offer.revisionID, audio.revisionID)
        XCTAssertEqual(offer.contentHash, audio.contentHash)
        XCTAssertEqual(offer.preparation, audio.preparation)
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertFalse(holding)
        let books = await runtime.service.accountedAssetCount
        XCTAssertEqual(books, 0)
        await runtime.consume(try request(rig, entry, from: tabletID, intentID: "w-3"))
        let again = try await rig.phone.mediaOffers().first?.state
        XCTAssertEqual(again, .ready, "a later request uploads again")
    }

    func testTheOfferIsWithdrawnWhenTheEntryLeavesTheLarderOrIsUnprepared() async throws {
        let (rig, entry, _, runtime) = try availableRig("available-withdraw")
        await runtime.service.reconcileAvailable()
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "x-1"))
        let priorReady = try await onlyOffer(rig)

        rig.source.setQueued(entry, false)
        await runtime.service.reconcileAvailable()
        var offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .notReady, "leaving the Larder explicitly revokes preparation")
        XCTAssertFalse(offers.contains { $0.isPrepared })
        do {
            _ = try await rig.phone.fetchMedia(priorReady) { _ in }
            XCTFail("withdrawal removes the prior ready asset, not only its offer authority")
        } catch {}
        let books = await runtime.service.accountedAssetCount
        XCTAssertEqual(books, 0)

        rig.source.setQueued(entry, true)
        await runtime.service.reconcileAvailable()
        offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .available)

        rig.source.set(entry, nil)
        await runtime.service.reconcileAvailable()
        offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .notReady, "an unprepared entry explicitly revokes preparation")
        XCTAssertFalse(offers.contains { $0.isPrepared })
    }

    func testANewRevisionReplacesTheOfferAndItsAsset() async throws {
        let (rig, entry, _, runtime) = try availableRig("available-revision")
        await runtime.service.reconcileAvailable()
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "n-1"))

        let newer = try makeAudio(rig.directory, revision: "rev-2", bytes: 2_048)
        rig.source.set(entry, newer)
        await runtime.service.reconcileAvailable()

        let offer = try await onlyOffer(rig)
        XCTAssertEqual(offer.state, .available)
        XCTAssertEqual(offer.revisionID, newer.revisionID)
        XCTAssertEqual(offer.byteCount, 2_048)
        let books = await runtime.service.accountedAssetCount
        XCTAssertEqual(books, 0, "the old revision's audio is gone from the transport")
    }

    func testSameRevisionPreparationRenewalChangesTheOfferAndDropsTheOldAsset() async throws {
        let (rig, entry, audio, runtime) = try availableRig("available-proof-renewal")
        await runtime.service.reconcileAvailable()
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "proof-1"))
        var renewed = audio
        renewed.preparation = LibraryMediaPreparation(preparedAt: Timestamp(audio.preparation.preparedAt.date.addingTimeInterval(60)))
        rig.source.set(entry, renewed)
        let reconciled = await runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled)
        let offer = try await onlyOffer(rig)
        XCTAssertEqual(offer.state, .available)
        XCTAssertEqual(offer.revisionID, audio.revisionID)
        XCTAssertEqual(offer.contentHash, audio.contentHash)
        XCTAssertEqual(offer.preparation, renewed.preparation)
        let books = await runtime.service.accountedAssetCount
        XCTAssertEqual(books, 0)
        do {
            _ = try await rig.phone.fetchMedia(offer) { _ in }
            XCTFail("renewal drops the prior asset until a new request")
        } catch {}
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "proof-2"))
        let ready = try await onlyOffer(rig)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.preparation, renewed.preparation)
    }

    func testAStartedServiceWithdrawsAStaleOfferItFindsOnTheTransport() async throws {
        let (rig, _, _, first) = try availableRig("available-restart")
        await first.service.reconcileAvailable()
        let stale = try id("episode-stale")
        try await rig.mac.publishMedia(offer: try LibraryMediaOffer(
            entryID: stale, revisionID: RevisionID(rawValue: "rev-9"), contentHash: "", byteCount: 10,
            mediaType: "audio/mp4", state: .available), fileURL: URL(fileURLWithPath: "/dev/null"))

        // A restarted Mac has no memory of what it published; the transport is the truth.
        let restarted = runtime(rig)
        await restarted.service.reconcileAvailable()

        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.filter { $0.isPrepared }.map(\.entryID.rawValue), ["episode-available"])
        XCTAssertEqual(offers.first { $0.entryID == stale }?.state, .notReady)
    }
}

