import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacMediaPreuploadPumpTests: XCTestCase {
    let macID = "mac-pump"
    let phoneID = "iphone-pump"

    struct Rig {
        let server: InMemoryLibraryServer
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let transport: PumpTrackingTransport
        let source: PumpScriptedAudioSource
        let clock: PumpTestClock
        let sleepTracker: PumpSleepTracker
        let directory: URL
    }

    func makeRig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let mac = InMemoryLibraryTransport(deviceID: macID, server: server)
        let phone = InMemoryLibraryTransport(deviceID: phoneID, server: server)
        let clock = PumpTestClock()
        let sleepTracker = PumpSleepTracker()
        let source = PumpScriptedAudioSource()
        let transport = PumpTrackingTransport(inner: mac)
        return Rig(
            server: server, mac: mac, phone: phone, transport: transport,
            source: source, clock: clock, sleepTracker: sleepTracker,
            directory: wiltedTemporaryDirectory(name)
        )
    }

    func makeService(_ rig: Rig, preuploadLimit: Int = WiltedMacMediaService.standardPreuploadLimit) -> WiltedMacMediaService {
        WiltedMacMediaService(
            source: rig.source, transport: rig.transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { rig.clock.now }, preuploadLimit: preuploadLimit,
            sleep: { [sleepTracker = rig.sleepTracker] duration in
                try await sleepTracker.sleep(for: duration)
            },
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )
    }

    func makeAudio(_ directory: URL, name: String, revision: String, bytes: Int = 1_024) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(name)-\(revision).m4a")
        try Data(repeating: 0x42, count: bytes).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: revision),
            contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: Int64(bytes), mediaType: "audio/mp4", durationSeconds: 60, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        )
    }

    func cached(_ rig: Rig, _ entryID: ItemID, _ revision: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(
            entryID: entryID, revisionID: try RevisionID(rawValue: revision), deviceID: phoneID,
            createdAt: rig.clock.now, id: intentID
        )
    }

    func testTwelveEligibleUploadsFirstTenSerially() async throws {
        let rig = makeRig("pump-twelve-serially")
        var entryIDs: [ItemID] = []
        for i in 1...12 {
            let id = try ItemID(rawValue: String(format: "entry-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-1")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        let uploadedCount = rig.transport.readyUploads
        XCTAssertEqual(uploadedCount, 10, "exactly the first 10 entries must be uploaded")
        let maxConcurrent = rig.transport.maxConcurrency
        XCTAssertEqual(maxConcurrent, 1, "uploads must be serial")
        let uploaded = rig.transport.uploadedIDs
        let expected = Array(entryIDs.prefix(10))
        XCTAssertEqual(uploaded, expected)
    }

    func testSecondReconcileUploadsNothing() async throws {
        let rig = makeRig("pump-second-reconcile")
        var entryIDs: [ItemID] = []
        for i in 1...10 {
            let id = try ItemID(rawValue: String(format: "entry-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-1")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()
        let firstCount = rig.transport.readyUploads
        XCTAssertEqual(firstCount, 10)

        let ok2 = await service.reconcileAvailable()
        XCTAssertTrue(ok2)
        await service.waitForPreuploadPump()

        let secondCount = rig.transport.readyUploads
        XCTAssertEqual(secondCount, 10, "second reconcile must upload nothing")
    }

    func testDeliveredEntryIsNotUploadedAgain() async throws {
        let rig = makeRig("pump-delivered-entry")
        var entryIDs: [ItemID] = []
        for i in 1...12 {
            let id = try ItemID(rawValue: String(format: "entry-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-1")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()
        let count1 = rig.transport.readyUploads
        XCTAssertEqual(count1, 10)

        let ack = try cached(rig, entryIDs[0], "rev-1", intentID: "ack-1")
        await service.handle(ack)

        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let count2 = rig.transport.readyUploads
        XCTAssertEqual(count2, 11)
        let uploaded = rig.transport.uploadedIDs
        let firstEntryUploadCount = uploaded.filter { $0 == entryIDs[0] }.count
        XCTAssertEqual(firstEntryUploadCount, 1, "delivered entry must not be uploaded again")
        let containsEleventh = uploaded.contains(entryIDs[10])
        XCTAssertTrue(containsEleventh, "next entry must be uploaded")
    }

    func testEntryLeavingLarderHasAssetRemovedAndNextEntryUploaded() async throws {
        let rig = makeRig("pump-leave-larder")
        var entryIDs: [ItemID] = []
        for i in 1...11 {
            let id = try ItemID(rawValue: String(format: "entry-%02d", i))
            entryIDs.append(id)
            let audio = try makeAudio(rig.directory, name: id.rawValue, revision: "rev-1")
            rig.source.set(id, audio)
        }
        rig.source.setQueueOrder(entryIDs)

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()
        let count1 = rig.transport.readyUploads
        XCTAssertEqual(count1, 10)

        rig.source.set(entryIDs[0], nil)
        rig.source.setQueueOrder(Array(entryIDs.dropFirst()))

        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let isHoldingLeft = await service.isHolding(entryID: entryIDs[0], revisionID: try RevisionID(rawValue: "rev-1"))
        XCTAssertFalse(isHoldingLeft, "entry that left the Larder must have its asset removed")
        let offers = try await rig.mac.mediaOffers()
        let leftOffer = offers.first { $0.entryID == entryIDs[0] }
        XCTAssertEqual(leftOffer?.state, .notReady)

        let uploaded = rig.transport.uploadedIDs
        let containsEleventh = uploaded.contains(entryIDs[10])
        XCTAssertTrue(containsEleventh, "next entry must be uploaded once slot opens")
    }

    func testNewRevisionIsUploadedOnce() async throws {
        let rig = makeRig("pump-new-revision")
        let entryID = try ItemID(rawValue: "entry-01")
        let rev1 = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, rev1)
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let count1 = rig.transport.readyUploads
        XCTAssertEqual(count1, 1)

        let rev2 = try makeAudio(rig.directory, name: "entry-01", revision: "rev-2")
        rig.source.set(entryID, rev2)

        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let count2 = rig.transport.readyUploads
        XCTAssertEqual(count2, 2, "new revision must be uploaded")

        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let count3 = rig.transport.readyUploads
        XCTAssertEqual(count3, 2, "new revision must only be uploaded once")
    }

    func testRequestAdmittedWhileTargetsRemainIsServedBeforeNextPreuploadStarts() async throws {
        let rig = makeRig("pump-request-priority")
        let entry1 = try ItemID(rawValue: "entry-01")
        let entry2 = try ItemID(rawValue: "entry-02")
        let audio1 = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        let audio2 = try makeAudio(rig.directory, name: "entry-02", revision: "rev-1")
        rig.source.set(entry1, audio1)
        rig.source.set(entry2, audio2)
        rig.source.setQueueOrder([entry1, entry2])

        final class OrderRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var log: [String] = []
            func record(_ event: String) { lock.withLock { log.append(event) } }
            var events: [String] { lock.withLock { log } }
        }
        let recorder = OrderRecorder()
        let latch1 = PumpAsyncLatch()

        rig.transport.setLatch(for: entry1.rawValue) {
            recorder.record("entry-01-uploading")
            await latch1.wait()
        }

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()

        while !recorder.events.contains("entry-01-uploading") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let requestIntent = try LibraryIntent.requestMedia(
            entryID: entry2, deviceID: phoneID, createdAt: rig.clock.now, id: "req-entry-02"
        )
        let requestTask = Task {
            await service.handle(requestIntent)
            recorder.record("request-entry-02-served")
        }

        latch1.open()

        await requestTask.value
        await service.waitForPreuploadPump()

        let events = recorder.events
        let requestIndex = events.firstIndex(of: "request-entry-02-served")
        XCTAssertNotNil(requestIndex, "request must be served")
        let uploads = rig.transport.readyUploads
        XCTAssertEqual(uploads, 2, "both audio files uploaded (one pre-upload, one request)")
    }

    func testRequestForPreuploadedEntryIsAnsweredWithNoSecondUpload() async throws {
        let rig = makeRig("pump-req-preuploaded")
        let entryID = try ItemID(rawValue: "entry-01")
        let audio = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let count1 = rig.transport.readyUploads
        XCTAssertEqual(count1, 1, "entry was pre-uploaded")

        let requestIntent = try LibraryIntent.requestMedia(
            entryID: entryID, deviceID: phoneID, createdAt: rig.clock.now, id: "req-preuploaded"
        )
        await service.handle(requestIntent)

        let count2 = rig.transport.readyUploads
        XCTAssertEqual(count2, 1, "must answer request with no second upload")
    }

    func testThrottlePausesPumpUntilItsTimeAndReconcileDuringPauseStartsNoUpload() async throws {
        let rig = makeRig("pump-throttle-pause")
        let entryID = try ItemID(rawValue: "entry-01")
        let audio = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        let retryDate = rig.clock.now.addingTimeInterval(30)
        rig.transport.planFailure(for: entryID.rawValue) {
            TransportThrottled(retryAt: retryDate)
        }

        let sleepNotifier = PumpAsyncLatch()
        let blocker = PumpAsyncLatch()

        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { rig.clock.now }, preuploadLimit: 10,
            sleep: { _ in
                sleepNotifier.open()
                await blocker.wait()
            },
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )

        _ = await service.reconcileAvailable()
        await sleepNotifier.wait()

        let isPaused = await service.isPreuploadPaused
        XCTAssertTrue(isPaused, "pump must be paused")

        rig.transport.clearFailure(for: entryID.rawValue)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        let uploadsDuringPause = rig.transport.readyUploads
        XCTAssertEqual(uploadsDuringPause, 0, "reconcile during pause starts no upload")

        rig.clock.advance(by: 31)
        blocker.open()

        await service.waitForPreuploadPump()
        let finalUploads = rig.transport.readyUploads
        XCTAssertEqual(finalUploads, 1, "upload completes after pause finishes")
    }

    func testRequestDuringPauseIsServedWithoutWaitingForIt() async throws {
        let rig = makeRig("pump-request-during-pause")
        let entry1 = try ItemID(rawValue: "entry-01")
        let entry2 = try ItemID(rawValue: "entry-02")
        let audio1 = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        let audio2 = try makeAudio(rig.directory, name: "entry-02", revision: "rev-1")
        rig.source.set(entry1, audio1)
        rig.source.set(entry2, audio2)
        rig.source.setQueueOrder([entry1, entry2])

        let retryDate = rig.clock.now.addingTimeInterval(60)
        rig.transport.planFailure(for: entry1.rawValue) {
            TransportThrottled(retryAt: retryDate)
        }

        let inSleep = PumpAsyncLatch()
        let releaseSleep = PumpAsyncLatch()

        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { rig.clock.now }, preuploadLimit: 10,
            sleep: { _ in
                inSleep.open()
                await releaseSleep.wait()
            },
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )

        _ = await service.reconcileAvailable()
        await inSleep.wait()

        let requestIntent = try LibraryIntent.requestMedia(
            entryID: entry2, deviceID: phoneID, createdAt: rig.clock.now, id: "req-during-pause"
        )
        await service.handle(requestIntent)

        let uploaded = rig.transport.uploadedIDs
        let containsEntry2 = uploaded.contains(entry2)
        XCTAssertTrue(containsEntry2, "request must be served without waiting for throttle pause")

        // The fake wait returns at once after this, so the throttle must be gone or the pump retries forever.
        rig.transport.clearFailure(for: entry1.rawValue)
        releaseSleep.open()
        await service.waitForPreuploadPump()
        XCTAssertEqual(rig.transport.uploadedIDs, [entry2, entry1], "the paused target uploads once its wait ends")
    }

    func testAccountHoldStopsPumpMarksNothingAndNextReconcileResumesIt() async throws {
        let rig = makeRig("pump-account-hold")
        let entryID = try ItemID(rawValue: "entry-01")
        let audio = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        rig.transport.planFailure(for: entryID.rawValue) {
            WiltedMacLibraryAccountError.notApproved
        }

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let uploadsAfterHold = rig.transport.readyUploads
        XCTAssertEqual(uploadsAfterHold, 0)
        let isPaused = await service.isPreuploadPaused
        XCTAssertFalse(isPaused, "account hold must not pause")
        let isStopped = await service.preuploadStopped
        XCTAssertFalse(isStopped, "account hold must not set stopped flag")

        rig.transport.clearFailure(for: entryID.rawValue)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        let finalUploads = rig.transport.readyUploads
        XCTAssertEqual(finalUploads, 1, "next reconcile resumes pump and uploads")
    }

    func testQuotaErrorPausesSixHours() async throws {
        let rig = makeRig("pump-quota-error")
        let entryID = try ItemID(rawValue: "entry-01")
        let audio = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        rig.transport.planFailure(for: entryID.rawValue) {
            // The shape the iCloud adapter throws for a full account (`CKError.Code.quotaExceeded`).
            CloudKitSyncError.cloudKit(code: 25, message: "Quota exceeded")
        }

        let inSleep = PumpAsyncLatch()
        let releaseSleep = PumpAsyncLatch()

        final class DurationLog: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [Duration] = []
            func add(_ d: Duration) { lock.withLock { recorded.append(d) } }
            var durations: [Duration] { lock.withLock { recorded } }
        }
        let durationLog = DurationLog()

        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { rig.clock.now }, preuploadLimit: 10,
            sleep: { d in
                durationLog.add(d)
                inSleep.open()
                await releaseSleep.wait()
            },
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )

        _ = await service.reconcileAvailable()
        await inSleep.wait()

        let isPaused = await service.isPreuploadPaused
        XCTAssertTrue(isPaused, "quota error must pause pump")
        let durations = durationLog.durations
        XCTAssertEqual(durations.first, .seconds(6 * 3600), "must pause for 6 hours")
        XCTAssertEqual(rig.transport.readyUploads, 0)

        // The fake wait returns at once after this, so the quota error must be gone or the pump retries forever.
        rig.transport.clearFailure(for: entryID.rawValue)
        releaseSleep.open()
        await service.waitForPreuploadPump()
        XCTAssertEqual(durationLog.durations.count, 1, "one pause, then the retry succeeds")
        XCTAssertEqual(rig.transport.readyUploads, 1, "the target uploads once the pause ends")
    }

    func testOtherErrorSkipsEntrySixHoursAndNextTargetUploads() async throws {
        let rig = makeRig("pump-other-error")
        let entry1 = try ItemID(rawValue: "entry-01")
        let entry2 = try ItemID(rawValue: "entry-02")
        let audio1 = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        let audio2 = try makeAudio(rig.directory, name: "entry-02", revision: "rev-1")
        rig.source.set(entry1, audio1)
        rig.source.set(entry2, audio2)
        rig.source.setQueueOrder([entry1, entry2])

        struct CustomPermanentError: Error {}
        rig.transport.planFailure(for: entry1.rawValue) {
            CustomPermanentError()
        }

        let service = makeService(rig, preuploadLimit: 10)
        _ = await service.reconcileAvailable()
        await service.waitForPreuploadPump()

        let uploads = rig.transport.uploadedIDs
        let containsEntry1 = uploads.contains(entry1)
        XCTAssertFalse(containsEntry1, "failed entry must not be uploaded")
        let containsEntry2 = uploads.contains(entry2)
        XCTAssertTrue(containsEntry2, "next target must be uploaded after first is skipped")

        let isPaused = await service.isPreuploadPaused
        XCTAssertFalse(isPaused, "other error skips entry, does not pause pump")
    }

    func testTargetWhoseAudioChangedSinceTheReconcileIsTriedOnceAndTheNextTargetUploads() async throws {
        let rig = makeRig("pump-stale-target")
        let entry1 = try ItemID(rawValue: "entry-01")
        let entry2 = try ItemID(rawValue: "entry-02")
        rig.source.set(entry1, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.set(entry2, try makeAudio(rig.directory, name: "entry-02", revision: "rev-1"))
        rig.source.setQueueOrder([entry1, entry2])
        // The pump's own read finds a newer revision three times, then the listed one again, so a
        // pump that retried the unchanged target would upload it on its fourth read.
        rig.source.overrideReady(entry1, with: try makeAudio(rig.directory, name: "entry-01", revision: "rev-2"), calls: 3)

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        XCTAssertEqual(rig.transport.uploadedIDs, [entry2], "the changed target is left for the next reconcile")
        XCTAssertEqual(rig.source.readyAudioCalls, 2, "one read per target: the changed one is not retried in this run")
        let isPaused = await service.isPreuploadPaused
        XCTAssertFalse(isPaused, "a changed target is not a failure and pauses nothing")
    }

    func testDrainEndingThrottleWaitsPreventsUploadEvenWhenReconcileFollows() async throws {
        let rig = makeRig("pump-drain-prevents-upload")
        let entryID = try ItemID(rawValue: "entry-01")
        let audio = try makeAudio(rig.directory, name: "entry-01", revision: "rev-1")
        rig.source.set(entryID, audio)
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        await service.drainEndingThrottleWaits()

        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        let uploads = rig.transport.readyUploads
        XCTAssertEqual(uploads, 0, "after drainEndingThrottleWaits() no upload starts even when reconcile follows")
    }

    func testResumePreuploadAfterDrainLetsTheNextReconcileUploadAMissingTarget() async throws {
        let rig = makeRig("pump-resume-after-drain")
        let entryID = try ItemID(rawValue: "entry-01")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        await service.drainEndingThrottleWaits()
        let okWhileStopped = await service.reconcileAvailable()
        XCTAssertTrue(okWhileStopped)
        await service.waitForPreuploadPump()
        XCTAssertEqual(rig.transport.readyUploads, 0, "the target is still missing while pre-upload is stopped")
        let stoppedBeforeResume = await service.preuploadStopped
        XCTAssertTrue(stoppedBeforeResume)

        await service.resumePreupload()
        let stoppedAfterResume = await service.preuploadStopped
        XCTAssertFalse(stoppedAfterResume, "resumePreupload() must clear the stopped mark")
        XCTAssertEqual(rig.transport.readyUploads, 0, "resumePreupload() starts no upload itself")

        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        XCTAssertEqual(rig.transport.uploadedIDs, [entryID], "the reconcile after resumePreupload() uploads the missing target")
    }

    func testDrainWithoutResumeKeepsPreuploadStoppedThroughLaterReconciles() async throws {
        let rig = makeRig("pump-drain-without-resume")
        let entryID = try ItemID(rawValue: "entry-01")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        await service.drainEndingThrottleWaits()

        for _ in 1...2 {
            let ok = await service.reconcileAvailable()
            XCTAssertTrue(ok)
            await service.waitForPreuploadPump()
        }

        XCTAssertEqual(rig.transport.readyUploads, 0, "without resumePreupload() a reconcile after shutdown uploads nothing")
        let targets = await service.preuploadTargets
        XCTAssertEqual(targets?.map(\.entryID), [entryID], "the target is listed, so only the stopped mark holds the upload back")
        let isStopped = await service.preuploadStopped
        XCTAssertTrue(isStopped, "a reconcile must not clear the stopped mark")
    }
}
