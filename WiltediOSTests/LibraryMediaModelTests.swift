import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Lets a test hold a download open until it decides to release it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isSet: Bool { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

/// Delegates to the in-memory transport, with hooks to hold, stall or fail media operations.
private struct ScriptedTransport: LibraryTransport {
    enum Delivery: Sendable { case normal, holdAfter(bytes: Int64, gate: Gate), neverDelivers }

    let inner: InMemoryLibraryTransport
    var delivery: Delivery = .normal
    var failAcknowledgements: Flag = Flag(false)

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func send(intent: LibraryIntent) async throws {
        if case .mediaCached = intent.action, failAcknowledgements.isSet {
            throw LibraryTransportError.transport("offline")
        }
        try await inner.send(intent: intent)
    }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        switch delivery {
        case .normal:
            return try await inner.fetchMedia(offer, progress: progress)
        case let .holdAfter(bytes, gate):
            progress(bytes)
            await gate.wait()
            return try await inner.fetchMedia(offer, progress: progress)
        case .neverDelivers:
            try await Task.sleep(for: .seconds(60))
            throw LibraryTransportError.transport("unreachable")
        }
    }
}

private actor MediaModelStore: LibraryStore {
    private var saved: LibraryStoreState
    init(_ saved: LibraryStoreState) { self.saved = saved }
    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
    func hold() { saved.reviewHold = true; saved.revision += 1 }
}

