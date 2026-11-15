import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacMediaPreuploadTests: XCTestCase {
    let macID = "mac-preupload"
    let phoneID = "iphone-preupload"

    struct Rig {
        let server: InMemoryLibraryServer
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let source: ScriptedAudioSource
        let clock: MutableClock
        let directory: URL
    }

    func makeRig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        return Rig(
            server: server,
            mac: InMemoryLibraryTransport(deviceID: macID, server: server),
            phone: InMemoryLibraryTransport(deviceID: phoneID, server: server),
            source: ScriptedAudioSource(),
            clock: MutableClock(Date(timeIntervalSince1970: 1_800_000_000)),
            directory: wiltedTemporaryDirectory(name)
        )
    }

    func makeService(_ rig: Rig, preuploadLimit: Int = WiltedMacMediaService.standardPreuploadLimit) -> WiltedMacMediaService {
        WiltedMacMediaService(
            source: rig.source,
            transport: rig.mac,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { rig.clock.now },
            preuploadLimit: preuploadLimit,
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )
    }

    func makeAudio(_ directory: URL, name: String, revision: String, bytes: Int = 1_024) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(name)-\(revision).m4a")
        try Data(repeating: 0x42, count: bytes).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: revision),
            contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: Int64(bytes),
            mediaType: "audio/mp4",
            durationSeconds: 60,
            fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        )
    }

    /// A `mediaCached` acknowledgement from the phone, the real path that marks an entry delivered.
    func cached(_ rig: Rig, _ entryID: ItemID, _ revision: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(
            entryID: entryID, revisionID: try RevisionID(rawValue: revision), deviceID: phoneID,
            createdAt: rig.clock.now, id: intentID
        )
    }

    func testPreuploadTargetsWithTwelveEligibleAndLimitTenEqualsFirstTen() async throws {
        let rig = makeRig("twelve-eligible")
        var entryIDs: [ItemID] = []
        for i in 1...12 {
            let id = try ItemID(rawValue: String(format: "entry-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-1")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        let beforeReconcile = await service.preuploadTargets
        XCTAssertNil(beforeReconcile, "targets must be unknown (nil) before first reconcile")

        let reconciled = await service.reconcileAvailable()
        XCTAssertTrue(reconciled)

        let targets = await service.preuploadTargets
        let expectedFirstTen = Array(entryIDs.prefix(10))
        XCTAssertEqual(targets?.count, 10)
        XCTAssertEqual(targets?.map(\.entryID), expectedFirstTen)
        let reread = await service.preuploadTargets
        XCTAssertEqual(reread?.map(\.entryID), expectedFirstTen)
    }

    func testPreuploadTargetsSkipsOversizeAndDeliveredEntriesTakingNextEligible() async throws {
        let rig = makeRig("skip-ineligible")
        var entryIDs: [ItemID] = []
        for i in 1...13 {
            let id = try ItemID(rawValue: String(format: "item-%02d", i))
            entryIDs.append(id)
        }

        // item-01: valid
        rig.source.set(entryIDs[0], try makeAudio(rig.directory, name: "item-01", revision: "rev-1", bytes: 1_024))
        // item-02: oversize (> 250 MB)
        let oversizeBytes = Int(WiltedMacMediaService.maximumByteCount + 1024)
        rig.source.set(entryIDs[1], try makeAudio(rig.directory, name: "item-02", revision: "rev-1", bytes: oversizeBytes))
        // item-03: delivered at this revision
        rig.source.set(entryIDs[2], try makeAudio(rig.directory, name: "item-03", revision: "rev-1", bytes: 1_024))
        // item-04: file size mismatch
        let mismatchFile = rig.directory.appendingPathComponent("mismatch.m4a")
        try Data(repeating: 0x11, count: 512).write(to: mismatchFile)
        rig.source.set(entryIDs[3], WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: "rev-mismatch"),
            contentHash: "hash-mismatch",
            byteCount: 2048,
            mediaType: "audio/mp4",
            durationSeconds: 60,
            fileURL: mismatchFile,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        ))
        // item-05...item-13: valid
        for i in 4..<13 {
            rig.source.set(entryIDs[i], try makeAudio(rig.directory, name: entryIDs[i].rawValue, revision: "rev-1", bytes: 1_024))
        }

        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        // The phone acknowledges item-03 at rev-1, which marks it delivered at that revision.
        await service.handle(try cached(rig, entryIDs[2], "rev-1", intentID: "ack-item-03"))
        let deliveredBefore = await service.delivered
        XCTAssertEqual(deliveredBefore[entryIDs[2].rawValue], "rev-1")

        let reconciled = await service.reconcileAvailable()
        XCTAssertTrue(reconciled)

        let targets = await service.preuploadTargets
        XCTAssertEqual(targets?.count, 10)
        let targetIDs = targets?.map(\.entryID) ?? []
        XCTAssertTrue(targetIDs.contains(entryIDs[0]))
        XCTAssertFalse(targetIDs.contains(entryIDs[1]), "oversize entry must be skipped")
        XCTAssertFalse(targetIDs.contains(entryIDs[2]), "delivered entry must be skipped")
        XCTAssertFalse(targetIDs.contains(entryIDs[3]), "mismatched file size must be skipped")
        for i in 4..<13 {
            XCTAssertTrue(targetIDs.contains(entryIDs[i]), "next eligible entry \(entryIDs[i].rawValue) must take its place")
        }
    }

    func testPreuploadTargetsWithLimitZeroReturnsEmpty() async throws {
        let rig = makeRig("limit-zero")
        let entryID = try ItemID(rawValue: "entry-01")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 0)
        let beforeReconcile = await service.preuploadTargets
        XCTAssertNil(beforeReconcile, "targets must be unknown before first reconcile")

        let reconciled = await service.reconcileAvailable()
        XCTAssertTrue(reconciled)
        let targets = await service.preuploadTargets
        XCTAssertEqual(targets, [], "limit 0 must return no targets (empty array)")
    }

    func testAcknowledgementMarksDeliveredAndSurvivesReloadingAccountingFile() async throws {
        let rig = makeRig("ack-delivered")
        let service = makeService(rig)
        let entryID = try ItemID(rawValue: "entry-delivered")
        let revisionID = try RevisionID(rawValue: "rev-ack")

        let intent = try LibraryIntent.mediaCached(
            entryID: entryID, revisionID: revisionID, deviceID: "iphone-ack", createdAt: rig.clock.now, id: "ack-1"
        )
        await service.handle(intent)

        let delivered = await service.delivered
        XCTAssertEqual(delivered[entryID.rawValue], revisionID.rawValue)

        let reloaded = makeService(rig)
        let reloadedDelivered = await reloaded.delivered
        XCTAssertEqual(reloadedDelivered[entryID.rawValue], revisionID.rawValue, "delivered accounting must survive reload")
    }

    func testAccountingFileWithoutDeliveredFieldDecodes() async throws {
        let rig = makeRig("legacy-accounting")
        let accountingURL = rig.directory.appendingPathComponent("media-accounting.json")
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
            "version": 1,
            "records": [],
            "published": {"entry-legacy": "rev-legacy"}
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: accountingURL)

        let service = makeService(rig)
        let delivered = await service.delivered
        let accountedAssetCount = await service.accountedAssetCount
        let published = await service.published
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(accountedAssetCount, 0)
        // A failed decode would also start empty, so prove the file was read rather than set aside.
        XCTAssertEqual(published["entry-legacy"], "rev-legacy", "the older file's books must load")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: accountingURL.appendingPathExtension("corrupt").path),
            "an older file without the field must not be set aside as unreadable"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountingURL.path))
    }

    func testRequesterLessAcknowledgedRecordIsWithdrawnToAvailable() async throws {
        let rig = makeRig("requester-less-ack")
        let entryID = try ItemID(rawValue: "entry-reqless")
        let audio = try makeAudio(rig.directory, name: "entry-reqless", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()

        let key = WiltedMacMediaService.AssetKey(entryID: entryID.rawValue, revisionID: audio.revisionID.rawValue)
        let availableOffer = try LibraryMediaOffer(
            entryID: entryID, revisionID: audio.revisionID, contentHash: audio.contentHash,
            byteCount: audio.byteCount, mediaType: audio.mediaType, durationSeconds: audio.durationSeconds,
            state: .available, preparation: audio.preparation
        )
        let readyOffer = try LibraryMediaOffer(
            entryID: entryID, revisionID: audio.revisionID, contentHash: audio.contentHash,
            byteCount: audio.byteCount, mediaType: audio.mediaType, durationSeconds: audio.durationSeconds,
            state: .ready, preparation: audio.preparation
        )

        await service.seedPreuploadedAsset(
            WiltedMacMediaService.AssetRecord(key: key, requesters: [], acked: [], touchedAt: rig.clock.now),
            available: availableOffer, uploaded: readyOffer
        )

        let seeded = await service.records[key]
        XCTAssertNotNil(seeded)
        XCTAssertFalse(try XCTUnwrap(seeded).isComplete)

        let ack = try LibraryIntent.mediaCached(
            entryID: entryID, revisionID: audio.revisionID, deviceID: "phone-ack", createdAt: rig.clock.now, id: "ack-reqless"
        )
        await service.handle(ack)

        let recordAfter = await service.records[key]
        let publishedAfter = await service.published[entryID.rawValue]
        let offeredAfter = await service.offered[entryID.rawValue]
        XCTAssertNil(recordAfter, "record must be removed once complete")
        XCTAssertNil(publishedAfter, "audio must no longer be published")
        XCTAssertEqual(offeredAfter?.state, .available, "offer must be withdrawn to available")
    }

    func testEightDayOldRequesterLessRecordKeptBeforeFirstReconcileAndWhileTargetAndWithdrawnOutsideTargets() async throws {
        let rig = makeRig("eight-day-rule")
        let entryID = try ItemID(rawValue: "entry-aged")
        let audio = try makeAudio(rig.directory, name: "entry-aged", revision: "rev-aged")
        let key = WiltedMacMediaService.AssetKey(entryID: entryID.rawValue, revisionID: audio.revisionID.rawValue)
        let eightDaysAgo = rig.clock.now.addingTimeInterval(-8 * 24 * 60 * 60)

        let availableOffer = try LibraryMediaOffer(
            entryID: entryID, revisionID: audio.revisionID, contentHash: audio.contentHash,
            byteCount: audio.byteCount, mediaType: audio.mediaType, durationSeconds: audio.durationSeconds,
            state: .available, preparation: audio.preparation
        )
        let readyOffer = try LibraryMediaOffer(
            entryID: entryID, revisionID: audio.revisionID, contentHash: audio.contentHash,
            byteCount: audio.byteCount, mediaType: audio.mediaType, durationSeconds: audio.durationSeconds,
            state: .ready, preparation: audio.preparation
        )

        let service = makeService(rig, preuploadLimit: 10)
        await service.seedPreuploadedAsset(
            WiltedMacMediaService.AssetRecord(key: key, requesters: [], acked: [], touchedAt: eightDaysAgo),
            available: availableOffer, uploaded: readyOffer
        )

        // Stage 1: Before first reconcile (targets are nil)
        let targetsBefore = await service.preuploadTargets
        XCTAssertNil(targetsBefore)
        await service.sweepExpired()
        let recordBeforeReconcile = await service.records[key]
        XCTAssertNotNil(recordBeforeReconcile, "requester-less record must be kept while targets are nil")

        // Stage 2: Target is known and entry IS a target
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])
        let ok1 = await service.reconcileAvailable()
        XCTAssertTrue(ok1)
        let targetsWhileTarget = await service.preuploadTargets
        XCTAssertTrue(targetsWhileTarget?.contains(where: { $0.entryID == entryID }) == true)
        await service.sweepExpired()
        let recordWhileTarget = await service.records[key]
        XCTAssertNotNil(recordWhileTarget, "requester-less record must be kept while it is a target")

        // Stage 3: Targets change and entry is NO LONGER a target
        var otherIDs: [ItemID] = []
        for i in 1...10 {
            let otherID = try ItemID(rawValue: String(format: "other-%02d", i))
            otherIDs.append(otherID)
            rig.source.set(otherID, try makeAudio(rig.directory, name: otherID.rawValue, revision: "rev-other"))
        }
        rig.source.setQueueOrder(otherIDs + [entryID])
        let ok2 = await service.reconcileAvailable()
        XCTAssertTrue(ok2)
        let targetsOutside = await service.preuploadTargets
        XCTAssertFalse(targetsOutside?.contains(where: { $0.entryID == entryID }) == true, "entry must be pushed out of top 10")

        await service.sweepExpired()
        let recordOutside = await service.records[key]
        let publishedOutside = await service.published[entryID.rawValue]
        let offeredOutside = await service.offered[entryID.rawValue]
        XCTAssertNil(recordOutside, "requester-less record must be withdrawn once outside targets")
        XCTAssertNil(publishedOutside)
        XCTAssertEqual(offeredOutside?.state, .available)
    }

    func testModelLibrarySyncPassesStandardPreuploadLimitSourceAssertion() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fileURL = repoRoot.appendingPathComponent("WiltedMac/ViewModel/WiltedMacModel+LibrarySync.swift")
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("preuploadLimit: WiltedMacMediaService.standardPreuploadLimit"),
            "WiltedMacModel+LibrarySync.swift must pass preuploadLimit: WiltedMacMediaService.standardPreuploadLimit"
        )
    }

    func testInboundRuntimeBuiltWithPreuploadLimitTenHasMediaServiceHoldingTargets() async throws {
        let rig = makeRig("runtime-preupload")
        var entryIDs: [ItemID] = []
        for i in 1...12 {
            let id = try ItemID(rawValue: String(format: "runtime-item-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-rt")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let clock = rig.clock
        let runtime = WiltedMacInboundRuntime(
            source: rig.source,
            transport: rig.mac,
            directory: rig.directory,
            preuploadLimit: 10,
            now: { clock.now }
        )

        let reconciled = await runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled)

        let targets = await runtime.service.preuploadTargets
        let expectedFirstTen = Array(entryIDs.prefix(10))
        XCTAssertEqual(targets?.count, 10)
        XCTAssertEqual(targets?.map(\.entryID), expectedFirstTen)
        let reread = await runtime.service.preuploadTargets
        XCTAssertEqual(reread?.map(\.entryID), expectedFirstTen)
    }

    func testReconcilePrunesDeliveredEntriesNoLongerInLarder() async throws {
        let rig = makeRig("prune-delivered")
        let inLarder = try ItemID(rawValue: "item-in-larder")
        let leftLarder = try ItemID(rawValue: "item-left-larder")

        rig.source.set(inLarder, try makeAudio(rig.directory, name: inLarder.rawValue, revision: "rev-1"))
        rig.source.setQueueOrder([inLarder])

        let service = makeService(rig, preuploadLimit: 10)
        // Real acknowledgements mark both delivered; one entry has since left the Larder.
        await service.handle(try cached(rig, inLarder, "rev-1", intentID: "ack-in-larder"))
        await service.handle(try cached(rig, leftLarder, "rev-old", intentID: "ack-left-larder"))
        let deliveredBefore = await service.delivered
        XCTAssertEqual(deliveredBefore[inLarder.rawValue], "rev-1")
        XCTAssertEqual(deliveredBefore[leftLarder.rawValue], "rev-old", "both entries must be delivered before the reconcile")

        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)

        let deliveredAfter = await service.delivered
        XCTAssertEqual(deliveredAfter[inLarder.rawValue], "rev-1")
        XCTAssertNil(deliveredAfter[leftLarder.rawValue], "entry no longer in Larder must be pruned from delivered")
    }

    func testDeliveredMarkOutlivesALossOfPreparedAudioWhileTheEntryStaysOnTheLarder() async throws {
        let rig = makeRig("delivered-kept")
        let entryID = try ItemID(rawValue: "item-kept")
        let audio = try makeAudio(rig.directory, name: entryID.rawValue, revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])
        let service = makeService(rig, preuploadLimit: 10)
        await service.handle(try cached(rig, entryID, "rev-1", intentID: "ack-kept"))

        // The prepared audio goes missing for a round; the entry is still on the Larder.
        rig.source.set(entryID, nil)
        let withoutAudio = await service.reconcileAvailable()
        XCTAssertTrue(withoutAudio)
        let kept = await service.delivered
        XCTAssertEqual(kept[entryID.rawValue], "rev-1", "the mark must outlive the loss of prepared audio")

        // The same revision comes back: a device already has it, so it is not a target again.
        rig.source.set(entryID, audio)
        let withAudio = await service.reconcileAvailable()
        XCTAssertTrue(withAudio)
        let targets = await service.preuploadTargets
        XCTAssertEqual(targets?.map(\.entryID), [], "acknowledged audio must not be uploaded again")
    }
}

extension WiltedMacMediaService {
    /// Books an asset the way a pre-upload leaves it (no requesters), since the upload itself is
    /// a later change: the record, the published revision and both offers.
    func seedPreuploadedAsset(_ record: AssetRecord, available: LibraryMediaOffer, uploaded: LibraryMediaOffer) {
        records[record.key] = record
        published[record.key.entryID] = record.key.revisionID
        availableOffers[record.key.entryID] = available
        offered[record.key.entryID] = uploaded
    }
}
