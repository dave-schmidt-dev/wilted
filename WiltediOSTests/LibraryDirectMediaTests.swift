import CryptoKit
import Foundation
import Network
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

private enum PressureError: Error { case cloudKit(code: Int, message: String) }

/// The phone's direct path (reliable media delivery, Task 3.2): the fallback rules 1-8, the owner fence,
/// adoption against an `available` offer, partial files, the background task, and a real TLS-PSK transfer.
@MainActor
final class LibraryDirectMediaTests: XCTestCase {
    var scratch: URL!
    private var jobStoreURL: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    let entryA = try! ItemID(rawValue: "item-direct-a")
    private let entryB = try! ItemID(rawValue: "item-direct-b")
    private let revisionID = try! RevisionID(rawValue: "rev-direct-1")
    let payload = Data((0..<50_000).map { UInt8($0 % 251) })
    let owner = "direct-media-owner"
    let macKey = LANKeyAgreementKey()
    let phoneKey = LANKeyAgreementKey()
    private var store: DirectStoreWrapper!
    private var cache: FileMediaCache!
    let counter = DirectCloudCounter()
    private let locator = DirectFakeLocator()
    private let source = DirectFakeSource()
    private let scheduler = DirectFakeScheduler()
    private let sleeps = DirectSleepLog()
    private var suites: [String] = []

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("direct-media-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        jobStoreURL = scratch.appendingPathComponent("media-jobs.json")
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        var changes: [PendingLibraryChange] = []
        var entries: [LibraryEntry] = [], slots: [QueueSlot] = []
        for (index, id) in [entryA, entryB].enumerated() {
            let entry = try LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"),
                title: "Direct Episode \(index)", summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
            let slot = try QueueSlot(entryID: id, sortKey: Double(index))
            entries.append(entry); slots.append(slot)
            changes.append(PendingLibraryChange(localSeq: UInt64(index * 2 + 1), change: .entry(entry), baseVersion: 0))
            changes.append(PendingLibraryChange(localSeq: UInt64(index * 2 + 2), change: .slot(slot), baseVersion: 0))
        }
        _ = try await mac.push(changes: changes)
        var state = LibraryStoreState()
        state.ownerToken = owner
        state.content = LibrarySnapshot(entries: entries, slots: slots)
        store = DirectStoreWrapper(state)
    }

