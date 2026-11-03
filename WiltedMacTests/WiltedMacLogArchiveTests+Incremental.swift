import Foundation
import OSLog
import XCTest
@testable import WiltedMac

extension WiltedMacLogArchiveTests {
    func testIncrementalSourceWindowPushesCursorIntoQueryAndReadsOnlyOverlapAndNew() async throws {
        let file = try makeFile("incremental-cursor", maximumBytes: 100_000, backupCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let early = makeEntry("incr-early-marker", date: base.addingTimeInterval(10))
        let newest = makeEntry("incr-newest-marker", date: base.addingTimeInterval(100))

        let recordedCursors = LockedArray<Date?>()
        let allEntries = LockedLogEntries([early, newest])

        let archive = WiltedMacLogArchive(file: file, source: { since in
            recordedCursors.append(since)
            let snapshot = allEntries.snapshot
            if let since {
                return snapshot.filter { $0.date >= since }
            }
            return snapshot
        })

        // Pass 1: cursor must be nil (query from beginning)
        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(recordedCursors.values.count, 1)
        XCTAssertNil(recordedCursors.values[0])

        // Add:
        // - an expired entry at base + 20 (older than 100 - lateness(60) = 40)
        // - a late arrival entry at base + 80 (within lateness window)
        // - a brand new entry at base + 120
        let expired = makeEntry("incr-expired-marker", date: base.addingTimeInterval(20))
        let lateArrival = makeEntry("incr-late-arrival", date: base.addingTimeInterval(80))
        let brandNew = makeEntry("incr-brand-new", date: base.addingTimeInterval(120))
        allEntries.replace(with: [early, expired, lateArrival, newest, brandNew])

        // Pass 2: cursor pushed into query must be newestWritten - lateness (100 - 60 = 40)
        let secondCount = await archive.archivePass()
        XCTAssertEqual(secondCount, 2, "only the late arrival and brand new entry are written")
        XCTAssertEqual(recordedCursors.values.count, 2)
        let pass2Cursor = try XCTUnwrap(recordedCursors.values[1])
        XCTAssertEqual(pass2Cursor, newest.date.addingTimeInterval(-WiltedMacLogArchive.lateness))

        // Pass 3: no new entries -> 0 written
        let thirdCount = await archive.archivePass()
        XCTAssertEqual(thirdCount, 0)
        XCTAssertEqual(recordedCursors.values.count, 3)
        let pass3Cursor = try XCTUnwrap(recordedCursors.values[2])
        XCTAssertEqual(pass3Cursor, brandNew.date.addingTimeInterval(-WiltedMacLogArchive.lateness))

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.count, 4)
        XCTAssertTrue(rendered.contains { $0.contains("incr-early-marker") })
        XCTAssertTrue(rendered.contains { $0.contains("incr-newest-marker") })
        XCTAssertTrue(rendered.contains { $0.contains("incr-late-arrival") })
        XCTAssertTrue(rendered.contains { $0.contains("incr-brand-new") })
        XCTAssertFalse(rendered.contains { $0.contains("incr-expired-marker") })
    }

