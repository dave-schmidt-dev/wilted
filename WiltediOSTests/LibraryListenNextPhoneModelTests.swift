import Foundation
import XCTest
import WiltedDomain
@testable import WiltedLibrary
import WiltedPlayback
@testable import WiltediOS

actor ListenNextAudioFixture: LibraryStoryAudioTransport {
    private let owner: String
    private let sourceFile: URL
    private var holdFetch: Bool
    private var downloadFailuresRemaining: Int
    private var fetchAttempts = 0
    private var statusReadAttempts = 0
    private var statuses: [String: LibraryListenNextStatus] = [:]
    private var downloadedOffers: [LibraryStoryAudioOffer] = []
    private var fetchStarted = false
    private var fetchCancelled = false
    private var startedRequestIDs: Set<String> = []
    private var cancelledRequestIDs: Set<String> = []

    init(owner: String, sourceFile: URL, holdFetch: Bool = false, downloadFailures: Int = 0) {
        self.owner = owner
        self.sourceFile = sourceFile
        self.holdFetch = holdFetch
        downloadFailuresRemaining = max(0, downloadFailures)
    }

    func setStatus(_ status: LibraryListenNextStatus) { statuses[status.requestID] = status }
    func publishReadyBulletinStatus(for intent: LibraryIntent, at date: Date, revision: UInt64 = 1) throws {
        guard case let .requestBulletinAudio(bulletinID) = intent.action else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            throw LibraryTransportError.transport("the bulletin audio fixture has no size")
        }
        let offer = try LibraryStoryAudioOffer(
            requestID: intent.id, storyID: bulletinID, requesterDeviceID: intent.deviceID,
            voiceID: "casey-kasem", voiceRevision: "casey-kasem-short-v1",
            audioRevision: RevisionID(rawValue: "rev-bulletin-audio"),
            contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: byteCount,
            mediaType: "audio/mp4", durationSeconds: 2)
        statuses[intent.id] = try LibraryListenNextStatus(
            requestID: intent.id, storyID: bulletinID, requesterDeviceID: intent.deviceID,
            phase: .ready, statusRevision: revision, updatedAt: date,
            voiceID: offer.voiceID, voiceRevision: offer.voiceRevision, audioOffer: offer)
    }
    func setHoldFetch(_ hold: Bool) { holdFetch = hold }
    var fetchedOffers: [LibraryStoryAudioOffer] { downloadedOffers }
    var fetchAttemptCount: Int { fetchAttempts }
    var statusReadCount: Int { statusReadAttempts }
    var didStartFetch: Bool { fetchStarted }
    var wasFetchCancelled: Bool { fetchCancelled }
    func didStartFetch(requestID: String) -> Bool { startedRequestIDs.contains(requestID) }
    func wasFetchCancelled(requestID: String) -> Bool { cancelledRequestIDs.contains(requestID) }

    func publishStoryAudio(offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        guard expectedOwner == owner else { throw LibraryTransportError.superseded }
    }

    func fetchStoryAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String,
        progress: @escaping MediaProgressHandler
    ) async throws -> URL {
        guard expectedOwner == owner, offer.requesterDeviceID == "phone-1" else {
            throw LibraryTransportError.ownershipViolation("The story offer is outside this phone's scope.")
        }
        fetchAttempts += 1
        if downloadFailuresRemaining > 0 {
            downloadFailuresRemaining -= 1
            throw LibraryTransportError.transport("a transient story audio transfer failure")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == offer.byteCount,
              try MediaHash.sha256(fileAt: sourceFile) == offer.contentHash else {
            throw LibraryTransportError.transport("The story audio fixture does not match its offer.")
        }
        fetchStarted = true
        startedRequestIDs.insert(offer.requestID)
        progress(offer.byteCount)
        if holdFetch {
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                fetchCancelled = true
                cancelledRequestIDs.insert(offer.requestID)
                throw error
            }
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: sourceFile, to: destination)
        downloadedOffers.append(offer)
        return destination
    }

    func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async throws {
        guard expectedOwner == owner else { throw LibraryTransportError.superseded }
    }

    func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws {
        guard expectedOwner == owner else { throw LibraryTransportError.superseded }
        statuses[status.requestID] = status
    }

    func listenNextStatuses(requestIDs: Set<String>, expectedOwner: String) async throws -> [LibraryListenNextStatus] {
        guard expectedOwner == owner else { throw LibraryTransportError.superseded }
        statusReadAttempts += 1
        return requestIDs.compactMap { statuses[$0] }
    }
}

