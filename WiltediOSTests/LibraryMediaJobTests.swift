import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A latch a test opens to release a wait or a download. Waiting polls, so cancelling the waiting task
/// ends the wait the way a real sleep or fetch would.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    private var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func wait() async throws {
        while !isOpen {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// What a test makes the phone's transport do, and what it saw.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var sendErrors: [any Error] = []
    private var fetchErrors: [any Error] = []
    private var sentIDs: [String] = []
    private var fetches = 0
    private var held: Latch?

    func failSends(_ errors: [any Error]) { lock.lock(); sendErrors = errors; lock.unlock() }
    func failFetches(_ errors: [any Error]) { lock.lock(); fetchErrors = errors; lock.unlock() }
    func holdFetches(_ latch: Latch?) { lock.lock(); held = latch; lock.unlock() }
    var requestIDs: [String] { lock.lock(); defer { lock.unlock() }; return sentIDs }
    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return fetches }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sentIDs.count }

    func nextSend(_ intent: LibraryIntent) -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        guard case .requestMedia = intent.action else { return nil }
        sentIDs.append(intent.id)
        return sendErrors.isEmpty ? nil : sendErrors.removeFirst()
    }

    func nextFetch() -> (error: (any Error)?, hold: Latch?) {
        lock.lock(); defer { lock.unlock() }
        fetches += 1
        return (fetchErrors.isEmpty ? nil : fetchErrors.removeFirst(), held)
    }
}

private struct ScriptedTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let script: Script

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
        if let error = script.nextSend(intent) { throw error }
        try await inner.send(intent: intent)
    }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        let next = script.nextFetch()
        if let hold = next.hold { try await hold.wait() }
        if let error = next.error { throw error }
        return try await inner.fetchMedia(offer, progress: progress)
    }
}

private actor JobStoreWrapper: LibraryStore {
    private var saved: LibraryStoreState

    init(_ state: LibraryStoreState) { saved = state }

    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
    func quarantine() { saved.reviewHold = true; saved.revision += 1 }
}

