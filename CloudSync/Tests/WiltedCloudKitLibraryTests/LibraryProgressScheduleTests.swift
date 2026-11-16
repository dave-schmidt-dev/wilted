import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// The pure progress schedule: which pairs one sync round reads.
final class LibraryProgressScheduleTests: XCTestCase {
    private func pair(_ device: String, _ entry: String) throws -> LibraryPlaybackPair {
        LibraryPlaybackPair(deviceID: device, entryID: try item(entry))
    }

    private func schedule(_ known: Set<LibraryPlaybackPair>, hot: [String] = [], neverRead: Set<LibraryPlaybackPair> = [],
                          lastRead: [LibraryPlaybackPair: Int] = [:], slots: Int) throws -> [LibraryPlaybackPair] {
        LibraryProgressSchedule.pairs(
            known: known, ownDeviceID: "mac", hotEntryIDs: Set(try hot.map(item)), neverRead: neverRead,
            lastReadRound: lastRead, slotCount: slots)
    }

    func testOrderIsHotThenNeverReadThenLeastRecentlyRead() throws {
        let hot = try pair("phone", "ep-hot"), fresh = try pair("phone", "ep-never")
        let old = try pair("phone", "ep-old"), recent = try pair("phone", "ep-recent")
        let scheduled = try schedule([hot, fresh, old, recent], hot: ["ep-hot"], neverRead: [fresh],
                                     lastRead: [hot: 5, old: 1, recent: 5], slots: 10)
        XCTAssertEqual(scheduled, [hot, fresh, old, recent])
    }

    func testSlotsLimitOnlyThePeerPairsAndHotPairsGoInPastThem() throws {
        let hotA = try pair("phone", "ep-a"), hotB = try pair("watch", "ep-a")
        let old = try pair("phone", "ep-old"), recent = try pair("phone", "ep-recent")
        let scheduled = try schedule([hotA, hotB, old, recent], hot: ["ep-a"], lastRead: [old: 1, recent: 2], slots: 3)
        XCTAssertEqual(scheduled, [hotA, hotB, old], "one spare slot goes to the least recently read pair")
        let crowded = try schedule([hotA, hotB, old, recent], hot: ["ep-a"], lastRead: [old: 1, recent: 2], slots: 1)
        XCTAssertEqual(crowded, [hotA, hotB], "hot pairs are read even when they exceed the slots")
    }

    func testOwnPairsAreSkippedAfterTheirFirstReadEvenWhenHot() throws {
        let ownFresh = try pair("mac", "ep-own-never"), ownRead = try pair("mac", "ep-own-read")
        let peer = try pair("phone", "ep-own-read")
        let scheduled = try schedule([ownFresh, ownRead, peer], hot: ["ep-own-read"], neverRead: [ownFresh],
                                     lastRead: [ownRead: 1, peer: 1], slots: 10)
        XCTAssertEqual(Set(scheduled), [ownFresh, peer])
    }

    func testWarmUpReturnsEveryPairWhateverTheSlots() throws {
        var known: Set<LibraryPlaybackPair> = []
        for index in 1...25 {
            known.insert(try pair("mac", "ep-own-\(index)"))
            known.insert(try pair("phone", "ep-peer-\(index)"))
        }
        let scheduled = try schedule(known, neverRead: known, slots: 10)
        XCTAssertEqual(scheduled.count, 50)
        XCTAssertEqual(Set(scheduled), known)
    }

    func testEveryNonHotPeerPairIsChosenWithinCeilPOverSRounds() throws {
        let peers = 25, slots = 7
        let bound = (peers + slots - 1) / slots
        XCTAssertEqual(bound, 4)
        let known = Set(try (1...peers).map { try pair("phone", "ep-\($0)") })
        var lastRead = Dictionary(uniqueKeysWithValues: known.map { ($0, 0) })
        // Whatever round a pair was last read in, it is read again within the bound.
        for round in 1...(bound * 3) {
            for chosen in try schedule(known, lastRead: lastRead, slots: slots) { lastRead[chosen] = round }
            if round >= bound {
                let stalest = round - (lastRead.values.min() ?? 0)
                XCTAssertLessThan(stalest, bound, "round \(round): a pair waited \(stalest) rounds")
            }
        }
    }
}