struct ListenNextPhoneTransport: LibraryTransport, LibraryStoryAudioTransport {
    let inner: InMemoryLibraryTransport
    let sendScript: OutboxSendScript
    let audio: ListenNextAudioFixture
    let identity: ListenNextPhoneIdentity
    let autoReadyBulletinAudio: Bool

    func operationGeneration() async -> UInt64 { await identity.operationGeneration() }
    func verifiedOwnerToken() async -> String? { await identity.ownerToken() }
    func switchAccount(to owner: String) async {
        await inner.invalidateOperations()
        await identity.switchAccount(to: owner)
    }
    func disconnect() async { await identity.disconnect() }
    func verifyOwner() async throws { try await inner.verifyOwner() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws {
        switch sendScript.begin(intent.id) {
        case .deliver:
            try await inner.send(intent: intent)
            if autoReadyBulletinAudio {
                try await audio.publishReadyBulletinStatus(for: intent, at: Date())
            }
        case .fail: throw LibraryTransportError.transport("the Mac is unreachable")
        case .deliverThenFail:
            try await inner.send(intent: intent)
            throw LibraryTransportError.transport("the reply was lost")
        case .hold:
            await sendScript.waitForRelease()
            try await inner.send(intent: intent)
        }
    }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }

    func publishStoryAudio(offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        try await audio.publishStoryAudio(offer: offer, fileURL: fileURL, expectedOwner: expectedOwner)
    }
    func fetchStoryAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String,
        progress: @escaping MediaProgressHandler
    ) async throws -> URL {
        try await audio.fetchStoryAudio(offer, expectedOwner: expectedOwner, progress: progress)
    }
    func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async throws {
        try await audio.removeStoryAudio(offer, expectedOwner: expectedOwner)
    }
    func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws {
        try await audio.publishListenNextStatus(status, expectedOwner: expectedOwner)
    }
    func listenNextStatuses(
        requestIDs: Set<String>,
        expectedOwner: String
    ) async throws -> [LibraryListenNextStatus] {
        try await audio.listenNextStatuses(requestIDs: requestIDs, expectedOwner: expectedOwner)
    }
}

actor ListenNextPhoneIdentity {
    private var owner: String?
    private var generation: UInt64 = 0

    init(owner: String) { self.owner = owner }

    func operationGeneration() -> UInt64 { generation }
    func ownerToken() -> String? { owner }
    func advanceGeneration() { generation &+= 1 }
    func disconnect() { owner = nil; generation &+= 1 }
    func switchAccount(to owner: String) {
        generation &+= 1
        self.owner = owner
    }
}

actor ListenNextPhoneStore: LibraryStore {
    private var saved: LibraryStoreState

    init(owner: String) {
        var state = LibraryStoreState()
        state.ownerToken = owner
        saved = state
    }

    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) throws { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
}

final class ListenNextPhoneTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(start: Date) { date = start }

    func current() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

@MainActor
final class LibraryListenNextPhoneModelTests: XCTestCase {
    let owner = "listen-next-owner"
    let clock = ListenNextPhoneTestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
    var now: Date { clock.current() }
    var scratch: URL!
    var sourceFile: URL!
    var defaults: UserDefaults!
    let server = InMemoryLibraryServer(writerDeviceID: "mac")

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("listen-next-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        sourceFile = scratch.appendingPathComponent("story-audio.m4a")
        try Data([1, 2, 3, 4]).write(to: sourceFile)
        let suite = "listen-next-model-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    func story() throws -> LibraryHeadlineStory {
        try story(id: "headline-1")
    }

