import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// V14 measured lifetime events: typed units, exact-key deduplication,
/// separate high-water and summary entities, and the rebuild.
final class LocalLibraryLifetimeEventTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeStoreURL() throws -> URL {
        let directory = OwnedTestTemp.root
            .appendingPathComponent("wilted-lifetime-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func time(_ kind: LifetimeMeasureKind, _ seconds: Double) throws -> LifetimeMeasureAmount {
        try XCTUnwrap(LifetimeMeasureAmount.time(kind, seconds: seconds))
    }

    private func bytes(_ count: Int64) throws -> LifetimeMeasureAmount {
        try XCTUnwrap(LifetimeMeasureAmount.bytes(.receivedBytes, count: count))
    }

    /// A store whose ledger holds rows but whose summary was never built --
    /// the state every migrated V13 store opens in.
    private func migratedFixtureStore() throws -> (LocalLibraryStore, URL) {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/library-v13.store")
        let url = try makeStoreURL()
        try FileManager.default.copyItem(at: fixture, to: url)
        return (try LocalLibraryStore(url: url), url)
    }

    func testUnitsAreTypedPerKindAndDerivedForDisplay() throws {
        XCTAssertNil(LifetimeMeasureAmount.time(.receivedBytes, seconds: 1), "bytes cannot be recorded as time")
        XCTAssertNil(LifetimeMeasureAmount.bytes(.playedTime, count: 1), "time cannot be recorded as bytes")
        XCTAssertNil(LifetimeMeasureAmount.time(.playedTime, seconds: -1))
        XCTAssertNil(LifetimeMeasureAmount.time(.playedTime, seconds: .nan))
        XCTAssertNil(LifetimeMeasureAmount.time(.manuallySkippedTime, seconds: .infinity))
        XCTAssertNil(LifetimeMeasureAmount.bytes(.receivedBytes, count: -1))
        XCTAssertEqual(try time(.playedTime, 1.2345).baseUnits, 1_235)
        XCTAssertEqual(try time(.playedTime, 1.5).seconds, 1.5)
        XCTAssertNil(try time(.playedTime, 1.5).byteCount)
        XCTAssertEqual(try bytes(7).byteCount, 7)
        XCTAssertNil(try bytes(7).seconds)
        XCTAssertEqual(LifetimeMeasureKind.playedTime.unit, .milliseconds)
        XCTAssertEqual(LifetimeMeasureKind.manuallySkippedTime.unit, .milliseconds)
        XCTAssertEqual(LifetimeMeasureKind.receivedBytes.unit, .bytes)

        var totals = LifetimeMeasuredTotals(playedMilliseconds: 90_000, receivedBytes: 2_500_000_000,
                                            manuallySkippedMilliseconds: 30_000)
        XCTAssertEqual(totals.playedMinutes, 1.5)
        XCTAssertEqual(totals.manuallySkippedMinutes, 0.5)
        XCTAssertEqual(totals.receivedDecimalGigabytes, 2.5)
        totals.receivedBytes = .max - 1
        totals.add(try bytes(10))
        XCTAssertEqual(totals.receivedBytes, .max, "a total saturates rather than trapping")
    }

    func testFreshStoreStartsReadyWithDurableTrackingStart() async throws {
        let url = try makeStoreURL()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try LocalLibraryStore(url: url, migrate: true, hooks: LocalLibraryOpenHooks(now: { started }))
        let summary = try await first.lifetimeStatisticsSummary()
        XCTAssertEqual(summary, LifetimeStatisticsSummary(state: .ready, trackingStartedAt: started,
                                                          updatedAt: summary.updatedAt))

        let later = Date(timeIntervalSince1970: 1_900_000_000)
        let reopened = try LocalLibraryStore(url: url, migrate: true, hooks: LocalLibraryOpenHooks(now: { later }))
        let reopenedSummary = try await reopened.lifetimeStatisticsSummary()
        XCTAssertEqual(reopenedSummary.trackingStartedAt, started, "the tracking start is written once")
        _ = try await reopened.rebuildLifetimeStatisticsSummary()
        let rebuiltSummary = try await reopened.lifetimeStatisticsSummary()
        XCTAssertEqual(rebuiltSummary.trackingStartedAt, started, "a rebuild never moves the tracking start")
    }