// MARK: - The budget on the transport

/// 125 entries saved by both the Mac and the phone: 250 known pairs across two devices.
extension LibraryPollRequestCountTests {
    private static let budgetEntries = (1...125).map { String(format: "ep-%03d", $0) }

    private func budgetRig(
        fixture: MediaFixture? = nil, mac given: MediaFixture.Endpoint? = nil
    ) async throws -> (MediaFixture, MediaFixture.Endpoint, MediaFixture.Endpoint) {
        let fixture = try fixture ?? MediaFixture()
        let mac = try given ?? fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publish(try Self.budgetEntries.map { (try makePosition(device: "mac", entry: $0), .progress) })
        try await phone.transport.publish(try Self.budgetEntries.map { (try makePosition(device: "phone", entry: $0), .progress) })
        await mac.transport.track(devices: ["phone"], entries: try Self.budgetEntries.map(item))
        return (fixture, mac, phone)
    }

    private func progressName(_ device: String, _ entry: String) throws -> String {
        try LibraryRecordMapper().recordID(progressFor: device, entryID: item(entry)).recordName
    }

    /// Polls once and returns the result with the requests that poll made.
    private func pollRound(_ endpoint: MediaFixture.Endpoint) async throws -> (LibraryDeviceRecords, [[String]]) {
        let before = await endpoint.driver.askedNames.count
        let result = try await endpoint.transport.poll([.deviceRecords])
        let requests = Array(await endpoint.driver.askedNames.dropFirst(before))
        return (try XCTUnwrap(result.records), requests)
    }

    private func phoneProgress(_ records: LibraryDeviceRecords, _ entry: String) -> ObservedPlayback? {
        records.progress.first { $0.record.deviceID == "phone" && $0.record.entryID.rawValue == entry }
    }

    func testTwoHundredFiftyKnownPairsCostOneOperationPerIdleRoundAndAllAreReturned() async throws {
        let (_, mac, _) = try await budgetRig()
        let (warm, _) = try await pollRound(mac)  // may batch: every peer pair is read once
        XCTAssertEqual(warm.progress.count, 250)
        let before = await mac.driver.targetedFetches
        for _ in 0..<10 {
            let (records, requests) = try await pollRound(mac)
            XCTAssertEqual(records.progress.count, 250, "every known pair is in every round's records")
            XCTAssertLessThanOrEqual(requests.first?.count ?? 0, 100)
        }
        let after = await mac.driver.targetedFetches
        XCTAssertEqual(after - before, 10, "ten idle rounds, ten operations")
    }

    func testAfterReplaceDriverClearsTheCacheTheNextPollReadsEveryKnownPair() async throws {
        // The Mac's factory hands out drivers the test can still see, to count the rebuilt engine's reads.
        let fixture = try MediaFixture()
        let outbox = CloudKitLibraryOutbox(), server = fixture.server, built = BuiltDrivers()
        let first = FakeMediaDriver(server: server, outbox: outbox)
        let transport = try CloudKitLibraryTransport(
            deviceID: "mac", isLibraryWriter: true, driver: first,
            driverFactory: { _ in built.add(FakeMediaDriver(server: server, outbox: outbox)) }, outbox: outbox)
        let (_, mac, _) = try await budgetRig(
            fixture: fixture, mac: MediaFixture.Endpoint(transport: transport, driver: first, log: FactoryLog()))
        await mac.transport.track(entries: [try item("ep-none")])  // no server record: read once, found missing
        let (warm, _) = try await pollRound(mac)
        XCTAssertEqual(warm.progress.count, 250)
        let (_, idle) = try await pollRound(mac)
        XCTAssertFalse(Set(idle.joined()).contains(try progressName("mac", "ep-none")), "found missing, so not read again")
        try await mac.transport.replaceDriver(state: nil)
        let rebuilt = MediaFixture.Endpoint(transport: transport, driver: try XCTUnwrap(built.last), log: FactoryLog())
        let (records, requests) = try await pollRound(rebuilt)
        XCTAssertEqual(records.progress.count, 250)
        let asked = Set(requests.joined())
        XCTAssertTrue(asked.contains(try progressName("mac", "ep-none")), "the found-missing set is cleared with the cache")
        for entry in Self.budgetEntries {
            XCTAssertTrue(asked.contains(try progressName("mac", entry)), "own pair \(entry) is read again")
            XCTAssertTrue(asked.contains(try progressName("phone", entry)))
        }
    }