/// Durable phone media jobs: a passing cause keeps a request pending with its time and its intent id,
/// across relaunch, and only a terminal cause ends it.
@MainActor
final class LibraryMediaJobTests: XCTestCase {
    private var scratch: URL!
    private var jobStoreURL: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let entryID = try! ItemID(rawValue: "item-job-a")
    private let revisionID = try! RevisionID(rawValue: "rev-job-1")
    private let payload = Data((0..<50_000).map { UInt8($0 % 251) })
    private let owner = "media-job-owner"
    private let offline = URLError(.notConnectedToInternet)
    private var store: JobStoreWrapper!
    private var cache: FileMediaCache!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("media-jobs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        jobStoreURL = scratch.appendingPathComponent("media-jobs.json")
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let entry = try makeEntry()
        let slot = try QueueSlot(entryID: entryID, sortKey: 0)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(slot), baseVersion: 0),
        ])
        var state = LibraryStoreState()
        state.ownerToken = owner
        state.content = LibrarySnapshot(entries: [entry], slots: [slot])
        store = JobStoreWrapper(state)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: fixtures

    private func makeEntry() throws -> LibraryEntry {
        try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"),
            title: "Job Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeOffer(hashOf other: Data? = nil) throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(other ?? payload),
            byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 60,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
    }

    private func macPublish(_ offer: LibraryMediaOffer) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        try await mac.publishMedia(offer: offer, fileURL: file)
    }

    private func makeModel(script: Script = Script(), timing: LibraryMediaTiming? = nil) -> LibraryAppModel {
        var tm = timing ?? LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30))
        tm.jobStoreURL = jobStoreURL
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        return LibraryAppModel(
            transport: ScriptedTransport(inner: phone, script: script), store: store, deviceID: "phone", mediaCache: cache,
            mediaTiming: tm, outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    /// Timing whose waits cost no time and are recorded, unless a latch holds them.
    private func timing(sleeps: SleepLog, holding latch: Latch? = nil, offerTimeout: Duration = .seconds(5)) -> LibraryMediaTiming {
        var tm = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: offerTimeout, watchdog: .seconds(30))
        tm.retrySleep = { duration in
            sleeps.record(duration)
            if let latch { try await latch.wait() }
        }
        return tm
    }

    private var reader: LibraryMediaJobStore { LibraryMediaJobStore(url: jobStoreURL) }

    private func savedJob() -> LibraryMediaJob? { reader.loadJobs().first { $0.entryID == entryID } }

    private func requestIDs() async throws -> [String] {
        try await mac.listIntents().filter { if case .requestMedia = $0.action { true } else { false } }.map(\.id)
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func notice(_ model: LibraryAppModel) -> String { model.mediaState(for: entryID).statusText() }

    // MARK: durability

    func testAJobSurvivesRelaunchAndKeepsItsIntentID() async throws {
        try await macPublish(makeOffer())
        let hold = Latch()
        let script = Script()
        script.holdFetches(hold)
        let first = makeModel(script: script)
        first.performMediaAction(.request, entryID: entryID)
        try await eventually("downloading") {
            if case .downloading = first.mediaState(for: self.entryID) { return true }
            return false
        }
        let saved = try XCTUnwrap(savedJob())
        XCTAssertEqual(saved.stage, .downloading)

        // The app dies mid-download: its task ends but nobody pressed Cancel, so the job stays.
        let run = try XCTUnwrap(first.mediaRuns[entryID]?.task)
        run.cancel()
        await run.value
        XCTAssertEqual(savedJob()?.intentID, saved.intentID, "an interrupted run leaves its job in the file")

        let second = makeModel()
        await second.loadLocalState()
        XCTAssertTrue(second.mediaState(for: entryID).isInFlight, "the relaunch resumes the job at once")
        await second.waitForMedia(entryID: entryID)

        XCTAssertEqual(second.mediaState(for: entryID), .onPhone)
        XCTAssertNil(savedJob(), "a finished job leaves the file")
        let ids = try await requestIDs()
        XCTAssertEqual(ids, [saved.intentID], "one request with the id it was made with, not sent again")
    }

    func testARelaunchRestoresOnceAndLaterReadsDoNotStartASecondRun() async throws {
        try await macPublish(makeOffer())
        let hold = Latch()
        let script = Script()
        script.holdFetches(hold)
        reader.saveJob(LibraryMediaJob(entryID: entryID, intentID: "kept-id", createdAt: Date()), ownerToken: owner)
        let model = makeModel(script: script)
        await model.loadLocalState()
        let first = model.mediaRuns[entryID]?.id
        XCTAssertNotNil(first)
        await model.loadLocalState()
        await model.refreshMediaFromCache()
        XCTAssertEqual(model.mediaRuns[entryID]?.id, first, "the job file is read again without a second run")
        model.performMediaAction(.cancel, entryID: entryID)
        hold.release()
    }

    func testAJobFromAnotherAccountIsDroppedAtRestore() async throws {
        reader.saveJob(LibraryMediaJob(entryID: entryID, intentID: "old-account", createdAt: Date()), ownerToken: "someone-else")
        let model = makeModel()
        await model.loadLocalState()
        XCTAssertNil(model.mediaRuns[entryID])
        XCTAssertNil(savedJob())
    }

    // MARK: passing causes

    func testAThirtyMinuteThrottleEndsCachedNotFailedAndTheRowNamesTheRetryTime() async throws {
        try await macPublish(makeOffer())
        let retryAt = Date().addingTimeInterval(1_800)
        let script = Script()
        script.failFetches([TransportThrottled(retryAt: retryAt)])
        let latch = Latch()
        let sleeps = SleepLog()
        let model = makeModel(script: script, timing: timing(sleeps: sleeps, holding: latch))
        model.performMediaAction(.request, entryID: entryID)

        try await eventually("the throttle is kept in the job") { self.savedJob()?.nextAttempt != nil }
        let due = try XCTUnwrap(savedJob()?.nextAttempt)
        XCTAssertEqual(due.timeIntervalSince1970, retryAt.timeIntervalSince1970, accuracy: 1)
        let status = notice(model)
        XCTAssertEqual(status, "Waiting for iCloud, retrying at \(model.clockFormat.clock(due))")
        XCTAssertTrue(model.mediaState(for: entryID).isInFlight, "Cancel stays available while it waits")

        latch.release()
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, 1, "one request for the whole wait")
        XCTAssertEqual((sleeps.values.max() ?? .zero) > .seconds(1_700), true, "it slept until iCloud's time")
    }

    func testATransientSendFailurePastTheOldCapsStillEndsCached() async throws {
        try await macPublish(makeOffer())
        let script = Script()
        script.failSends(Array(repeating: offline, count: 7)) // the old cap was 3 retries
        let sleeps = SleepLog()
        let model = makeModel(script: script, timing: timing(sleeps: sleeps))
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.sendCount, 8)
        XCTAssertEqual(Set(script.requestIDs).count, 1, "every try carries the same intent id")
        let waits = sleeps.values.map { Int($0.components.seconds) }
        XCTAssertEqual(waits.count, 7)
        let cap = Int(SyncCadence.backoffCap)
        XCTAssertTrue(waits.suffix(2).allSatisfy { $0 >= cap - 2 && $0 <= cap }, "the backoff is capped at \(cap) s: \(waits)")
        XCTAssertTrue(waits.first.map { $0 <= 10 } ?? false, "and starts short: \(waits)")
        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, 1)
    }

    func testATransientSendFailureShowsTheRetryTimeAndCancelStopsTheTries() async throws {
        let script = Script()
        script.failSends(Array(repeating: offline, count: 100))
        let latch = Latch()
        let model = makeModel(script: script, timing: timing(sleeps: SleepLog(), holding: latch))
        model.performMediaAction(.request, entryID: entryID)

        try await eventually("a wait with a time") { self.savedJob()?.nextAttempt != nil }
        let due = try XCTUnwrap(savedJob()?.nextAttempt)
        XCTAssertEqual(notice(model), "Waiting for iCloud, retrying at \(model.clockFormat.clock(due))")
        let sent = script.sendCount

        model.performMediaAction(.cancel, entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        XCTAssertNil(savedJob())
        latch.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(script.sendCount, sent, "cancel sends nothing more")
        XCTAssertNil(model.mediaRuns[entryID])
        XCTAssertEqual(model.mediaState(for: entryID), .available)
    }

    func testATransientDownloadFailureRetriesAndEndsCached() async throws {
        try await macPublish(makeOffer())
        let script = Script()
        script.failFetches(Array(repeating: offline, count: 4)) // three quick tries, then the job's wait
        let sleeps = SleepLog()
        let model = makeModel(script: script, timing: timing(sleeps: sleeps))
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.fetchCount, 5)
        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, 1, "the download restarts; the request is not sent again")
    }

    func testAMacThatIsNotAnsweringKeepsWaitingAndEndsCachedWhenItAnswers() async throws {
        let latch = Latch()
        var tm = timing(sleeps: SleepLog(), holding: latch, offerTimeout: .milliseconds(60))
        tm.macRecheckDelay = .seconds(300)
        let model = makeModel(timing: tm)
        model.performMediaAction(.request, entryID: entryID)

        try await eventually("the wait for the Mac") { self.savedJob()?.nextAttempt != nil }
        let job = try XCTUnwrap(savedJob())
        let due = try XCTUnwrap(job.nextAttempt)
        XCTAssertTrue(job.waitsOnMac)
        XCTAssertEqual(notice(model), "Waiting for the Mac, checking again at \(model.clockFormat.clock(due))")
        XCTAssertTrue(model.mediaState(for: entryID).isInFlight, "it is not a failure, and Cancel stays")

        try await macPublish(makeOffer())
        latch.release()
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        let ids = try await requestIDs()
        XCTAssertEqual(ids, [job.intentID], "the same request the whole time")
    }

    // MARK: terminal causes

    func testTheSameVerificationMismatchTwiceEndsFailedAfterOneImmediateRetry() async throws {
        try await macPublish(makeOffer(hashOf: Data([1, 2, 3])))
        let script = Script()
        let sleeps = SleepLog()
        let model = makeModel(script: script, timing: timing(sleeps: sleeps))
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        guard case let .failed(reason) = model.mediaState(for: entryID) else { return XCTFail("expected failed") }
        XCTAssertEqual(reason, "The file did not match the Mac's copy.")
        XCTAssertEqual(script.fetchCount, 2, "one retry at once, then the same mismatch ends it")
        XCTAssertTrue(sleeps.values.isEmpty, "the retry did not wait")
        XCTAssertNil(savedJob())
        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, 1)
    }

    // MARK: cancel, quarantine, reissue

    func testCancelSendsNothingMoreAndAStaleRunCannotTouchTheNextJob() async throws {
        try await macPublish(makeOffer())
        let hold = Latch()
        let script = Script()
        script.holdFetches(hold)
        let model = makeModel(script: script)
        model.performMediaAction(.request, entryID: entryID)
        try await eventually("downloading") {
            if case .downloading = model.mediaState(for: self.entryID) { return true }
            return false
        }
        let before = try await requestIDs()
        model.performMediaAction(.cancel, entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .available)
        XCTAssertNil(savedJob())

        script.holdFetches(nil)
        model.performMediaAction(.request, entryID: entryID)
        let second = try XCTUnwrap(savedJob())
        hold.release()
        try await Task.sleep(for: .milliseconds(50))
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, before.count + 1, "only the new request was sent")
        XCTAssertTrue(ids.contains(second.intentID))
    }

    func testQuarantineDropsTheJob() async throws {
        try await macPublish(makeOffer())
        let hold = Latch()
        let script = Script()
        script.holdFetches(hold)
        let model = makeModel(script: script)
        model.performMediaAction(.request, entryID: entryID)
        try await eventually("job saved") { self.savedJob() != nil }

        await store.quarantine()
        await model.loadLocalState()
        XCTAssertTrue(model.accountQuarantined)
        XCTAssertNil(savedJob(), "quarantine drops the job")
        XCTAssertNil(model.mediaRuns[entryID], "and stops its run")
        XCTAssertFalse(model.mediaState(for: entryID).isInFlight)
        hold.release()
    }

    func testRevokingAnEntrysPreparationDropsItsJob() async throws {
        try await macPublish(makeOffer())
        let hold = Latch()
        let script = Script()
        script.holdFetches(hold)
        let model = makeModel(script: script)
        model.performMediaAction(.request, entryID: entryID)
        try await eventually("job saved") { self.savedJob() != nil }

        let found = await model.mediaContext(live: true)
        let context = try XCTUnwrap(found)
        let revoked = await model.revokeMediaPreparation(entryID, context: context)
        XCTAssertTrue(revoked)
        XCTAssertNil(savedJob(), "revocation drops the job")
        XCTAssertNil(model.mediaRuns[entryID], "and stops its run")
        XCTAssertEqual(model.mediaState(for: entryID), .notPrepared)
        hold.release()
    }

    func testAnOfflineRelaunchKeepsTheJobAndAnUnreadableFileIsNeverOverwritten() throws {
        let job = LibraryMediaJob(entryID: entryID, intentID: "kept", createdAt: Date())
        reader.saveJob(job, ownerToken: owner)
        let before = try Data(contentsOf: jobStoreURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: jobStoreURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobStoreURL.path) }
        guard !FileManager.default.isReadableFile(atPath: jobStoreURL.path) else { return } // running as an owner that can read anyway
        reader.saveJob(LibraryMediaJob(entryID: entryID, intentID: "other", createdAt: Date()), ownerToken: owner)
        reader.removeAll(ownerToken: owner)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobStoreURL.path)
        XCTAssertEqual(try Data(contentsOf: jobStoreURL), before, "a file that could not be read was not saved over")
    }

    func testASixDayOldIntentIsReissuedOnceUnderANewID() async throws {
        try await macPublish(makeOffer())
        var job = LibraryMediaJob(entryID: entryID, intentID: "old-intent", createdAt: Date().addingTimeInterval(-6 * 86_400 - 3_600))
        job.requestSent = true // it was sent, six days ago
        reader.saveJob(job, ownerToken: owner)

        let model = makeModel()
        await model.loadLocalState()
        await model.waitForMedia(entryID: entryID)

        let ids = try await requestIDs()
        XCTAssertEqual(ids.count, 1, "re-issued once")
        XCTAssertNotEqual(ids.first, "old-intent")
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testAFiveDayOldIntentIsKept() async throws {
        try await macPublish(makeOffer())
        reader.saveJob(
            LibraryMediaJob(entryID: entryID, intentID: "five-days", createdAt: Date().addingTimeInterval(-5 * 86_400)),
            ownerToken: owner)
        let model = makeModel()
        await model.loadLocalState()
        await model.waitForMedia(entryID: entryID)
        let ids = try await requestIDs()
        XCTAssertEqual(ids, ["five-days"])
    }
}

/// The durations a test's retry sleep was asked for.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    func record(_ duration: Duration) { lock.lock(); recorded.append(duration); lock.unlock() }
    var values: [Duration] { lock.lock(); defer { lock.unlock() }; return recorded }
}