    override func tearDown() async throws {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: fixtures

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func offer(
        _ entry: ItemID? = nil, state: LibraryMediaOffer.State = .ready, data: Data? = nil, revision: RevisionID? = nil
    ) throws -> LibraryMediaOffer {
        let bytes = data ?? payload
        return try LibraryMediaOffer(
            entryID: entry ?? entryA, revisionID: revision ?? revisionID, contentHash: hash(bytes),
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 60, state: state,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
    }

    /// The Mac has uploaded `entry`'s audio, so the iCloud path can finish.
    private func macPublish(_ entry: ItemID? = nil) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        try await mac.publishMedia(offer: offer(entry), fileURL: file)
    }

    /// What the phone remembers of the Mac: its key, device id and prepared offers, as the file beside the job file.
    func seedDirect(
        key: Bool = true, offers: [LibraryMediaOffer]? = nil, owner ownerToken: String? = nil, macDeviceID: String = "mac"
    ) throws {
        let saved = try LibraryDirectSaved(
            ownerToken: ownerToken ?? owner, macKey: key ? macKey.publicKey : nil, macDeviceID: macDeviceID,
            offers: offers ?? [offer(state: .available), offer(entryB, state: .available)])
        LibraryDirectStore(url: scratch.appendingPathComponent("media-direct.json")).save(saved)
    }

    private func defaults() -> UserDefaults {
        let name = "direct-media-tests-\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        // The one-time step has been answered; `testNoBrowseRunsBeforeTheOneTimeStepIsAnswered` covers the other case.
        defaults.set(true, forKey: LibrarySettingsStore.directDownloadsOnboardingShownKey)
        return defaults
    }

    /// A model on the in-memory iCloud, with the direct path installed unless `direct` is false.
    func makeModel(
        verified: String? = nil, preferences: UserDefaults? = nil, holdingWaits latch: DirectLatch? = nil,
        phone: Bool = true, scheduler useScheduler: Bool = true, direct: Bool = true
    ) -> LibraryAppModel {
        var timing = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30))
        timing.jobStoreURL = jobStoreURL
        let log = sleeps
        timing.retrySleep = { duration in
            log.record(duration)
            if let latch { try await latch.wait() }
        }
        let inner = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: verified ?? owner)
        let model = LibraryAppModel(
            transport: DirectCountingTransport(inner: inner, counter: counter), store: store, deviceID: "phone",
            mediaCache: cache, mediaTiming: timing, preferences: preferences ?? defaults(),
            outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            timeZone: TimeZone(identifier: "UTC")!, throttleSleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        if direct {
            let key = phoneKey, source = source
            model.directState.environment = LibraryDirectEnvironment(
                locator: locator, phoneKey: { phone ? key : nil }, makeSource: { _ in source },
                scheduler: useScheduler ? scheduler : nil)
        }
        return model
    }

    /// A transport with no verified owner yet: the cold-launch state before the first iCloud answer.
    private func makeUnverifiedModel(latch: DirectLatch) -> LibraryAppModel {
        var timing = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30))
        timing.jobStoreURL = jobStoreURL
        timing.retrySleep = { _ in try await latch.wait() }
        let inner = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: nil)
        let model = LibraryAppModel(
            transport: DirectCountingTransport(inner: inner, counter: counter), store: store, deviceID: "phone",
            mediaCache: cache, mediaTiming: timing, preferences: defaults(),
            outboxURL: scratch.appendingPathComponent("pending-intents.json"), timeZone: TimeZone(identifier: "UTC")!)
        let key = phoneKey, source = source
        model.directState.environment = LibraryDirectEnvironment(
            locator: locator, phoneKey: { key }, makeSource: { _ in source }, scheduler: nil)
        return model
    }

    /// A fetch that delivers `data` as a finished, verified-looking file.
    private func delivering(_ data: Data? = nil, progressing: Int64? = nil) -> DirectFakeSource.Handler {
        let scratch = scratch!, bytes = data ?? payload
        return { _, _, progress in
            if let progressing { progress(progressing) }
            let file = scratch.appendingPathComponent("delivered-\(UUID().uuidString)")
            try bytes.write(to: file)
            progress(Int64(bytes.count))
            return file
        }
    }

    /// A fetch that leaves `bytes` of a partial file on disk and then fails with `error`.
    private func leavingPartial(_ bytes: Int, then error: LANMediaError) -> DirectFakeSource.Handler {
        let cache = cache!, payload = payload
        return { offer, _, _ in
            try Self.makePartial(cache, payload, offer, bytes: bytes)
            throw error
        }
    }

    /// A fetch that has `bytes` on disk, reports them, and waits for `latch`.
    private func partialThenWait(_ bytes: @escaping @Sendable (ItemID) -> Int, _ latch: DirectLatch) -> DirectFakeSource.Handler {
        let cache = cache!, payload = payload, scratch = scratch!
        return { offer, _, progress in
            let count = bytes(offer.entryID)
            try Self.makePartial(cache, payload, offer, bytes: count)
            progress(Int64(count))
            try await latch.wait()
            return scratch
        }
    }

    @discardableResult
    private func writePartial(_ offer: LibraryMediaOffer, bytes: Int) throws -> URL {
        try Self.makePartial(cache, payload, offer, bytes: bytes)
    }

    @discardableResult
    private nonisolated static func makePartial(_ cache: FileMediaCache, _ payload: Data, _ offer: LibraryMediaOffer, bytes: Int) throws -> URL {
        guard let directory = cache.partialDirectory(for: offer.entryID) else { throw CocoaError(.fileNoSuchFile) }
        let file = try LANPartialFile.open(in: directory, for: offer)
        defer { file.close() }
        try file.append(payload.prefix(bytes))
        return file.url
    }

    private func partialSize(_ offer: LibraryMediaOffer) -> Int64 {
        guard let directory = cache.partialDirectory(for: offer.entryID) else { return -1 }
        return LANPartialFile.resumeOffset(in: directory, for: offer)
    }

    private func partialCount(_ entry: ItemID) -> Int {
        guard let directory = cache.partialDirectory(for: entry) else { return 0 }
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func notice(_ model: LibraryAppModel, _ entry: ItemID? = nil) -> String {
        model.mediaState(for: entry ?? entryA).statusText()
    }

    func causes(_ model: LibraryAppModel) -> [LibraryDirectFallback] { model.directState.events.map(\.cause) }

    /// Runs a request where the direct path is expected to give up for `cause`, and checks the iCloud
    /// request was sent with the one cause logged. With `publish`, iCloud then finishes the download.
    func expectFallback(
        _ cause: LibraryDirectFallback, _ model: LibraryAppModel, publish: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        if publish { try await macPublish() }
        model.performMediaAction(.request, entryID: entryA)
        if publish {
            await model.waitForMedia(entryID: entryA)
            XCTAssertEqual(model.mediaState(for: entryA), .onPhone, file: file, line: line)
        } else {
            try await eventually("the iCloud request") { self.counter.requestIDs.count == 1 }
        }
        XCTAssertEqual(counter.requestIDs.count, 1, "the normal intent is sent", file: file, line: line)
        XCTAssertEqual(causes(model).last, cause, "the cause is typed and logged", file: file, line: line)
        XCTAssertEqual(causes(model).first, cause, file: file, line: line)
    }

    // MARK: fallback rule 1: the direct path is not attempted

    func testRule1SwitchOffSendsTheICloudRequestAtOnce() async throws {
        try seedDirect()
        let prefs = defaults()
        prefs.set(false, forKey: LibrarySettingsStore.directDownloadsKey)
        let model = makeModel(preferences: prefs)
        try await expectFallback(.switchOff, model)
        XCTAssertEqual(locator.calls, 0)
        XCTAssertEqual(source.fetchCount, 0)
        XCTAssertEqual(causes(model), [.switchOff])
    }

    func testNoBrowseRunsBeforeTheOneTimeStepIsAnswered() async throws {
        try seedDirect()
        let prefs = defaults()
        prefs.removeObject(forKey: LibrarySettingsStore.directDownloadsOnboardingShownKey)
        let model = makeModel(preferences: prefs)
        try await expectFallback(.switchOff, model)
        XCTAssertEqual(locator.calls, 0, "no local-network browse before the step")
        XCTAssertEqual(source.fetchCount, 0)
    }

    func testRule1NoMacKeySendsTheICloudRequest() async throws {
        try seedDirect(key: false)
        try await expectFallback(.noMacKey, makeModel())
        XCTAssertEqual(locator.calls, 0)
    }

    func testRule1NoCachedOfferSendsTheICloudRequest() async throws {
        try seedDirect(offers: [])
        try await expectFallback(.noOffer, makeModel())
        XCTAssertEqual(locator.calls, 0)
    }

    func testRule1AnOfferThatIsNotPreparedSendsTheICloudRequest() async throws {
        try seedDirect(offers: [LibraryMediaOffer.notReady(entryID: entryA)])
        try await expectFallback(.offerNotPrepared, makeModel())
        XCTAssertEqual(locator.calls, 0)
    }

    func testRule1AHashlessOfferSendsTheICloudRequest() async throws {
        let hashless = try LibraryMediaOffer(
            entryID: entryA, revisionID: revisionID, contentHash: "", byteCount: 50_000, mediaType: "audio/mp4", state: .available)
        try seedDirect(offers: [hashless])
        try await expectFallback(.hashlessOffer, makeModel())
        XCTAssertEqual(locator.calls, 0)
        XCTAssertEqual(source.fetchCount, 0)
    }

    func testRule1AMissingPhoneKeySendsTheICloudRequest() async throws {
        try seedDirect()
        try await expectFallback(.noPhoneKey, makeModel(phone: false))
        XCTAssertEqual(locator.calls, 0)
    }

    func testRule1LocalNetworkDeniedSendsTheICloudRequestAndIsNotAskedAgainUntilTheAppReturns() async throws {
        try seedDirect()
        locator.set(.denied)
        let model = makeModel()
        try await expectFallback(.localNetworkDenied, model)
        XCTAssertTrue(model.directState.localNetworkDenied)

        try await macPublish(entryB)
        model.performMediaAction(.request, entryID: entryB)
        await model.waitForMedia(entryID: entryB)
        XCTAssertEqual(locator.calls, 1, "the second download does not browse again")
        XCTAssertEqual(causes(model), [.localNetworkDenied, .localNetworkDenied])
    }

    // MARK: fallback rule 1a: the owner is not verified for this launch

    func testRule1AColdLaunchWithAnUnverifiedOwnerSkipsTheDirectPathSaysWhyAndReadsTheOffersBackAfterRelaunch() async throws {
        try seedDirect()
        let latch = DirectLatch()
        let cold = makeUnverifiedModel(latch: latch)
        cold.performMediaAction(.request, entryID: entryA)
        try await eventually("the owner wait") { self.notice(cold).hasPrefix("Confirming your iCloud account") }
        XCTAssertTrue(notice(cold).hasPrefix("Confirming your iCloud account, trying again at "), notice(cold))
        XCTAssertTrue(cold.mediaState(for: entryA).isInFlight, "Cancel stays available while it waits")
        XCTAssertEqual(source.fetchCount, 0, "nothing direct starts for an unverified owner")
        XCTAssertEqual(locator.calls, 0)
        XCTAssertEqual(counter.serverCalls, 0, "and nothing goes to iCloud either")
        XCTAssertEqual(causes(cold), [.ownerUnverified])

        // The relaunch: the job and the offers come back from their files, and the verified owner goes direct.
        cold.mediaRuns[entryA]?.task?.cancel()
        latch.release()
        source.set(delivering())
        let relaunched = makeModel()
        await relaunched.loadLocalState()
        XCTAssertEqual(relaunched.directSaved(owner: owner)?.offers.map(\.entryID), [entryA, entryB], "offers are read back")
        await relaunched.waitForMedia(entryID: entryA)
        XCTAssertEqual(relaunched.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(source.fetchCount, 1)
        XCTAssertEqual(counter.requestIDs, [], "a direct success asks iCloud for nothing")
    }

    // MARK: fallback rule 2: no Mac, or no handshake

    func testRule2NoMacFoundInTheBrowseBudgetSendsTheICloudRequest() async throws {
        try seedDirect()
        locator.set(.none)
        let model = makeModel()
        try await expectFallback(.macNotFound, model, publish: false)
        XCTAssertEqual(source.fetchCount, 0)
        let ids = counter.requestIDs
        XCTAssertEqual(ids.count, 1)
        let job = try XCTUnwrap(LibraryMediaJobStore(url: jobStoreURL).loadJobs().first { $0.entryID == entryA })
        XCTAssertEqual(job.intentID, ids[0], "the fallback request carries the job's own intent id")
        model.performMediaAction(.cancel, entryID: entryA)
    }

    func testRule2AFailedHandshakeSendsTheICloudRequest() async throws {
        try seedDirect()
        source.set { _, _, _ in throw LANMediaError.handshakeFailed }
        try await expectFallback(.handshakeFailed, makeModel())
        XCTAssertEqual(source.fetchCount, 1)
    }

    // MARK: fallback rule 3: the Mac cannot serve this file

    func testRule3NotReadySendsTheICloudRequest() async throws { try await expectRule3(.notReady, .macNotReady) }
    func testRule3DifferentSendsTheICloudRequest() async throws { try await expectRule3(.different, .macDifferent) }
    func testRule3RefusedSendsTheICloudRequest() async throws { try await expectRule3(.refused, .macRefused) }

    private func expectRule3(_ error: LANMediaError, _ cause: LibraryDirectFallback) async throws {
        try seedDirect()
        source.set { _, _, _ in throw error }
        let model = makeModel()
        try await expectFallback(cause, model)
        XCTAssertEqual(causes(model), [cause])
        XCTAssertEqual(source.fetchCount, 1, "no retry")
    }

    // MARK: fallback rule 4: busy, one retry

    func testRule4ABusyMacIsRetriedOnceAfterTwoSecondsAndThenServesTheFile() async throws {
        try seedDirect()
        let tries = DirectCounter()
        let good = delivering()
        source.set { offer, offset, progress in
            if tries.next() == 1 { throw LANMediaError.busy }
            return try await good(offer, offset, progress)
        }
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(source.fetchCount, 2)
        XCTAssertEqual(sleeps.values, [.seconds(2)], "one retry after two seconds")
        XCTAssertEqual(causes(model), [.macBusy])
        XCTAssertEqual(counter.requestIDs, [], "the retry succeeded, so iCloud heard nothing")
    }

    func testRule4ABusyMacTwiceSendsTheICloudRequest() async throws {
        try seedDirect()
        source.set { _, _, _ in throw LANMediaError.busy }
        let model = makeModel()
        try await expectFallback(.macBusy, model)
        XCTAssertEqual(source.fetchCount, 2, "one try and one retry")
        XCTAssertEqual(sleeps.values.first, .seconds(2))
    }

    // MARK: fallback rule 5: dropped twice, partial kept

    func testRule5ADropTwiceSendsTheICloudRequestAndKeepsThePartial() async throws {
        try seedDirect()
        let target = try offer(state: .available)
        source.set(leavingPartial(20_000, then: .connectionDropped(receivedBytes: 20_000)))
        let model = makeModel()
        try await expectFallback(.connectionDropped, model, publish: false)
        XCTAssertEqual(partialSize(target), 20_000, "the partial survives for a later try")
        model.performMediaAction(.cancel, entryID: entryA)
    }

    // MARK: fallback rule 6: a mismatch is never adopted

    func testRule6AMismatchedFileNeverResolvesAndSendsTheICloudRequest() async throws {
        try seedDirect()
        source.set(delivering(Data(payload.reversed()))) // same size, other bytes
        let model = makeModel()
        try await expectFallback(.mismatch, model, publish: false)
        let cached = await cache.cachedEntries()
        XCTAssertNil(cached[entryA], "the wrong bytes are not in the cache")
        XCTAssertNotEqual(model.mediaState(for: entryA), .onPhone)
        let token = model.commandState.token
        let playable = await model.verifiedCachedMedia(entryA, token: token)
        XCTAssertNil(playable, "and nothing plays")
        model.performMediaAction(.cancel, entryID: entryA)
    }

    func testRule6ATruncatedFileIsNotAdoptedEither() async throws {
        try seedDirect()
        source.set(delivering(Data(payload.prefix(49_000))))
        let model = makeModel()
        try await expectFallback(.mismatch, model, publish: false)
        let cached = await cache.cachedEntries()
        XCTAssertNil(cached[entryA])
        model.performMediaAction(.cancel, entryID: entryA)
    }

    // MARK: fallback rule 7: a direct success asks iCloud for nothing

    func testRule7ADirectSuccessSendsNoIntentAndQueuesOnlyTheAcknowledgement() async throws {
        try seedDirect()
        source.set(delivering())
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(counter.serverCalls, 0, "no iCloud call at all")
        XCTAssertTrue(causes(model).isEmpty)
        let ack = try XCTUnwrap(model.unacknowledgedMedia[entryA], "the acknowledgement waits for the next round")
        XCTAssertEqual(ack.action, .mediaCached(entryID: entryA, revisionID: revisionID, deviceID: "phone"))
        let onMac = try await mac.listIntents()
        XCTAssertTrue(onMac.isEmpty)
        XCTAssertNil(try LibraryMediaJobStore(url: jobStoreURL).loadJobs().first, "the job is done")
    }

    // MARK: M3 test 2: the gate is closed and the transport throws

    func testAClosedGateAndAThrowingTransportStillDownloadDirectly() async throws {
        try seedDirect()
        source.set(delivering())
        let model = makeModel()
        do {
            try await model.throttleGate.run {
                throw PressureError.cloudKit(code: 7, message: "Request was rate limited. Retry after 600 seconds")
            } as Void
        } catch {}
        let closure = await model.throttleGate.state
        XCTAssertNotNil(closure, "the gate is closed")
        counter.failEverything = true

        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)

        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(counter.serverCalls, 0, "zero CloudKit calls")
        XCTAssertEqual(counter.requestIDs, [])
        let still = await model.throttleGate.state
        XCTAssertNotNil(still, "and the gate was never probed")
    }

    // MARK: M3 test 2a / DS-2: plays while the offer stays available

    func testADirectFileInAnAvailableOfferPlaysAndStaysValidWhenTheOfferTurnsReady() async throws {
        try seedDirect()
        source.set(delivering())
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)

        let played = await model.verifiedCachedMedia(entryA, token: model.commandState.token)
        XCTAssertNotNil(played, "the proof stores the available offer and the file plays")
        XCTAssertEqual(played?.preparation?.offer.state, .available)

        // The Mac finishes uploading: the same revision, hash and size now read `ready`.
        let ready = try offer()
        let maybeContext = await model.mediaContext(live: true)
        let context = try XCTUnwrap(maybeContext)
        let applied = await model.applyMediaOffers([ready], context: context)
        XCTAssertTrue(applied)
        let after = await model.verifiedCachedMedia(entryA, token: model.commandState.token)
        XCTAssertNotNil(after, "the file is still the offer's file")
        await model.refreshMediaFromCache()
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
    }

    func testTheCacheMatchesAFileByPreparedIdentityNotByStateOrStructEquality() throws {
        let available = try offer(state: .available), ready = try offer()
        XCTAssertNotEqual(available, ready)
        XCTAssertTrue(FileMediaCache.samePreparedFile(available, ready))
        XCTAssertFalse(FileMediaCache.samePreparedFile(available, try offer(data: Data(payload.reversed()))), "another hash")
        XCTAssertFalse(FileMediaCache.samePreparedFile(available, try offer(revision: RevisionID(rawValue: "rev-2"))))
        XCTAssertFalse(FileMediaCache.samePreparedFile(available, try offer(entryB)))
        XCTAssertFalse(FileMediaCache.samePreparedFile(available, try offer(data: Data(payload.prefix(49_999)))), "another size")
    }

    // MARK: partial files

    func testAPartialIsCountedInTheStoredAudioTotal() async throws {
        let target = try offer(state: .available)
        try await cache.bindOwner(ownerToken: owner, libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        try writePartial(target, bytes: 12_345)
        let counts = await cache.storedAudioByteCounts()
        XCTAssertEqual(counts[entryA], 12_345)
    }

    func testAPartialSurvivesACacheRefreshAndIsNeverMistakenForAnEntry() async throws {
        let target = try offer(state: .available)
        try await cache.bindOwner(ownerToken: owner, libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        try writePartial(target, bytes: 4_321)
        let model = makeModel()
        await model.loadLocalState()
        await model.refreshMediaFromCache()
        let reclaimed = await cache.reclaimUnplayableAudio(keeping: [])
        XCTAssertTrue(reclaimed.isEmpty)
        XCTAssertEqual(partialSize(target), 4_321, "the routine refresh and reclaim leave it alone")
        let counts = await cache.storedAudioByteCounts()
        XCTAssertEqual(counts, [entryA: 4_321], "counted once, under its own entry, with no stray key")
        let entries = await cache.cachedEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testAPartialIsRemovedWhenPreparationIsRevokedTheAccountChangesOrTheIdentityChanges() async throws {
        let target = try offer(state: .available)
        let scope = LibraryAppModel.mediaLibraryScope
        try await cache.bindOwner(ownerToken: owner, libraryScope: scope, held: false)

        try writePartial(target, bytes: 100)
        try await cache.revokePreparation(entryID: entryA)
        XCTAssertEqual(partialCount(entryA), 0, "revoked")

        try writePartial(target, bytes: 100)
        try await cache.bindOwner(ownerToken: "another-account", libraryScope: scope, held: false)
        XCTAssertEqual(partialCount(entryA), 0, "account change")

        // A new revision of the entry: the old revision's partial can never finish.
        let current = try offer(state: .available, revision: RevisionID(rawValue: "rev-2"))
        let old = target
        try writePartial(old, bytes: 100)
        try writePartial(current, bytes: 200)
        let model = makeModel()
        await model.discardStalePartials(for: [current])
        XCTAssertEqual(partialSize(old), 0, "the old revision's partial is gone")
        XCTAssertEqual(partialSize(current), 200, "the offered revision's partial is kept to resume")
        await model.discardStalePartials(for: [LibraryMediaOffer.notReady(entryID: entryA)])
        XCTAssertEqual(partialCount(entryA), 0, "a not-ready entry keeps none")
    }

    func testAPartialIsRemovedWhenICloudCompletesTheSameEntry() async throws {
        try seedDirect()
        let target = try offer(state: .available)
        try await cache.bindOwner(ownerToken: owner, libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        try writePartial(target, bytes: 30_000)
        locator.set(.none)
        try await macPublish()
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(counter.requestIDs.count, 1, "iCloud delivered it")
        XCTAssertEqual(partialCount(entryA), 0, "so the partial has no use left (DS-5)")
    }

    func testPartialsOlderThanSevenDaysAreDeletedAndNewerOnesStay() async throws {
        let target = try offer(state: .available), other = try offer(entryB, state: .available)
        try await cache.bindOwner(ownerToken: owner, libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let stale = try writePartial(target, bytes: 100)
        try writePartial(other, bytes: 100)
        let eightDays = Date().addingTimeInterval(-8 * 24 * 3_600)
        try FileManager.default.setAttributes([.modificationDate: eightDays], ofItemAtPath: stale.path)
        await cache.purgePartials(olderThan: Date().addingTimeInterval(-FileMediaCache.partialLifetime))
        XCTAssertEqual(partialCount(entryA), 0)
        XCTAssertEqual(partialSize(other), 100)
        XCTAssertEqual(FileMediaCache.partialLifetime, 7 * 24 * 3_600)
    }

    // MARK: row text

    func testTheRowSaysWhatItIsWaitingOnAndTheCancelControlIsLabelledForVoiceOver() async throws {
        try seedDirect()
        let browsing = DirectLatch()
        locator.hold = browsing
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        try await eventually("looking for the Mac") { self.notice(model).hasPrefix("Looking for your Mac…") }
        XCTAssertEqual(model.mediaState(for: entryA).cancelLabel, "Cancel download from your Mac")

        source.set(partialThenWait({ _ in 20_000 }, DirectLatch()))
        browsing.release()
        try await eventually("downloading") {
            if case .downloadingFromMac = model.mediaState(for: self.entryA) { return true }
            return false
        }
        XCTAssertTrue(notice(model).hasPrefix("Downloading from your Mac · "), notice(model))
        XCTAssertTrue(model.mediaState(for: entryA).isInFlight)
        XCTAssertEqual(model.mediaState(for: entryA).fraction ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(model.mediaState(for: entryA).cancelLabel, "Cancel download from your Mac")
        XCTAssertEqual(LibraryMediaState.downloading(bytes: 1, total: 2, since: Date()).cancelLabel, "Cancel download")
        model.performMediaAction(.cancel, entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .available)
    }

    // MARK: M3 test 5: the background task

    func testTheBackgroundTaskIsSubmittedOnceJoinedByASecondDownloadAndReportsBytesAcrossBothJobs() async throws {
        try seedDirect()
        let hold = DirectLatch()
        let a = entryA
        source.set(partialThenWait({ $0 == a ? 20_000 : 10_000 }, hold))
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        try await eventually("the first job running") { self.source.fetchCount == 1 }
        XCTAssertEqual(scheduler.submissions, 1)
        model.performMediaAction(.request, entryID: entryB)
        try await eventually("the second job running") { self.source.fetchCount == 2 }
        XCTAssertEqual(scheduler.submissions, 1, "the second Get audio joins the running task")
        XCTAssertEqual(scheduler.titles, ["Downloading from your Mac"])

        let task = DirectFakeTask()
        scheduler.begin(task)
        try await eventually("combined progress") { task.progress.completed == 30_000 }
        XCTAssertEqual(task.progress.total, 100_000, "bytes over the total of both queued jobs")
        XCTAssertEqual(task.subtitle, "2 episodes")

        model.performMediaAction(.cancel, entryID: entryA)
        model.performMediaAction(.cancel, entryID: entryB)
    }

    func testWhenTheSystemEndsTheTaskTheDownloadsPauseKeepTheirPartialsAndResumeInTheForeground() async throws {
        try seedDirect()
        let hold = DirectLatch()
        let a = entryA
        source.set(partialThenWait({ $0 == a ? 20_000 : 10_000 }, hold))
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        model.performMediaAction(.request, entryID: entryB)
        try await eventually("both running") { self.source.fetchCount == 2 }
        let task = DirectFakeTask()
        scheduler.begin(task)
        try await eventually("task progress") { task.progress.completed == 30_000 }

        task.expirationHandler?()
        XCTAssertEqual(task.completion, false, "the system's task ends as failed")
        for entry in [entryA, entryB] {
            XCTAssertEqual(notice(model, entry), "Paused. Open Wilted to continue.")
            XCTAssertTrue(model.mediaState(for: entry).isInFlight, "Cancel stays")
        }
        XCTAssertEqual(partialSize(try offer(state: .available)), 20_000, "expiry keeps the partial")
        XCTAssertEqual(partialSize(try offer(entryB, state: .available)), 10_000)
        XCTAssertEqual(counter.requestIDs, [], "pausing sends nothing to iCloud")

        // Back in front: both resume from where their partials ended.
        source.set(delivering())
        await model.sceneBecameActive()
        await model.waitForMedia(entryID: entryA)
        await model.waitForMedia(entryID: entryB)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(model.mediaState(for: entryB), .onPhone)
        let resumed = Dictionary(uniqueKeysWithValues: source.fetches.suffix(2).map { ($0.entry, $0.offset) })
        XCTAssertEqual(resumed, [entryA: 20_000, entryB: 10_000])
        XCTAssertEqual(counter.requestIDs, [])
    }

    func testCancellingADirectDownloadKeepsItsPartial() async throws {
        try seedDirect()
        let hold = DirectLatch()
        source.set(partialThenWait({ _ in 15_000 }, hold))
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        try await eventually("downloading") { self.source.fetchCount == 1 && self.partialCount(self.entryA) == 1 }
        let task = DirectFakeTask()
        scheduler.begin(task)
        model.performMediaAction(.cancel, entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .available)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(partialSize(try offer(state: .available)), 15_000, "Cancel keeps the bytes")
        XCTAssertEqual(counter.requestIDs, [])
        XCTAssertEqual(task.completion, true, "no direct job is left, so the task ends")
    }

    func testARefusedBackgroundRequestStillDownloadsInTheForeground() async throws {
        try seedDirect()
        scheduler.refuse = true
        source.set(delivering())
        let model = makeModel()
        model.performMediaAction(.request, entryID: entryA)
        await model.waitForMedia(entryID: entryA)
        XCTAssertEqual(model.mediaState(for: entryA), .onPhone)
        XCTAssertEqual(scheduler.submissions, 0)
    }
}

private actor DirectStoreWrapper: LibraryStore {
    private var saved: LibraryStoreState

    init(_ state: LibraryStoreState) { saved = state }

    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
    func quarantine() { saved.reviewHold = true; saved.revision += 1 }
}
