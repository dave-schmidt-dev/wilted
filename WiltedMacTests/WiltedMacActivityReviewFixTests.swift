import Foundation
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
import XCTest
@testable import WiltedMac

/// Regressions for the Mac Activity checkpoint review: a read across a restart, preparation
/// counts, and the uploading entry after its audio is booked.
final class WiltedMacActivityReviewFixTests: XCTestCase {
    private func makeAudio(_ directory: URL, name: String) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(name).m4a")
        try Data(repeating: 0x42, count: 1_024).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: "rev-1"), contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: 1_024, mediaType: "audio/mp4", durationSeconds: 60, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        )
    }

    private func episode(_ id: String, _ state: WiltedMacEpisodePreparationState) -> WiltedMacEpisode {
        var episode = WiltedMacEpisode(
            id: id, title: id, feedTitle: "A show", summary: "", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_699_000_000), publishedAt: nil,
            sourceDurationSeconds: 60, durationSeconds: 60, playbackSeconds: 0, downloadState: .notDownloaded
        )
        episode.preparationState = state
        return episode
    }

    /// While the transcript is sent after the audio, the entry is counted as uploaded, not as
    /// being sent, so the row never reads "Sending 2 of 1".
    @MainActor
    func testEntryWhoseAudioIsBookedIsNotReportedAsSending() async throws {
        let directory = wiltedTemporaryDirectory("activity-fix-transcript")
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac"))
        let source = PumpScriptedAudioSource()
        let entryID = try ItemID(rawValue: "booked-entry")
        source.set(entryID, try makeAudio(directory, name: "booked-entry"))
        source.setQueueOrder([entryID])
        let inTranscript = PumpAsyncLatch()
        let release = PumpAsyncLatch()
        source.holdTranscriptReads {
            inTranscript.open()
            await release.wait()
        }
        let runtime = WiltedMacInboundRuntime(source: source, transport: transport, directory: directory, preuploadLimit: 10)

        let ok = await runtime.service.reconcileAvailable()
        XCTAssertTrue(ok)
        await inTranscript.wait()

        let activity = await runtime.mediaActivity()
        let preupload = try XCTUnwrap(activity.preupload)
        XCTAssertEqual(preupload.uploadedCount, 1)
        XCTAssertNil(preupload.uploadingID, "the booked entry is not the one being sent")

        release.open()
        await runtime.service.waitForPreuploadPump()
        await runtime.close()
    }

    /// Each start and stop of the same runtime moves its lifecycle on.
    @MainActor
    func testRuntimeLifecycleMovesOnAtStartAndStop() async throws {
        let directory = wiltedTemporaryDirectory("activity-fix-lifecycle")
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac"))
        let runtime = WiltedMacInboundRuntime(
            source: PumpScriptedAudioSource(), transport: transport, directory: directory, preuploadLimit: 0
        )
        let start = runtime.lifecycle
        await runtime.start(sink: WiltedMacLibraryIntentSink())?.value
        XCTAssertEqual(runtime.lifecycle, start + 1)
        await runtime.stop()?.value
        XCTAssertEqual(runtime.lifecycle, start + 2)
        await runtime.start(sink: WiltedMacLibraryIntentSink())?.value
        XCTAssertEqual(runtime.lifecycle, start + 3)
        await runtime.close()
    }

    /// The account gate stops the runtime without removing it; the model does not read it then.
    @MainActor
    func testModelDoesNotReadAStoppedRuntime() async throws {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("activity-fix-stopped"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let transport = InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac"))
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "1"], transport: transport))
        let inbound = try XCTUnwrap(model.librarySyncController?.inbound)

        await inbound.stop()?.value
        await model.refreshMediaActivity()
        XCTAssertNil(model.librarySyncActivity.media)

        model.stopLibrarySync()
    }

    /// A queued episode shows a "preparing" state but counts as waiting; an active Prepare Again
    /// counts as preparing although the episode stays prepared.
    @MainActor
    func testPreparationCountsEachItemOnceInItsRealState() async {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        model.episodes = [
            episode("running", .preparing(stage: WiltedMacModel.preparingStage)),
            episode("queued-1", .preparing(stage: WiltedMacModel.preparationQueuedStage)),
            episode("queued-2", .preparing(stage: WiltedMacModel.preparationQueuedStage)),
            episode("again-active", .prepared(summary: "")),
            episode("again-waiting", .prepared(summary: "")),
        ]
        model.preparationQueue = WiltedMacPreparationQueue()
        for id in ["queued-1", "queued-2"] {
            model.preparationQueue.enter(WiltedMacWaitingPreparation(id: id, title: id, source: "A show"))
        }
        model.prepareAgainRows = [
            "again-active": WiltedMacPrepareAgainRow(phase: .preparing),
            "again-waiting": WiltedMacPrepareAgainRow(phase: .waiting),
        ]

        let counts = model.preparationCounts
        XCTAssertEqual(counts.preparing, 2)
        XCTAssertEqual(counts.waiting, 3)
    }
}
