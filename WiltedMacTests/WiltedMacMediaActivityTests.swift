import Foundation
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacMediaActivityTests: XCTestCase {
    let macID = "mac-activity"
    let phoneID = "iphone-activity"

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

    private func makeModel(_ name: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    private func bootstrapped(_ name: String) async throws -> WiltedMacModel {
        let model = makeModel(name)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    // 1. Before the first reconcile preupload is nil
    func testBeforeFirstReconcilePreuploadIsNil() async throws {
        let rig = makeRig("activity-before-reconcile")
        let service = makeService(rig, preuploadLimit: 10)
        let activity = await service.activitySnapshot()
        XCTAssertNil(activity.preupload)
        XCTAssertEqual(activity.requestsQueued, 0)
    }

    // 2. After a reconcile with three targets and none uploaded targetCount == 3 and uploadedCount == 0
    func testAfterReconcileWithThreeTargetsAndNoneUploaded() async throws {
        let rig = makeRig("activity-reconcile-three")
        let id1 = try ItemID(rawValue: "entry-01")
        let id2 = try ItemID(rawValue: "entry-02")
        let id3 = try ItemID(rawValue: "entry-03")
        rig.source.set(id1, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.set(id2, try makeAudio(rig.directory, name: "entry-02", revision: "rev-1"))
        rig.source.set(id3, try makeAudio(rig.directory, name: "entry-03", revision: "rev-1"))
        rig.source.setQueueOrder([id1, id2, id3])

        let latch = PumpAsyncLatch()
        rig.transport.setLatch(for: id1.rawValue) { await latch.wait() }

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.targetCount, 3)
        XCTAssertEqual(preupload.uploadedCount, 0)

        latch.open()
        await service.waitForPreuploadPump()
    }

    // 3. While an upload is held open by a latch uploadingID is that entry
    func testWhileUploadHeldOpenUploadingIDIsThatEntry() async throws {
        let rig = makeRig("activity-uploading-id")
        let entryID = try ItemID(rawValue: "entry-held")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-held", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let inUpload = PumpAsyncLatch()
        let releaseUpload = PumpAsyncLatch()

        rig.transport.setLatch(for: entryID.rawValue) {
            inUpload.open()
            await releaseUpload.wait()
        }

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await inUpload.wait()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.uploadingID, entryID.rawValue)

        releaseUpload.open()
        await service.waitForPreuploadPump()
    }

    // 4. After the pump finishes uploadedCount == targetCount and uploadingID is nil
    func testAfterPumpFinishesUploadedCountEqualsTargetCountAndUploadingIDIsNil() async throws {
        let rig = makeRig("activity-pump-finishes")
        let id1 = try ItemID(rawValue: "entry-01")
        let id2 = try ItemID(rawValue: "entry-02")
        rig.source.set(id1, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.set(id2, try makeAudio(rig.directory, name: "entry-02", revision: "rev-1"))
        rig.source.setQueueOrder([id1, id2])

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.targetCount, 2)
        XCTAssertEqual(preupload.uploadedCount, preupload.targetCount)
        XCTAssertNil(preupload.uploadingID)
    }

    // 5. A quota error gives pausedUntil six hours ahead with storageFull
    func testQuotaErrorGivesPausedUntilSixHoursAheadWithStorageFull() async throws {
        let rig = makeRig("activity-quota-error")
        let entryID = try ItemID(rawValue: "entry-quota")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-quota", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        rig.transport.planFailure(for: entryID.rawValue) {
            CloudKitSyncError.cloudKit(code: 25, message: "Quota exceeded")
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

        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await inSleep.wait()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.pauseReason, .storageFull)
        let expectedPausedUntil = rig.clock.now.addingTimeInterval(6 * 3600)
        let pausedUntil = try XCTUnwrap(preupload.pausedUntil)
        XCTAssertEqual(pausedUntil.timeIntervalSince1970, expectedPausedUntil.timeIntervalSince1970, accuracy: 1)

        rig.transport.clearFailure(for: entryID.rawValue)
        releaseSleep.open()
        await service.waitForPreuploadPump()
    }

    // 6. A transient error gives retrying
    func testTransientErrorGivesRetrying() async throws {
        let rig = makeRig("activity-transient-error")
        let entryID = try ItemID(rawValue: "entry-transient")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-transient", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let retryDate = rig.clock.now.addingTimeInterval(30)
        rig.transport.planFailure(for: entryID.rawValue) {
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

        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await inSleep.wait()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.pauseReason, .retrying)
        XCTAssertEqual(preupload.pausedUntil, retryDate)

        rig.transport.clearFailure(for: entryID.rawValue)
        releaseSleep.open()
        await service.waitForPreuploadPump()
    }

    // 7. A target that fails for another reason raises setAsideCount
    func testOtherErrorRaisesSetAsideCount() async throws {
        let rig = makeRig("activity-other-error")
        let entry1 = try ItemID(rawValue: "entry-01")
        let entry2 = try ItemID(rawValue: "entry-02")
        rig.source.set(entry1, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.set(entry2, try makeAudio(rig.directory, name: "entry-02", revision: "rev-1"))
        rig.source.setQueueOrder([entry1, entry2])

        struct OtherFailure: Error {}
        rig.transport.planFailure(for: entry1.rawValue) { OtherFailure() }

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.waitForPreuploadPump()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.setAsideCount, 1)
        XCTAssertEqual(preupload.uploadedCount, 1)
    }

    // 8. After drainEndingThrottleWaits() isStopped is true
    func testAfterDrainEndingThrottleWaitsIsStoppedIsTrue() async throws {
        let rig = makeRig("activity-drain-stopped")
        let entryID = try ItemID(rawValue: "entry-01")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "entry-01", revision: "rev-1"))
        rig.source.setQueueOrder([entryID])

        let service = makeService(rig, preuploadLimit: 10)
        let ok = await service.reconcileAvailable()
        XCTAssertTrue(ok)
        await service.drainEndingThrottleWaits()

        let activity = await service.activitySnapshot()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertTrue(preupload.isStopped)
    }

    // 9. A runtime with one queued request reports requestsQueued == 1
    func testRuntimeWithOneQueuedRequestReportsRequestsQueuedOne() async throws {
        let rig = makeRig("activity-requests-queued")
        let entryID = try ItemID(rawValue: "req-entry")
        rig.source.set(entryID, try makeAudio(rig.directory, name: "req-entry", revision: "rev-1"))
        let uploading = PumpAsyncLatch()
        let release = PumpAsyncLatch()
        rig.transport.setLatch(for: entryID.rawValue) {
            uploading.open()
            await release.wait()
        }
        // No ahead-of-time uploads here: the request is the only upload.
        let runtime = WiltedMacInboundRuntime(
            source: rig.source, transport: rig.transport, directory: rig.directory, preuploadLimit: 0
        )

        let intent = try LibraryIntent.requestMedia(
            entryID: entryID, deviceID: phoneID, createdAt: Date(), id: "req-intent-1"
        )
        let admitted = await runtime.admit(intent)
        let serving = try XCTUnwrap(admitted)
        await uploading.wait()

        let held = await runtime.mediaActivity()
        XCTAssertEqual(held.requestsQueued, 1, "a request stays queued while its upload runs")
        XCTAssertNil(held.preupload)

        release.open()
        await serving.value
        let served = await runtime.mediaActivity()
        XCTAssertEqual(served.requestsQueued, 0)

        await runtime.close()
    }

    // Extra: runtime start after stop resumes preupload and reports isStopped == false after reconcile
    func testRuntimeRestartClearsIsStoppedSoReconcileReportsNotStopped() async throws {
        let directory = wiltedTemporaryDirectory("activity-runtime-restart")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let source = PumpScriptedAudioSource()
        let entryID = try ItemID(rawValue: "restart-entry")
        let audio = try makeAudio(directory, name: "restart-entry", revision: "rev-1")
        source.set(entryID, audio)
        source.setQueueOrder([entryID])

        let runtime = WiltedMacInboundRuntime(
            source: source,
            transport: transport,
            directory: directory,
            preuploadLimit: 10
        )

        let initialStartup = try XCTUnwrap(runtime.start(sink: WiltedMacLibraryIntentSink()))
        await initialStartup.value

        let ok1 = await runtime.service.reconcileAvailable()
        XCTAssertTrue(ok1)
        await runtime.service.waitForPreuploadPump()

        let initialActivity = await runtime.mediaActivity()
        let initialPreupload = try XCTUnwrap(initialActivity.preupload)
        XCTAssertFalse(initialPreupload.isStopped)

        let stopping = runtime.stop()
        await stopping?.value

        let stoppedActivity = await runtime.mediaActivity()
        let stoppedPreupload = try XCTUnwrap(stoppedActivity.preupload)
        XCTAssertTrue(stoppedPreupload.isStopped, "stop() must leave preupload marked stopped")

        let restartedStartup = try XCTUnwrap(runtime.start(sink: WiltedMacLibraryIntentSink()))
        await restartedStartup.value

        let ok2 = await runtime.service.reconcileAvailable()
        XCTAssertTrue(ok2)

        let resumedActivity = await runtime.mediaActivity()
        let resumedPreupload = try XCTUnwrap(resumedActivity.preupload)
        XCTAssertFalse(resumedPreupload.isStopped, "start() after stop() must clear stopped so reconcile reports isStopped == false")

        await runtime.close()
    }

    // Extra: model refreshMediaActivity updates librarySyncActivity.media
    func testModelRefreshMediaActivityUpdatesLibrarySyncActivity() async throws {
        let model = try await bootstrapped("activity-model-refresh")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: server)
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "1"], transport: transport))

        XCTAssertNil(model.librarySyncActivity.media)

        await model.refreshMediaActivity()

        let media = try XCTUnwrap(model.librarySyncActivity.media)
        XCTAssertEqual(media.requestsQueued, 0)
        XCTAssertNil(media.preupload)

        model.stopLibrarySync()
        XCTAssertNil(model.librarySyncActivity.media)
    }
}
