import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
@testable import WiltediOS

private final class ListenNextCompletionEngine: ListenerAudioEngine, LibraryCompletingAudioEngine, @unchecked Sendable {
    var duration = 5.0
    var currentTime = 0.0
    var isPlaying = false
    private var generation: UInt64 = 0
    private var completionHandler: (@Sendable (UInt64, Bool) -> Void)?

    func load(url: URL) throws { currentTime = 0 }
    func load(url: URL, completionGeneration: UInt64) throws {
        generation = completionGeneration
        currentTime = 0
    }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64, Bool) -> Void) {
        completionHandler = handler
    }

    func finishNaturally() {
        isPlaying = false
        currentTime = duration
        completionHandler?(generation, true)
    }
}

@MainActor
extension LibraryListenNextPhoneModelTests {
    func testNaturalCompletionDeletesRequestAudioAfterBothCompletionsAreDurable() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story(id: "headline-completed-normal")
        let prepared = try await playingStory(story, model: model, transport: transport)
        let continuation = try saveContinuation(for: prepared.snapshot, on: model)

        let engine = ListenNextCompletionEngine()
        let player = LibraryPlayer(
            engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(
            defaultSpeed: LibrarySettingsStore.defaultSpeed,
            skipBackSeconds: LibrarySettingsStore.defaultSkipBack,
            skipForwardSeconds: LibrarySettingsStore.defaultSkipForward,
            autoPlayNext: false))
        model.attachPlayer(player)
        let item = LibraryPlayer.Item(
            entryID: try ItemID(rawValue: prepared.snapshot.storyID),
            title: prepared.snapshot.story.title, showTitle: prepared.snapshot.story.publisherName,
            fileURL: prepared.fileURL, storyRequestID: prepared.snapshot.requestID)
        XCTAssertTrue(player.start(item, autoplay: true, automatic: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))

        engine.finishNaturally()