    func story(id: String) throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: id, title: "A story worth hearing", publisherID: "publisher-1",
            publisherName: "Publisher", link: URL(string: "https://example.invalid/\(id)"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now
        )
    }

    func transport(
        _ script: OutboxSendScript, holdFetch: Bool = false,
        downloadFailures: Int = 0, autoReadyBulletinAudio: Bool = false
    ) -> ListenNextPhoneTransport {
        ListenNextPhoneTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone-1", server: server, verifiedOwnerToken: owner),
            sendScript: script,
            audio: ListenNextAudioFixture(
                owner: owner, sourceFile: sourceFile, holdFetch: holdFetch, downloadFailures: downloadFailures),
            identity: ListenNextPhoneIdentity(owner: owner), autoReadyBulletinAudio: autoReadyBulletinAudio
        )
    }

    func model(
        _ transport: ListenNextPhoneTransport,
        recovery: LibraryAccountRecovery? = nil
    ) -> LibraryAppModel {
        let clock = self.clock
        let model = LibraryAppModel(
            transport: transport, store: ListenNextPhoneStore(owner: owner), deviceID: "phone-1", recovery: recovery,
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("media-cache")),
            preferences: defaults, outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            listenNextURL: scratch.appendingPathComponent("pending-listen-next-v1.json"),
            now: { clock.current() }, timeZone: TimeZone(identifier: "UTC")!
        )
        model.macAddActions = ["listenNext", "cancelListenNext"]
        return model
    }

    private var outbox: LibraryListenNextPhoneOutbox {
        LibraryListenNextPhoneOutbox(url: scratch.appendingPathComponent("pending-listen-next-v1.json"))
    }

    func eventually(_ description: String, _ condition: () async -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= end { XCTFail("Timed out waiting for \(description)."); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testNowPlayingHeadlineUsesTheExactStoredCatalogStoryID() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story()
        let generation = await transport.operationGeneration()
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [story], saved: [], publishers: [])
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(projection, owner: owner, generation: generation)
        let bulletin = try Bulletin(
            id: "headline:\(story.id)", kind: .headline, text: "Spoken copy",
            issuedAt: now, expiresAt: now.addingTimeInterval(300), storyID: story.id,
            publisherID: "publisher-1", publisherName: "A different display value",
            headline: "A different title", link: URL(string: "https://example.invalid/other"))

        XCTAssertEqual(model.canonicalHeadlineStory(for: bulletin), story)
        let unknown = try Bulletin(
            id: "headline:unknown", kind: .headline, text: story.title,
            issuedAt: now, expiresAt: now.addingTimeInterval(300), storyID: "unknown",
            headline: story.title, link: story.link)
        XCTAssertNil(model.canonicalHeadlineStory(for: unknown))
    }

    func testRequestIsDurablePendingBeforeSendAndSentOnlyAfterAcceptance() async throws {
        let script = OutboxSendScript(.hold)
        let transport = transport(script)
        let model = model(transport)
        await model.loadLocalState()

        let story = try story()
        let send = Task { await model.listenNext(story) }
        await eventually("the held request send") { script.attempts.count == 1 }

        guard case let .saved(duringSend) = outbox.load(), let pending = duringSend.entries.first else {
            return XCTFail("The request was not on disk before transport acceptance.")
        }
        XCTAssertEqual(pending.snapshot.status, .pending)
        XCTAssertNotNil(pending.requestIntent)
        XCTAssertEqual(pending.snapshot.ownerToken, owner)
        XCTAssertEqual(pending.snapshot.requesterDeviceID, "phone-1")

        script.release()
        await send.value
        guard case let .saved(accepted) = outbox.load() else { return XCTFail("The accepted request was not saved.") }
        XCTAssertEqual(accepted.entries.first?.snapshot.status, .sent)
        XCTAssertNil(accepted.entries.first?.requestIntent)
        XCTAssertEqual(accepted.entries.first?.id, pending.id)
    }

    func testSimultaneousListenNextTapsFromDifferentSurfacesCreateOnePendingRequest() async throws {
        let script = OutboxSendScript(.hold)
        let model = model(transport(script))
        await model.loadLocalState()
        let story = try story()

        let firstSurfaceTap = Task { await model.listenNext(story) }
        let secondSurfaceTap = Task { await model.listenNext(story) }

        await eventually("the single shared request send") { !script.attempts.isEmpty }
        guard case let .saved(pending) = outbox.load() else {
            script.release()
            return XCTFail("The concurrent request was not persisted before send.")
        }
        XCTAssertEqual(pending.entries.count, 1)
        XCTAssertEqual(pending.entries.first?.snapshot.status, .pending)
        script.release()
        await firstSurfaceTap.value
        await secondSurfaceTap.value

        guard case let .saved(saved) = outbox.load() else { return XCTFail("The request was not saved.") }
        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertEqual(saved.entries.first?.snapshot.storyID, story.id)
        XCTAssertEqual(script.attempts.count, 1)
        XCTAssertEqual(model.listenNextRequests.filter { $0.storyID == story.id && !$0.isTerminal }.count, 1)
    }

    func testExplicitListenNextRearmsAPreviouslyHeldStoryQueue() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        defaults.set(UInt64(4), forKey: "wilted.listenNext.playback.hold.v1")
        defaults.set(true, forKey: "wilted.listenNext.playback.held.v1")
        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)

        await model.listenNext(try story())

        XCTAssertFalse(defaults.bool(forKey: "wilted.listenNext.playback.held.v1"))
        XCTAssertEqual(player.storyAutoStartEpoch, 5)
        let data = try XCTUnwrap(defaults.data(forKey: "wilted.listenNext.playback.v1"))
        let ledger = try JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data)
        XCTAssertEqual(ledger.entries.first?.holdEpoch, 5)
    }

    func testRelaunchAfterLostAcceptanceResendsTheSameRequestIDOnce() async throws {
        let first = model(transport(OutboxSendScript(.deliverThenFail)))
        await first.loadLocalState()
        await first.listenNext(try story())
        guard case let .saved(savedAfterLostReply) = outbox.load(), let acceptedRemotely = savedAfterLostReply.entries.first else {
            return XCTFail("The crash-window request was not durable.")
        }
        XCTAssertEqual(acceptedRemotely.snapshot.status, .pending)
        let beforeReplay = await server.allIntents().map(\.id)
        XCTAssertEqual(beforeReplay, [acceptedRemotely.id])

        let retryingTransport = transport(OutboxSendScript(.deliver))
        let relaunched = model(retryingTransport)
        await relaunched.loadLocalState()
        XCTAssertEqual(relaunched.listenNextRequests.map(\.requestID), [acceptedRemotely.id])
        await relaunched.syncListenNextRequests()

        guard case let .saved(replayedOutbox) = outbox.load() else { return XCTFail("The replayed request was not saved.") }
        XCTAssertEqual(replayedOutbox.entries.first?.snapshot.status, .sent)
        let afterReplayIntentIDs = await server.allIntents().map(\.id)
        XCTAssertEqual(afterReplayIntentIDs, [acceptedRemotely.id])
    }

    func testUndoPersistsCancellationTombstoneBeforeSendingIt() async throws {
        let script = OutboxSendScript(.deliver)
        let transport = transport(script)
        let model = model(transport)
        await model.loadLocalState()
        await model.listenNext(try story())
        let requestID = try XCTUnwrap(model.listenNextRequests.first?.requestID)
        script.mode = .hold

        let undo = Task { await model.undoListenNext(requestID: requestID) }
        await eventually("the held cancellation send") { script.attempts.count == 2 }
        guard case let .saved(duringCancellation) = outbox.load(), let cancelled = duringCancellation.entries.first else {
            return XCTFail("Undo removed the durable cancellation tombstone.")
        }
        XCTAssertEqual(cancelled.snapshot.status, .cancelled)
        XCTAssertEqual(cancelled.cancellationIntent?.action, .cancelListenNext(requestID: requestID))
        XCTAssertEqual(model.listenNextRequests.first?.status, .cancelled)

        script.release()
        await undo.value
        guard case let .saved(afterCancellation) = outbox.load() else { return XCTFail("The cancellation result was not saved.") }
        XCTAssertNil(afterCancellation.entries.first?.cancellationIntent)
    }

    func testUndoAfterLostSendReplyRetriesOriginalIDThenSendsCancellation() async throws {
        let script = OutboxSendScript(.deliverThenFail)
        let transport = transport(script)
        let model = model(transport)
        await model.loadLocalState()
        await model.listenNext(try story())
        let requestID = try XCTUnwrap(model.listenNextRequests.first?.requestID)
        guard case let .saved(afterLostReply) = outbox.load(), let pending = afterLostReply.entries.first else {
            return XCTFail("The attempted request was not saved.")
        }
        XCTAssertTrue(pending.requestAttempted)
        XCTAssertFalse(pending.requestSent)

        script.mode = .deliver
        await model.undoListenNext(requestID: requestID)
        guard case let .saved(afterUndo) = outbox.load(), let cancelled = afterUndo.entries.first else {
            return XCTFail("Undo removed the request recovery state.")
        }
        XCTAssertEqual(cancelled.snapshot.status, .cancelled)
        XCTAssertTrue(cancelled.requestSent)
        XCTAssertNil(cancelled.requestIntent)
        XCTAssertNil(cancelled.cancellationIntent)

        let acceptedIntents = await server.allIntents()
        XCTAssertEqual(acceptedIntents.filter { $0.id == requestID }.count, 1)
        XCTAssertTrue(acceptedIntents.contains { intent in
            if case let .cancelListenNext(cancelledID) = intent.action { return cancelledID == requestID }
            return false
        })
    }

    func testReadyStatusFetchesOnlyExactRequesterOfferAndCachesIt() async throws {
        let script = OutboxSendScript(.deliver)
        let transport = transport(script)
        let model = model(transport)
        await model.loadLocalState()
        await model.listenNext(try story())
        let request = try XCTUnwrap(model.listenNextRequests.first)
        let offer = try LibraryStoryAudioOffer(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            voiceID: "approved-voice", voiceRevision: "voice-revision-1",
            audioRevision: RevisionID(rawValue: "story-audio-1"),
            contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: 4,
            mediaType: "audio/mp4", durationSeconds: 3
        )
        let statusUpdatedAt = now.addingTimeInterval(45)
        let status = try LibraryListenNextStatus(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            phase: .ready, statusRevision: 1, updatedAt: statusUpdatedAt, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer
        )
        await transport.audio.setStatus(status)

        await model.syncListenNextRequests()
        await eventually("the exact story audio cache") {
            guard case let .saved(saved) = self.outbox.load() else { return false }
            return saved.entries.first?.audioCached == true
        }

        let fetchedOffers = await transport.audio.fetchedOffers
        XCTAssertEqual(fetchedOffers, [offer])
        XCTAssertEqual(model.listenNextStoryStatuses[request.requestID], "Up next")
        let readyRequest = try XCTUnwrap(model.listenNextRequests.first)
        XCTAssertEqual(readyRequest.voiceRevision, offer.voiceRevision)
        XCTAssertEqual(readyRequest.audioOffer, offer)
        XCTAssertEqual(readyRequest.statusUpdatedAt, statusUpdatedAt)
        let cachedCandidate = await model.listenNextAudioURL(for: readyRequest)
        let cachedURL = try XCTUnwrap(cachedCandidate)
        let selectedCandidate = await model.setListenNextStatus(readyRequest, to: .selected)
        let selectedRequest = try XCTUnwrap(selectedCandidate)
        XCTAssertEqual(selectedRequest.statusRevision, readyRequest.statusRevision + 1)
        XCTAssertEqual(selectedRequest.audioOffer, offer)
        let readyAgainCandidate = await model.setListenNextStatus(selectedRequest, to: .ready)
        let readyAgain = try XCTUnwrap(readyAgainCandidate)
        XCTAssertEqual(readyAgain.statusRevision, selectedRequest.statusRevision + 1)
        XCTAssertEqual(readyAgain.audioOffer, offer, "An abandoned pre-start selection keeps verified audio cached.")
        let staleCandidate = await model.setListenNextStatus(readyRequest, to: .selected)
        XCTAssertNil(staleCandidate, "A stale ready callback must not overwrite playback state.")
        let selectedAgainCandidate = await model.setListenNextStatus(readyAgain, to: .selected)
        let selectedAgain = try XCTUnwrap(selectedAgainCandidate)
        let playingCandidate = await model.setListenNextStatus(selectedAgain, to: .playing)
        let playingRequest = try XCTUnwrap(playingCandidate)
        await model.syncListenNextRequests()
        let refreshedPlaying = try XCTUnwrap(model.listenNextRequests.first)
        XCTAssertEqual(refreshedPlaying.status, .playing)
        XCTAssertEqual(refreshedPlaying.statusRevision, playingRequest.statusRevision)
        let restoredPlayingURL = await model.listenNextAudioURL(for: refreshedPlaying)
        XCTAssertEqual(restoredPlayingURL, cachedURL)

        let relaunched = self.model(self.transport(OutboxSendScript(.deliver)))
        await relaunched.loadLocalState()
        let restoredRequest = try XCTUnwrap(relaunched.listenNextRequests.first)
        let restoredURL = await relaunched.listenNextAudioURL(for: restoredRequest)
        XCTAssertEqual(restoredURL, cachedURL)

        relaunched.discardListenNextAfterAccountChange()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
    }

    func testFailedRequestOffersRetryUsingTheOriginalStoryURL() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story()
        await model.listenNext(story)
        let failedID = try XCTUnwrap(model.listenNextRequests.first?.requestID)
        await transport.audio.setStatus(try LibraryListenNextStatus(
            requestID: failedID, storyID: story.id, requesterDeviceID: "phone-1",
            phase: .failed, statusRevision: 1, updatedAt: now, failure: .unavailableStory
        ))

        await model.syncListenNextRequests()
        XCTAssertEqual(model.listenNextStoryStatuses[failedID], "Could not prepare")
        XCTAssertEqual(model.listenNextStoryMessages[failedID], "The article could not be fetched. Retry the original story link.")
        await model.retryListenNext(requestID: failedID)

        let retried = try XCTUnwrap(model.listenNextRequests.first { $0.requestID != failedID })
        XCTAssertNotEqual(retried.requestID, failedID)
        XCTAssertEqual(retried.story, story)
        XCTAssertEqual(retried.story.link, story.link)
        guard case let .saved(saved) = outbox.load() else { return XCTFail("The retry was not persisted.") }
        XCTAssertEqual(saved.entries.count, 2)
        XCTAssertTrue(saved.entries.contains { $0.id == retried.requestID && $0.requestSent })
    }

    func testCompletedRequestAllowsASeparateListenNextRequest() async throws {
        let transport = transport(OutboxSendScript(.deliver))
        let model = model(transport)
        await model.loadLocalState()
        let story = try story()
        await model.listenNext(story)
        let request = try XCTUnwrap(model.listenNextRequests.first)
        let offer = try LibraryStoryAudioOffer(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            voiceID: "approved-voice", voiceRevision: "voice-revision-1",
            audioRevision: RevisionID(rawValue: "story-audio-completed"),
            contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: 4,
            mediaType: "audio/mp4", durationSeconds: 3
        )
        await transport.audio.setStatus(try LibraryListenNextStatus(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            phase: .ready, statusRevision: 1, updatedAt: now, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer
        ))
        await model.syncListenNextRequests()

        let ready = try XCTUnwrap(model.listenNextRequests.first)
        let selectedCandidate = await model.setListenNextStatus(ready, to: .selected)
        let selected = try XCTUnwrap(selectedCandidate)
        let playingCandidate = await model.setListenNextStatus(selected, to: .playing)
        let playing = try XCTUnwrap(playingCandidate)
        let completedCandidate = await model.setListenNextStatus(playing, to: .completed)
        let completed = try XCTUnwrap(completedCandidate)
        XCTAssertEqual(completed.status, .completed)

        await model.listenNext(story)

        XCTAssertEqual(model.listenNextRequests.filter { $0.storyID == story.id }.count, 2)
        XCTAssertEqual(model.listenNextRequests.filter { $0.storyID == story.id && $0.status == .completed }.count, 1)
        XCTAssertEqual(model.listenNextRequests.filter { $0.storyID == story.id && !$0.isTerminal }.count, 1)
    }

    func testOwnerGenerationChangeCancelsFetchAndAccountRecoveryClearsOldRequests() async throws {
        let script = OutboxSendScript(.deliver)
        let transport = transport(script, holdFetch: true)
        let recovery = LibraryAccountRecovery(
            quarantineEvents: AsyncStream<Void> { continuation in continuation.finish() }) {
                InMemoryLibraryStore()
            }
        let model = model(transport, recovery: recovery)
        await model.loadLocalState()
        await model.listenNext(try story())
        let request = try XCTUnwrap(model.listenNextRequests.first)
        let offer = try LibraryStoryAudioOffer(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            voiceID: "approved-voice", voiceRevision: "voice-revision-1",
            audioRevision: RevisionID(rawValue: "story-audio-2"),
            contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: 4,
            mediaType: "audio/mp4", durationSeconds: 3
        )
        await transport.audio.setStatus(try LibraryListenNextStatus(
            requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
            phase: .ready, statusRevision: 1, updatedAt: now, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer
        ))
        await model.syncListenNextRequests()
        await eventually("story audio fetch start") { await transport.audio.didStartFetch }

        await transport.identity.advanceGeneration()
        await model.syncListenNextRequests()
        await eventually("story audio fetch cancellation") { await transport.audio.wasFetchCancelled }
        await model.recoverFromAccountChange()

        XCTAssertTrue(model.listenNextRequests.isEmpty)
        guard case let .saved(cleared) = outbox.load() else { return XCTFail("The recovered account did not save an empty outbox.") }
        XCTAssertNil(cleared.ownerToken)
        XCTAssertTrue(cleared.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "wilted.listenNext.playback.v1"))
    }

    func testAccountSwitchRejectsCachedStoryAndCancelsOldGenerationDelivery() async throws {
        try await assertAccountSwitchRejectsCachedStoryAndCancelsOldGenerationDelivery(self)
    }
}
