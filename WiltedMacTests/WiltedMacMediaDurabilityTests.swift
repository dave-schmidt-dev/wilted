import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// Writes the accounting through the central replacement primitive, failing the folder sync of
/// chosen saves or throwing before the rename.
private final class ScriptedAccountingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    private let uncertainSaves: Set<Int>
    private let failingSave: Int?

    init(uncertainSaves: Set<Int> = [], failingBeforeRename save: Int? = nil) {
        self.uncertainSaves = uncertainSaves
        failingSave = save
    }

    var calls: Int { lock.withLock { saves } }

    var write: WiltedMacMediaService.AccountingWriter {
        { [self] data, url in
            let save = lock.withLock { () -> Int in
                saves += 1
                return saves
            }
            if save == failingSave { throw POSIXError(.ENOSPC) }
            guard uncertainSaves.contains(save) else { return try DurableFile.replace(data, to: url) }
            return try DurableFile.$directorySyncInterceptor.withValue({ _ in throw POSIXError(.EIO) }) {
                try DurableFile.replace(data, to: url)
            }
        }
    }
}

/// Records the stages the service reports for a request.
private final class RequestStageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(LibraryMediaRequestStatus.Stage, String?)] = []

    var stages: [LibraryMediaRequestStatus.Stage] { lock.withLock { storage.map(\.0) } }
    var entries: [(LibraryMediaRequestStatus.Stage, String?)] { lock.withLock { storage } }

    func append(_ stage: LibraryMediaRequestStatus.Stage, detail: String? = nil) {
        lock.withLock { storage.append((stage, detail)) }
    }
}

private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []
    func append(_ wait: Duration) { lock.withLock { waits.append(wait) } }
    var values: [Duration] { lock.withLock { waits } }
}

private final class FlakyCountingMediaTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var failuresLeft: Int
    private var attempts = 0
    private var uploads = 0
    private var failure: @Sendable () -> Error

    init(_ inner: InMemoryLibraryTransport, failing count: Int = 0, with failure: @escaping @Sendable () -> Error = { URLError(.networkConnectionLost) }) {
        self.inner = inner
        self.failuresLeft = count
        self.failure = failure
    }

    var readyAttempts: Int { lock.withLock { attempts } }
    var readyUploads: Int { lock.withLock { uploads } }

    func setFailures(_ count: Int, with failure: @escaping @Sendable () -> Error = { URLError(.networkConnectionLost) }) {
        lock.withLock {
            self.failuresLeft = count
            self.failure = failure
        }
    }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await inner.publishTranscript(transcript) }
    func removeTranscript(entryID: ItemID) async throws { try await inner.removeTranscript(entryID: entryID) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        guard offer.state == .ready else { return try await inner.publishMedia(offer: offer, fileURL: fileURL) }
        let shouldFail = lock.withLock { () -> Bool in
            attempts += 1
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if shouldFail { throw lock.withLock { failure() } }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
        lock.withLock { uploads += 1 }
    }
}

/// Forwards to the in-memory transport and counts ready-audio uploads.
private final class CountingMediaTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var uploads = 0

    init(_ inner: InMemoryLibraryTransport) { self.inner = inner }

    var readyUploads: Int { lock.withLock { uploads } }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await inner.publishTranscript(transcript) }
    func removeTranscript(entryID: ItemID) async throws { try await inner.removeTranscript(entryID: entryID) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        if offer.state == .ready { lock.withLock { uploads += 1 } }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }
}