    func testProductionSourceReducesRealEnumerationWithDatePredicateAndOverlap() async throws {
        let oldMarker = "prod-old-" + UUID().uuidString
        let newMarker = "prod-new-" + UUID().uuidString
        let logger = Logger(
            subsystem: "com.zerodelta.wilted.mac.tests",
            category: "IncrementalArchive"
        )

        // 1. Log synthetic old entry
        logger.error("old entry \(oldMarker, privacy: .public)")

        let source = WiltedMacLogArchive.currentProcessSource()
        var oldEntryDate: Date?

        let oldDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < oldDeadline {
            let entries = (try? source(nil)) ?? []
            if let match = entries.first(where: { WiltedMacLogLine.render($0)?.contains(oldMarker) == true }) {
                oldEntryDate = match.date
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let dateOld = try XCTUnwrap(oldEntryDate, "old synthetic entry must be enumerated by production source")

        // 2. Log synthetic new entry after old entry
        try await Task.sleep(for: .milliseconds(20))
        logger.error("new entry \(newMarker, privacy: .public)")

        var allEntries: [WiltedMacLogArchiveEntry] = []
        var newEntryDate: Date?
        let newDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < newDeadline {
            let entries = (try? source(nil)) ?? []
            if let match = entries.first(where: { WiltedMacLogLine.render($0)?.contains(newMarker) == true }) {
                allEntries = entries
                newEntryDate = match.date
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(allEntries.contains { WiltedMacLogLine.render($0)?.contains(oldMarker) == true })
        XCTAssertTrue(allEntries.contains { WiltedMacLogLine.render($0)?.contains(newMarker) == true })

        // 3. Date-restricted query: choose a point between the two captured timestamps.
        // Must exclude old entry and reduce real enumeration
        let dateNew = try XCTUnwrap(newEntryDate, "new synthetic entry must be enumerated by production source")
        XCTAssertGreaterThan(dateNew, dateOld, "the new log record must have a later source timestamp")
        let restrictedSince = dateOld.addingTimeInterval(dateNew.timeIntervalSince(dateOld) / 2)
        let restrictedEntries = try source(restrictedSince)

        XCTAssertTrue(
            restrictedEntries.contains { WiltedMacLogLine.render($0)?.contains(newMarker) == true },
            "date-restricted query must contain the new entry"
        )
        XCTAssertFalse(
            restrictedEntries.contains { WiltedMacLogLine.render($0)?.contains(oldMarker) == true },
            "date-restricted query must NOT contain the old entry"
        )
        XCTAssertLessThan(
            restrictedEntries.count, allEntries.count,
            "date-restricted query must enumerate fewer entries than unrestricted query"
        )

        // 4. Overlap query: since is before dateOld (within lateness overlap)
        let overlapSince = dateOld.addingTimeInterval(-10)
        let overlapEntries = try source(overlapSince)

        XCTAssertTrue(
            overlapEntries.contains { WiltedMacLogLine.render($0)?.contains(oldMarker) == true },
            "overlap query must preserve entries within the lateness window"
        )
        XCTAssertTrue(
            overlapEntries.contains { WiltedMacLogLine.render($0)?.contains(newMarker) == true },
            "overlap query must contain the new entry"
        )
    }

    func testDuplicateTimestampsArePreservedAcrossPassesWithCursor() async throws {
        let file = try makeFile("incr-duplicate-timestamps", maximumBytes: 100_000, backupCount: 2)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let marker = "dup-timestamp-marker"

        let entry1 = makeEntry(marker, date: timestamp)
        let entry2 = makeEntry(marker, date: timestamp)
        let box = LockedLogEntries([entry1])

        let archive = WiltedMacLogArchive(file: file, source: { since in
            let snapshot = box.snapshot
            if let since {
                return snapshot.filter { $0.date >= since }
            }
            return snapshot
        })

        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 1)

        // Second pass has both entries (duplicate timestamps with same date and line)
        box.replace(with: [entry1, entry2])
        let secondCount = await archive.archivePass()
        XCTAssertEqual(secondCount, 1, "second occurrence at identical timestamp is written on next pass")

        let thirdCount = await archive.archivePass()
        XCTAssertEqual(thirdCount, 0, "no further writes once all duplicate occurrences are archived")

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.filter { $0.contains(marker) }.count, 2)
    }

    func testLateOverlappingPassUsesNewestPostReadHorizon() async throws {
        let file = try makeFile("incr-overlapping-passes", maximumBytes: 100_000, backupCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let old = makeEntry("overlap-old-marker", date: base)
        let newest = makeEntry("overlap-newest-marker", date: base.addingTimeInterval(100))
        let source = HeldFirstLogRead([old, newest])
        let archive = WiltedMacLogArchive(file: file, source: { since in source.read(since: since) })

        async let delayedPass = archive.archivePass()
        guard source.waitForFirstRead() == .success else {
            source.releaseFirstRead()
            _ = await delayedPass
            XCTFail("the first source read should be held")
            return
        }

        // This second pass captured the same initial cursor, but completes first and advances
        // the archive horizon far enough to prune the old entry's duplicate count.
        let newerPassCount = await archive.archivePass()
        XCTAssertEqual(newerPassCount, 2)

        source.releaseFirstRead()
        let delayedPassCount = await delayedPass
        XCTAssertEqual(delayedPassCount, 0, "the late pass sees the post-read horizon and writes nothing")

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.filter { $0.contains("overlap-old-marker") }.count, 1)
        XCTAssertEqual(rendered.filter { $0.contains("overlap-newest-marker") }.count, 1)
    }

    func testPartialWriteFailureRetriesOnNextPassWithoutDuplicatingCommittedLines() async throws {
        let directory = try makeDirectory("incr-partial-write")
        let writeAttempts = LockedCounter()

        let file = WiltedMacRotatingLogFile(
            url: directory.appendingPathComponent("wilted.log"),
            maximumBytes: 100_000,
            backupCount: 2
        ) { handle, data in
            if writeAttempts.increment() == 2 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: data)
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = makeEntry("partial-e1", date: base)
        let e2 = makeEntry("partial-e2", date: base.addingTimeInterval(10))
        let e3 = makeEntry("partial-e3", date: base.addingTimeInterval(20))

        let requestedCursors = LockedArray<Date?>()
        let box = LockedLogEntries([e1, e2, e3])

        let archive = WiltedMacLogArchive(file: file, source: { since in
            requestedCursors.append(since)
            let snapshot = box.snapshot
            if let since {
                return snapshot.filter { $0.date >= since }
            }
            return snapshot
        })

        // Pass 1: fail on second write
        let count1 = await archive.archivePass()
        XCTAssertEqual(count1, 1, "only first entry landed before write failure")

        // Pass 2: next pass retries with cursor = e1.date - lateness
        let count2 = await archive.archivePass()
        XCTAssertEqual(count2, 2, "remaining entries are written without duplicating the first")

        XCTAssertEqual(requestedCursors.values.count, 2)
        let retryCursor = try XCTUnwrap(requestedCursors.values[1])
        XCTAssertEqual(retryCursor, e1.date.addingTimeInterval(-WiltedMacLogArchive.lateness))

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.count, 3)
        XCTAssertEqual(rendered.filter { $0.contains("partial-e1") }.count, 1)
        XCTAssertEqual(rendered.filter { $0.contains("partial-e2") }.count, 1)
        XCTAssertEqual(rendered.filter { $0.contains("partial-e3") }.count, 1)
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }

    var values: [Element] {
        lock.withLock { elements }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Holds the first off-actor source read so a later archive pass can finish first.
private final class HeldFirstLogRead: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadEntered = DispatchSemaphore(value: 0)
    private let releaseFirstReadSignal = DispatchSemaphore(value: 0)
    private let entries: [WiltedMacLogArchiveEntry]
    private var readCount = 0

    init(_ entries: [WiltedMacLogArchiveEntry]) {
        self.entries = entries
    }

    func read(since: Date?) -> [WiltedMacLogArchiveEntry] {
        let isFirst = lock.withLock { () -> Bool in
            defer { readCount += 1 }
            return readCount == 0
        }
        if isFirst {
            firstReadEntered.signal()
            _ = releaseFirstReadSignal.wait(timeout: .now() + 10)
        }
        guard let since else { return entries }
        return entries.filter { $0.date >= since }
    }

    func waitForFirstRead() -> DispatchTimeoutResult {
        firstReadEntered.wait(timeout: .now() + 5)
    }

    func releaseFirstRead() {
        releaseFirstReadSignal.signal()
    }
}