    func testExactKeyDeduplicationKeepsEventsImmutable() async throws {
        let url = try makeStoreURL()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let store = try LocalLibraryStore(url: url)
            let first = try await store.recordLifetimeMeasure(id: "skip|1", try time(.manuallySkippedTime, 30), at: at)
            let duplicate = try await store.recordLifetimeMeasure(id: "skip|1", try time(.manuallySkippedTime, 99), at: at)
            let zero = try await store.recordLifetimeMeasure(id: "skip|2", try time(.manuallySkippedTime, 0), at: at)
            XCTAssertTrue(first)
            XCTAssertFalse(duplicate, "a repeated ID with a different amount changes nothing")
            XCTAssertFalse(zero)
            let exists = try await store.lifetimeMeasureEventExists(id: "skip|1")
            XCTAssertTrue(exists)
        }
        let relaunched = try LocalLibraryStore(url: url)
        let relaunchedDuplicate = try await relaunched.recordLifetimeMeasure(
            id: "skip|1", try time(.manuallySkippedTime, 30), at: at
        )
        XCTAssertFalse(relaunchedDuplicate)
        let summary = try await relaunched.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.manuallySkippedMilliseconds, 30_000)
        let rebuilt = try await relaunched.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuilt.measured.manuallySkippedMilliseconds, 30_000, "the stored row kept its first amount")
    }

    func testCheckpointHighWaterAdmitsOnlyNewlyCrossedAmounts() async throws {
        let url = try makeStoreURL()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let store = try LocalLibraryStore(url: url)
            let first = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 10), ownerKey: "session-a", at: at)
            let repeated = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 10), ownerKey: "session-a", at: at)
            let lower = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 4), ownerKey: "session-a", at: at)
            let advanced = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 25), ownerKey: "session-a", at: at)
            let otherOwner = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 5), ownerKey: "session-b", at: at)
            let download = try await store.recordLifetimeMeasureCheckpoint(try bytes(4_096), ownerKey: "attempt-1", at: at)
            XCTAssertEqual(first, try time(.playedTime, 10))
            XCTAssertNil(repeated)
            XCTAssertNil(lower)
            XCTAssertEqual(advanced, try time(.playedTime, 15))
            XCTAssertEqual(otherOwner, try time(.playedTime, 5))
            XCTAssertEqual(download, try bytes(4_096))
            let mark = try await store.lifetimeMeasureHighWater(kind: .playedTime, ownerKey: "session-a")
            XCTAssertEqual(mark, try time(.playedTime, 25))
            let unrelated = try await store.lifetimeMeasureHighWater(kind: .receivedBytes, ownerKey: "session-a")
            XCTAssertNil(unrelated, "high-water keys are per kind and owner")
        }
        let relaunched = try LocalLibraryStore(url: url)
        let replay = try await relaunched.recordLifetimeMeasureCheckpoint(try time(.playedTime, 25), ownerKey: "session-a", at: at)
        XCTAssertNil(replay, "a relaunch replaying its last checkpoint adds nothing")
        let summary = try await relaunched.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured, LifetimeMeasuredTotals(playedMilliseconds: 30_000, receivedBytes: 4_096))
    }

    func testLegacyTotalsShareTheSummaryAndStayCorrectBeforeRebuild() async throws {
        let (store, _) = try migratedFixtureStore()
        let pending = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(pending.state, .rebuildRequired)
        // The legacy API keeps answering from the ledger until the rebuild.
        let beforeRebuild = try await store.lifetimeStatistics()
        XCTAssertEqual(beforeRebuild, LifetimeStatistics(audioProcessedSeconds: 12.5))
        _ = try await store.recordLifetimeStatistic(id: "pre-rebuild|speech", kind: .speechGenerated, seconds: 3)
        _ = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 8), ownerKey: "s", at: Date())

        let rebuilt = try await store.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuilt.legacy, LifetimeStatistics(audioProcessedSeconds: 12.5, speechGeneratedSeconds: 3))
        XCTAssertEqual(rebuilt.measured, LifetimeMeasuredTotals(playedMilliseconds: 8_000))

        _ = try await store.recordLifetimeStatistic(id: "post-rebuild|ad", kind: .confirmedAdTimeRemoved, seconds: 4)
        let incremental = try await store.lifetimeStatisticsSummary()
        let legacyAPI = try await store.lifetimeStatistics()
        XCTAssertEqual(incremental.legacy.confirmedAdTimeRemovedSeconds, 4, "writers update a ready summary atomically")
        XCTAssertEqual(legacyAPI, incremental.legacy)
        let rebuiltAgain = try await store.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuiltAgain.legacy, incremental.legacy)
        XCTAssertEqual(rebuiltAgain.measured, incremental.measured)
    }

    func testRebuildReportsProgressAndCancellationLeavesSummaryUntouched() async throws {
        let (store, _) = try migratedFixtureStore()
        for index in 0..<12 {
            _ = try await store.recordLifetimeMeasure(id: "played|\(index)", try time(.playedTime, 1), at: Date())
        }
        let cancelled = Task { () -> Int in
            let calls = ProgressLog()
            do {
                _ = try await store.rebuildLifetimeStatisticsSummary(batchSize: 3) { report in
                    calls.append(report)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("a cancelled rebuild must throw")
            } catch is CancellationError {
            } catch {
                XCTFail("unexpected error \(error)")
            }
            return calls.reports.count
        }
        let reportsBeforeCancel = await cancelled.value
        XCTAssertEqual(reportsBeforeCancel, 1, "cancellation is honoured at the next page boundary")
        let afterCancel = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(afterCancel.state, .rebuildRequired, "a cancelled rebuild publishes nothing")

        let log = ProgressLog()
        let rebuilt = try await store.rebuildLifetimeStatisticsSummary(batchSize: 5) { log.append($0) }
        let reports = log.reports
        XCTAssertEqual(rebuilt.measured.playedMilliseconds, 12_000)
        XCTAssertEqual(reports.first?.phase, .measuredLedger)
        XCTAssertEqual(reports.last, LifetimeStatisticsRebuildProgress(phase: .published, processedEvents: 13, totalEvents: 13))
        XCTAssertEqual(reports.map(\.processedEvents), reports.map(\.processedEvents).sorted(), "progress is monotonic")
        XCTAssertTrue(reports.contains { $0.phase == .legacyLedger })
    }

    func testOnlyOneRebuildRunsAtATime() async throws {
        let (store, _) = try migratedFixtureStore()
        for index in 0..<20 {
            _ = try await store.recordLifetimeMeasure(id: "bytes|\(index)", try bytes(1), at: Date())
        }
        let first = Task { try await store.rebuildLifetimeStatisticsSummary(batchSize: 1) }
        let second = Task { try await store.rebuildLifetimeStatisticsSummary(batchSize: 1) }
        var refused = 0
        var published: [LifetimeStatisticsSummary] = []
        for result in [await first.result, await second.result] {
            switch result {
            case .success(let summary): published.append(summary)
            case .failure(let error):
                XCTAssertEqual(error as? LocalLibraryStoreError, .statisticsRebuildInProgress)
                refused += 1
            }
        }
        XCTAssertEqual(published.count + refused, 2)
        XCTAssertGreaterThanOrEqual(published.count, 1)
        XCTAssertTrue(published.allSatisfy { $0.measured.receivedBytes == 20 })
    }

    func testConcurrentLargeLedgerKeepsExactKeyCostsFlatAndTotalsExact() async throws {
        let url = try makeStoreURL()
        let store = try LocalLibraryStore(url: url)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func fetches(_ operation: () async throws -> Void) async throws -> Int {
            let before = await store.lifetimeStatisticsFetchCount
            try await operation()
            return await store.lifetimeStatisticsFetchCount - before
        }
        _ = try await store.recordLifetimeMeasure(id: "warm", try bytes(1), at: at)
        let smallCheckpoint = try await fetches {
            _ = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 1), ownerKey: "probe-small", at: at)
        }
        let smallRead = try await fetches { _ = try await store.lifetimeStatisticsSummary() }

        for index in 0..<2_000 {
            _ = try await store.recordLifetimeMeasure(id: "bulk|\(index)", try bytes(1), at: at)
        }
        let largeCheckpoint = try await fetches {
            _ = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 1), ownerKey: "probe-large", at: at)
        }
        let largeRead = try await fetches { _ = try await store.lifetimeStatisticsSummary() }
        XCTAssertEqual(largeCheckpoint, smallCheckpoint, "a checkpoint's cost does not grow with the ledger")
        XCTAssertLessThanOrEqual(largeCheckpoint, 3, "high-water, greatest sequence and summary, each by index")
        XCTAssertEqual(largeRead, smallRead)
        XCTAssertEqual(largeRead, 2, "a summary read is one summary row and one tracking row")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    for step in 1...25 {
                        let cumulative = try XCTUnwrap(LifetimeMeasureAmount.bytes(.receivedBytes, count: Int64(step * 100)))
                        _ = try await store.recordLifetimeMeasureCheckpoint(cumulative, ownerKey: "writer-\(writer)", at: at)
                        // A replayed checkpoint from the same attempt adds nothing.
                        _ = try await store.recordLifetimeMeasureCheckpoint(cumulative, ownerKey: "writer-\(writer)", at: at)
                    }
                }
            }
            group.addTask {
                for _ in 0..<25 {
                    let summary = try await store.lifetimeStatisticsSummary()
                    XCTAssertEqual(summary.state, .ready)
                }
            }
            group.addTask { _ = try await store.rebuildLifetimeStatisticsSummary(batchSize: 64) }
            try await group.waitForAll()
        }

        let expected = LifetimeMeasuredTotals(playedMilliseconds: 2_000, receivedBytes: 1 + 2_000 + 4 * 2_500)
        let live = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(live.measured, expected)
        let rebuilt = try await store.rebuildLifetimeStatisticsSummary(batchSize: 256)
        XCTAssertEqual(rebuilt.measured, expected, "the incremental summary matches the ledger exactly")

        let indexes = try Self.indexSQL(at: url, table: "ZLIFETIMEMEASUREEVENTRECORD")
            + Self.indexSQL(at: url, table: "ZLIFETIMEMEASUREHIGHWATERRECORD")
        for column in ["ZID", "ZSEQUENCE", "ZKEY"] {
            XCTAssertTrue(indexes.contains(column), "exact-key column \(column) must be indexed: \(indexes)")
        }
    }

    func testWritesCommittedDuringARebuildAreCountedExactlyOnce() async throws {
        let (store, _) = try migratedFixtureStore()
        for index in 0..<50 {
            _ = try await store.recordLifetimeMeasure(id: "played|\(index)", try time(.playedTime, 1), at: Date())
        }
        let (firstPage, signal) = AsyncStream<Void>.makeStream()
        let log = ProgressLog()
        let rebuild = Task {
            try await store.rebuildLifetimeStatisticsSummary(batchSize: 1) { report in
                log.append(report)
                signal.yield()
            }
        }
        for await _ in firstPage { break }
        // The rebuild is paused between pages; these commit behind its cursor.
        _ = try await store.recordLifetimeMeasureCheckpoint(try time(.playedTime, 7), ownerKey: "during", at: Date())
        _ = try await store.recordLifetimeStatistic(id: "during|speech", kind: .speechGenerated, seconds: 2)
        let published = try await rebuild.value
        signal.finish()

        XCTAssertEqual(log.reports.last?.phase, .published)
        XCTAssertEqual(log.reports.last?.processedEvents, 53, "the rebuild read the rows committed while it ran")
        XCTAssertEqual(log.reports.last?.totalEvents, 51)
        XCTAssertEqual(published.measured.playedMilliseconds, 57_000)
        XCTAssertEqual(published.legacy, LifetimeStatistics(audioProcessedSeconds: 12.5, speechGeneratedSeconds: 2))
    }

    func testTwoStoreInstancesNeverOverwriteEachOthersEvents() async throws {
        let url = try makeStoreURL()
        let first = try LocalLibraryStore(url: url)
        let second = try LocalLibraryStore(url: url)
        let at = Date()
        _ = try await first.recordLifetimeMeasure(id: "a|1", try bytes(1), at: at)
        _ = try await second.recordLifetimeMeasure(id: "b|1", try bytes(10), at: at)
        _ = try await first.recordLifetimeMeasure(id: "a|2", try bytes(100), at: at)
        for id in ["a|1", "b|1", "a|2"] {
            let exists = try await second.lifetimeMeasureEventExists(id: id)
            XCTAssertTrue(exists, "event \(id) must survive")
        }
        let rebuilt = try await second.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuilt.measured.receivedBytes, 111)
    }

    private static func indexSQL(at url: URL, table: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", url.path,
                             "SELECT group_concat(sql, ' ') FROM sqlite_master WHERE type='index' AND tbl_name='\(table)';"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Collects rebuild progress reports from the store's executor.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LifetimeStatisticsRebuildProgress] = []

    func append(_ report: LifetimeStatisticsRebuildProgress) { lock.withLock { storage.append(report) } }
    var reports: [LifetimeStatisticsRebuildProgress] { lock.withLock { storage } }
}

