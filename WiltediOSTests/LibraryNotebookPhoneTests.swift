import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryNotebookPhoneTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func revision(_ raw: String) -> RevisionID { try! RevisionID(rawValue: raw) }

    private func notebookEntry(
        _ rawID: String = "notebook-clip",
        source: String = "episode-a",
        revision: String = "audio-r1",
        excerpt: String? = nil,
        note: String? = nil,
        deletedAt: Date? = nil
    ) throws -> LibraryNotebookEntry {
        try LibraryNotebookEntry(
            id: id(rawID), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceItemID: id(source), sourceRevision: self.revision(revision),
            sourceTitle: "A saved episode", sourceURL: URL(string: "https://example.test/episode")!,
            startSeconds: 30, endSeconds: 60, textExcerpt: excerpt, note: note,
            capturedOn: .iphone, deletedAt: deletedAt)
    }

    func testCaptureWindowUsesWholeCuesFromTheExactRevision() throws {
        let episode = id("episode-a")
        let revision = revision("audio-r1")
        let transcript = try LibraryTranscript(
            entryID: episode, revisionID: revision,
            cues: [
                .init(start: 10, end: 20, text: "Before the window."),
                .init(start: 30, end: 40, text: "First full cue."),
                .init(start: 40, end: 55, text: "Second full cue."),
                .init(start: 65, end: 70, text: "After the window."),
            ])

        let result = try XCTUnwrap(LibraryNotebookClipRange.capture(
            endingAt: 65, transcript: transcript, entryID: episode, revisionID: revision))

        XCTAssertEqual(result.startSeconds, 30)
        XCTAssertEqual(result.endSeconds, 55)
        XCTAssertEqual(result.textExcerpt, "First full cue.\nSecond full cue.")
    }

    func testCaptureWindowWithoutMatchingTimedTranscriptStaysBoundedAndTextless() throws {
        let episode = id("episode-a")
        let currentRevision = revision("audio-r2")
        let wrongRevision = try LibraryTranscript(
            entryID: episode, revisionID: revision("audio-r1"), plainText: "Wrong recording text.")
        let untimed = try LibraryTranscript(
            entryID: episode, revisionID: currentRevision, plainText: "Untimed text is not cue evidence.")

        let wrongResult = try XCTUnwrap(LibraryNotebookClipRange.capture(
            endingAt: 65, transcript: wrongRevision, entryID: episode, revisionID: currentRevision))
        let untimedResult = try XCTUnwrap(LibraryNotebookClipRange.capture(
            endingAt: 65, transcript: untimed, entryID: episode, revisionID: currentRevision))

        for result in [wrongResult, untimedResult] {
            XCTAssertEqual(result.startSeconds, 35)
            XCTAssertEqual(result.endSeconds, 65)
            XCTAssertNil(result.textExcerpt)
        }
    }

    func testReplayPolicyRequiresTheSavedPreparedRevision() throws {
        let entry = try notebookEntry()
        let exact = CachedMedia(revisionID: revision("audio-r1"), url: scratch.appendingPathComponent("r1.m4a"), byteCount: 1)
        let newer = CachedMedia(revisionID: revision("audio-r2"), url: scratch.appendingPathComponent("r2.m4a"), byteCount: 1)

        XCTAssertTrue(LibraryNotebookReplayPolicy.matches(entry, cached: exact))
        XCTAssertFalse(LibraryNotebookReplayPolicy.matches(entry, cached: newer))
        XCTAssertFalse(LibraryNotebookReplayPolicy.matches(entry, cached: nil))
    }

    func testCapturePersistsCueSnapshotAndImmediateUndoTombstone() async throws {
        let transcript = try timedTranscript(revision: "audio-r1")
        let (model, cache, item, player, _) = try await makeCaptureRig(transcript: transcript)

        let captureResult = await model.captureNotebookClip(for: item, at: 45, capturedOn: .iphone)
        withExtendedLifetime((cache, player)) {}
        let captured = try XCTUnwrap(captureResult)

        XCTAssertEqual(captured.startSeconds, 30)
        XCTAssertEqual(captured.endSeconds, 55)
        XCTAssertEqual(captured.textExcerpt, "Opening cue.\nSecond cue.")
        XCTAssertEqual(model.notebookStatus(for: captured.id), "Saved on this phone")
        await model.undoNotebookCapture(id: captured.id)
        XCTAssertTrue(try XCTUnwrap(model.notebookPhoneState.entry(id: captured.id, includeDeleted: true)).isDeleted)
        XCTAssertTrue(model.notebookPhoneState.entries.isEmpty)
    }

    func testOldRevisionTranscriptIsCapturedBeforeAudioRevocation() async throws {
        let (model, cache, item, player, _) = try await makeCaptureRig(transcript: nil)
        let captureResult = await model.captureNotebookClip(for: item, at: 45, capturedOn: .iphone)
        withExtendedLifetime((cache, player)) {}
        let captured = try XCTUnwrap(captureResult)
        XCTAssertNil(captured.textExcerpt)

        let oldTranscript = try timedTranscript(revision: "audio-r1")
        await model.mediaCache.storeTranscript(oldTranscript)
        let contextResult = await model.mediaContext()
        let context = try XCTUnwrap(contextResult)
        let revoked = await model.revokeMediaPreparation(item.entryID, context: context)
        XCTAssertTrue(revoked)

        let preserved = try XCTUnwrap(model.notebookPhoneState.entry(id: captured.id))
        XCTAssertEqual(preserved.sourceRevision, revision("audio-r1"))
        XCTAssertEqual(preserved.textExcerpt, "Opening cue.\nSecond cue.")
        let replacement = try timedTranscript(revision: "audio-r2")
        await model.fillNotebookExcerpt(id: captured.id, from: replacement)
        XCTAssertEqual(model.notebookPhoneState.entry(id: captured.id)?.textExcerpt, "Opening cue.\nSecond cue.")
    }

    func testReplayStartsAtTheSavedOffsetOnlyForItsExactRevision() async throws {
        let (model, _, item, player, engine) = try await makeCaptureRig(transcript: nil)
        let exactEntry = try notebookEntry(source: item.entryID.rawValue, revision: "audio-r1")
        XCTAssertTrue(model.notebookPhoneState.store(exactEntry))

        let exactPlayed = await model.replayNotebookEntry(id: exactEntry.id)

        XCTAssertTrue(exactPlayed)
        XCTAssertEqual(engine.currentTime, 30)
        XCTAssertEqual(player.item?.feedbackRevisionID, revision("audio-r1"))

        let mismatch = try notebookEntry("notebook-mismatch", source: item.entryID.rawValue, revision: "audio-r2")
        XCTAssertTrue(model.notebookPhoneState.store(mismatch))
        let transportCount = player.transportCount
        let mismatchPlayed = await model.replayNotebookEntry(id: mismatch.id)
        XCTAssertFalse(mismatchPlayed)
        XCTAssertEqual(player.transportCount, transportCount)
    }

    func testOutboxKeepsOwnerRowsHiddenAndRecoversInterruptedSend() throws {
        let outboxURL = scratch.appendingPathComponent("notebook-state.json")
        let state = LibraryNotebookPhoneState(url: outboxURL)
        state.bind(ownerToken: "owner-a", deviceID: "phone", generation: 1, reviewHold: false)
        let scope = try NotebookLocalScope(ownerToken: "owner-a", deviceID: "phone")
        let entry = try notebookEntry()
        let intent = try LibraryIntent.setNotebookEntry(
            entry: entry, basedOnVersion: 0, deviceID: "phone", createdAt: entry.createdAt)
        let sent = LibraryNotebookOutbox.Command(
            id: intent.id, scope: scope, createdAt: entry.createdAt, entry: entry,
            baseVersion: 0, delivery: .sent, detail: "Waiting for Mac")
        XCTAssertTrue(state.store(entry, command: sent))

        state.bind(ownerToken: "owner-b", deviceID: "phone", generation: 2, reviewHold: false)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.commands.isEmpty)

        let relaunched = LibraryNotebookPhoneState(url: outboxURL)
        relaunched.bind(ownerToken: "owner-a", deviceID: "phone", generation: 3, reviewHold: false)
        XCTAssertEqual(relaunched.entries, [entry])
        XCTAssertEqual(relaunched.commands.map(\.id), [intent.id])
        XCTAssertEqual(relaunched.commands.first?.delivery, .pending)
    }

    func testTranscriptProgressIsPartitionedByAccount() throws {
        let state = LibraryNotebookPhoneState(url: scratch.appendingPathComponent("scoped-progress.json"))
        let entryA = try notebookEntry(revision: "audio-r1")
        let entryB = try notebookEntry(revision: "audio-r2")
        let scopeA = try NotebookLocalScope(ownerToken: "owner-a", deviceID: "phone")
        let scopeB = try NotebookLocalScope(ownerToken: "owner-b", deviceID: "phone")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        state.bind(ownerToken: "owner-a", deviceID: "phone", generation: 1, reviewHold: false)
        XCTAssertTrue(state.beginExcerptCheck(for: entryA, now: now))
        state.bind(ownerToken: "owner-b", deviceID: "phone", generation: 2, reviewHold: false)
        XCTAssertTrue(state.beginExcerptCheck(for: entryB, now: now))
        state.setExcerptPending(false, for: entryA.id, in: scopeA)

        XCTAssertTrue(state.excerptPendingIDs.contains(entryB.id))
        state.setExcerptPending(false, for: entryB.id, in: scopeB)
        XCTAssertFalse(state.excerptPendingIDs.contains(entryB.id))
    }

    func testCaptureUndoPersistsATombstoneAndNeverRestoresLateText() async throws {
        let model = makeLocalModel()
        model.notebookPhoneState.bind(ownerToken: "owner-a", deviceID: "phone", generation: 0, reviewHold: false)
        let entry = try notebookEntry()
        XCTAssertTrue(model.notebookPhoneState.store(entry))

        await model.undoNotebookCapture(id: entry.id)

        XCTAssertTrue(try XCTUnwrap(model.notebookPhoneState.entry(id: entry.id, includeDeleted: true)).isDeleted)
        XCTAssertNil(model.notebookPhoneState.entry(id: entry.id))
        XCTAssertTrue(model.notebookPhoneState.commands.isEmpty, "Production/local-only changes never enqueue cloud writes")
        let reopened = LibraryNotebookPhoneState(url: scratch.appendingPathComponent("notebook-state.json"))
        reopened.bind(ownerToken: "owner-a", deviceID: "phone", generation: 1, reviewHold: false)
        XCTAssertNil(reopened.entry(id: entry.id))
        XCTAssertTrue(try XCTUnwrap(reopened.entry(id: entry.id, includeDeleted: true)).isDeleted)
    }

    func testUndoForCommittedDeleteRestoresAsANewID() async throws {
        let model = makeLocalModel()
        model.notebookPhoneState.bind(ownerToken: "owner-a", deviceID: "phone", generation: 0, reviewHold: false)
        let original = try notebookEntry(excerpt: "A retained cue.", note: "Keep this.")
        XCTAssertTrue(model.notebookPhoneState.store(original))

        await model.deleteNotebookEntry(id: original.id)
        let pendingTombstone = try XCTUnwrap(model.notebookPhoneState.entry(id: original.id, includeDeleted: true))
        XCTAssertTrue(pendingTombstone.isDeleted)
        XCTAssertTrue(model.notebookPhoneState.commands.isEmpty)

        let restoredResult = await model.restoreNotebookEntryAsNewID(id: original.id)
        let restored = try XCTUnwrap(restoredResult)

        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.sourceItemID, original.sourceItemID)
        XCTAssertEqual(restored.sourceRevision, original.sourceRevision)
        XCTAssertEqual(restored.startSeconds, original.startSeconds)
        XCTAssertEqual(restored.endSeconds, original.endSeconds)
        XCTAssertEqual(restored.textExcerpt, original.textExcerpt)
        XCTAssertEqual(restored.note, original.note)
        XCTAssertTrue(try XCTUnwrap(model.notebookPhoneState.entry(id: original.id, includeDeleted: true)).isDeleted)
        XCTAssertEqual(model.notebookPhoneState.entries.map(\.id), [restored.id])
    }

    func testUndoForPendingDeleteCreatesFreshIDAndKeepsOldCommand() async throws {
        let model = makeLocalModel()
        model.notebookPhoneState.bind(ownerToken: "owner-a", deviceID: "phone", generation: 0, reviewHold: false)
        let original = try notebookEntry(excerpt: "A retained cue.", note: "Keep this.")
        XCTAssertTrue(model.notebookPhoneState.store(original))
        await model.deleteNotebookEntry(id: original.id)
        let pendingTombstone = try XCTUnwrap(model.notebookPhoneState.entry(id: original.id, includeDeleted: true))
        let scope = try NotebookLocalScope(ownerToken: "owner-a", deviceID: "phone")
        let tombstoneIntent = try LibraryIntent.setNotebookEntry(
            entry: pendingTombstone, basedOnVersion: 0, deviceID: "phone", createdAt: pendingTombstone.updatedAt)
        let command = LibraryNotebookOutbox.Command(
            id: tombstoneIntent.id, scope: scope, createdAt: pendingTombstone.updatedAt,
            entry: pendingTombstone, baseVersion: 0, delivery: .pending, detail: "Waiting to sync")
        XCTAssertTrue(model.notebookPhoneState.store(pendingTombstone, command: command))

        let restored = await model.restoreNotebookEntryAsNewID(id: original.id)
        let restoredEntry = try XCTUnwrap(restored)

        XCTAssertNotEqual(restoredEntry.id, original.id)
        XCTAssertEqual(restoredEntry.sourceItemID, original.sourceItemID)
        XCTAssertEqual(restoredEntry.sourceRevision, original.sourceRevision)
        XCTAssertEqual(restoredEntry.startSeconds, original.startSeconds)
        XCTAssertEqual(restoredEntry.endSeconds, original.endSeconds)
        XCTAssertEqual(restoredEntry.textExcerpt, original.textExcerpt)
        XCTAssertEqual(restoredEntry.note, original.note)
        XCTAssertTrue(try XCTUnwrap(model.notebookPhoneState.entry(id: original.id, includeDeleted: true)).isDeleted)
        XCTAssertEqual(model.notebookPhoneState.commands.map(\.id), [tombstoneIntent.id])
        XCTAssertEqual(model.notebookPhoneState.entries.map(\.id), [restoredEntry.id])
    }

    func testLateTranscriptFillAcceptsOnlyExactRevisionAndNeverRevivesDelete() async throws {
        let model = makeLocalModel()
        model.notebookPhoneState.bind(ownerToken: "owner-a", deviceID: "phone", generation: 0, reviewHold: false)
        let entry = try notebookEntry()
        XCTAssertTrue(model.notebookPhoneState.store(entry))
        let oldText = try LibraryTranscript(
            entryID: entry.sourceItemID, revisionID: entry.sourceRevision,
            cues: [.init(start: 30, end: 45, text: "Original revision cue.")])
        let replacementText = try LibraryTranscript(
            entryID: entry.sourceItemID, revisionID: revision("audio-r2"),
            cues: [.init(start: 30, end: 45, text: "Replacement revision cue.")])

        await model.fillNotebookExcerpt(id: entry.id, from: replacementText)
        XCTAssertNil(model.notebookPhoneState.entry(id: entry.id)?.textExcerpt)
        await model.fillNotebookExcerpt(id: entry.id, from: oldText)
        XCTAssertEqual(model.notebookPhoneState.entry(id: entry.id)?.textExcerpt, "Original revision cue.")
        await model.deleteNotebookEntry(id: entry.id)
        await model.fillNotebookExcerpt(id: entry.id, from: oldText)
        XCTAssertTrue(try XCTUnwrap(model.notebookPhoneState.entry(id: entry.id, includeDeleted: true)).isDeleted)
    }

    private func makeLocalModel() -> LibraryAppModel {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner-a")
        return LibraryAppModel(
            transport: transport, store: InMemoryLibraryStore(), deviceID: "phone",
            notebookOutboxURL: scratch.appendingPathComponent("notebook-state.json"))
    }

    private func timedTranscript(revision: String) throws -> LibraryTranscript {
        try LibraryTranscript(
            entryID: id("episode-capture"), revisionID: self.revision(revision),
            cues: [
                .init(start: 5, end: 15, text: "Earlier cue."),
                .init(start: 30, end: 40, text: "Opening cue."),
                .init(start: 40, end: 55, text: "Second cue."),
            ])
    }

    private func makeCaptureRig(
        transcript: LibraryTranscript?
    ) async throws -> (LibraryAppModel, FileMediaCache, LibraryPlayer.Item, LibraryPlayer, RuntimeFakeEngine) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner-a")
        let store = FileLibraryStore(url: scratch.appendingPathComponent("capture-library-state.json"))
        let source = try LibraryEntry.podcastEpisode(
            id: id("episode-capture"), sourceID: id("show-a"), title: "A capture episode", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            payload: PodcastEpisodePayload(
                enclosureURL: URL(string: "https://example.test/audio.mp3")!,
                episodeLink: URL(string: "https://example.test/episode")!))
        let slot = try QueueSlot(entryID: source.id, sortKey: 0)
        let writer = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner-a")
        let seedChanges: [LibraryChange] = [.entry(source), .slot(slot)]
        let seeded = try await writer.push(changes: seedChanges.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        XCTAssertTrue(seeded.failures.isEmpty, "the fixture seeds its episode and queue slot through the Mac writer")
        _ = try await LibraryReconciler(transport: transport, store: store).synchronize().get()
        let persisted = await store.state()
        XCTAssertEqual(persisted.ownerToken, "owner-a", "capture uses a verified, persisted account projection")
        XCTAssertEqual(persisted.content.entries[source.id], source)
        XCTAssertEqual(persisted.content.queue, [slot])
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("capture-cache", isDirectory: true))
        let bytes = Data(repeating: 17, count: 512)
        let input = scratch.appendingPathComponent("capture-source.mp3")
        try bytes.write(to: input)
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: id("episode-capture"), revisionID: revision("audio-r1"),
            contentHash: PreparedMediaFixture.hash(bytes), byteCount: Int64(bytes.count),
            mediaType: "audio/mp4", durationSeconds: 600))
        let cachedURL = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: input, for: offer, owner: "owner-a")
        if let transcript { await cache.storeTranscript(transcript) }
        let model = LibraryAppModel(
            transport: transport, store: store, deviceID: "phone", mediaCache: cache,
            notebookOutboxURL: scratch.appendingPathComponent("capture-notebook-state.json"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await model.loadLocalState()
        let item = LibraryPlayer.Item(
            entryID: source.id, title: source.title, showTitle: "The Show", fileURL: cachedURL,
            feedbackRevisionID: offer.revisionID)
        let engine = RuntimeFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)
        XCTAssertTrue(player.start(item, at: 45, autoplay: false))
        XCTAssertTrue(model.handoffState.player === player, "the model retains the player used by capture and replay")
        XCTAssertTrue(model.canCaptureNotebook(item), "the exact podcast remains in the persisted queue")
        XCTAssertEqual(model.notebookPhoneState.activeScope?.ownerToken, "owner-a")
        let contextResult = await model.mediaContext()
        let context = try XCTUnwrap(contextResult, "the saved library account must admit the media context")
        let cachedEntries = await cache.cachedEntries()
        let cached = try XCTUnwrap(cachedEntries[source.id])
        XCTAssertTrue(model.cachedProofMatches(cached, entryID: source.id, context: context))
        let cacheVerified = await cache.verifies(cached)
        XCTAssertTrue(cacheVerified, "the cached file has a valid owner-bound preparation proof")
        let contextCurrent = await model.mediaContextIsCurrent(context)
        XCTAssertTrue(contextCurrent, "the current operation still belongs to the persisted library")
        return (model, cache, item, player, engine)
    }
}