    func testAChangedPeerPositionIsReturnedWithinTheBound() async throws {
        let (_, mac, phone) = try await budgetRig()
        _ = try await pollRound(mac)
        let (_, round2) = try await pollRound(mac)
        // The worst case: a pair read in the round just finished changes right after it.
        XCTAssertTrue(try XCTUnwrap(round2.first).contains(try progressName("phone", "ep-050")))
        let changed = try DevicePlaybackPosition(
            deviceID: "phone", entryID: item("ep-050"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 777, rate: 1, isPlaying: false, epoch: 2)
        try await phone.transport.publish(changed, as: .progress)
        let bound = (125 + 98 - 1) / 98  // P = 125 peer pairs, S = 100 - 2 now-playing names
        var seen: Double?
        for _ in 0..<bound {
            let (records, _) = try await pollRound(mac)
            XCTAssertEqual(records.progress.count, 250)
            seen = phoneProgress(records, "ep-050")?.record.positionSeconds
        }
        XCTAssertEqual(seen, 777, "returned within ceil(P / S) = \(bound) rounds")
    }

    func testANowPlayingRecordsPairIsReadInThatRoundEvenWhenKnownAndNotScheduled() async throws {
        let (_, mac, phone) = try await budgetRig()
        _ = try await pollRound(mac)
        _ = try await pollRound(mac)  // reads ep-001 to ep-098; the next round reads ep-099 to ep-125 and ep-001 to ep-071
        let playing = try DevicePlaybackPosition(
            deviceID: "phone", entryID: item("ep-090"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 4_321, rate: 1, isPlaying: true, epoch: 3)
        try await phone.transport.publish([(playing, .nowPlaying), (playing, .progress)])
        let name = try progressName("phone", "ep-090")
        let (records, requests) = try await pollRound(mac)
        XCTAssertFalse(try XCTUnwrap(requests.first).contains(name), "not scheduled for this round")
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains(name), "read in the same round's second request")
        XCTAssertEqual(phoneProgress(records, "ep-090")?.record.positionSeconds, 4_321)
        let (_, next) = try await pollRound(mac)
        XCTAssertTrue(try XCTUnwrap(next.first).contains(name), "a hot pair is in every first request")
        XCTAssertEqual(next.count, 1)
    }

    func testAnOwnPublishIsReturnedFromTheCacheWithoutARead() async throws {
        let (_, mac, _) = try await budgetRig()
        _ = try await pollRound(mac)
        let own = try DevicePlaybackPosition(
            deviceID: "mac", entryID: item("ep-own"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 55, rate: 1, isPlaying: false, epoch: 2)
        try await mac.transport.publish(own, as: .progress)
        let (records, requests) = try await pollRound(mac)
        XCTAssertFalse(Set(requests.joined()).contains(try progressName("mac", "ep-own")))
        let returned = records.progress.first { $0.record.deviceID == "mac" && $0.record.entryID.rawValue == "ep-own" }
        XCTAssertEqual(returned?.record.positionSeconds, 55)
        XCTAssertEqual(records.progress.count, 251)
    }

    func testADeletedPairLeavesTheResultsOnceRead() async throws {
        let (fixture, mac, _) = try await budgetRig()
        _ = try await pollRound(mac)
        let name = try progressName("phone", "ep-010")
        await fixture.server.remove(try LibraryRecordMapper().recordID(progressFor: "phone", entryID: item("ep-010")), via: "test")
        var read = false
        for _ in 0..<2 where !read {
            let (records, requests) = try await pollRound(mac)
            read = requests.joined().contains(name)
            XCTAssertEqual(phoneProgress(records, "ep-010") == nil, read, "cached until read, gone once read")
        }
        XCTAssertTrue(read)
        let (after, _) = try await pollRound(mac)
        XCTAssertNil(phoneProgress(after, "ep-010"))
        XCTAssertEqual(after.progress.count, 249)
    }
}

/// The drivers a test's engine factory built, newest last.
private final class BuiltDrivers: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [FakeMediaDriver] = []
    var last: FakeMediaDriver? { lock.withLock { drivers.last } }
    func add(_ driver: FakeMediaDriver) -> FakeMediaDriver {
        lock.withLock { drivers.append(driver) }
        return driver
    }
}

// MARK: - A save during a read

extension LibraryPollRequestCountTests {
    /// The first read of an own pair is in flight when this device saves that pair. The older
    /// fetched copy must not replace the saved one, because own pairs are not read again.
    func testAnOwnSaveDuringTheFirstReadOfThatPairIsNotReplacedByTheFetchedCopy() async throws {
        let fixture = try MediaFixture()
        let old = try fixture.endpoint("mac", writer: true)
        try await old.transport.publish(try makePosition(device: "mac", entry: "ep-own"), as: .progress)

        let outbox = CloudKitLibraryOutbox()
        let server = fixture.server
        let gate = HeldFetchDriver(inner: FakeMediaDriver(server: fixture.server, outbox: outbox))
        let transport = try CloudKitLibraryTransport(
            deviceID: "mac", isLibraryWriter: true, driver: gate,
            driverFactory: { _ in FakeMediaDriver(server: server, outbox: outbox) }, outbox: outbox)
        await transport.track(entries: [try item("ep-own")])

        let firstPoll = Task { try await transport.poll([.deviceRecords]) }
        await gate.waitUntilHeld()
        let saved = try DevicePlaybackPosition(
            deviceID: "mac", entryID: item("ep-own"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 55, rate: 1, isPlaying: false, epoch: 2)
        try await transport.publish(saved, as: .progress)
        await gate.release()
        _ = try await firstPoll.value

        let nextResult = try await transport.poll([.deviceRecords])
        let next = try XCTUnwrap(nextResult.records)
        let own = next.progress.first { $0.record.deviceID == "mac" && $0.record.entryID.rawValue == "ep-own" }
        XCTAssertEqual(own?.record.positionSeconds, 55)
    }
}

/// Holds the first progress read until the test releases it; every other call passes through.
private actor HeldFetchDriver: CloudKitEngineDriver {
    private let inner: any CloudKitEngineDriver
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(inner: any CloudKitEngineDriver) { self.inner = inner }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    var events: AsyncStream<CloudKitEngineEvent> { get async { await inner.events } }
    func currentAccountIdentity() async throws -> CloudKitAccountIdentity? { try await inner.currentAccountIdentity() }
    func ensureZone() async throws { try await inner.ensureZone() }
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws { try await inner.ensureZone(zoneID) }
    func fetchChanges() async throws { try await inner.fetchChanges() }
    func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws { try await inner.fetchChanges(zoneIDs: zoneIDs) }
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { try await inner.fetchRecords(ids) }
    func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        let records = try await inner.fetchRecordsIfPresent(ids, desiredKeys: desiredKeys)
        if !held, ids.contains(where: { $0.recordName.contains("ep-own") }) {
            held = true
            heldWaiters.forEach { $0.resume() }
            heldWaiters = []
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        return records
    }
    func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await inner.saveRecordRaw(record, progress: progress)
    }
    func fetchAssetRecordRaw(_ id: CKRecord.ID, assetField: String, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord {
        try await inner.fetchAssetRecordRaw(id, assetField: assetField, to: destination, progress: progress)
    }
    func deleteRecordsRaw(_ ids: [CKRecord.ID]) async throws { try await inner.deleteRecordsRaw(ids) }
    func sendChanges() async throws { try await inner.sendChanges() }
    func cancelOperations() async { await inner.cancelOperations() }
    func resetZoneBootstrap() async { await inner.resetZoneBootstrap() }
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async { await inner.addPendingRecordZoneChanges(changes) }
    nonisolated func isValidStateData(_ data: Data) -> Bool { inner.isValidStateData(data) }
}