@MainActor
final class WiltedMacMediaDurabilityTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-a"
    private let tabletID = "ipad-b"
    private let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))

    private struct Rig {
        let server: InMemoryLibraryServer
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let source: ScriptedAudioSource
        let clock: MutableClock
        let directory: URL
    }

    private func rig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        return Rig(
            server: server, mac: InMemoryLibraryTransport(deviceID: macID, server: server),
            phone: InMemoryLibraryTransport(deviceID: phoneID, server: server), source: ScriptedAudioSource(),
            clock: clock, directory: wiltedTemporaryDirectory(name)
        )
    }

    private func id(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    private func makeAudio(_ directory: URL, revision: String) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(revision).m4a")
        try Data(repeating: UInt8(revision.utf8.last ?? 1), count: 4_096).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: revision), contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: 4_096, mediaType: "audio/mp4", durationSeconds: 60, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(clock.now))
        )
    }

    private func request(_ rig: Rig, _ entry: ItemID, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.requestMedia(entryID: entry, deviceID: device, createdAt: rig.clock.now, id: intentID)
    }

    private func cached(_ rig: Rig, _ entry: ItemID, _ revision: String, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(
            entryID: entry, revisionID: try RevisionID(rawValue: revision), deviceID: device, createdAt: rig.clock.now, id: intentID
        )
    }

    private func makeService(
        _ rig: Rig, transport: any LibraryTransport, writer: ScriptedAccountingWriter,
        reportRequest: WiltedMacMediaService.RequestReporter? = nil
    ) -> WiltedMacMediaService {
        let clock = rig.clock
        return WiltedMacMediaService(
            source: rig.source, transport: transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { clock.now }, reportRequest: reportRequest, accountingWrite: writer.write
        )
    }

    func testAnUncertainAccountingSaveAnswersSuccessAndDoesNotUploadAgain() async throws {
        let rig = rig("media-accounting-uncertain")
        let entry = try id("episode-accounting-uncertain")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(uncertainSaves: [1, 2])
        let stages = RequestStageLog()
        let service = makeService(rig, transport: transport, writer: writer,
                                  reportRequest: { _, stage, _ in stages.append(stage) })
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "a-1")

        await service.handle(mediaRequest)

        let failure = await service.lastFailure
        XCTAssertNil(failure, "a landed accounting save must not be reported as a failure")
        XCTAssertEqual(transport.readyUploads, 1)
        let holding = await service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
        XCTAssertEqual(stages.stages, [.sending, .answered], "an uncertain folder sync is not reported as a failed request")

        await service.handle(mediaRequest)
        XCTAssertEqual(transport.readyUploads, 1, "a false save failure must not trigger another upload")
        XCTAssertEqual(writer.calls, 2, "the redundant request updated the requester, not the audio")
    }

    func testTwoRequestersSurviveRestartAndWithdrawalWaitsForBothAcks() async throws {
        let rig = rig("media-accounting-requesters")
        let entry = try id("episode-two-requesters")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(uncertainSaves: Set(1...8))
        let first = makeService(rig, transport: transport, writer: writer)

        await first.handle(try request(rig, entry, from: phoneID, intentID: "two-a"))
        await first.handle(try request(rig, entry, from: tabletID, intentID: "two-b"))
        XCTAssertEqual(transport.readyUploads, 1)
        let firstFailure = await first.lastFailure
        XCTAssertNil(firstFailure)

        let restarted = makeService(rig, transport: transport, writer: writer)
        let accounted = await restarted.accountedAssetCount
        XCTAssertEqual(accounted, 1, "the accounting with both requesters survives the restart")

        await restarted.handle(try cached(rig, entry, "rev-1", from: phoneID, intentID: "two-ack-a"))
        let holdingAfterOne = await restarted.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holdingAfterOne, "one acknowledgment is not enough")
        XCTAssertEqual(transport.readyUploads, 1)

        await restarted.handle(try cached(rig, entry, "rev-1", from: tabletID, intentID: "two-ack-b"))
        let holdingAfterBoth = await restarted.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertFalse(holdingAfterBoth)
        let remaining = await restarted.accountedAssetCount
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(transport.readyUploads, 1, "withdrawal never uploads the audio again")
    }

    func testAnAccountingSaveThatFailsBeforeTheRenameIsStillReported() async throws {
        let rig = rig("media-accounting-before-rename")
        let entry = try id("episode-accounting-before-rename")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(failingBeforeRename: 1)
        let service = makeService(rig, transport: transport, writer: writer)

        await service.handle(try request(rig, entry, from: phoneID, intentID: "b-1"))

        let failure = await service.lastFailure
        XCTAssertNotNil(failure, "a pre-rename persistence failure stays observable")
        XCTAssertEqual(transport.readyUploads, 1)
        XCTAssertEqual(writer.calls, 1)
    }

    private func makeRuntime(
        _ rig: Rig, transport: any LibraryTransport? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onRoundFinished: WiltedMacInboundPoller.RoundFinished? = nil
    ) -> WiltedMacInboundRuntime {
        let clock = rig.clock
        return WiltedMacInboundRuntime(
            source: rig.source, transport: transport ?? rig.mac, directory: rig.directory,
            deviceID: macID, onRoundFinished: onRoundFinished,
            sleep: sleep, now: { clock.now }
        )
    }

    private func seedQueueFile(_ rig: Rig, intents: [LibraryIntent]) throws {
        let file = rig.directory.appendingPathComponent("media-upload-queue.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = WiltedMacMediaUploadQueue.Stored(version: 1, intents: intents)
        let data = try JSONEncoder().encode(stored)
        _ = try DurableFile.replace(data, to: file)
    }

    private func seedLedgerFile(_ rig: Rig, ids: [String]) throws {
        let file = rig.directory.appendingPathComponent("intent-ledger.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct LedgerStored: Codable {
            var version = 1
            var recorded: [String: Date]
        }
        var recorded: [String: Date] = [:]
        for id in ids { recorded[id] = rig.clock.now }
        let data = try JSONEncoder().encode(LedgerStored(recorded: recorded))
        _ = try DurableFile.replace(data, to: file)
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func queuedService(
        _ rig: Rig, transport: any LibraryTransport,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reportRequest: WiltedMacMediaService.RequestReporter? = nil
    ) -> WiltedMacMediaService {
        let clock = rig.clock
        return WiltedMacMediaService(
            source: rig.source, transport: transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { clock.now }, sleep: sleep, reportRequest: reportRequest,
            queueURL: rig.directory.appendingPathComponent("media-upload-queue.json")
        )
    }

    func testLongThrottleThenSuccessAnswersOnce() async throws {
        let rig = rig("media-throttle-long-success")
        let entry = try id("episode-throttle-long")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let clock = rig.clock
        // Longer than the old ten-minute limit, which would have failed the request.
        let transport = FlakyCountingMediaTransport(
            rig.mac, failing: 1, with: { TransportThrottled(retryAt: clock.now.addingTimeInterval(1800)) }
        )
        let stages = RequestStageLog()
        let waits = WaitLog()
        let service = queuedService(rig, transport: transport, sleep: { wait in
            waits.append(wait)
            clock.advance(1800)
        }, reportRequest: { _, stage, detail in stages.append(stage, detail: detail) })

        await service.handle(try request(rig, entry, from: phoneID, intentID: "throttle-ok-1"))

        XCTAssertEqual(transport.readyAttempts, 2)
        XCTAssertEqual(transport.readyUploads, 1)
        XCTAssertEqual(waits.values, [.seconds(1800)])
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
        XCTAssertEqual(stages.entries.filter { $0.0 == .answered }.count, 1, "the request is answered once")
        XCTAssertEqual(stages.entries.filter { $0.0 == .failed }.count, 0)
        XCTAssertEqual(stages.entries.filter { $0.1 == "waiting for iCloud" }.count, 1)
        let failure = await service.lastFailure
        XCTAssertNil(failure)
        let queued = await service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 0, "a served request leaves the queue")
    }

    func testQuitDuringThrottleWaitDrainsUnderTenSecondsAndRequestServedAfterRelaunch() async throws {
        let rig = rig("media-quit-during-throttle")
        let entry = try id("episode-quit-drain")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let clock = rig.clock
        let transport = FlakyCountingMediaTransport(
            rig.mac, failing: 1, with: { TransportThrottled(retryAt: clock.now.addingTimeInterval(3600)) }
        )
        let waits = WaitLog()
        // The wait lasts an hour unless cancelled, as `Task.sleep` does.
        let first = makeRuntime(rig, transport: transport, sleep: { wait in
            waits.append(wait)
            try await Task.sleep(for: .seconds(3600))
        })
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "quit-1")
        _ = await first.admit(mediaRequest)
        try await eventually("throttle wait active") { waits.values.count == 1 }

        let started = Date()
        await first.service.drainEndingThrottleWaits()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.0, "quit must drain under 10 seconds")

        let queueURL = rig.directory.appendingPathComponent("media-upload-queue.json")
        let stored = try JSONDecoder().decode(WiltedMacMediaUploadQueue.Stored.self, from: Data(contentsOf: queueURL))
        XCTAssertEqual(stored.intents.map(\.id), ["quit-1"], "the request stays queued")
        XCTAssertEqual(transport.readyUploads, 0)

        let relaunched = makeRuntime(rig, transport: transport)
        await relaunched.resumeQueuedRequests()
        await relaunched.service.drain()

        XCTAssertEqual(transport.readyUploads, 1)
        let holding = await relaunched.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
        let redelivered = await relaunched.admit(mediaRequest)
        XCTAssertNil(redelivered, "a served request is not served again when it is handed over again")
        XCTAssertEqual(transport.readyUploads, 1)
        let queued = await relaunched.service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testCrashAfterQueueWriteBeforeLedgerWriteServesRequestExactlyOnceAfterRelaunch() async throws {
        let rig = rig("media-crash-before-ledger")
        let entry = try id("episode-crash-before-ledger")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "crash-1")
        try seedQueueFile(rig, intents: [mediaRequest])
        let transport = FlakyCountingMediaTransport(rig.mac)

        let runtime = makeRuntime(rig, transport: transport)
        await runtime.resumeQueuedRequests()
        await runtime.service.drain()

        XCTAssertEqual(transport.readyUploads, 1, "served from the queue")
        let ledgerHasIt = await runtime.ledger.contains("crash-1")
        XCTAssertTrue(ledgerHasIt, "the replay records what the crash left out of the ledger")
        let redelivered = await runtime.admit(mediaRequest)
        XCTAssertNil(redelivered)
        XCTAssertEqual(transport.readyUploads, 1, "handed over again, it is not served again")
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
    }

    func testARequestHandedOverBeforeTheReplayIsServedOnceNotTwice() async throws {
        let rig = rig("media-crash-redelivered")
        let entry = try id("episode-crash-redelivered")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "crash-3")
        try seedQueueFile(rig, intents: [mediaRequest])
        let transport = FlakyCountingMediaTransport(rig.mac)

        let runtime = makeRuntime(rig, transport: transport)
        await runtime.consume(mediaRequest)
        await runtime.resumeQueuedRequests()
        await runtime.service.drain()

        XCTAssertEqual(transport.readyUploads, 1, "queued once, served once")
        let ledgerHasIt = await runtime.ledger.contains("crash-3")
        XCTAssertTrue(ledgerHasIt)
    }

    func testCrashAfterBothQueueWriteAndLedgerWriteServesRequestExactlyOnceAfterRelaunch() async throws {
        let rig = rig("media-crash-after-both")
        let entry = try id("episode-crash-after-both")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "crash-2")
        try seedQueueFile(rig, intents: [mediaRequest])
        try seedLedgerFile(rig, ids: ["crash-2"])
        let transport = FlakyCountingMediaTransport(rig.mac)

        let runtime = makeRuntime(rig, transport: transport)
        // The ledger has the id, but the queue still holds it, so the request is served.
        await runtime.consume(mediaRequest)
        await runtime.resumeQueuedRequests()
        await runtime.service.drain()

        XCTAssertEqual(transport.readyUploads, 1, "served exactly once from the replayed queue")
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
        let redelivered = await runtime.admit(mediaRequest)
        XCTAssertNil(redelivered)
        XCTAssertEqual(transport.readyUploads, 1)
    }

    func testIntentOlderThanMaximumIntentAgeFails() async throws {
        let rig = rig("media-stale-intent")
        let entry = try id("episode-stale")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let transport = FlakyCountingMediaTransport(rig.mac)
        let stages = RequestStageLog()
        let staleDate = rig.clock.now.addingTimeInterval(-(WiltedMacMediaService.maximumIntentAge + 3600))
        let staleIntent = try LibraryIntent.requestMedia(entryID: entry, deviceID: phoneID, createdAt: staleDate, id: "stale-1")
        let service = queuedService(rig, transport: transport, reportRequest: { _, stage, detail in stages.append(stage, detail: detail) })

        await service.handle(staleIntent)

        XCTAssertEqual(transport.readyAttempts, 0, "a stale request is not uploaded")
        XCTAssertEqual(stages.stages, [.failed])
        let queued = await service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 0, "a stale request leaves the queue")
    }

    func testATransientFailureRetriesUntilTheIntentIsTooOldThenFails() async throws {
        let rig = rig("media-retry-until-stale")
        let entry = try id("episode-retry-stale")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let clock = rig.clock
        let transport = FlakyCountingMediaTransport(rig.mac, failing: .max)
        let stages = RequestStageLog()
        let service = queuedService(rig, transport: transport, sleep: { wait in
            clock.advance(Double(wait.components.seconds))
        }, reportRequest: { _, stage, detail in stages.append(stage, detail: detail) })

        await service.handle(try request(rig, entry, from: phoneID, intentID: "retry-stale-1"))

        XCTAssertGreaterThan(transport.readyAttempts, 100, "it kept trying for the whole age limit")
        XCTAssertEqual(transport.readyUploads, 0)
        XCTAssertEqual(stages.entries.filter { $0.1 == "waiting for iCloud" }.count, 1, "waiting is reported once")
        XCTAssertEqual(stages.entries.filter { $0.0 == .sending && $0.1 == nil }.count, 1, "a retry does not repeat sending")
        XCTAssertEqual(stages.stages.last, .failed)
        XCTAssertEqual(stages.stages.filter { $0 == .failed }.count, 1)
        let queued = await service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testAPermanentErrorFailsAtOnceAndLeavesTheQueue() async throws {
        let rig = rig("media-permanent-error")
        let entry = try id("episode-permanent")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let transport = FlakyCountingMediaTransport(rig.mac, failing: .max, with: { LibraryTransportError.transport("rejected") })
        let stages = RequestStageLog()
        let service = queuedService(rig, transport: transport, reportRequest: { _, stage, detail in stages.append(stage, detail: detail) })

        await service.handle(try request(rig, entry, from: phoneID, intentID: "permanent-1"))

        XCTAssertEqual(transport.readyAttempts, 1)
        XCTAssertEqual(stages.stages, [.sending, .failed])
        let queued = await service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testRepeatedAndConcurrentReplaysServeOnce() async throws {
        let rig = rig("media-replay-once")
        let entry = try id("episode-replay-once")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        try seedQueueFile(rig, intents: [try request(rig, entry, from: phoneID, intentID: "replay-1")])
        let transport = FlakyCountingMediaTransport(rig.mac)

        // Two replays run side by side (as start() and a second start() would), then a third.
        let runtime = makeRuntime(rig, transport: transport)
        async let first: Void = runtime.resumeQueuedRequests()
        async let second: Void = runtime.resumeQueuedRequests()
        _ = await (first, second)
        await runtime.service.drain()
        await runtime.resumeQueuedRequests()
        await runtime.service.drain()

        XCTAssertEqual(transport.readyUploads, 1, "the queue starts one upload per request, however often it is replayed")
    }

    func testARequestAlreadyQueuedIsNotQueuedTwice() async throws {
        let rig = rig("media-queue-dedupe")
        let entry = try id("episode-dedupe")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let clock = rig.clock
        let transport = FlakyCountingMediaTransport(
            rig.mac, failing: 1, with: { TransportThrottled(retryAt: clock.now.addingTimeInterval(600)) }
        )
        let waits = WaitLog()
        let service = queuedService(rig, transport: transport, sleep: { wait in
            waits.append(wait)
            try await Task.sleep(for: .seconds(3600))
        })
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "dedupe-1")
        _ = await service.enqueue(mediaRequest)
        try await eventually("throttle wait active") { waits.values.count == 1 }

        _ = await service.enqueue(mediaRequest)

        let queued = await service.uploadQueue.queuedCount
        XCTAssertEqual(queued, 1)
        await service.drainEndingThrottleWaits()
        XCTAssertEqual(transport.readyAttempts, 1, "one upload loop, however often it is handed over")
    }
}
