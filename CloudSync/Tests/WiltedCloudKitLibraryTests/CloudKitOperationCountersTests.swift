import CloudKit
import os
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// Tests per-operation CloudKit counters, results, throttling and privacy guarantees.
final class CloudKitOperationCountersTests: XCTestCase {

    private actor StubDriver: CloudKitEngineDriver {
        nonisolated let stream: AsyncStream<CloudKitEngineEvent>
        private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
        var throttleError: Error?
        var fetchReturnRecords: [CKRecord] = []

        init() {
            (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        }

        var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }

        func setThrottleError(_ error: Error?) {
            throttleError = error
        }

        func setFetchReturnRecords(_ records: [CKRecord]) {
            fetchReturnRecords = records
        }

        func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
            if let throttleError {
                throw throttleError
            }
            return fetchReturnRecords
        }

        func cancelOperations() async {}
        func fetchChanges() async throws { continuation.yield(.fetchCompleted) }
        func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws { continuation.yield(.fetchCompleted) }
        func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
        nonisolated func isValidStateData(_ data: Data) -> Bool { true }
        func sendChanges() async throws { continuation.yield(.sendCompleted) }
        func ensureZone(_ zoneID: CKRecordZone.ID) async throws {}
        func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws {}
        func fetchAssetRecordRaw(
            _ id: CKRecord.ID, assetField: String, to destination: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> CKRecord {
            throw CloudKitSyncError.assetUnavailable(id.recordName)
        }
    }