        await eventually("completed request audio deletion") {
            guard case let .saved(saved) = LibraryListenNextPhoneOutbox(
                url: self.scratch.appendingPathComponent("pending-listen-next-v1.json")).load(),
                  let entry = saved.entries.first(where: { $0.id == prepared.snapshot.requestID }) else { return false }
            return entry.snapshot.status == .completed && !entry.audioCached
                && !FileManager.default.fileExists(atPath: prepared.fileURL.path)
        }
        let ledgerStore = try XCTUnwrap(model.storyPlaybackLedgerStore(for: prepared.snapshot))
        XCTAssertEqual(ledgerStore.load().entries.first(where: { $0.requestID == prepared.snapshot.requestID })?.continuation,
                       continuation)
    }

    func testRecoveryDeletesAudioWhenCrashFollowedLocalCompletionBeforeRequestStatus() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story(id: "headline-completed-before-status")
        let prepared = try await playingStory(story, model: model, transport: transport)
        let continuation = try saveContinuation(for: prepared.snapshot, on: model)
        let ledgerStore = try XCTUnwrap(model.storyPlaybackLedgerStore(for: prepared.snapshot))
        var ledger = ledgerStore.load()
        ledger.markCompleted(requestID: prepared.snapshot.requestID)
        try ledgerStore.save(ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))

        let player = makeIdlePlayer()
        model.attachPlayer(player)
        await model.restoreStoryPlaybackAfterRelaunch()

        let completed = try XCTUnwrap(model.listenNextRequests.first { $0.requestID == prepared.snapshot.requestID })
        XCTAssertEqual(completed.status, .completed)
        XCTAssertFalse(try XCTUnwrap(savedEntry(for: completed.requestID)).audioCached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertEqual(ledgerStore.load().entries.first(where: { $0.requestID == completed.requestID })?.continuation,
                       continuation)
    }

    func testRecoveryDeletesAudioWhenCrashFollowedRequestCompletionBeforeCleanup() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story(id: "headline-completed-before-cleanup")
        let prepared = try await playingStory(story, model: model, transport: transport)
        let continuation = try saveContinuation(for: prepared.snapshot, on: model)
        let ledgerStore = try XCTUnwrap(model.storyPlaybackLedgerStore(for: prepared.snapshot))
        var ledger = ledgerStore.load()
        ledger.markCompleted(requestID: prepared.snapshot.requestID)
        try ledgerStore.save(ledger)
        let completedCandidate = await model.setListenNextStatus(prepared.snapshot, to: .completed)
        let completed = try XCTUnwrap(completedCandidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertTrue(try XCTUnwrap(savedEntry(for: completed.requestID)).audioCached)

        let player = makeIdlePlayer()
        model.attachPlayer(player)
        await model.restoreStoryPlaybackAfterRelaunch()

        XCTAssertFalse(try XCTUnwrap(savedEntry(for: completed.requestID)).audioCached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertEqual(ledgerStore.load().entries.first(where: { $0.requestID == completed.requestID })?.continuation,
                       continuation)
        await model.restoreStoryPlaybackAfterRelaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path))
    }

    private func playingStory(
        _ story: LibraryHeadlineStory, model: LibraryAppModel, transport: ListenNextPhoneTransport
    ) async throws -> (snapshot: LibraryListenNextRequestSnapshot, fileURL: URL) {
        await model.listenNext(story)
        let pending = try XCTUnwrap(model.listenNextRequests.first { $0.storyID == story.id })
        let offer = try LibraryStoryAudioOffer(
            requestID: pending.requestID, storyID: pending.storyID, requesterDeviceID: "phone-1",
            voiceID: "approved-voice", voiceRevision: "completion-voice-r1",
            audioRevision: try RevisionID(rawValue: "completion-\(pending.requestID)"),
            contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: 4,
            mediaType: "audio/mp4", durationSeconds: 5
        )
        await transport.audio.setStatus(try LibraryListenNextStatus(
            requestID: pending.requestID, storyID: pending.storyID, requesterDeviceID: "phone-1",
            phase: .ready, statusRevision: 1, updatedAt: now, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer
        ))
        await model.syncListenNextRequests()
        await eventually("completed story audio cache admission") {
            guard case let .saved(saved) = LibraryListenNextPhoneOutbox(
                url: self.scratch.appendingPathComponent("pending-listen-next-v1.json")).load() else { return false }
            return saved.entries.first(where: { $0.id == pending.requestID })?.audioCached == true
        }
        let ready = try XCTUnwrap(model.listenNextRequests.first { $0.requestID == pending.requestID })
        let urlCandidate = await model.listenNextAudioURL(for: ready)
        let fileURL = try XCTUnwrap(urlCandidate)
        let selectedCandidate = await model.setListenNextStatus(ready, to: .selected)
        let selected = try XCTUnwrap(selectedCandidate)
        let playingCandidate = await model.setListenNextStatus(selected, to: .playing)
        let playing = try XCTUnwrap(playingCandidate)
        // The fixture starts after playback admission, so mirror the durable
        // local handoff before testing either completion write order.
        let ledgerStore = try XCTUnwrap(model.storyPlaybackLedgerStore(for: playing))
        var ledger = ledgerStore.load()
        ledger.updateRequestPhase(requestID: playing.requestID, phase: .selected)
        ledger.markStarting(requestID: playing.requestID)
        ledger.markPlaying(requestID: playing.requestID)
        try ledgerStore.save(ledger)
        return (playing, fileURL)
    }

    private func saveContinuation(
        for snapshot: LibraryListenNextRequestSnapshot, on model: LibraryAppModel
    ) throws -> ListenNextContinuation {
        let storyID = try ItemID(rawValue: snapshot.storyID)
        let continuation = ListenNextContinuation(
            kind: .phoneForwardSequence, anchorID: storyID, entryIDs: [], allowsAutomaticContinuation: false)
        let store = try XCTUnwrap(model.storyPlaybackLedgerStore(for: snapshot))
        var ledger = store.load()
        ledger.updateContinuation(requestID: snapshot.requestID, continuation: continuation)
        try store.save(ledger)
        return continuation
    }

    private func savedEntry(for requestID: String) throws -> LibraryListenNextPhoneEntry? {
        guard case let .saved(saved) = LibraryListenNextPhoneOutbox(
            url: scratch.appendingPathComponent("pending-listen-next-v1.json")).load() else { return nil }
        return saved.entries.first(where: { $0.id == requestID })
    }

    private func makeIdlePlayer() -> LibraryPlayer {
        LibraryPlayer(
            engine: RuntimeFakeEngine(), session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
    }
}