@MainActor
final class LibraryMediaModelTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let entryID = try! ItemID(rawValue: "item-a")
    private let revisionID = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<300_000).map { UInt8($0 % 251) })
    private let fast = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30))

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let entry = try LibraryEntry(id: entryID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"),
                                     title: "Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
        let slot = try QueueSlot(entryID: entryID, sortKey: 0)
        _ = try await mac.push(changes: [PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
                                       PendingLibraryChange(localSeq: 2, change: .slot(slot), baseVersion: 0)])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: fixtures

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeOffer(_ data: Data? = nil, hashOf other: Data? = nil) throws -> LibraryMediaOffer {
        let bytes = data ?? payload
        return try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(other ?? bytes),
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 60,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
    }

    /// The Mac publishing `data` under an offer, as its media service would.
    private func macPublish(_ offer: LibraryMediaOffer, data: Data? = nil) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try (data ?? payload).write(to: file)
        try await mac.publishMedia(offer: offer, fileURL: file)
    }

    private func makeCache() -> FileMediaCache { FileMediaCache(rootURL: scratch.appendingPathComponent("cache")) }

    private func makeModel(
        _ delivery: ScriptedTransport.Delivery = .normal, cache: FileMediaCache? = nil,
        timing: LibraryMediaTiming? = nil, failAcknowledgements: Flag = Flag(false), store: MediaModelStore? = nil
    ) -> LibraryAppModel {
        let transport = ScriptedTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "media-model-owner"),
            delivery: delivery, failAcknowledgements: failAcknowledgements)
        return LibraryAppModel(
            transport: transport, store: store ?? fixtureStore(), deviceID: "phone", mediaCache: cache ?? makeCache(),
            mediaTiming: timing ?? fast, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func fixtureStore() -> MediaModelStore {
        var state = LibraryStoreState()
        state.ownerToken = "media-model-owner"
        let row = try! LibraryEntry(id: entryID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"),
                                   title: "Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
        state.content = LibrarySnapshot(entries: [row], slots: [try! QueueSlot(entryID: entryID, sortKey: 0)])
        return MediaModelStore(state)
    }

    private func cacheAdmission(_ cache: FileMediaCache) async throws -> MediaCacheAdmission {
        try await cache.bindOwner(ownerToken: "media-model-owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let admission = await cache.admission(entryID: entryID, ownerToken: "media-model-owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        return try XCTUnwrap(admission)
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func intents() async throws -> [LibraryIntent] {
        try await InMemoryLibraryTransport(deviceID: "mac", server: server).listIntents()
    }

    /// Records only synthetic fixture facts; this does not load or mutate the cold mirror.
    private func recordColdRequestContext(_ model: LibraryAppModel, phase: String) async {
        let saved = await model.mediaStoreState()
        let generation = await model.transport.operationGeneration()
        let owner = await model.transport.verifiedOwnerToken()
        let runID = model.mediaRuns[entryID]?.id
        let context = await model.mediaContext(live: true)
        let contextCurrent: Bool
        let entryCurrent: Bool
        if let context {
            contextCurrent = await model.mediaContextIsCurrent(context, live: true)
            entryCurrent = await model.mediaContextIsCurrent(context, entryID: entryID, live: true)
        } else {
            contextCurrent = false
            entryCurrent = false
        }
        let finalGeneration = await model.transport.operationGeneration()
        let facts: [String: String] = [
            "phase": phase,
            "savedOwnerPresent": String(saved.ownerToken != nil),
            "savedOwnerMatchesFixture": String(saved.ownerToken == "media-model-owner"),
            "transportOwnerMatchesSaved": String(owner == saved.ownerToken),
            "reviewHold": String(saved.reviewHold),
            "accountQuarantined": String(model.accountQuarantined),
            "savedEntryPresent": String(saved.content.entries[entryID] != nil),
            "decisionEntryPresent": String(model.decisionContent.entries[entryID] != nil),
            "entryEqualsSaved": String(model.decisionContent.entries[entryID] == saved.content.entries[entryID]),
            "savedQueueContainsEntry": String(saved.content.queue.contains { $0.entryID == entryID }),
            "modelQueueContainsEntry": String(model.queued.contains { $0.id == entryID }),
            "contextPresent": String(context != nil),
            "contextCurrent": String(contextCurrent),
            "entryContextCurrent": String(entryCurrent),
            "generation": String(generation),
            "finalGeneration": String(finalGeneration),
            "runPresent": String(runID != nil),
            "runCurrent": String(runID != nil && model.mediaRuns[entryID]?.id == runID),
            "taskCancelled": String(Task.isCancelled),
            "mediaState": String(describing: model.mediaState(for: entryID))
        ]
        let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .prettyPrinted])
        XCTContext.runActivity(named: "Cold request context: \(phase)") { activity in
            let attachment = XCTAttachment(string: String(decoding: data, as: UTF8.self))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    // MARK: transitions

    func testRequestWaitsForOfferThenDownloadsVerifiesAndCaches() async throws {
        let cache = makeCache()
        let model = makeModel(cache: cache)
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        await recordColdRequestContext(model, phase: "before cold request")

        model.performMediaAction(.request, entryID: entryID)
        guard case .requested = model.mediaState(for: entryID) else { return XCTFail("expected requested, got \(model.mediaState(for: entryID))") }
        try await eventually("request intent") {
            let sent = (try? await self.intents()) ?? []
            return sent.contains { $0.action == .requestMedia(entryID: self.entryID) }
        }

        try await macPublish(makeOffer())
        await model.waitForMedia(entryID: entryID)
        await recordColdRequestContext(model, phase: "after cold request wait")

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        let cached = await cache.cachedEntries()
        XCTAssertEqual(cached[entryID]?.revisionID, revisionID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cached[entryID]).url), payload)
        let sent = try await intents()
        XCTAssertTrue(sent.contains { $0.action == .requestMedia(entryID: entryID) && $0.deviceID == "phone" })
        XCTAssertTrue(sent.contains { $0.action == .mediaCached(entryID: entryID, revisionID: revisionID, deviceID: "phone") })
        XCTAssertTrue(model.unacknowledgedMedia.isEmpty)
    }

    func testTheTranscriptIsFetchedAndCachedAfterTheAudioVerifies() async throws {
        let cache = makeCache()
        let model = makeModel(cache: cache)
        let transcript = try LibraryTranscript(
            entryID: entryID, revisionID: revisionID, cues: [LibraryTranscriptCue(start: 0, end: 2, text: "Hello")])
        try await mac.publishTranscript(transcript)

        model.performMediaAction(.request, entryID: entryID)
        try await macPublish(makeOffer())
        await model.waitForMedia(entryID: entryID)
        await model.waitForTranscript(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(model.transcript(for: entryID), transcript)
        let stored = await cache.cachedTranscript(entryID: entryID, revisionID: revisionID)
        XCTAssertEqual(stored, transcript)
    }

    func testAnAvailableOfferIsNotAnAnswerSoTheRequestWaitsForTheUploadAndOnlyThenFetches() async throws {
        let model = makeModel()
        try await macPublish(
            try LibraryMediaOffer(
                entryID: entryID, revisionID: revisionID, contentHash: hash(payload), byteCount: Int64(payload.count),
                mediaType: "audio/mp4", durationSeconds: 60, state: .available,
                preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000)))),
            data: Data())

        model.performMediaAction(.request, entryID: entryID)
        try await eventually("request intent") {
            ((try? await self.intents()) ?? []).contains { $0.action == .requestMedia(entryID: self.entryID) }
        }
        try await Task.sleep(for: .milliseconds(100))
        guard case .requested = model.mediaState(for: entryID) else {
            return XCTFail("an available offer must not end the wait, got \(model.mediaState(for: entryID))")
        }

        try await macPublish(makeOffer())
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testDownloadingReportsRealBytesAndTotalBeforeVerifyingAndCached() async throws {
        let gate = Gate()
        try await macPublish(makeOffer())
        let model = makeModel(.holdAfter(bytes: 4_096, gate: gate))
        model.performMediaAction(.request, entryID: entryID)

        try await eventually("downloading") {
            if case .downloading(4_096, 300_000, _) = model.mediaState(for: self.entryID) { return true }
            return false
        }
        XCTAssertEqual(model.mediaState(for: entryID).fraction ?? 0, 4_096.0 / 300_000.0, accuracy: 0.0001)
        XCTAssertTrue(model.mediaState(for: entryID).isInFlight)
        XCTAssertTrue(model.mediaState(for: entryID).statusText(elapsed: 14).contains("0:14"))

        await gate.open()
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testHashMismatchFailsThenRetrySucceedsOnceTheMacRepublishes() async throws {
        let cache = makeCache()
        try await macPublish(makeOffer(hashOf: Data([1, 2, 3])))
        let model = makeModel(cache: cache)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        guard case let .failed(reason) = model.mediaState(for: entryID) else { return XCTFail("expected failed") }
        XCTAssertTrue(reason.contains("did not match"), reason)
        let nothingCached = await cache.cachedEntries()
        XCTAssertTrue(nothingCached.isEmpty)

        try await macPublish(makeOffer())
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testByteCountMismatchFails() async throws {
        let short = payload.prefix(1_000)
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(payload), byteCount: Int64(payload.count), mediaType: "audio/mp4",
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
        try await macPublish(offer, data: Data(short))
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        guard case let .failed(reason) = model.mediaState(for: entryID) else { return XCTFail("expected failed") }
        XCTAssertTrue(reason.contains("wrong size"), reason)
    }

    func testNotReadyOfferShowsNotPreparedAndAllowsCheckingAgain() async throws {
        try await macPublish(.notReady(entryID: entryID))
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .notPrepared)
        XCTAssertEqual(model.mediaState(for: entryID).statusText(), "Not prepared on Mac")

        try await macPublish(makeOffer())
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testMacThatNeverAnswersFailsAfterTheOfferTimeout() async throws {
        let timing = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .milliseconds(80), watchdog: .seconds(30))
        let model = makeModel(timing: timing)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        guard case let .failed(reason) = model.mediaState(for: entryID) else { return XCTFail("expected failed") }
        XCTAssertTrue(reason.contains("has not answered"), reason)
    }

    func testStalledDownloadFailsAfterTheWatchdog() async throws {
        try await macPublish(makeOffer())
        let timing = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .milliseconds(150))
        let model = makeModel(.neverDelivers, timing: timing)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        guard case let .failed(reason) = model.mediaState(for: entryID) else { return XCTFail("expected failed") }
        XCTAssertTrue(reason.contains("stalled"), reason)
    }

    func testCancelReturnsToAvailableAndAllowsANewRequest() async throws {
        try await macPublish(makeOffer())
        let model = makeModel(.neverDelivers)
        model.performMediaAction(.request, entryID: entryID)
        try await eventually("downloading") {
            if case .downloading = model.mediaState(for: self.entryID) { return true }
            return false
        }
        model.performMediaAction(.cancel, entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        XCTAssertNil(model.mediaRuns[entryID])
        // The cancelled run must not write a state after it was replaced.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.mediaState(for: entryID), .available)

        model.performMediaAction(.request, entryID: entryID)
        guard case .requested = model.mediaState(for: entryID) else { return XCTFail("expected a fresh request") }
        model.performMediaAction(.cancel, entryID: entryID)
    }

    func testRequestWhileRunningOrOnPhoneIsIgnored() async throws {
        try await macPublish(makeOffer())
        let model = makeModel()
        model.startMediaRequest(entryID: entryID)
        let firstRun = model.mediaRuns[entryID]?.id
        model.startMediaRequest(entryID: entryID)
        XCTAssertEqual(model.mediaRuns[entryID]?.id, firstRun)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        model.startMediaRequest(entryID: entryID)
        XCTAssertNil(model.mediaRuns[entryID])
    }

    func testRemoveFromPhoneDeletesTheCachedFile() async throws {
        let cache = makeCache()
        try await macPublish(makeOffer())
        let model = makeModel(cache: cache)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        let cached = await cache.cachedEntries()
        let file = try XCTUnwrap(cached[entryID]).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        await model.removeFromPhone(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let remaining = await cache.cachedEntries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRefreshMarksAlreadyCachedEntriesOnPhoneAndDropsDeletedOnes() async throws {
        let cache = makeCache()
        let offer = try makeOffer()
        let file = scratch.appendingPathComponent("seed")
        try payload.write(to: file)
        _ = try await cache.adopt(verifiedFile: file, for: offer, admission: try await cacheAdmission(cache))

        let model = makeModel(cache: cache)
        await model.refresh()
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)

        try await cache.remove(entryID: entryID)
        await model.refresh()
        XCTAssertEqual(model.mediaState(for: entryID), .available)
    }

    func testAcknowledgementThatFailsIsRetriedOnTheNextRefresh() async throws {
        let offline = Flag(true)
        try await macPublish(makeOffer())
        let model = makeModel(failAcknowledgements: offline)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(model.unacknowledgedMedia[entryID], revisionID)
        var sent = try await intents()
        XCTAssertFalse(sent.contains { if case .mediaCached = $0.action { true } else { false } })

        offline.isSet = false
        await model.refresh()
        XCTAssertTrue(model.unacknowledgedMedia.isEmpty)
        sent = try await intents()
        XCTAssertEqual(sent.filter { if case .mediaCached = $0.action { true } else { false } }.count, 1)
    }

    func testTransportFailureOnRequestShowsFailedWithReason() async throws {
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "iCloud is off."), deviceID: "phone",
            mediaCache: makeCache(), mediaTiming: fast)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .failed("The saved library account is not verified for downloading."))
    }

    func testAccountChangeDiscardsCachedAudioAndStates() async throws {
        let cache = makeCache()
        try await macPublish(makeOffer())
        let model = makeModel(cache: cache)
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        await model.discardMediaAfterAccountChange()
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        let remaining = await cache.cachedEntries()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: status wording

    func testEveryStateSpellsItselfOutWithoutRelyingOnColor() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(LibraryMediaState.available.statusText(), "Not on phone")
        XCTAssertTrue(LibraryMediaState.requested(since: start).statusText(elapsed: 5).hasPrefix("Requested"))
        XCTAssertTrue(LibraryMediaState.downloading(bytes: 1, total: 2, since: start).statusText().hasPrefix("Downloading"))
        XCTAssertEqual(LibraryMediaState.verifying.statusText(), "Verifying")
        XCTAssertEqual(LibraryMediaState.onPhone.statusText(), "On phone")
        XCTAssertEqual(LibraryMediaState.failed("x").statusText(), "Failed: x")
        XCTAssertEqual(LibraryMediaState.notPrepared.statusText(), "Not prepared on Mac")
    }

    func testLegacyReadyOfferCannotDownloadOrPromoteToOnPhone() async throws {
        let legacy = try LibraryMediaOffer(entryID: entryID, revisionID: revisionID,
            contentHash: hash(payload), byteCount: Int64(payload.count), mediaType: "audio/mp4")
        try await macPublish(legacy)
        let model = makeModel()
        model.startMediaRequest(entryID: entryID)
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .notPrepared)
        let inventory = await model.mediaCache.cachedEntries()
        XCTAssertNil(inventory[entryID])
    }

    func testReviewHoldDuringActualDownloadPreventsOnPhoneAndPlaybackAdmission() async throws {
        let gate = Gate()
        let store = fixtureStore()
        let cache = makeCache()
        try await macPublish(makeOffer())
        let model = makeModel(.holdAfter(bytes: 4096, gate: gate), cache: cache, store: store)
        model.startMediaRequest(entryID: entryID)
        try await eventually("held download") {
            if case .downloading = model.mediaState(for: self.entryID) { return true }
            return false
        }
        await store.hold()
        await gate.open()
        await model.waitForMedia(entryID: entryID)
        XCTAssertNotEqual(model.mediaState(for: entryID), .onPhone)
        let admitted = await model.verifiedCachedMedia(entryID, token: model.beginExternalStart())
        XCTAssertNil(admitted)
        await model.refreshMediaFromCache()
        let inventory = await cache.cachedEntries()
        XCTAssertNil(inventory[entryID], "binding the durable hold leaves any completed bytes inert")
    }

    // MARK: FileMediaCache

    func testFileMediaCacheAdoptsIdempotentlyAndKeysByHash() async throws {
        let cache = makeCache()
        let offer = try makeOffer()
        let missing = await cache.cachedFile(for: offer, admission: try await cacheAdmission(cache))
        XCTAssertNil(missing)

        let first = scratch.appendingPathComponent("first")
        try payload.write(to: first)
        let stored = try await cache.adopt(verifiedFile: first, for: offer, admission: try await cacheAdmission(cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(stored.pathExtension, "m4a")
        let found = await cache.cachedFile(for: offer, admission: try await cacheAdmission(cache))
        XCTAssertEqual(found, stored)

        let second = scratch.appendingPathComponent("second")
        try payload.write(to: second)
        let again = try await cache.adopt(verifiedFile: second, for: offer, admission: try await cacheAdmission(cache))
        XCTAssertEqual(again, stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        let other = try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(Data([9])), byteCount: 1, mediaType: "audio/mp4",
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
        let differentBytes = await cache.cachedFile(for: other, admission: try await cacheAdmission(cache))
        XCTAssertNil(differentBytes)
        let notReady = await cache.cachedFile(for: .notReady(entryID: entryID), admission: try await cacheAdmission(cache))
        XCTAssertNil(notReady)
    }

    func testFileMediaCacheLeavesNoPartialFilesAndReportsNewestRevision() async throws {
        let cache = makeCache()
        let bytes = Data([1, 2, 3, 4])
        let file = scratch.appendingPathComponent("v1")
        try bytes.write(to: file)
        let offer = try makeOffer(bytes)
        _ = try await cache.adopt(verifiedFile: file, for: offer, admission: try await cacheAdmission(cache))
        let entries = await cache.cachedEntries()
        XCTAssertEqual(entries[entryID]?.byteCount, 4)
        let root = scratch.appendingPathComponent("cache")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(Set(hidden), [".preparation-ledger.json"], "only the durable admission ledger may remain at the root")

        let missingSource = scratch.appendingPathComponent("nope")
        let otherOffer = try makeOffer(Data([5, 6]))
        do {
            _ = try await cache.adopt(verifiedFile: missingSource, for: otherOffer, admission: try await cacheAdmission(cache))
            XCTFail("adopting a missing file must throw")
        } catch {}
        let afterFailure = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(Set(afterFailure), [".preparation-ledger.json"])
    }
}