    func testOperationCountAndResultPerCallAndThrottledRetryAfter() async throws {
        let stub = StubDriver()
        let counters = CloudKitOperationCounters(startLoggingTask: false)
        let driver = CountingEngineDriver(inner: stub, counters: counters)
        let ids = [CKRecord.ID(recordName: "x", zoneID: LibraryRecordMapper().zoneID)]
        func fetch() async -> Error? {
            do {
                _ = try await CloudKitOperationContext.$caller.withValue(.poll) {
                    try await driver.fetchRecordsIfPresent(ids, desiredKeys: nil)
                }
                return nil
            } catch { return error }
        }

        // 1. Successful call: result is .ok
        let first = await fetch()
        XCTAssertNil(first)
        var summary = counters.summary()
        XCTAssertEqual(summary.totalRequests, 1)
        XCTAssertEqual(summary.count(for: .poll), 1)
        XCTAssertEqual(summary.count(for: .poll, result: .ok), 1)
        XCTAssertNil(summary.lastThrottleRetryAfter)

        // 2. Throttled call with Retry-After: result is .throttled(retryAfter:)
        await stub.setThrottleError(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 45.0)]))
        let throttled = await fetch()
        XCTAssertNotNil(throttled)
        summary = counters.summary()
        XCTAssertEqual(summary.totalRequests, 2)
        XCTAssertEqual(summary.count(for: .poll), 2)
        XCTAssertEqual(summary.count(for: .poll, result: .throttled(retryAfter: 45.0)), 1)
        XCTAssertEqual(summary.lastThrottleRetryAfter, 45.0)

        // 3. Other error: result is .other
        await stub.setThrottleError(CKError(.networkFailure))
        let other = await fetch()
        XCTAssertNotNil(other)
        summary = counters.summary()
        XCTAssertEqual(summary.totalRequests, 3)
        XCTAssertEqual(summary.count(for: .poll, result: .other), 1)
    }

    func testSummaryContainsNoRecordNamesTokensOrIdentifiers() async throws {
        let fixture = try MediaFixture()
        let recognisableRecordName = "record-secret-ident-xyz-98765"
        let recognisableToken = "token-secret-auth-abc-54321"
        let recognisableDevice = "device-secret-phone-67890"
        let recognisableAccount = "account-secret-user-12345"

        let outbox = CloudKitLibraryOutbox()
        let driver = FakeMediaDriver(server: fixture.server, outbox: outbox)
        let counters = CloudKitOperationCounters(startLoggingTask: false)

        let transport = try CloudKitLibraryTransport(
            deviceID: recognisableDevice,
            isLibraryWriter: true,
            driver: driver,
            driverFactory: { [server = fixture.server] _ in FakeMediaDriver(server: server, outbox: outbox) },
            outbox: outbox,
            knownOwnerToken: recognisableToken,
            mapper: fixture.mapper,
            counters: counters
        )

        // Seed a record with the recognisable record name
        let zoneID = fixture.mapper.zoneID
        let secretRecord = CKRecord(recordType: "LibraryRecord", recordID: CKRecord.ID(recordName: recognisableRecordName, zoneID: zoneID))
        secretRecord[LibraryRecordMapper.payloadField] = Data("secret-content".utf8)
        await fixture.server.putRaw(secretRecord)

        // Perform some operations
        _ = try await transport.poll([.intents, .deviceRecords])
        try await transport.publish(try makePosition(device: recognisableDevice, entry: "ep-1"), as: .nowPlaying)
        try await transport.publishStats(LibraryStats())

        let summary = await transport.operationSummary()
        let description = summary.description
        let summaryString = summary.summaryString()

        // Assert that neither description nor summaryString leak any of the identifiable strings
        for text in [description, summaryString] {
            XCTAssertFalse(text.contains(recognisableRecordName), "summary must not leak record name")
            XCTAssertFalse(text.contains(recognisableToken), "summary must not leak token")
            XCTAssertFalse(text.contains(recognisableDevice), "summary must not leak device ID")
            XCTAssertFalse(text.contains(recognisableAccount), "summary must not leak account ID")
        }
    }

    func testCountersTrackOperationsByCaller() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)

        // Handoff (publish playback)
        try await phone.transport.publish(try makePosition(device: "phone", entry: "ep-1"), as: .nowPlaying)
        let phoneSummary = await phone.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(phoneSummary.count(for: .handoff), 1)

        // Poll
        _ = try await mac.transport.poll([.intents, .deviceRecords])
        let macSummary1 = await mac.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(macSummary1.count(for: .poll), 1)

        // Stats
        try await mac.transport.publishStats(LibraryStats())
        _ = try await mac.transport.readStats()
        let macSummary2 = await mac.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(macSummary2.count(for: .stats), 2)

        // Bulletins
        try await mac.transport.publishBulletins(
            try LibraryBulletins(alertsEnabled: true, headlinesEnabled: false, headlines: [], updatedAt: Date()))
        _ = try await mac.transport.fetchBulletins()
        let macSummary3 = await mac.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(macSummary3.count(for: .bulletins), 2)

        // DeviceLink
        _ = try await phone.transport.fetchDeviceDirectory()
        let phoneSummary2 = await phone.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(phoneSummary2.count(for: .deviceLink), 1)

        // Publication
        let pub = try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: "mac")
        try await mac.transport.publishPublication(pub)
        _ = try await mac.transport.readPublication()
        let macSummary4 = await mac.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(macSummary4.count(for: .publication), 2)

        // Scan
        _ = try await mac.transport.discoverPeers()
        let macSummary5 = await mac.transport.operationSummary()
        XCTAssertGreaterThanOrEqual(macSummary5.count(for: .scan), 1)
    }

    func testFiveMinuteSummaryWindowAndTotalsSinceLaunch() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let elapsed = OSAllocatedUnfairLock(initialState: TimeInterval(0))
        let counters = CloudKitOperationCounters(
            clock: { start.addingTimeInterval(elapsed.withLock { $0 }) },
            logInterval: 300,
            startLoggingTask: false
        )

        // Record 3 operations at t = 0
        counters.record(caller: .poll, recordCount: 1, bytes: 100, result: .ok)
        counters.record(caller: .handoff, recordCount: 2, bytes: 200, result: .ok)
        counters.record(caller: .stats, recordCount: 1, bytes: 50, result: .throttled(retryAfter: 30))

        let t0Summary = counters.summary()
        XCTAssertEqual(t0Summary.totalRequests, 3)
        XCTAssertEqual(t0Summary.recentRequests, 3)
        XCTAssertEqual(t0Summary.lastThrottleRetryAfter, 30)

        // Advance time by 6 minutes (360 seconds)
        elapsed.withLock { $0 = 360 }

        // Record 1 operation at t = 6m
        counters.record(caller: .poll, recordCount: 1, bytes: 150, result: .ok)

        let t6Summary = counters.summary()
        XCTAssertEqual(t6Summary.totalRequests, 4, "total requests since launch includes all 4")
        XCTAssertEqual(t6Summary.recentRequests, 1, "recent requests in last 5m includes only the new one")
        XCTAssertEqual(t6Summary.recentCount(for: .poll), 1)
        XCTAssertEqual(t6Summary.recentCount(for: .handoff), 0)
        XCTAssertEqual(t6Summary.count(for: .handoff), 1, "totals since launch still track handoff")
    }

    func testSummaryAttributesOperationBytesEngineChangesAndRebuildReasons() {
        let counters = CloudKitOperationCounters(startLoggingTask: false)
        counters.record(caller: .poll, operation: .fetchRecordsIfPresent, recordCount: 2, bytes: 30, result: .ok)
        counters.record(caller: .poll, operation: .fetchChanges, recordCount: 0, bytes: 0,
                        result: .throttled(retryAfter: 30))
        counters.record(caller: .stats, operation: .fetchChanges, recordCount: 0, bytes: 0,
                        result: .throttled(retryAfter: 10))
        counters.recordEngineFetch(caller: .poll, metrics: CloudKitEngineFetchMetrics(
            receivedRecords: 3, receivedBytes: 90, decodedRecords: 2, decodedBytes: 50,
            receivedDeletions: 1, mappedDeletions: 1))
        counters.recordEngineRebuild(.tokenMismatch)
        counters.recordEngineRebuild(.recovery)
        counters.recordNamedReads(caller: .poll, metrics: [
            CloudKitNamedReadMetrics(recordType: .progress, freshness: .unchanged, records: 1, bytes: 10),
            CloudKitNamedReadMetrics(recordType: .nowPlaying, freshness: .changed, records: 1, bytes: 20),
        ])

        let summary = counters.summary().summaryString()
        XCTAssertTrue(summary.contains("poll.fetchRecordsIfPresent: 1 reqs (2 records, 30 B)"), summary)
        XCTAssertTrue(summary.contains("last 5m engine changes: [poll: received 3 records/90 B, mapped 2/50 B, deletions 1/1]"), summary)
        XCTAssertTrue(summary.contains("recovery: 1, tokenMismatch: 1"), summary)
        XCTAssertTrue(summary.contains("last 5m throttles: [poll: 1, stats: 1]"), summary)
        XCTAssertTrue(summary.contains("poll.ProgressRecord.unchanged: 1 records/10 B"), summary)
        XCTAssertTrue(summary.contains("poll.NowPlayingRecord.changed: 1 records/20 B"), summary)
    }

    func testPollProgressReadsDistinguishActiveHotAndInactivePairsWithoutNames() async throws {
        let fixture = try MediaFixture()
        let counters = CloudKitOperationCounters(startLoggingTask: false)
        let mac = try fixture.endpoint("mac", writer: true, counters: counters)
        let phone = try fixture.endpoint("phone", writer: false)
        let active = try DevicePlaybackPosition(deviceID: "phone", entryID: item("ep-secret"),
                                                revision: RevisionID(rawValue: "rev-1"), positionSeconds: 10,
                                                isPlaying: true, epoch: 1)
        let paused = try DevicePlaybackPosition(deviceID: "phone", entryID: item("ep-secret"),
                                                revision: RevisionID(rawValue: "rev-1"), positionSeconds: 10,
                                                isPlaying: false, epoch: 1)
        try await phone.transport.publish(active, as: .nowPlaying)
        try await phone.transport.publish(paused, as: .progress)
        await mac.transport.track(devices: ["phone"])

        _ = try await mac.transport.poll([.deviceRecords])
        var summary = await mac.transport.operationSummary().summaryString()
        XCTAssertTrue(summary.contains("poll.active.firstSeen: 1 records/"), summary)
        XCTAssertFalse(summary.contains("ep-secret"), "progress attribution must not expose entry IDs")

        _ = try await mac.transport.poll([.deviceRecords])
        summary = await mac.transport.operationSummary().summaryString()
        XCTAssertTrue(summary.contains("poll.active.unchanged: 1 records/"), summary)

        try await phone.transport.publish(paused, as: .nowPlaying)
        _ = try await mac.transport.poll([.deviceRecords])
        summary = await mac.transport.operationSummary().summaryString()
        XCTAssertTrue(summary.contains("poll.hot.unchanged: 1 records/"), summary)

        await fixture.server.remove(try fixture.mapper.recordID(nowPlayingFor: "phone"), via: "test")
        _ = try await mac.transport.poll([.deviceRecords])
        summary = await mac.transport.operationSummary().summaryString()
        XCTAssertTrue(summary.contains("poll.inactive.unchanged: 1 records/"), summary)
        XCTAssertFalse(summary.contains("phone"), "progress attribution must not expose device IDs")
    }

    func testNamedReadMetricsClassifyFirstSeenUnchangedAndChangedWithoutRecordNames() async throws {
        let fixture = try MediaFixture()
        let counters = CloudKitOperationCounters(startLoggingTask: false)
        let endpoint = try fixture.endpoint("mac", writer: true, counters: counters)
        let mapper = fixture.mapper
        let directory = LibraryDeviceDirectory()
        let id = mapper.deviceDirectoryRecordID
        _ = await fixture.server.putEngine(try mapper.record(deviceDirectory: directory))

        _ = try await endpoint.transport.poll([.deviceDirectory])
        _ = try await endpoint.transport.poll([.deviceDirectory])
        _ = await fixture.server.putEngine(try mapper.record(deviceDirectory: directory))
        _ = try await endpoint.transport.poll([.deviceDirectory])

        let summary = await endpoint.transport.operationSummary().summaryString()
        XCTAssertTrue(summary.contains("poll.LibraryDeviceDirectoryRecord.firstSeen: 1 records/"), summary)
        XCTAssertTrue(summary.contains("poll.LibraryDeviceDirectoryRecord.unchanged: 1 records/"), summary)
        XCTAssertTrue(summary.contains("poll.LibraryDeviceDirectoryRecord.changed: 1 records/"), summary)
        XCTAssertFalse(summary.contains(id.recordName), "read summaries must not expose record names")
    }

    func testRecordingPastTheLogIntervalLogsWithoutDeadlockAndKeepsOnlyTheRecentWindow() {
        let base = Date(timeIntervalSince1970: 1_000)
        let counters = CloudKitOperationCounters(clock: { base }, logInterval: 10, startLoggingTask: false)
        for second in 0..<100 {
            counters.record(caller: .poll, recordCount: 1, bytes: 10, result: .ok,
                            timestamp: base.addingTimeInterval(TimeInterval(second)))
        }
        let summary = counters.summary(now: base.addingTimeInterval(99))
        XCTAssertEqual(summary.totalRequests, 100)
        XCTAssertEqual(summary.count(for: .poll, result: .ok), 100)
        XCTAssertEqual(summary.recent.count, 11, "only the last 10 s of records are kept")
    }

    func testTheArchiveKeepsALaunchLineAndEverySummaryAndRotatesWhenFull() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Logs/cloudkit-operations.log")
        let base = Date(timeIntervalSince1970: 1_000)
        let counters = CloudKitOperationCounters(clock: { base }, startLoggingTask: false,
                                                 archive: CloudKitOperationArchive(url: file, maxBytes: 600))
        counters.record(caller: .poll, recordCount: 3, bytes: 90, result: .ok)
        counters.logNoticeSummary()

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" launch"))
        XCTAssertTrue(lines[1].contains("since launch: 1 reqs (3 records, 90 B)"), String(lines[1]))

        for _ in 0..<3 { counters.logNoticeSummary() }
        let backup = file.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "a full file moves to .1")
        XCTAssertLessThan(try Data(contentsOf: file).count, 600)
    }
}