extension LocalLibraryLifetimeEventTests {
    /// The byte meter behind `PodcastDownloadCoordinator`: a periodic write at
    /// most once per second, only when something new arrived, and a terminal
    /// amount that a failed write keeps covering.
    func testDownloadByteMeterWritesAtMostOncePerSecondAndKeepsFailedAmounts() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let episodeID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        var meter = PodcastDownloadByteMeter(episodeID: episodeID, startedAt: start)
        XCTAssertTrue(meter.ownerKey.hasPrefix("download|\(episodeID.rawValue)|"))
        XCTAssertNil(meter.pendingAmount, "nothing received, nothing to write")
        meter.receive(100)
        XCTAssertNil(meter.takeDueCheckpoint(at: start.addingTimeInterval(0.9)))
        let first = try XCTUnwrap(meter.takeDueCheckpoint(at: start.addingTimeInterval(1)))
        XCTAssertEqual(first, try bytes(100))
        meter.didPersist(first)
        meter.receive(50)
        XCTAssertNil(meter.takeDueCheckpoint(at: start.addingTimeInterval(1.5)), "under a second since the last write")
        let second = try XCTUnwrap(meter.takeDueCheckpoint(at: start.addingTimeInterval(2)))
        XCTAssertEqual(second, try bytes(150), "checkpoints are cumulative per attempt")
        // That write failed: the terminal amount still covers its bytes.
        meter.receive(1)
        XCTAssertEqual(meter.pendingAmount, try bytes(151))
        meter.didPersist(try bytes(151))
        XCTAssertNil(meter.pendingAmount)
        XCTAssertNil(meter.takeDueCheckpoint(at: start.addingTimeInterval(10)), "nothing new, no write")
        meter.receive(0)
        XCTAssertNil(meter.pendingAmount)
    }

    /// Two download attempts for one episode never share a high-water mark.
    func testDownloadAttemptsOwnSeparateHighWaterMarks() async throws {
        let store = try LocalLibraryStore(url: try makeStoreURL())
        let episodeID = try ItemID(rawValue: "item-" + String(repeating: "8", count: 64))
        let now = Date()
        for _ in 0..<2 {
            var meter = PodcastDownloadByteMeter(episodeID: episodeID, startedAt: now)
            meter.receive(64)
            let amount = try XCTUnwrap(meter.pendingAmount)
            let admitted = try await store.recordLifetimeMeasureCheckpoint(amount, ownerKey: meter.ownerKey, at: now)
            XCTAssertEqual(admitted, try bytes(64))
        }
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 128)
    }

    /// A legacy contribution moves the ready summary's `updatedAt` just as a
    /// measured one does; a deduplicated retry leaves it alone.
    func testLegacyContributionAdvancesSummaryUpdatedAtOnlyWhenAdmitted() async throws {
        let store = try LocalLibraryStore(url: try makeStoreURL())
        let backdated = Date(timeIntervalSince1970: 1_000)
        _ = try await store.recordLifetimeMeasure(id: "backdate|1", try time(.playedTime, 1), at: backdated)
        let before = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(before.updatedAt, backdated)

        let admitted = try await store.recordLifetimeStatistic(id: "legacy|a", kind: .speechGenerated, seconds: 2)
        XCTAssertTrue(admitted)
        let after = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(after.legacy.speechGeneratedSeconds, 2)
        XCTAssertGreaterThan(try XCTUnwrap(after.updatedAt), backdated, "a legacy write advances updatedAt")

        _ = try await store.recordLifetimeMeasure(id: "backdate|2", try time(.playedTime, 1), at: backdated)
        let duplicate = try await store.recordLifetimeStatistic(id: "legacy|a", kind: .speechGenerated, seconds: 2)
        XCTAssertFalse(duplicate)
        let unchanged = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(unchanged.updatedAt, backdated, "a deduplicated retry changes nothing")
    }
}
